package cmd

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	"google.golang.org/grpc"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	"github.com/sycophant-md/sycophant/cmd/syco/internal/grpcclient"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
)

// runTUI launches the interactive Bubble Tea TUI for multi-turn chat.
func runTUI(
	cfgDir string,
	p *config.Profile,
	token string,
	continueFlag bool,
	resumeID string,
	grants []*commonpb.GrantSelection,
) error {
	m := newTUIModel(cfgDir, p, token, continueFlag, resumeID, grants)
	prog := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseAllMotion())
	_, err := prog.Run()
	return err
}

// --- Phases ---

type tuiPhase int

const (
	phasePicker tuiPhase = iota // Workspace selection screen.
	phaseChat                   // Chat session.
)

// --- Styles ---

var (
	userStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
	assistantStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true)
	toolStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	sepStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	statusStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	errorStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	pickerTitle    = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
	pickerItem     = lipgloss.NewStyle().PaddingLeft(2)
	pickerSelected = lipgloss.NewStyle().PaddingLeft(2).Foreground(lipgloss.Color("10")).Bold(true)
)

// --- Messages ---

type frameMsg struct {
	frame *commonpb.ChannelOutbound
}

type streamErrMsg struct {
	err error
}

type connectedMsg struct {
	conn      *grpc.ClientConn
	client    relaypb.RelayGatewayClient
	stream    grpc.ServerStreamingClient[commonpb.ChannelOutbound]
	channelID string
}

type connErrMsg struct {
	err error
}

type ingestAckMsg struct {
	conversationID string
}

type reconnectMsg struct{}

// workspacesMsg carries the result of ListWorkspaces.
type workspacesMsg struct {
	workspaces []string
	conn       *grpc.ClientConn
	client     relaypb.RelayGatewayClient
}

// workspacesErrMsg signals a failure to list workspaces.
type workspacesErrMsg struct {
	err error
}

// --- Model ---

type tuiModel struct {
	phase tuiPhase

	// Config.
	cfgDir       string
	profile      *config.Profile
	token        string
	continueFlag bool
	resumeID     string
	grants       []*commonpb.GrantSelection

	// Connection state.
	conn      *grpc.ClientConn
	client    relaypb.RelayGatewayClient
	stream    grpc.ServerStreamingClient[commonpb.ChannelOutbound]
	channelID string
	connected bool

	// Conversation state.
	conversationID string
	lastSeq        *uint64
	toolCalls      map[string]string
	textBuf        strings.Builder
	waiting        bool

	// Display.
	committed strings.Builder
	liveBuf   strings.Builder

	// Identity from token.
	subject string

	// Picker state.
	workspaces    []string
	pickerCursor  int
	pickerLoading bool

	// Chat UI components.
	viewport     viewport.Model
	input        textinput.Model
	ready        bool
	userAtBottom bool

	// Terminal dimensions.
	width  int
	height int

	// Quitting.
	quitting bool
	err      error
}

func newTUIModel(
	cfgDir string,
	p *config.Profile,
	token string,
	continueFlag bool,
	resumeID string,
	grants []*commonpb.GrantSelection,
) *tuiModel {
	ti := textinput.New()
	ti.Placeholder = "Type a message…"
	ti.CharLimit = 0

	seq := uint64(0)

	sub, _ := config.TokenSubject(token)
	email := config.TokenEmail(token)
	identity := email
	if identity == "" {
		identity = sub
	}

	// If the profile already has a workspace, skip the picker.
	phase := phasePicker
	if p.Workspace != "" {
		phase = phaseChat
		ti.Prompt = p.Workspace + " › "
		ti.Focus()
	}

	return &tuiModel{
		phase:         phase,
		cfgDir:        cfgDir,
		profile:       p,
		token:         token,
		continueFlag:  continueFlag,
		resumeID:      resumeID,
		grants:        grants,
		lastSeq:       &seq,
		toolCalls:     make(map[string]string),
		input:         ti,
		subject:       identity,
		pickerLoading: phase == phasePicker,
		userAtBottom:  true,
	}
}

func (m *tuiModel) Init() tea.Cmd {
	if m.phase == phaseChat {
		return tea.Batch(textinput.Blink, m.connectCmd())
	}
	// Picker phase: list workspaces first.
	return m.listWorkspacesCmd()
}

// --- Commands ---

// listWorkspacesCmd connects to the relay and fetches the workspace list.
func (m *tuiModel) listWorkspacesCmd() tea.Cmd {
	return func() tea.Msg {
		ctx := grpcclient.WithToken(context.Background(), m.token)
		conn, err := grpcclient.Dial(ctx, m.profile.Server)
		if err != nil {
			return workspacesErrMsg{err: fmt.Errorf("connecting to relay: %w", err)}
		}
		client := relaypb.NewRelayGatewayClient(conn)
		resp, err := client.ListWorkspaces(ctx, &commonpb.ListWorkspacesRequest{})
		if err != nil {
			conn.Close()
			return workspacesErrMsg{err: fmt.Errorf("listing workspaces: %w", err)}
		}
		return workspacesMsg{
			workspaces: resp.Workspaces,
			conn:       conn,
			client:     client,
		}
	}
}

func (m *tuiModel) connectCmd() tea.Cmd {
	return func() tea.Msg {
		ctx := grpcclient.WithToken(context.Background(), m.token)

		seq := loadCursor(m.cfgDir, m.profile.Workspace)
		m.lastSeq = seq

		// Reuse existing connection from picker if available.
		conn := m.conn
		var err error
		if conn == nil {
			conn, err = grpcclient.Dial(ctx, m.profile.Server)
			if err != nil {
				return connErrMsg{err: fmt.Errorf("connecting to relay: %w", err)}
			}
		}

		client := relaypb.NewRelayGatewayClient(conn)
		stream, err := openStream(ctx, client, m.profile.Workspace, seq)
		if err != nil {
			conn.Close()
			return connErrMsg{err: fmt.Errorf("channel receive: %w", err)}
		}

		channelID, err := readAck(stream)
		if err != nil {
			conn.Close()
			return connErrMsg{err: fmt.Errorf("reading channel ack: %w", err)}
		}

		if m.continueFlag {
			entry, err := config.HistoryLastForWorkspace(m.cfgDir, m.profile.Workspace)
			if err == nil {
				m.conversationID = entry.ConversationID
			}
		} else if m.resumeID != "" {
			m.conversationID = m.resumeID
		}

		return connectedMsg{
			conn:      conn,
			client:    client,
			stream:    stream,
			channelID: channelID,
		}
	}
}

func (m *tuiModel) recvCmd() tea.Cmd {
	stream := m.stream
	return func() tea.Msg {
		frame, err := stream.Recv()
		if err != nil {
			return streamErrMsg{err: err}
		}
		return frameMsg{frame: frame}
	}
}

func (m *tuiModel) ingestCmd(message string) tea.Cmd {
	return func() tea.Msg {
		ctx := grpcclient.WithToken(context.Background(), m.token)
		resp, err := m.client.ChannelIngest(ctx, &commonpb.ChannelIngestRequest{
			ChannelId:      m.channelID,
			ConversationId: m.conversationID,
			UserMessage: &commonpb.UserMessage{
				Content: []*commonpb.ContentBlock{
					{
						Block: &commonpb.ContentBlock_Text{
							Text: &commonpb.TextBlock{Text: message},
						},
					},
				},
				Grants: m.grants,
			},
		})
		if err != nil {
			return streamErrMsg{err: fmt.Errorf("channel ingest: %w", err)}
		}
		return ingestAckMsg{conversationID: resp.ConversationId}
	}
}

func (m *tuiModel) reconnectCmd(backoff time.Duration) tea.Cmd {
	return tea.Tick(backoff, func(time.Time) tea.Msg {
		return reconnectMsg{}
	})
}

func (m *tuiModel) doReconnect() tea.Cmd {
	return func() tea.Msg {
		if m.conn != nil {
			m.conn.Close()
		}
		ctx := grpcclient.WithToken(context.Background(), m.token)
		conn, err := grpcclient.Dial(ctx, m.profile.Server)
		if err != nil {
			return connErrMsg{err: fmt.Errorf("reconnecting to relay: %w", err)}
		}
		client := relaypb.NewRelayGatewayClient(conn)
		stream, err := openStream(ctx, client, m.profile.Workspace, m.lastSeq)
		if err != nil {
			conn.Close()
			return connErrMsg{err: fmt.Errorf("channel receive on reconnect: %w", err)}
		}
		channelID, err := readAck(stream)
		if err != nil {
			conn.Close()
			return connErrMsg{err: fmt.Errorf("reading ack on reconnect: %w", err)}
		}
		return connectedMsg{
			conn:      conn,
			client:    client,
			stream:    stream,
			channelID: channelID,
		}
	}
}

// --- Update ---

func (m *tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m.phase {
	case phasePicker:
		return m.updatePicker(msg)
	case phaseChat:
		return m.updateChat(msg)
	}
	return m, nil
}

// --- Picker Update ---

func (m *tuiModel) updatePicker(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc, tea.KeyCtrlC:
			m.quitting = true
			return m, tea.Quit
		case tea.KeyUp:
			if m.pickerCursor > 0 {
				m.pickerCursor--
			}
		case tea.KeyDown:
			if m.pickerCursor < len(m.workspaces)-1 {
				m.pickerCursor++
			}
		case tea.KeyEnter:
			if len(m.workspaces) > 0 {
				return m.selectWorkspace(m.workspaces[m.pickerCursor])
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case workspacesMsg:
		m.workspaces = msg.workspaces
		m.conn = msg.conn
		m.client = msg.client
		m.pickerLoading = false
		// If only one workspace, select it automatically.
		if len(m.workspaces) == 1 {
			return m.selectWorkspace(m.workspaces[0])
		}

	case workspacesErrMsg:
		m.pickerLoading = false
		m.err = msg.err
	}

	return m, nil
}

// selectWorkspace transitions from picker to chat.
func (m *tuiModel) selectWorkspace(workspace string) (tea.Model, tea.Cmd) {
	m.profile.Workspace = workspace
	m.phase = phaseChat
	m.input.Prompt = workspace + " › "
	m.input.Focus()
	return m, tea.Batch(textinput.Blink, m.connectCmd())
}

// --- Chat Update ---

func (m *tuiModel) updateChat(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc, tea.KeyCtrlC:
			m.quitting = true
			saveCursor(m.cfgDir, m.profile.Workspace, m.lastSeq)
			if m.conn != nil {
				m.conn.Close()
			}
			return m, tea.Quit

		case tea.KeyEnter:
			if m.waiting || !m.connected {
				break
			}
			text := strings.TrimSpace(m.input.Value())
			if text == "" {
				break
			}
			m.input.SetValue("")
			m.waiting = true

			m.commitLine(userStyle.Render("you") + "  " + text)
			m.commitLine("")
			m.syncViewport()

			m.textBuf.Reset()
			m.liveBuf.Reset()

			cmds = append(cmds, m.ingestCmd(text))
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		inputHeight := 2
		if !m.ready {
			m.viewport = viewport.New(msg.Width, msg.Height-inputHeight)
			m.viewport.SetContent(m.committed.String())
			m.ready = true
		} else {
			m.viewport.Width = msg.Width
			m.viewport.Height = msg.Height - inputHeight
		}
		m.input.Width = msg.Width - lipgloss.Width(m.input.Prompt) - 1

	case connectedMsg:
		m.conn = msg.conn
		m.client = msg.client
		m.stream = msg.stream
		m.channelID = msg.channelID
		m.connected = true
		m.commitLine(statusStyle.Render("Connected to " + m.profile.Workspace))
		m.commitLine("")
		m.syncViewport()
		cmds = append(cmds, m.recvCmd())

	case connErrMsg:
		m.err = msg.err
		m.commitLine(errorStyle.Render("⚠ " + msg.err.Error()))
		m.syncViewport()

	case ingestAckMsg:
		m.conversationID = msg.conversationID

	case frameMsg:
		m.userAtBottom = m.viewport.AtBottom()
		m.handleFrameMsg(msg.frame)
		m.syncViewport()
		cmds = append(cmds, m.recvCmd())

	case streamErrMsg:
		m.commitLine(errorStyle.Render("⚠ Stream disconnected, reconnecting…"))
		m.syncViewport()
		cmds = append(cmds, m.reconnectCmd(2*time.Second))

	case reconnectMsg:
		cmds = append(cmds, m.doReconnect())
	}

	if !m.waiting && m.connected {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		cmds = append(cmds, cmd)
	}

	var cmd tea.Cmd
	m.viewport, cmd = m.viewport.Update(msg)
	cmds = append(cmds, cmd)

	return m, tea.Batch(cmds...)
}

// --- Frame handling ---

func (m *tuiModel) handleFrameMsg(frame *commonpb.ChannelOutbound) {
	switch c := frame.Command.(type) {
	case *commonpb.ChannelOutbound_Heartbeat:
		return
	case *commonpb.ChannelOutbound_CatchUpComplete:
		return
	case *commonpb.ChannelOutbound_ReplayImpossible:
		m.commitLine(errorStyle.Render("⚠ Replay impossible; history may be incomplete."))
		return
	case *commonpb.ChannelOutbound_TurnState:
		if m.dedupFrame(frame) {
			return
		}
		if c.TurnState.ConversationId != m.conversationID {
			return
		}
		switch c.TurnState.State {
		case commonpb.TurnState_TURN_STATE_IDLE:
			m.flushStreamingToCommitted()
			m.commitLine(sepStyle.Render("───────────────────────────────"))
			m.commitLine("")
			m.waiting = false
			m.input.Focus()
			config.AppendHistory(m.cfgDir, m.conversationID, m.profile.Workspace)
		case commonpb.TurnState_TURN_STATE_FAILED:
			m.flushStreamingToCommitted()
			m.commitLine(errorStyle.Render("⚠ Turn failed: " + c.TurnState.Reason))
			m.commitLine("")
			m.waiting = false
			m.input.Focus()
		}
	case *commonpb.ChannelOutbound_StreamItem:
		if m.dedupFrame(frame) {
			return
		}
		item := c.StreamItem
		if item.ConversationId != m.conversationID {
			return
		}
		m.handleStreamItem(item)
	case *commonpb.ChannelOutbound_SendMessage:
		m.dedupFrame(frame)
	case *commonpb.ChannelOutbound_ServerRequest:
		m.dedupFrame(frame)
	case *commonpb.ChannelOutbound_Ack:
		// Extra ack; ignore.
	}
}

func (m *tuiModel) handleStreamItem(item *commonpb.StreamItem) {
	switch phase := item.Phase.(type) {
	case *commonpb.StreamItem_Start:
		if tu := phase.Start.GetToolUse(); tu != nil {
			m.toolCalls[item.ItemId] = tu.Name
			m.flushStreamingToCommitted()
			m.commitLine(toolStyle.Render(fmt.Sprintf("⚙ %s (started)", tu.Name)))
		}
	case *commonpb.StreamItem_Delta:
		if delta := phase.Delta.GetTextDelta(); delta != "" {
			m.textBuf.WriteString(delta)
			m.liveBuf.WriteString(delta)
		}
	case *commonpb.StreamItem_Stop:
		if name, ok := m.toolCalls[item.ItemId]; ok {
			m.flushStreamingToCommitted()
			m.commitLine(toolStyle.Render(fmt.Sprintf("⚙ %s (finished)", name)))
		}
	}
}

// --- Display helpers ---

func (m *tuiModel) commitLine(s string) {
	m.committed.WriteString(s)
	m.committed.WriteString("\n")
}

func (m *tuiModel) flushStreamingToCommitted() {
	if m.textBuf.Len() == 0 {
		return
	}
	raw := m.textBuf.String()
	rendered, err := glamour.Render(raw, "dark")
	if err != nil {
		rendered = raw
	}
	m.committed.WriteString(assistantStyle.Render("assistant") + "\n")
	m.committed.WriteString(rendered)
	m.textBuf.Reset()
	m.liveBuf.Reset()
}

func (m *tuiModel) syncViewport() {
	if !m.ready {
		return
	}
	var full strings.Builder
	full.WriteString(m.committed.String())
	if m.liveBuf.Len() > 0 {
		full.WriteString(assistantStyle.Render("assistant") + "\n")
		full.WriteString(m.liveBuf.String())
	}
	m.viewport.SetContent(full.String())
	if m.userAtBottom {
		m.viewport.GotoBottom()
	}
}

func (m *tuiModel) dedupFrame(frame *commonpb.ChannelOutbound) bool {
	if frame.WorkspaceSeq == nil {
		return false
	}
	seq := frame.GetWorkspaceSeq()
	if seq <= *m.lastSeq {
		return true
	}
	*m.lastSeq = seq
	saveCursor(m.cfgDir, m.profile.Workspace, m.lastSeq)
	return false
}

// --- View ---

func (m *tuiModel) View() string {
	if m.quitting {
		return ""
	}

	switch m.phase {
	case phasePicker:
		return m.viewPicker()
	case phaseChat:
		return m.viewChat()
	}
	return ""
}

func (m *tuiModel) viewPicker() string {
	var b strings.Builder

	b.WriteString("\n")
	b.WriteString(pickerTitle.Render("  sycophant"))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render(fmt.Sprintf("  %s · %s", m.subject, m.profile.Server)))
	b.WriteString("\n\n")

	if m.pickerLoading {
		b.WriteString(statusStyle.Render("  Loading workspaces…"))
		b.WriteString("\n")
		return b.String()
	}

	if m.err != nil {
		b.WriteString(errorStyle.Render("  ⚠ " + m.err.Error()))
		b.WriteString("\n")
		return b.String()
	}

	if len(m.workspaces) == 0 {
		b.WriteString(statusStyle.Render("  No workspaces available."))
		b.WriteString("\n")
		return b.String()
	}

	b.WriteString(statusStyle.Render("  Select a workspace:"))
	b.WriteString("\n\n")

	for i, ws := range m.workspaces {
		if i == m.pickerCursor {
			b.WriteString(pickerSelected.Render("› " + ws))
		} else {
			b.WriteString(pickerItem.Render("  " + ws))
		}
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(statusStyle.Render("  ↑/↓ navigate · enter select · esc quit"))
	b.WriteString("\n")

	return b.String()
}

func (m *tuiModel) viewChat() string {
	if !m.ready {
		return "Connecting…"
	}

	identity := m.subject
	if identity == "" {
		identity = "unknown"
	}
	ctx := statusStyle.Render(fmt.Sprintf("  %s · %s · %s", identity, m.profile.Server, m.profile.Workspace))
	var indicator string
	if m.waiting {
		indicator = statusStyle.Render(" thinking…")
	} else if !m.connected {
		indicator = errorStyle.Render(" disconnected")
	}
	pad := m.width - lipgloss.Width(ctx) - lipgloss.Width(indicator)
	if pad < 0 {
		pad = 0
	}
	status := ctx + strings.Repeat(" ", pad) + indicator

	return m.viewport.View() + "\n" + status + "\n" + m.input.View()
}
