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
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

// runTUI launches the interactive Bubble Tea TUI for multi-turn chat.
// When the profile names a workspace, a conversation named by --continue or
// --resume is opened first, so a refusal is returned before the program takes
// over the screen. Otherwise it is opened after the workspace picker, and a
// refusal quits the program.
func runTUI(
	cfgDir string,
	p *config.Profile,
	token string,
	continueFlag bool,
	resumeID string,
	grants []*commonpb.GrantSelection,
) error {
	m, err := openTUIModel(cfgDir, p, token, continueFlag, resumeID, grants)
	if err != nil {
		return err
	}
	prog := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseAllMotion())
	final, err := prog.Run()
	if err != nil {
		return err
	}
	if fm, ok := final.(*tuiModel); ok && fm.openErr != nil {
		return fm.openErr
	}
	return nil
}

// openTUIModel builds the TUI model for a profile and flags. When the
// profile names a workspace and the flags name a conversation, it also
// connects and opens that conversation: the stream is open before history
// and turn state are read, so no live frame after that point is lost.
func openTUIModel(
	cfgDir string,
	p *config.Profile,
	token string,
	continueFlag bool,
	resumeID string,
	grants []*commonpb.GrantSelection,
) (tea.Model, error) {
	m := newTUIModel(cfgDir, p, token, continueFlag, resumeID, grants)
	if p.Workspace == "" {
		return m, nil
	}
	id := m.namedConversation()
	if id == "" {
		return m, nil
	}
	msg, err := connectChannelStream(token, p.Server, p.Workspace, nil)
	if err != nil {
		return nil, err
	}
	if err := msg.openConversation(token, p.Workspace, id); err != nil {
		msg.conn.Close()
		return nil, err
	}
	m.applyConnected(msg)
	return m, nil
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
	frame *commonpb.ChannelStreamOutbound
}

type streamErrMsg struct {
	err error
	// ingest marks a failed ChannelStreamIngest rather than a broken stream.
	ingest bool
}

// connectedMsg carries an open channel stream and, when conversationID is set, the
// conversation read through it.
type connectedMsg struct {
	conn            *grpc.ClientConn
	client          relaypb.RelayGatewayClient
	stream          grpc.ServerStreamingClient[commonpb.ChannelStreamOutbound]
	channelStreamID string

	conversationID string
	history        []*commonpb.HistoryEntry
	running        bool
}

type connErrMsg struct {
	err error
}

// openFailedMsg reports that a named conversation could not be opened.
// The program quits and the chat command returns the error.
type openFailedMsg struct {
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
	conn            *grpc.ClientConn
	client          relaypb.RelayGatewayClient
	stream          grpc.ServerStreamingClient[commonpb.ChannelStreamOutbound]
	channelStreamID string
	connected       bool

	// Conversation state.
	conversationID string
	toolCalls      map[string]string
	textBuf        strings.Builder
	// running is the relay's latest turn state for the viewed conversation.
	running bool
	// sending covers an ingest in flight.
	sending bool
	// approvals wait for a y or n key each, first in, first out. The first
	// is the one showing.
	approvals []toolApproval

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
	// openErr is a named conversation's open failure, returned by runTUI.
	openErr error
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
		toolCalls:     make(map[string]string),
		input:         ti,
		subject:       identity,
		pickerLoading: phase == phasePicker,
		userAtBottom:  true,
	}
}

// namedConversation is the conversation the flags name for the profile's
// workspace, or "" for a new conversation.
func (m *tuiModel) namedConversation() string {
	if m.continueFlag {
		entry, err := config.HistoryLastForWorkspace(m.cfgDir, m.profile.Workspace)
		if err == nil {
			return entry.ConversationID
		}
		return ""
	}
	return m.resumeID
}

func (m *tuiModel) Init() tea.Cmd {
	if m.phase == phaseChat {
		if m.connected {
			return tea.Batch(textinput.Blink, m.recvCmd())
		}
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

// connectChannelStream dials the relay (or reuses conn), opens ChannelStreamReceive for
// the workspace and reads the ack.
func connectChannelStream(token, server, workspace string, conn *grpc.ClientConn) (connectedMsg, error) {
	ctx := grpcclient.WithToken(context.Background(), token)
	if conn == nil {
		var err error
		conn, err = grpcclient.Dial(ctx, server)
		if err != nil {
			return connectedMsg{}, fmt.Errorf("connecting to relay: %w", err)
		}
	}
	client := relaypb.NewRelayGatewayClient(conn)
	stream, err := client.ChannelStreamReceive(ctx, &commonpb.ChannelStreamReceiveRequest{Workspace: workspace})
	if err != nil {
		conn.Close()
		return connectedMsg{}, fmt.Errorf("channel stream receive: %w", err)
	}
	channelStreamID, err := readAck(stream)
	if err != nil {
		conn.Close()
		return connectedMsg{}, fmt.Errorf("reading channel stream ack: %w", err)
	}
	return connectedMsg{conn: conn, client: client, stream: stream, channelStreamID: channelStreamID}, nil
}

// openConversation reads a conversation's whole history and then its turn
// state through the open channel stream.
func (c *connectedMsg) openConversation(token, workspace, conversationID string) error {
	ctx := grpcclient.WithToken(context.Background(), token)
	history, err := loadHistory(ctx, c.client, conversationID, workspace)
	if err != nil {
		return err
	}
	ts, err := getTurnState(ctx, c.client, conversationID, workspace)
	if err != nil {
		return err
	}
	c.conversationID = conversationID
	c.history = history
	c.running = ts.GetState() == commonpb.TurnState_TURN_STATE_WORKING
	return nil
}

func (m *tuiModel) connectCmd() tea.Cmd {
	token, server, workspace := m.token, m.profile.Server, m.profile.Workspace
	// Reuse existing connection from picker if available.
	conn := m.conn
	id := m.namedConversation()
	return func() tea.Msg {
		msg, err := connectChannelStream(token, server, workspace, conn)
		if err != nil {
			return connErrMsg{err: err}
		}
		if id != "" {
			if err := msg.openConversation(token, workspace, id); err != nil {
				msg.conn.Close()
				return openFailedMsg{err: err}
			}
		}
		return msg
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
	client, channelStreamID, conversationID, grants, token := m.client, m.channelStreamID, m.conversationID, m.grants, m.token
	return func() tea.Msg {
		ctx := grpcclient.WithToken(context.Background(), token)
		resp, err := client.ChannelStreamIngest(ctx, &commonpb.ChannelStreamIngestRequest{
			ChannelStreamId:  channelStreamID,
			ConversationId:   conversationID,
			SupportedMethods: supportedMethods,
			UserMessage: &commonpb.UserMessage{
				Content: []*commonpb.ContentBlock{
					{
						Block: &commonpb.ContentBlock_Text{
							Text: &commonpb.TextBlock{Text: message},
						},
					},
				},
				Grants: grants,
			},
		})
		if err != nil {
			return streamErrMsg{err: fmt.Errorf("channel stream ingest: %w", err), ingest: true}
		}
		return ingestAckMsg{conversationID: resp.ConversationId}
	}
}

func (m *tuiModel) answerApprovalCmd(requestID string, approved bool) tea.Cmd {
	client, channelStreamID, token := m.client, m.channelStreamID, m.token
	return func() tea.Msg {
		ctx := grpcclient.WithToken(context.Background(), token)
		if _, err := client.ChannelStreamIngest(ctx, approvalAnswer(channelStreamID, requestID, approved)); err != nil {
			return connErrMsg{err: fmt.Errorf("sending approval answer: %w", err)}
		}
		return nil
	}
}

func (m *tuiModel) reconnectCmd(backoff time.Duration) tea.Cmd {
	return tea.Tick(backoff, func(time.Time) tea.Msg {
		return reconnectMsg{}
	})
}

func (m *tuiModel) doReconnect() tea.Cmd {
	old := m.conn
	token, server, workspace, id := m.token, m.profile.Server, m.profile.Workspace, m.conversationID
	return func() tea.Msg {
		if old != nil {
			old.Close()
		}
		msg, err := connectChannelStream(token, server, workspace, nil)
		if err != nil {
			return connErrMsg{err: fmt.Errorf("reconnecting: %w", err)}
		}
		if id != "" {
			if err := msg.openConversation(token, workspace, id); err != nil {
				msg.conn.Close()
				return connErrMsg{err: fmt.Errorf("reconnecting: %w", err)}
			}
		}
		return msg
	}
}

// applyConnected adopts an open channel stream. An opened conversation replaces
// the transcript with its history and sets the running state.
func (m *tuiModel) applyConnected(msg connectedMsg) {
	m.conn = msg.conn
	m.client = msg.client
	m.stream = msg.stream
	m.channelStreamID = msg.channelStreamID
	m.connected = true
	if msg.conversationID != "" {
		m.conversationID = msg.conversationID
		m.committed.Reset()
		m.textBuf.Reset()
		m.liveBuf.Reset()
		m.renderHistory(msg.history)
		m.running = msg.running
	}
	m.commitLine(statusStyle.Render("Connected to " + m.profile.Workspace))
	m.commitLine("")
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

// acceptsInput reports whether the user may type and send.
func (m *tuiModel) acceptsInput() bool {
	return len(m.approvals) == 0 && m.connected && !m.running && !m.sending
}

func (m *tuiModel) updateChat(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		if len(m.approvals) > 0 && msg.Type == tea.KeyRunes {
			switch string(msg.Runes) {
			case "y", "n":
				a := m.approvals[0]
				m.approvals = m.approvals[1:]
				return m, m.answerApprovalCmd(a.requestID, string(msg.Runes) == "y")
			}
		}
		switch msg.Type {
		case tea.KeyEsc, tea.KeyCtrlC:
			m.quitting = true
			if m.conn != nil {
				m.conn.Close()
			}
			return m, tea.Quit

		case tea.KeyEnter:
			if !m.acceptsInput() {
				break
			}
			text := strings.TrimSpace(m.input.Value())
			if text == "" {
				break
			}
			m.input.SetValue("")
			m.sending = true

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
		m.applyConnected(msg)
		m.syncViewport()
		cmds = append(cmds, m.recvCmd())

	case connErrMsg:
		m.err = msg.err
		m.commitLine(errorStyle.Render("⚠ " + msg.err.Error()))
		m.syncViewport()

	case openFailedMsg:
		m.openErr = msg.err
		m.quitting = true
		return m, tea.Quit

	case ingestAckMsg:
		m.sending = false
		m.conversationID = msg.conversationID
		if msg.conversationID != "" {
			// The relay records WORKING for the conversation before it acks.
			m.running = true
			if err := config.AppendHistory(m.cfgDir, msg.conversationID, m.profile.Workspace); err != nil {
				m.commitLine(errorStyle.Render("⚠ saving conversation history: " + err.Error()))
				m.syncViewport()
			}
		}

	case frameMsg:
		m.userAtBottom = m.viewport.AtBottom()
		m.handleFrameMsg(msg.frame)
		m.syncViewport()
		cmds = append(cmds, m.recvCmd())

	case streamErrMsg:
		if msg.ingest {
			m.sending = false
		}
		m.commitLine(errorStyle.Render("⚠ Stream disconnected, reconnecting…"))
		m.syncViewport()
		cmds = append(cmds, m.reconnectCmd(2*time.Second))

	case reconnectMsg:
		cmds = append(cmds, m.doReconnect())
	}

	if m.acceptsInput() {
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

func (m *tuiModel) handleFrameMsg(frame *commonpb.ChannelStreamOutbound) {
	switch c := frame.Command.(type) {
	case *commonpb.ChannelStreamOutbound_TurnState:
		ts := c.TurnState
		if ts.ConversationId == "" || ts.ConversationId != m.conversationID {
			return
		}
		m.running = ts.State == commonpb.TurnState_TURN_STATE_WORKING
		switch ts.State {
		case commonpb.TurnState_TURN_STATE_IDLE:
			m.flushStreamingToCommitted()
			m.commitSeparator()
			m.input.Focus()
		case commonpb.TurnState_TURN_STATE_FAILED:
			m.flushStreamingToCommitted()
			m.commitLine(errorStyle.Render("⚠ Turn failed: " + ts.Reason))
			m.commitLine("")
			m.input.Focus()
		case commonpb.TurnState_TURN_STATE_CANCELLED:
			m.flushStreamingToCommitted()
			m.commitLine(errorStyle.Render("⚠ Turn cancelled"))
			m.commitLine("")
			m.input.Focus()
		}
	case *commonpb.ChannelStreamOutbound_StreamItem:
		item := c.StreamItem
		if item.ConversationId != m.conversationID {
			return
		}
		m.handleStreamItem(item)
	case *commonpb.ChannelStreamOutbound_ServerRequest:
		if a, ok := toolApprovalOf(c.ServerRequest); ok {
			m.approvals = append(m.approvals, a)
		}
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

func (m *tuiModel) commitSeparator() {
	m.commitLine(sepStyle.Render("───────────────────────────────"))
	m.commitLine("")
}

// commitAssistant commits assistant text under its label, rendered as
// markdown.
func (m *tuiModel) commitAssistant(raw string) {
	rendered, err := glamour.Render(raw, "dark")
	if err != nil {
		rendered = raw
	}
	m.committed.WriteString(assistantStyle.Render("assistant") + "\n")
	m.committed.WriteString(rendered)
}

func (m *tuiModel) flushStreamingToCommitted() {
	if m.textBuf.Len() == 0 {
		return
	}
	m.commitAssistant(m.textBuf.String())
	m.textBuf.Reset()
	m.liveBuf.Reset()
}

// renderHistory commits a conversation's history: user and assistant text
// and the assistant's tool calls. Tool results, tagged sub-agent entries
// and non-text blocks are not shown.
func (m *tuiModel) renderHistory(entries []*commonpb.HistoryEntry) {
	pendingSep := false
	for _, e := range entries {
		msg := e.GetMessage()
		if e.Tag != nil || msg == nil {
			continue
		}
		switch msg.GetRole() {
		case "user":
			if pendingSep {
				m.commitSeparator()
				pendingSep = false
			}
			m.commitLine(userStyle.Render("you") + "  " + entryText(msg))
			m.commitLine("")
		case "assistant":
			if text := entryText(msg); text != "" {
				m.commitAssistant(text)
			}
			for _, tc := range msg.GetToolCalls() {
				m.commitLine(toolStyle.Render("⚙ " + tc.GetName()))
			}
			pendingSep = true
		}
	}
	if pendingSep {
		m.commitSeparator()
	}
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
	if m.running {
		indicator = statusStyle.Render(" thinking…")
	} else if !m.connected {
		indicator = errorStyle.Render(" disconnected")
	}
	pad := m.width - lipgloss.Width(ctx) - lipgloss.Width(indicator)
	if pad < 0 {
		pad = 0
	}
	status := ctx + strings.Repeat(" ", pad) + indicator

	bottom := m.input.View()
	if len(m.approvals) > 0 {
		a := m.approvals[0]
		bottom = toolStyle.Render(fmt.Sprintf("⚙ %s wants to run with input: %s · y approve · n deny", a.tool, a.input))
	}
	return m.viewport.View() + "\n" + status + "\n" + bottom
}
