// Tests for how syco answers the harness's tool-call approval requests: the
// one-shot command reads one line of standard input per request, the TUI
// takes a y or n key. Both run against the fake relay gateway.

package cmd

import (
	"encoding/json"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

const (
	approvalMethod = "RequestToolApproval"
	approvalTool   = "Bash"
	approvalInput  = `{"cmd":"ls /srv/ApprovalInputOcelot"}`
)

// approvalParams is an otherwise valid request's params_json for tool and
// input.
func approvalParams(t *testing.T, tool, input string) string {
	t.Helper()
	b, err := json.Marshal(map[string]string{"tool": tool, "input": input})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// approvalRequest is an otherwise valid approval request for approvalTool
// and approvalInput.
func approvalRequest(t *testing.T, requestID string) *commonpb.ChannelStreamOutbound {
	t.Helper()
	return serverRequestFrame(requestID, approvalMethod, approvalParams(t, approvalTool, approvalInput))
}

// oneShotTurn starts `syco chat` with stdin on a fresh conversation and
// waits for its user message, then marks the turn running. It returns the
// fake, the run, and the open stream.
func oneShotTurn(t *testing.T, conv string, stdin io.Reader) (*fakeGateway, *chatRun, *fakeStream) {
	t.Helper()
	f, _ := newClientEnv(t)
	f.setFreshID(conv)
	run := startChatWithStdin(stdin, "hello")
	stream := f.nextStream(t, 5*time.Second)
	f.nextIngest(t, 5*time.Second)
	stream.push(turnStateFrame(conv, commonpb.TurnState_TURN_STATE_WORKING))
	return f, run, stream
}

// endTurn finishes the turn and waits for the command to return.
func endTurn(t *testing.T, run *chatRun, stream *fakeStream, conv string) {
	t.Helper()
	stream.push(turnStateFrame(conv, commonpb.TurnState_TURN_STATE_IDLE))
	if err := run.wait(t, 10*time.Second); err != nil {
		t.Fatalf("turn failed: %v\nstderr: %s", err, run.stderr.String())
	}
}

// approvedOf is the answer a ClientResponse ingest carries. Its result_json
// must be exactly an object holding a boolean approved.
func approvedOf(t *testing.T, ingest *commonpb.ChannelStreamIngestRequest) bool {
	t.Helper()
	var got map[string]any
	if err := json.Unmarshal([]byte(ingest.GetClientResponse().GetResultJson()), &got); err != nil {
		t.Fatalf("result_json %q is not a JSON object: %v", ingest.GetClientResponse().GetResultJson(), err)
	}
	approved, ok := got["approved"].(bool)
	if !ok || len(got) != 1 {
		t.Fatalf("result_json %q is not {\"approved\":<bool>}", ingest.GetClientResponse().GetResultJson())
	}
	return approved
}

// assertAnswer checks one answer: its request id and its approval.
func assertAnswer(t *testing.T, ingest *commonpb.ChannelStreamIngestRequest, requestID string, approved bool) {
	t.Helper()
	if got := ingest.GetClientResponse().GetRequestId(); got != requestID {
		t.Fatalf("answer echoes request_id %q, want %q", got, requestID)
	}
	if got := approvedOf(t, ingest); got != approved {
		t.Fatalf("answer to %s is approved=%v, want %v", requestID, got, approved)
	}
}

func advertisesApproval(ingest *commonpb.ChannelStreamIngestRequest) bool {
	return slices.Equal(ingest.GetSupportedMethods(), []string{approvalMethod})
}

// endlessYes is standard input that never ends: `y` lines, as `yes` writes.
type endlessYes struct{ newline bool }

func (e *endlessYes) Read(p []byte) (int, error) {
	for i := range p {
		if e.newline {
			p[i] = '\n'
		} else {
			p[i] = 'y'
		}
		e.newline = !e.newline
	}
	return len(p), nil
}

// --- One-shot ---

func TestOneShotUserMessageAdvertisesOnlyRequestToolApproval(t *testing.T) {
	f, run, stream := oneShotTurn(t, "conv-advertise-oneshot", strings.NewReader(""))

	if first := f.ingestLog()[0]; !advertisesApproval(first) {
		t.Fatalf("user-message ingest carries supported_methods %q, want [%s]", first.GetSupportedMethods(), approvalMethod)
	}
	endTurn(t, run, stream, "conv-advertise-oneshot")
}

func TestOneShotShowsTheRequestedToolAndInput(t *testing.T) {
	const conv = "conv-show-oneshot"
	_, run, stream := oneShotTurn(t, conv, strings.NewReader("n\n"))
	stream.push(approvalRequest(t, "req-show"))

	deadline := time.Now().Add(5 * time.Second)
	for {
		out := run.stdout.String()
		if strings.Contains(out, approvalTool) && strings.Contains(out, approvalInput) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stdout does not show tool %q and input %q:\n%s", approvalTool, approvalInput, out)
		}
		time.Sleep(20 * time.Millisecond)
	}
	endTurn(t, run, stream, conv)
}

func TestOneShotAnswersEachApprovalOnceFromOneLineOfStdin(t *testing.T) {
	cases := []struct {
		name     string
		stdin    string
		approved bool
	}{
		{"yes approves", "yes\n", true},
		{"y in any case with surrounding whitespace approves", "  Y \n", true},
		{"YeS in any case approves", "YeS\n", true},
		{"no denies", "no\n", false},
		{"any other line denies", "yep\n", false},
		{"end of input denies", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			const conv = "conv-answer-oneshot"
			f, run, stream := oneShotTurn(t, conv, strings.NewReader(tc.stdin))
			stream.push(approvalRequest(t, "req-answer"))

			assertAnswer(t, f.nextResponse(t, 5*time.Second), "req-answer", tc.approved)
			f.noResponse(t, 300*time.Millisecond)
			endTurn(t, run, stream, conv)
		})
	}
}

func TestOneShotApprovalAnswerAdvertisesTheMethodOnTheCurrentStreamWithNoConversation(t *testing.T) {
	const conv = "conv-answer-envelope"
	f, run, stream := oneShotTurn(t, conv, strings.NewReader("y\n"))
	stream.push(approvalRequest(t, "req-envelope"))

	answer := f.nextResponse(t, 5*time.Second)
	if !advertisesApproval(answer) {
		t.Fatalf("answer ingest carries supported_methods %q, want [%s]", answer.GetSupportedMethods(), approvalMethod)
	}
	if got := answer.GetChannelStreamId(); got != stream.channelStreamID {
		t.Fatalf("answer went on channel stream %q, want the current %q", got, stream.channelStreamID)
	}
	if got := answer.GetConversationId(); got != "" {
		t.Fatalf("answer names conversation %q, want none", got)
	}
	if answer.GetUserMessage() != nil {
		t.Fatalf("answer carries a user message: %v", answer.GetUserMessage())
	}
	endTurn(t, run, stream, conv)
}

func TestOneShotWithEndlessYesInputApprovesEveryRequestAndReturnsWhenTheTurnEnds(t *testing.T) {
	const conv = "conv-endless-yes"
	f, run, stream := oneShotTurn(t, conv, &endlessYes{})
	stream.push(approvalRequest(t, "req-1"))
	assertAnswer(t, f.nextResponse(t, 5*time.Second), "req-1", true)
	stream.push(approvalRequest(t, "req-2"))
	assertAnswer(t, f.nextResponse(t, 5*time.Second), "req-2", true)

	endTurn(t, run, stream, conv)
}

// --- TUI ---

func isServerRequestFrame(msg tea.Msg) bool {
	fm, ok := msg.(frameMsg)
	return ok && fm.frame.GetServerRequest() != nil
}

// tuiTurn opens the TUI on a fresh conversation, sends a message, and marks
// the turn running.
func tuiTurn(t *testing.T, conv string) (*fakeGateway, *tuiDriver, *fakeStream) {
	t.Helper()
	f, _ := newClientEnv(t)
	f.setFreshID(conv)
	d := openTUI(t, false, "")
	stream := f.nextStream(t, 5*time.Second)
	d.send("UserApprovalMessageLynx")
	stream.push(turnStateFrame(conv, commonpb.TurnState_TURN_STATE_WORKING))
	return f, d, stream
}

func TestTUIUserMessageAdvertisesOnlyRequestToolApproval(t *testing.T) {
	f, _, _ := tuiTurn(t, "conv-advertise-tui")

	if first := f.ingestLog()[0]; !advertisesApproval(first) {
		t.Fatalf("user-message ingest carries supported_methods %q, want [%s]", first.GetSupportedMethods(), approvalMethod)
	}
}

func TestTUIShowsTheRequestedToolAndInput(t *testing.T) {
	_, d, stream := tuiTurn(t, "conv-show-tui")
	stream.push(approvalRequest(t, "req-show"))

	d.waitView("the requested tool and input", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, approvalTool) && strings.Contains(v, approvalInput)
	})
}

func TestTUIAnswersAShownApprovalOnceWithTheYOrNKey(t *testing.T) {
	cases := []struct {
		key      rune
		approved bool
	}{
		{'y', true},
		{'n', false},
	}
	for _, tc := range cases {
		t.Run(string(tc.key), func(t *testing.T) {
			f, d, stream := tuiTurn(t, "conv-answer-tui")
			stream.push(approvalRequest(t, "req-key"))
			d.waitMsg("the approval request frame", 5*time.Second, isServerRequestFrame)

			d.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{tc.key}})
			answer := f.nextResponse(t, 5*time.Second)
			assertAnswer(t, answer, "req-key", tc.approved)
			if !advertisesApproval(answer) {
				t.Fatalf("answer ingest carries supported_methods %q, want [%s]", answer.GetSupportedMethods(), approvalMethod)
			}
			if got := answer.GetChannelStreamId(); got != stream.channelStreamID {
				t.Fatalf("answer went on channel stream %q, want the current %q", got, stream.channelStreamID)
			}
			if got := answer.GetConversationId(); got != "" {
				t.Fatalf("answer names conversation %q, want none", got)
			}

			d.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{tc.key}})
			f.noResponse(t, 300*time.Millisecond)
		})
	}
}
