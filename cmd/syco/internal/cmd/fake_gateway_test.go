package cmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

// testWorkspace is the workspace the test profile names.
const testWorkspace = "w-test"

// fakeGateway plays the relay's client-facing protocol on a loopback port.
// It acks every ChannelReceive with a fresh channel ID and then sends only
// the frames a test pushes onto that stream. It acks ChannelIngest with the
// conversation the request names, or with freshID when it names none, and
// from then on that conversation's history holds the user's message. It
// answers GetConversationHistory with the scripted entries for conversations
// it knows and NotFound for any other ID, and GetTurnState with the scripted
// state (IDLE unless a test sets another).
type fakeGateway struct {
	relaypb.UnimplementedRelayGatewayServer

	addr string

	mu        sync.Mutex
	history   map[string][]*commonpb.HistoryEntry
	turnState commonpb.TurnState
	freshID   string
	channels  int

	streamCh chan *fakeStream
	ingestCh chan struct{}
}

// fakeStream is one open ChannelReceive. Frames pushed onto it are sent in
// order; end() closes the stream after every pushed frame has gone out.
type fakeStream struct {
	channelID string
	frames    chan *commonpb.ChannelOutbound
	endOnce   sync.Once
}

func (s *fakeStream) push(frames ...*commonpb.ChannelOutbound) {
	for _, f := range frames {
		s.frames <- f
	}
}

func (s *fakeStream) end() {
	s.endOnce.Do(func() { close(s.frames) })
}

func startFakeGateway(t *testing.T) *fakeGateway {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	f := &fakeGateway{
		addr:      lis.Addr().String(),
		history:   make(map[string][]*commonpb.HistoryEntry),
		turnState: commonpb.TurnState_TURN_STATE_IDLE,
		freshID:   "conv-fresh",
		streamCh:  make(chan *fakeStream, 16),
		ingestCh:  make(chan struct{}, 16),
	}
	srv := grpc.NewServer()
	relaypb.RegisterRelayGatewayServer(srv, f)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	return f
}

// setHistory makes the fake know conversation id with exactly these entries.
func (f *fakeGateway) setHistory(id string, entries ...*commonpb.HistoryEntry) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.history[id] = append([]*commonpb.HistoryEntry(nil), entries...)
}

// appendHistory adds entries to a conversation the fake already knows.
func (f *fakeGateway) appendHistory(id string, entries ...*commonpb.HistoryEntry) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.history[id] = append(f.history[id], entries...)
}

func (f *fakeGateway) setTurnState(s commonpb.TurnState) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.turnState = s
}

func (f *fakeGateway) setFreshID(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.freshID = id
}

// nextStream waits for the next ChannelReceive the client opens.
func (f *fakeGateway) nextStream(t *testing.T, timeout time.Duration) *fakeStream {
	t.Helper()
	select {
	case s := <-f.streamCh:
		return s
	case <-time.After(timeout):
		t.Fatalf("client opened no ChannelReceive within %v", timeout)
		return nil
	}
}

// nextIngest waits for the next ChannelIngest the client sends.
func (f *fakeGateway) nextIngest(t *testing.T, timeout time.Duration) {
	t.Helper()
	select {
	case <-f.ingestCh:
	case <-time.After(timeout):
		t.Fatalf("client sent no ChannelIngest within %v", timeout)
	}
}

func (f *fakeGateway) ChannelReceive(
	_ *commonpb.ChannelReceiveRequest,
	stream grpc.ServerStreamingServer[commonpb.ChannelOutbound],
) error {
	f.mu.Lock()
	f.channels++
	s := &fakeStream{
		channelID: fmt.Sprintf("chan-%d", f.channels),
		frames:    make(chan *commonpb.ChannelOutbound, 64),
	}
	f.mu.Unlock()

	ack := &commonpb.ChannelOutbound{
		Command: &commonpb.ChannelOutbound_Ack{Ack: &commonpb.ChannelAck{ChannelId: s.channelID}},
	}
	if err := stream.Send(ack); err != nil {
		return err
	}
	f.streamCh <- s
	for {
		select {
		case <-stream.Context().Done():
			return nil
		case frame, ok := <-s.frames:
			if !ok {
				return nil
			}
			if err := stream.Send(frame); err != nil {
				return err
			}
		}
	}
}

func (f *fakeGateway) ChannelIngest(
	_ context.Context,
	req *commonpb.ChannelIngestRequest,
) (*commonpb.ChannelIngestAck, error) {
	f.mu.Lock()
	id := req.GetConversationId()
	if id == "" {
		id = f.freshID
		f.history[id] = nil
	}
	if _, known := f.history[id]; known && req.GetUserMessage() != nil {
		f.history[id] = append(f.history[id], &commonpb.HistoryEntry{
			Message: &commonpb.Message{Role: "user", Content: req.GetUserMessage().GetContent()},
		})
	}
	f.mu.Unlock()
	f.ingestCh <- struct{}{}
	return &commonpb.ChannelIngestAck{ChannelId: req.GetChannelId(), ConversationId: id}, nil
}

func (f *fakeGateway) GetConversationHistory(
	_ context.Context,
	req *commonpb.GetConversationHistoryRequest,
) (*commonpb.GetConversationHistoryResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	entries, known := f.history[req.GetConversationId()]
	if !known {
		return nil, status.Error(codes.NotFound, "conversation_id not found")
	}
	out := make([]*commonpb.HistoryEntry, len(entries))
	copy(out, entries)
	return &commonpb.GetConversationHistoryResponse{Entries: out}, nil
}

func (f *fakeGateway) GetTurnState(
	_ context.Context,
	req *commonpb.GetTurnStateRequest,
) (*commonpb.TurnStateEvent, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return &commonpb.TurnStateEvent{State: f.turnState, ConversationId: req.GetConversationId()}, nil
}

// --- Protocol values ---

func textContent(text string) []*commonpb.ContentBlock {
	return []*commonpb.ContentBlock{{Block: &commonpb.ContentBlock_Text{Text: &commonpb.TextBlock{Text: text}}}}
}

func userEntry(text string) *commonpb.HistoryEntry {
	return &commonpb.HistoryEntry{Message: &commonpb.Message{Role: "user", Content: textContent(text)}}
}

func assistantEntry(text string) *commonpb.HistoryEntry {
	return &commonpb.HistoryEntry{Message: &commonpb.Message{Role: "assistant", Content: textContent(text)}}
}

func turnStateFrame(conversationID string, state commonpb.TurnState) *commonpb.ChannelOutbound {
	return &commonpb.ChannelOutbound{
		Command: &commonpb.ChannelOutbound_TurnState{
			TurnState: &commonpb.TurnStateEvent{State: state, ConversationId: conversationID},
		},
	}
}

// streamTextFrames is one streamed text item for a conversation: start,
// one delta carrying text, stop.
func streamTextFrames(conversationID, itemID, text string) []*commonpb.ChannelOutbound {
	item := func(phase func(*commonpb.StreamItem)) *commonpb.ChannelOutbound {
		si := &commonpb.StreamItem{ItemId: itemID, ConversationId: conversationID}
		phase(si)
		return &commonpb.ChannelOutbound{Command: &commonpb.ChannelOutbound_StreamItem{StreamItem: si}}
	}
	return []*commonpb.ChannelOutbound{
		item(func(si *commonpb.StreamItem) {
			si.Phase = &commonpb.StreamItem_Start{Start: &commonpb.ItemStart{
				Kind: &commonpb.ItemStart_Text{Text: &commonpb.TextItem{}},
			}}
		}),
		item(func(si *commonpb.StreamItem) {
			si.Phase = &commonpb.StreamItem_Delta{Delta: &commonpb.ItemDelta{
				Kind: &commonpb.ItemDelta_TextDelta{TextDelta: text},
			}}
		}),
		item(func(si *commonpb.StreamItem) {
			si.Phase = &commonpb.StreamItem_Stop{Stop: &commonpb.ItemStop{}}
		}),
	}
}

// --- Client environment ---

// newClientEnv starts a fake gateway and points a fresh SYCO_CONFIG_DIR at
// it: one profile naming the fake as server and testWorkspace as workspace,
// with a JWT-shaped token that expires in an hour. Returns the fake and the
// config directory.
func newClientEnv(t *testing.T) (*fakeGateway, string) {
	t.Helper()
	f := startFakeGateway(t)
	dir := t.TempDir()
	t.Setenv("SYCO_CONFIG_DIR", dir)
	t.Setenv("SYCO_PROFILE", "")
	t.Setenv("SYCO_SERVER", "")
	t.Setenv("SYCO_WORKSPACE", "")

	cfg := fmt.Sprintf("[default]\nprofile = \"test\"\n\n[profile.test]\nserver = %q\nworkspace = %q\n",
		f.addr, testWorkspace)
	if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	creds := fmt.Sprintf("[test]\ntoken = %q\n", futureToken(t))
	if err := os.WriteFile(filepath.Join(dir, "credentials.toml"), []byte(creds), 0o600); err != nil {
		t.Fatal(err)
	}
	return f, dir
}

func futureToken(t *testing.T) string {
	t.Helper()
	enc := base64.RawURLEncoding
	payload, err := json.Marshal(map[string]any{"sub": "tester", "exp": time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	return enc.EncodeToString([]byte(`{"alg":"none"}`)) + "." + enc.EncodeToString(payload) + ".sig"
}

// saveHistoryLine appends a history line for the test workspace with the
// client's own history writer.
func saveHistoryLine(t *testing.T, dir, conversationID string) {
	t.Helper()
	if err := config.AppendHistory(dir, conversationID, testWorkspace); err != nil {
		t.Fatal(err)
	}
}

// makeLeftoverConfig adds what an earlier cluster leaves behind: a message
// number cursor of 727 for the workspace and a newest history line naming
// a conversation the fake does not know.
func makeLeftoverConfig(t *testing.T, dir, unknownID string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "cursors"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cursors", testWorkspace+".seq"), []byte("727\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	saveHistoryLine(t, dir, unknownID)
}

// --- Running the chat command ---

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// chatRun is one `syco chat ...` executing through the root command in the
// background.
type chatRun struct {
	stdout, stderr *syncBuffer
	done           chan error
}

func startChat(args ...string) *chatRun {
	r := &chatRun{stdout: &syncBuffer{}, stderr: &syncBuffer{}, done: make(chan error, 1)}
	root := Root()
	root.SetArgs(append([]string{"chat"}, args...))
	root.SetOut(r.stdout)
	root.SetErr(r.stderr)
	go func() { r.done <- root.Execute() }()
	return r
}

// wait returns the command's error, or fails the test if it has not
// returned within timeout.
func (r *chatRun) wait(t *testing.T, timeout time.Duration) error {
	t.Helper()
	select {
	case err := <-r.done:
		return err
	case <-time.After(timeout):
		t.Fatalf("chat command did not return within %v\nstdout: %q\nstderr: %q",
			timeout, r.stdout.String(), r.stderr.String())
		return nil
	}
}
