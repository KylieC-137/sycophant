// The tests in this file enter the TUI through openTUIModel, the function
// that builds the TUI model for a profile and flags and opens a named
// conversation before the full-screen program starts.

package cmd

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

const thinking = "thinking…"

// tuiDriver runs a TUI model without a terminal, the way the program would:
// every command runs on its own goroutine and its message comes back to
// Update on the test goroutine, one at a time.
type tuiDriver struct {
	t     *testing.T
	model tea.Model
	msgs  chan tea.Msg
	done  chan struct{}
}

// openTUI builds the model through openTUIModel for the test profile and
// the given flags, runs Init, and sizes the window to show the whole
// transcript.
func openTUI(t *testing.T, continueFlag bool, resumeID string) *tuiDriver {
	t.Helper()
	cfgDir := config.ConfigDir()
	p, err := config.LoadProfile(cfgDir, "", "")
	if err != nil {
		t.Fatal(err)
	}
	token, err := config.LoadToken(cfgDir, p.Name)
	if err != nil {
		t.Fatal(err)
	}
	model, err := openTUIModel(cfgDir, p, token, continueFlag, resumeID, nil)
	if err != nil {
		t.Fatalf("openTUIModel: %v", err)
	}
	d := &tuiDriver{t: t, model: model, msgs: make(chan tea.Msg, 256), done: make(chan struct{})}
	t.Cleanup(func() { close(d.done) })
	d.run(model.Init())
	d.update(tea.WindowSizeMsg{Width: 160, Height: 200})
	return d
}

func (d *tuiDriver) run(cmd tea.Cmd) {
	if cmd == nil {
		return
	}
	go func() { d.post(cmd()) }()
}

func (d *tuiDriver) post(msg tea.Msg) {
	if msg == nil {
		return
	}
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, c := range batch {
			d.run(c)
		}
		return
	}
	select {
	case d.msgs <- msg:
	case <-d.done:
	}
}

func (d *tuiDriver) update(msg tea.Msg) {
	var cmd tea.Cmd
	d.model, cmd = d.model.Update(msg)
	d.run(cmd)
}

// view is the rendered view with ANSI escapes stripped.
func (d *tuiDriver) view() string {
	return ansi.Strip(d.model.View())
}

// waitView feeds messages to the model until cond holds for its view, or
// fails the test at the deadline.
func (d *tuiDriver) waitView(desc string, deadline time.Time, cond func(view string) bool) {
	d.t.Helper()
	for {
		if cond(d.view()) {
			return
		}
		left := time.Until(deadline)
		if left <= 0 {
			d.t.Fatalf("timed out waiting for %s; view:\n%s", desc, d.view())
		}
		select {
		case msg := <-d.msgs:
			d.update(msg)
		case <-time.After(min(left, 50*time.Millisecond)):
		}
	}
}

// waitMsg feeds messages to the model until it has handled one for which
// match holds.
func (d *tuiDriver) waitMsg(desc string, timeout time.Duration, match func(tea.Msg) bool) {
	d.t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case msg := <-d.msgs:
			d.update(msg)
			if match(msg) {
				return
			}
		case <-deadline:
			d.t.Fatalf("timed out waiting for %s; view:\n%s", desc, d.view())
		}
	}
}

func isIngestAck(msg tea.Msg) bool {
	_, ok := msg.(ingestAckMsg)
	return ok
}

// send types text into the input and presses Enter once the TUI is
// connected, then waits until the TUI has handled the ingest ack.
func (d *tuiDriver) send(text string) {
	d.t.Helper()
	d.waitView("the TUI to connect", time.Now().Add(5*time.Second), func(v string) bool {
		return !strings.Contains(v, "disconnected") && !strings.Contains(v, "Connecting…")
	})
	d.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(text)})
	d.update(tea.KeyMsg{Type: tea.KeyEnter})
	d.waitMsg("the ingest ack", 5*time.Second, isIngestAck)
}

func TestTUISavesNewConversationIDAtAckBeforeTurnEnds(t *testing.T) {
	f, dir := newClientEnv(t)
	const conv = "conv-new-tui"
	f.setFreshID(conv)

	d := openTUI(t, false, "")
	d.send("UserNewMessageOtter")

	if e, err := config.HistoryLastForWorkspace(dir, testWorkspace); err != nil || e.ConversationID != conv {
		t.Fatalf("history holds no line for %s in %s after the ack while the turn is still running", conv, testWorkspace)
	}
}

func TestTUIOpenOnFinishedTurnShowsUserAndAssistantHistory(t *testing.T) {
	f, dir := newClientEnv(t)
	const conv = "conv-open-idle"
	f.setHistory(conv, userEntry("UserEarlierPelican"), assistantEntry("AssistantEarlierQuokka"))
	saveHistoryLine(t, dir, conv)

	d := openTUI(t, true, "")
	d.waitView("the history's user and assistant text", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, "UserEarlierPelican") && strings.Contains(v, "AssistantEarlierQuokka")
	})
}

func TestTUIOpenOnRunningTurnShowsThinkingThenLiveStreamText(t *testing.T) {
	f, dir := newClientEnv(t)
	const conv = "conv-open-working"
	f.setHistory(conv, userEntry("UserPendingHeron"))
	f.setTurnState(commonpb.TurnState_TURN_STATE_WORKING)
	saveHistoryLine(t, dir, conv)

	d := openTUI(t, true, "")
	stream := f.nextStream(t, 5*time.Second)
	d.waitView("the thinking indicator", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, thinking)
	})

	stream.push(streamTextFrames(conv, "item-live", "StreamLiveIbis")...)
	stream.push(turnStateFrame(conv, commonpb.TurnState_TURN_STATE_IDLE))
	d.waitView("the live stream text", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, "StreamLiveIbis")
	})
}

func TestTUIAfterDropRedrawsFromHistoryWithoutPreDropTextOrThinking(t *testing.T) {
	f, dir := newClientEnv(t)
	const (
		conv    = "conv-tui-drop"
		preDrop = "StreamPredropMarmot"
		final   = "AssistantFinalNarwhal"
	)
	f.setHistory(conv, userEntry("UserEarlierPelican"), assistantEntry("AssistantEarlierQuokka"))
	saveHistoryLine(t, dir, conv)

	d := openTUI(t, true, "")
	first := f.nextStream(t, 5*time.Second)
	d.send("UserNewMessageOtter")
	first.push(turnStateFrame(conv, commonpb.TurnState_TURN_STATE_WORKING))
	first.push(streamTextFrames(conv, "item-predrop", preDrop)...)
	d.waitView("the pre-drop stream text", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, preDrop)
	})

	// The turn finishes while the stream is down.
	f.appendHistory(conv, assistantEntry(final))
	f.setTurnState(commonpb.TurnState_TURN_STATE_IDLE)
	first.end()
	d.waitView("the reply from history with no pre-drop text and no thinking indicator",
		time.Now().Add(10*time.Second), func(v string) bool {
			return strings.Contains(v, final) && !strings.Contains(v, preDrop) && !strings.Contains(v, thinking)
		})
}

func TestOneShotThenTUITurnLeaveNoCursorsEntry(t *testing.T) {
	f, dir := newClientEnv(t)

	const oneShotConv = "conv-cursorless-oneshot"
	f.setFreshID(oneShotConv)
	run := startChat("hello")
	first := f.nextStream(t, 5*time.Second)
	f.nextIngest(t, 5*time.Second)
	first.push(turnStateFrame(oneShotConv, commonpb.TurnState_TURN_STATE_WORKING))
	first.push(streamTextFrames(oneShotConv, "item-1", "OneShotReplyGecko")...)
	first.push(turnStateFrame(oneShotConv, commonpb.TurnState_TURN_STATE_IDLE))
	if err := run.wait(t, 10*time.Second); err != nil {
		t.Fatalf("one-shot turn failed: %v", err)
	}

	const tuiConv = "conv-cursorless-tui"
	f.setFreshID(tuiConv)
	d := openTUI(t, false, "")
	second := f.nextStream(t, 5*time.Second)
	d.send("UserSecondMessageKiwi")
	second.push(turnStateFrame(tuiConv, commonpb.TurnState_TURN_STATE_WORKING))
	second.push(streamTextFrames(tuiConv, "item-2", "TuiReplyTapir")...)
	second.push(turnStateFrame(tuiConv, commonpb.TurnState_TURN_STATE_IDLE))
	d.waitView("the TUI turn to finish", time.Now().Add(5*time.Second), func(v string) bool {
		return strings.Contains(v, "TuiReplyTapir") && !strings.Contains(v, thinking)
	})
	d.update(tea.KeyMsg{Type: tea.KeyEsc})

	if _, err := os.Lstat(filepath.Join(dir, "cursors")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("config directory has a cursors entry after a one-shot and a TUI turn (stat err: %v)", err)
	}
}
