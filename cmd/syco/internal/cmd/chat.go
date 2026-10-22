package cmd

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-isatty"
	"github.com/spf13/cobra"
	"google.golang.org/grpc"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	"github.com/sycophant-md/sycophant/cmd/syco/internal/grpcclient"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
)

const (
	// heartbeatInterval matches the relay's server-side heartbeat interval.
	heartbeatInterval = 15 * time.Second
	// deadConnectionTimeout triggers a reconnect when no frame arrives within
	// 2× the heartbeat interval.
	deadConnectionTimeout = 2 * heartbeatInterval
	// maxBackoff caps the exponential reconnect delay.
	maxBackoff = 30 * time.Second
)

func newChatCmd() *cobra.Command {
	var (
		continueFlag bool
		resumeID     string
		grants       []string
	)

	cmd := &cobra.Command{
		Use:   "chat [message]",
		Short: "Send a message and stream the reply",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfgDir := config.ConfigDir()
			profileFlag, _ := cmd.Flags().GetString("profile")
			p, err := config.LoadProfile(cfgDir, profileFlag, "")
			if err != nil {
				return err
			}

			token, err := config.LoadToken(cfgDir, p.Name)
			if err != nil {
				return err
			}

			// Parse grants (shared by both paths).
			var grantSelections []*commonpb.GrantSelection
			for _, g := range grants {
				toolset, grant, err := config.ParseGrant(g)
				if err != nil {
					return err
				}
				grantSelections = append(grantSelections, &commonpb.GrantSelection{
					Toolset: toolset,
					Grant:   grant,
				})
			}

			// Interactive TUI mode when no message argument is given.
			// The TUI handles workspace selection if none is set.
			if len(args) == 0 {
				return runTUI(cfgDir, p, token, continueFlag, resumeID, grantSelections)
			}

			// One-shot mode requires a workspace.
			if p.Workspace == "" {
				return fmt.Errorf("workspace is required; set it with `syco session workspace <ws>`")
			}

			// One-shot mode.
			message := args[0]

			// Resolve conversation ID
			var conversationID string
			if continueFlag {
				entry, err := config.HistoryLastForWorkspace(cfgDir, p.Workspace)
				if err != nil {
					return err
				}
				conversationID = entry.ConversationID
			} else if resumeID != "" {
				conversationID = resumeID
			}

			ctx := grpcclient.WithToken(context.Background(), token)

			// Load the cursor for this workspace.
			lastSeq := loadCursor(cfgDir, p.Workspace)

			// Persist on clean exit.
			defer saveCursor(cfgDir, p.Workspace, lastSeq)

			conn, err := grpcclient.Dial(ctx, p.Server)
			if err != nil {
				return fmt.Errorf("connecting to relay: %w", err)
			}
			defer conn.Close()

			client := relaypb.NewRelayGatewayClient(conn)

			// Open the initial ChannelReceive stream with resume_after_seq.
			stream, err := openStream(ctx, client, p.Workspace, lastSeq)
			if err != nil {
				return fmt.Errorf("channel receive: %w", err)
			}

			// Read the ChannelAck.
			channelID, err := readAck(stream)
			if err != nil {
				return fmt.Errorf("reading channel ack: %w", err)
			}

			// Ingest the message (once, on first connect).
			ingestResp, err := client.ChannelIngest(ctx, &commonpb.ChannelIngestRequest{
				ChannelId:      channelID,
				ConversationId: conversationID,
				UserMessage: &commonpb.UserMessage{
					Content: []*commonpb.ContentBlock{
						{
							Block: &commonpb.ContentBlock_Text{
								Text: &commonpb.TextBlock{Text: message},
							},
						},
					},
					Grants: grantSelections,
				},
			})
			if err != nil {
				return fmt.Errorf("channel ingest: %w", err)
			}
			conversationID = ingestResp.ConversationId

			// Stream the reply with reconnect support.
			isTTY := isatty.IsTerminal(os.Stdout.Fd())
			rs := &recvState{
				cfgDir:         cfgDir,
				workspace:      p.Workspace,
				conversationID: conversationID,
				lastSeq:        lastSeq,
				isTTY:          isTTY,
				toolStyle:      lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
				toolCalls:      make(map[string]string),
			}

			backoff := time.Second
			for {
				result, err := rs.recvLoop(ctx, client, stream)
				switch result {
				case loopDone:
					// Turn completed normally.
					*lastSeq = *rs.lastSeq
					return nil
				case loopReconnect:
					// Fall through to reconnect.
				default:
					if err != nil {
						return err
					}
				}

				// Reconnect with exponential backoff.
				log.Printf("stream disconnected, reconnecting in %v…", backoff)
				time.Sleep(backoff)
				backoff *= 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}

				// Re-dial in case the connection is dead.
				conn.Close()
				conn, err = grpcclient.Dial(ctx, p.Server)
				if err != nil {
					return fmt.Errorf("reconnecting to relay: %w", err)
				}
				client = relaypb.NewRelayGatewayClient(conn)

				stream, err = openStream(ctx, client, p.Workspace, rs.lastSeq)
				if err != nil {
					return fmt.Errorf("channel receive on reconnect: %w", err)
				}
				// Read and discard the new ChannelAck.
				if _, err := readAck(stream); err != nil {
					return fmt.Errorf("reading channel ack on reconnect: %w", err)
				}
			}
		},
	}

	cmd.Flags().BoolVar(&continueFlag, "continue", false, "Continue the last conversation for the current workspace")
	cmd.Flags().StringVar(&resumeID, "resume", "", "Resume a specific conversation by ID")
	cmd.Flags().StringArrayVar(&grants, "grant", nil, "Grant selection (toolset/grant)")
	return cmd
}

// --- Cursor persistence ---

// cursorPath returns the file path for a workspace's cursor.
func cursorPath(cfgDir, workspace string) string {
	return filepath.Join(cfgDir, "cursors", workspace+".seq")
}

// loadCursor reads the last-seen workspace_seq from disk. Returns a pointer to
// 0 if no cursor file exists (request full replay).
func loadCursor(cfgDir, workspace string) *uint64 {
	data, err := os.ReadFile(cursorPath(cfgDir, workspace))
	if err != nil {
		v := uint64(0)
		return &v
	}
	seq, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		v := uint64(0)
		return &v
	}
	return &seq
}

// saveCursor writes lastSeq to disk atomically.
func saveCursor(cfgDir, workspace string, lastSeq *uint64) {
	if lastSeq == nil || *lastSeq == 0 {
		return
	}
	p := cursorPath(cfgDir, workspace)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		log.Printf("warning: failed to create cursor dir: %v", err)
		return
	}
	data := []byte(strconv.FormatUint(*lastSeq, 10) + "\n")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		log.Printf("warning: failed to save cursor: %v", err)
	}
}

// --- Stream helpers ---

// openStream starts a ChannelReceive stream with resume_after_seq set.
func openStream(ctx context.Context, client relaypb.RelayGatewayClient, workspace string, lastSeq *uint64) (grpc.ServerStreamingClient[commonpb.ChannelOutbound], error) {
	req := &commonpb.ChannelReceiveRequest{
		Workspace:      workspace,
		ResumeAfterSeq: lastSeq,
	}
	return client.ChannelReceive(ctx, req)
}

// readAck reads the first frame and expects a ChannelAck.
func readAck(stream grpc.ServerStreamingClient[commonpb.ChannelOutbound]) (string, error) {
	firstFrame, err := stream.Recv()
	if err != nil {
		return "", err
	}
	ack := firstFrame.GetAck()
	if ack == nil {
		return "", fmt.Errorf("expected ChannelAck as first frame")
	}
	return ack.ChannelId, nil
}

type loopResult int

const (
	loopDone      loopResult = iota // Turn finished (IDLE).
	loopReconnect                   // Stream broke; reconnect.
	loopFatal                       // Unrecoverable error.
	loopContinue  loopResult = -1   // Keep receiving frames.
)

// recvState holds mutable state across the receive loop and reconnects.
type recvState struct {
	cfgDir         string
	workspace      string
	conversationID string
	lastSeq        *uint64
	isTTY          bool
	toolStyle      lipgloss.Style
	textBuf        strings.Builder
	toolCalls      map[string]string // item_id -> tool name
}

// recvLoop reads frames until the turn completes, the stream breaks, or the
// dead-connection timer fires.
func (rs *recvState) recvLoop(
	ctx context.Context,
	client relaypb.RelayGatewayClient,
	stream grpc.ServerStreamingClient[commonpb.ChannelOutbound],
) (loopResult, error) {
	timer := time.NewTimer(deadConnectionTimeout)
	defer timer.Stop()

	frameCh := make(chan frameOrErr, 1)
	go func() {
		for {
			frame, err := stream.Recv()
			frameCh <- frameOrErr{frame: frame, err: err}
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return loopFatal, ctx.Err()
		case <-timer.C:
			log.Printf("dead connection detected (no frame in %v)", deadConnectionTimeout)
			return loopReconnect, nil
		case fe := <-frameCh:
			if fe.err != nil {
				if fe.err == io.EOF {
					return loopReconnect, nil
				}
				log.Printf("stream error: %v", fe.err)
				return loopReconnect, nil
			}
			frame := fe.frame

			// Reset dead-connection timer on every frame (including heartbeat).
			timer.Reset(deadConnectionTimeout)

			result, err := rs.handleFrame(ctx, client, frame)
			if result != loopContinue {
				return result, err
			}
		}
	}
}

type frameOrErr struct {
	frame *commonpb.ChannelOutbound
	err   error
}

// handleFrame processes a single ChannelOutbound frame. Returns (loopContinue, nil) to
// continue the loop.
func (rs *recvState) handleFrame(
	ctx context.Context,
	client relaypb.RelayGatewayClient,
	frame *commonpb.ChannelOutbound,
) (loopResult, error) {
	switch c := frame.Command.(type) {
	case *commonpb.ChannelOutbound_Heartbeat:
		// Heartbeat: timer already reset above. Do NOT advance lastSeq.
		return loopContinue, nil

	case *commonpb.ChannelOutbound_CatchUpComplete:
		log.Printf("catch-up complete")
		return loopContinue, nil

	case *commonpb.ChannelOutbound_ReplayImpossible:
		log.Printf("replay impossible, fetching conversation history")
		rs.fetchAndRenderHistory(ctx, client)
		// Stay on current stream; don't reconnect or reset lastSeq.
		return loopContinue, nil

	case *commonpb.ChannelOutbound_TurnState:
		// Dedup: skip if workspace_seq <= lastSeq.
		if rs.dedup(frame) {
			return loopContinue, nil
		}
		if c.TurnState.ConversationId != rs.conversationID {
			return loopContinue, nil
		}
		switch c.TurnState.State {
		case commonpb.TurnState_TURN_STATE_IDLE:
			flushText(&rs.textBuf, rs.isTTY)
			fmt.Fprintf(os.Stderr, "conversation: %s\n", rs.conversationID)
			cfgDir := rs.cfgDir
			config.AppendHistory(cfgDir, rs.conversationID, rs.workspace)
			return loopDone, nil
		case commonpb.TurnState_TURN_STATE_FAILED:
			return loopFatal, fmt.Errorf("turn failed: %s", c.TurnState.Reason)
		}

	case *commonpb.ChannelOutbound_StreamItem:
		if rs.dedup(frame) {
			return loopContinue, nil
		}
		item := c.StreamItem
		if item.ConversationId != rs.conversationID {
			return loopContinue, nil
		}
		rs.renderStreamItem(item)

	case *commonpb.ChannelOutbound_SendMessage:
		if rs.dedup(frame) {
			return loopContinue, nil
		}

	case *commonpb.ChannelOutbound_ServerRequest:
		if rs.dedup(frame) {
			return loopContinue, nil
		}

	case *commonpb.ChannelOutbound_Ack:
		// Unexpected extra ack; ignore.
	}

	return loopContinue, nil
}

// dedup checks whether a frame's workspace_seq has already been processed.
// If not, it advances lastSeq and flushes the cursor. Returns true if the
// frame should be skipped.
func (rs *recvState) dedup(frame *commonpb.ChannelOutbound) bool {
	if frame.WorkspaceSeq == nil {
		return false
	}
	seq := frame.GetWorkspaceSeq()
	if seq <= *rs.lastSeq {
		return true
	}
	*rs.lastSeq = seq
	saveCursor(rs.cfgDir, rs.workspace, rs.lastSeq)
	return false
}

// renderStreamItem displays a single stream item.
func (rs *recvState) renderStreamItem(item *commonpb.StreamItem) {
	switch phase := item.Phase.(type) {
	case *commonpb.StreamItem_Start:
		if tu := phase.Start.GetToolUse(); tu != nil {
			rs.toolCalls[item.ItemId] = tu.Name
			line := fmt.Sprintf("⚙ %s (started)", tu.Name)
			if rs.isTTY {
				fmt.Fprintln(os.Stdout, rs.toolStyle.Render(line))
			} else {
				fmt.Fprintln(os.Stdout, line)
			}
		}
	case *commonpb.StreamItem_Delta:
		if delta := phase.Delta.GetTextDelta(); delta != "" {
			rs.textBuf.WriteString(delta)
		}
	case *commonpb.StreamItem_Stop:
		if name, ok := rs.toolCalls[item.ItemId]; ok {
			line := fmt.Sprintf("⚙ %s (finished)", name)
			if rs.isTTY {
				fmt.Fprintln(os.Stdout, rs.toolStyle.Render(line))
			} else {
				fmt.Fprintln(os.Stdout, line)
			}
		}
	}
}

// fetchAndRenderHistory calls GetConversationHistory and renders the returned
// entries as completed turns.
func (rs *recvState) fetchAndRenderHistory(ctx context.Context, client relaypb.RelayGatewayClient) {
	resp, err := client.GetConversationHistory(ctx, &commonpb.GetConversationHistoryRequest{
		ConversationId: rs.conversationID,
		Workspace:      rs.workspace,
	})
	if err != nil {
		log.Printf("warning: GetConversationHistory failed: %v", err)
		return
	}
	for _, entry := range resp.GetEntries() {
		msg := entry.GetMessage()
		if msg == nil {
			continue
		}
		var text strings.Builder
		for _, block := range msg.Content {
			if tb := block.GetText(); tb != nil {
				text.WriteString(tb.Text)
			}
		}
		if text.Len() == 0 {
			continue
		}
		prefix := msg.Role
		if prefix == "" {
			prefix = "unknown"
		}
		fmt.Fprintf(os.Stderr, "[%s] ", prefix)
		if rs.isTTY {
			rendered, err := glamour.Render(text.String(), "dark")
			if err == nil {
				fmt.Fprint(os.Stdout, rendered)
			} else {
				fmt.Fprint(os.Stdout, text.String())
			}
		} else {
			fmt.Fprint(os.Stdout, text.String())
		}
		fmt.Fprintln(os.Stdout)
	}
}

func flushText(buf *strings.Builder, isTTY bool) {
	text := buf.String()
	if text == "" {
		return
	}
	if isTTY {
		rendered, err := glamour.Render(text, "dark")
		if err == nil {
			fmt.Fprint(os.Stdout, rendered)
		} else {
			fmt.Fprint(os.Stdout, text)
		}
	} else {
		fmt.Fprint(os.Stdout, text)
	}
	buf.Reset()
}
