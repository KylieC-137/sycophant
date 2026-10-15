package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-isatty"
	"github.com/spf13/cobra"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	"github.com/sycophant-md/sycophant/cmd/syco/internal/grpcclient"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
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
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			message := args[0]
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

			if p.Workspace == "" {
				return fmt.Errorf("workspace is required; set it with `syco session workspace <ws>`")
			}

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

			// Parse grants
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

			ctx := grpcclient.WithToken(context.Background(), token)
			conn, err := grpcclient.Dial(ctx, p.Server)
			if err != nil {
				return fmt.Errorf("connecting to relay: %w", err)
			}
			defer conn.Close()

			client := relaypb.NewRelayGatewayClient(conn)

			// Open ChannelReceive stream
			stream, err := client.ChannelReceive(ctx, &commonpb.ChannelReceiveRequest{
				Workspace: p.Workspace,
			})
			if err != nil {
				return fmt.Errorf("channel receive: %w", err)
			}

			// Read first frame: ChannelAck
			firstFrame, err := stream.Recv()
			if err != nil {
				return fmt.Errorf("reading channel ack: %w", err)
			}
			ack := firstFrame.GetAck()
			if ack == nil {
				return fmt.Errorf("expected ChannelAck as first frame")
			}
			channelID := ack.ChannelId

			// Send the message via ChannelIngest
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

			// Stream the reply
			isTTY := isatty.IsTerminal(os.Stdout.Fd())
			toolStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
			var textBuf strings.Builder
			toolCalls := make(map[string]string) // item_id -> tool name

			for {
				frame, err := stream.Recv()
				if err == io.EOF {
					break
				}
				if err != nil {
					return fmt.Errorf("stream error: %w", err)
				}

				switch c := frame.Command.(type) {
				case *commonpb.ChannelOutbound_TurnState:
					if c.TurnState.ConversationId != conversationID {
						continue
					}
					switch c.TurnState.State {
					case commonpb.TurnState_TURN_STATE_IDLE:
						// Flush text
						flushText(&textBuf, isTTY)
						// Print conversation ID to stderr
						fmt.Fprintf(os.Stderr, "conversation: %s\n", conversationID)
						// Record in history
						config.AppendHistory(cfgDir, conversationID, p.Workspace)
						return nil
					case commonpb.TurnState_TURN_STATE_FAILED:
						return fmt.Errorf("turn failed: %s", c.TurnState.Reason)
					}

				case *commonpb.ChannelOutbound_StreamItem:
					item := c.StreamItem
					if item.ConversationId != conversationID {
						continue
					}
					switch phase := item.Phase.(type) {
					case *commonpb.StreamItem_Start:
						if tu := phase.Start.GetToolUse(); tu != nil {
							toolCalls[item.ItemId] = tu.Name
							line := fmt.Sprintf("⚙ %s (started)", tu.Name)
							if isTTY {
								fmt.Fprintln(os.Stdout, toolStyle.Render(line))
							} else {
								fmt.Fprintln(os.Stdout, line)
							}
						}
					case *commonpb.StreamItem_Delta:
						if delta := phase.Delta.GetTextDelta(); delta != "" {
							textBuf.WriteString(delta)
						}
					case *commonpb.StreamItem_Stop:
						if name, ok := toolCalls[item.ItemId]; ok {
							line := fmt.Sprintf("⚙ %s (finished)", name)
							if isTTY {
								fmt.Fprintln(os.Stdout, toolStyle.Render(line))
							} else {
								fmt.Fprintln(os.Stdout, line)
							}
						}
					}
				}
			}

			return fmt.Errorf("stream ended without TURN_STATE_IDLE")
		},
	}

	cmd.Flags().BoolVar(&continueFlag, "continue", false, "Continue the last conversation for the current workspace")
	cmd.Flags().StringVar(&resumeID, "resume", "", "Resume a specific conversation by ID")
	cmd.Flags().StringArrayVar(&grants, "grant", nil, "Grant selection (toolset/grant)")
	return cmd
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
