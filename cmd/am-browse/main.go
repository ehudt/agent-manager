package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

// Command-line flags
var (
	previewCmd string
	killCmd    string
	clientName string
	benchmark  bool
)

func init() {
	flag.StringVar(&previewCmd, "preview-cmd", "", "Script to run for preview content")
	flag.StringVar(&killCmd, "kill-cmd", "", "Script to run for kill (ctrl-x)")
	flag.StringVar(&clientName, "client-name", "", "tmux client name (for kill-and-switch)")
	flag.BoolVar(&benchmark, "benchmark", false, "Print time-to-first-frame and exit")
}

func main() {
	startTime := time.Now()
	flag.Parse()

	if benchmark {
		// Load entries and measure time to "ready"
		entries := sessions.LoadBrowserEntries()
		elapsed := time.Since(startTime)
		fmt.Fprintf(os.Stderr, "am-browse: %d sessions loaded in %s\n", len(entries), elapsed)
		return
	}

	// Open /dev/tty for TUI rendering so stdout stays free for the output protocol.
	// This is needed because the caller captures stdout: result=$(am-browse ...)
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening /dev/tty: %v\n", err)
		os.Exit(1)
	}
	defer tty.Close()

	// Create renderer from tty so lipgloss detects color support correctly
	// (stdout is piped/captured, so the default renderer sees no colors).
	initStyles(lipgloss.NewRenderer(tty))

	m := newModel()
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithOutput(tty))

	result, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Output protocol: print result to stdout
	if model, ok := result.(model); ok && model.output != "" {
		fmt.Print(model.output)
	}
}

// --- Messages ---

type sessionsLoadedMsg struct {
	entries []sessions.Entry
}

type previewLoadedMsg struct {
	key     string
	content string
}

type killDoneMsg struct {
	session string
}

// --- Styles (initialized in initStyles after tty is opened) ---

var (
	accentStyle    lipgloss.Style
	titleStyle     lipgloss.Style
	selectedStyle  lipgloss.Style
	normalStyle    lipgloss.Style
	dimStyle       lipgloss.Style
	keyPillStyle   lipgloss.Style
	keyActionStyle lipgloss.Style
	separatorStyle lipgloss.Style
	helpOverlay    lipgloss.Style
)

// initStyles creates all styles from a renderer tied to the real tty,
// so color detection works even when stdout is captured by the caller.
func initStyles(r *lipgloss.Renderer) {
	accentStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))                                     // cyan accent bar
	titleStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("15"))                                      // bright white
	selectedStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("10")).Background(lipgloss.Color("235")) // green on subtle dark bg
	normalStyle = r.NewStyle()
	dimStyle = r.NewStyle().Foreground(lipgloss.Color("8"))                                                   // dim
	keyPillStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("14")).Background(lipgloss.Color("236")) // cyan on dark bg
	keyActionStyle = r.NewStyle().Foreground(lipgloss.Color("8"))                                             // dim
	separatorStyle = r.NewStyle().Foreground(lipgloss.Color("8"))
	helpOverlay = r.NewStyle().Padding(1, 2).Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("14"))
}

// --- Model ---

type model struct {
	entries     []sessions.Entry
	filtered    []int // indices into entries
	cursor      int
	filter      textinput.Model
	preview     string
	previewFor  string // preview key whose content is loaded
	showPreview bool
	showHelp    bool
	width       int
	height      int
	output      string // what to print on exit
	loading     bool
}

func newModel() model {
	ti := textinput.New()
	ti.Placeholder = "type to filter..."
	ti.Prompt = "/ "
	ti.PromptStyle = accentStyle
	ti.Focus()

	return model{
		filter:      ti,
		showPreview: true,
		loading:     true,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		textinput.Blink,
		loadSessions,
	)
}

func loadSessions() tea.Msg {
	entries := sessions.LoadBrowserEntries()
	return sessionsLoadedMsg{entries: entries}
}

func loadPreview(entry sessions.Entry) tea.Cmd {
	return func() tea.Msg {
		key := previewKey(entry)
		if key == "" {
			return previewLoadedMsg{key: key, content: ""}
		}
		if entry.Kind == sessions.EntryInactive {
			if entry.SnapshotPath != "" {
				if out, err := os.ReadFile(entry.SnapshotPath); err == nil {
					return previewLoadedMsg{key: key, content: string(out)}
				}
			}
			return previewLoadedMsg{key: key, content: "No snapshot available"}
		}
		if previewCmd == "" || entry.Name == "" {
			return previewLoadedMsg{key: key, content: ""}
		}
		cmd := exec.Command(previewCmd, entry.Name)
		out, _ := cmd.CombinedOutput()
		return previewLoadedMsg{key: key, content: string(out)}
	}
}

func killSession(sessionName string) tea.Cmd {
	return func() tea.Msg {
		if killCmd == "" || sessionName == "" {
			return killDoneMsg{session: sessionName}
		}
		client := clientName
		if client == "" {
			socket := sessions.EnvOr("AM_TMUX_SOCKET", "agent-manager")
			cmd := exec.Command("tmux", "-L", socket, "display-message", "-p", "#{client_name}")
			out, err := cmd.Output()
			if err == nil {
				client = strings.TrimSpace(string(out))
			}
		}
		cmd := exec.Command(killCmd, client, sessionName)
		_ = cmd.Run()
		return killDoneMsg{session: sessionName}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case sessionsLoadedMsg:
		m.entries = msg.entries
		m.loading = false
		m.applyFilter()
		return m, m.requestPreview()

	case previewLoadedMsg:
		// Only accept if still relevant
		if msg.key == m.selectedPreviewKey() {
			m.preview = msg.content
			m.previewFor = msg.key
		}
		return m, nil

	case killDoneMsg:
		// Reload sessions after kill
		return m, loadSessions

	case tea.KeyMsg:
		// Help overlay captures all keys
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

		switch msg.Type {
		case tea.KeyEsc:
			m.output = ""
			return m, tea.Quit

		case tea.KeyEnter:
			if entry, ok := m.selectedEntry(); ok {
				if entry.Kind == sessions.EntryInactive {
					m.output = "__RESTORE__\x1f" + entry.Meta.Directory + "\x1f" + entry.RestoreSessionID
				} else {
					m.output = entry.Name
				}
				return m, tea.Quit
			}
			return m, nil

		case tea.KeyCtrlN:
			m.output = "__NEW__"
			return m, tea.Quit

		case tea.KeyCtrlH:
			if m.moveToFirstKind(sessions.EntryInactive) {
				return m, m.requestPreview()
			}
			return m, nil

		case tea.KeyCtrlX:
			if s := m.selectedSession(); s != "" {
				return m, killSession(s)
			}
			return m, nil

		case tea.KeyCtrlR:
			m.loading = true
			return m, loadSessions

		case tea.KeyCtrlP:
			m.showPreview = !m.showPreview
			return m, nil

		case tea.KeyUp:
			if m.cursor > 0 {
				m.cursor--
				return m, m.requestPreview()
			}
			return m, nil

		case tea.KeyDown:
			if m.cursor < len(m.filtered)-1 {
				m.cursor++
				return m, m.requestPreview()
			}
			return m, nil

		case tea.KeyRunes:
			if msg.String() == "q" && m.filter.Value() == "" {
				m.output = ""
				return m, tea.Quit
			}
			if msg.String() == "?" && m.filter.Value() == "" {
				m.showHelp = true
				return m, nil
			}
			// Fall through to textinput
		}

		// Update text input for filter
		oldVal := m.filter.Value()
		var cmd tea.Cmd
		m.filter, cmd = m.filter.Update(msg)
		if m.filter.Value() != oldVal {
			m.applyFilter()
			return m, tea.Batch(cmd, m.requestPreview())
		}
		return m, cmd
	}

	// Pass other messages to textinput
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	return m, cmd
}

func (m *model) applyFilter() {
	query := strings.ToLower(m.filter.Value())
	m.filtered = nil
	for i, e := range m.entries {
		haystack := strings.ToLower(e.Display)
		if e.Kind == sessions.EntryInactive {
			haystack += " inactive restore closed"
		}
		if query == "" || fuzzyMatch(haystack, query) {
			m.filtered = append(m.filtered, i)
		}
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = maxInt(0, len(m.filtered)-1)
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type listRow struct {
	divider     bool
	label       string
	entryIndex  int
	filteredPos int
}

func (m model) selectedEntry() (sessions.Entry, bool) {
	if len(m.filtered) == 0 || m.cursor >= len(m.filtered) {
		return sessions.Entry{}, false
	}
	return m.entries[m.filtered[m.cursor]], true
}

func (m model) selectedSession() string {
	entry, ok := m.selectedEntry()
	if !ok || entry.Kind == sessions.EntryInactive {
		return ""
	}
	return entry.Name
}

func (m model) selectedPreviewKey() string {
	entry, ok := m.selectedEntry()
	if !ok {
		return ""
	}
	return previewKey(entry)
}

func previewKey(entry sessions.Entry) string {
	if entry.Kind == sessions.EntryInactive {
		if entry.RestoreSessionID == "" {
			return ""
		}
		return "inactive:" + entry.RestoreSessionID
	}
	if entry.Name == "" {
		return ""
	}
	return "active:" + entry.Name
}

func (m *model) moveToFirstKind(kind sessions.EntryKind) bool {
	for pos, idx := range m.filtered {
		if m.entries[idx].Kind == kind {
			m.cursor = pos
			return true
		}
	}
	return false
}

func (m model) entryCounts() (active, inactive int) {
	for _, entry := range m.entries {
		switch entry.Kind {
		case sessions.EntryInactive:
			inactive++
		default:
			active++
		}
	}
	return active, inactive
}

func (m model) listRows() ([]listRow, int) {
	rows := make([]listRow, 0, len(m.filtered)+1)
	cursorRow := -1
	inactiveDividerAdded := false
	for pos, idx := range m.filtered {
		if m.entries[idx].Kind == sessions.EntryInactive && !inactiveDividerAdded {
			rows = append(rows, listRow{divider: true, label: "Inactive sessions"})
			inactiveDividerAdded = true
		}
		if pos == m.cursor {
			cursorRow = len(rows)
		}
		rows = append(rows, listRow{entryIndex: idx, filteredPos: pos})
	}
	return rows, cursorRow
}

func (m model) requestPreview() tea.Cmd {
	entry, ok := m.selectedEntry()
	if !ok {
		return nil
	}
	key := previewKey(entry)
	if key == "" || key == m.previewFor {
		return nil
	}
	return loadPreview(entry)
}

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	var b strings.Builder

	// Header: accent bar + title + session count
	b.WriteByte('\n')
	activeCount, inactiveCount := m.entryCounts()
	countLabel := fmt.Sprintf("%d active", activeCount)
	if inactiveCount > 0 {
		countLabel = fmt.Sprintf("%d active, %d inactive", activeCount, inactiveCount)
	}
	countStr := dimStyle.Render(countLabel)
	title := "  " + accentStyle.Render("▎") + " " + titleStyle.Render("Agent Sessions")
	// Right-align count: pad between title and count
	titleVisLen := 2 + 2 + 14 // "  " + "▎ " + "Agent Sessions"
	countVisLen := len(countLabel)
	pad := m.width - titleVisLen - countVisLen
	if pad < 2 {
		pad = 2
	}
	b.WriteString(title + strings.Repeat(" ", pad) + countStr)
	b.WriteByte('\n')
	b.WriteString("  " + separatorStyle.Render(strings.Repeat("─", m.width-4)))
	b.WriteByte('\n')

	// Keybind pills
	b.WriteString("   ")
	keys := []struct{ key, action string }{
		{"?", "help"}, {"⏎", "open"}, {"^N", "new"}, {"^X", "kill"}, {"^R", "refresh"},
	}
	for i, k := range keys {
		b.WriteString(keyPillStyle.Render(" " + k.key + " "))
		b.WriteString(keyActionStyle.Render(" " + k.action))
		if i < len(keys)-1 {
			b.WriteString("  ")
		}
	}
	b.WriteByte('\n')

	// Filter input
	b.WriteByte('\n')
	b.WriteString("   ")
	b.WriteString(m.filter.View())
	b.WriteString("\n\n")

	// Calculate layout: list gets 25% of space, preview gets 75% (like fzf config)
	// 8 = blank + title + separator + keybinds + blank + filter + blank,
	// plus the blank line emitted between the list and the preview separator.
	headerLines := 8
	available := m.height - headerLines
	if available < 1 {
		available = 1
	}
	listHeight := available
	previewHeight := 0
	if m.showPreview && available > 6 {
		listHeight = maxInt(3, available/4)
		previewHeight = available - listHeight
	}

	// Help overlay
	if m.showHelp {
		help := helpText()
		styled := helpOverlay.Width(m.width - 6).Render(help)
		b.WriteString(styled)
		return b.String()
	}

	// Session list
	if m.loading && len(m.entries) == 0 {
		b.WriteString(dimStyle.Render("  Loading sessions..."))
		b.WriteByte('\n')
	} else if len(m.filtered) == 0 {
		if m.filter.Value() != "" {
			b.WriteString(dimStyle.Render("  No matches"))
		} else {
			b.WriteString(dimStyle.Render("  No sessions"))
		}
		b.WriteByte('\n')
	} else {
		rows, cursorRow := m.listRows()

		// Scroll window
		start := 0
		if cursorRow >= listHeight {
			start = cursorRow - listHeight + 1
		}
		end := start + listHeight
		if end > len(rows) {
			end = len(rows)
		}

		// Find longest base display among visible entries to set time column position
		maxBaseLen := 0
		for i := start; i < end; i++ {
			row := rows[i]
			if row.divider {
				continue
			}
			if n := len(m.entries[row.entryIndex].DisplayBase); n > maxBaseLen {
				maxBaseLen = n
			}
		}
		// Time column starts 2 tabs (16 chars) after the longest base, capped to terminal width
		timeCol := maxBaseLen + 16 // 16 ≈ two tabs of breathing room
		maxTimeCol := m.width - 14 // leave room for "(XXh XXm ago)"
		if maxTimeCol < 10 {
			maxTimeCol = 10
		}
		if timeCol > maxTimeCol {
			timeCol = maxTimeCol
		}

		for i := start; i < end; i++ {
			row := rows[i]
			if row.divider {
				b.WriteString(sectionDivider(row.label, m.width))
				b.WriteByte('\n')
				continue
			}

			entry := m.entries[row.entryIndex]
			base := entry.DisplayBase
			timeAgo := "(" + entry.TimeAgo + ")"

			prefix := "  "
			if row.filteredPos == m.cursor {
				prefix = "> "
			}

			// Truncate base if it would overlap the time column
			maxBase := timeCol - 2 // 2 = prefix width
			if maxBase < 10 {
				maxBase = 10
			}
			if len(base) > maxBase {
				base = base[:maxBase]
			}
			gap := timeCol - len(base)
			if gap < 2 {
				gap = 2
			}
			line := prefix + base + strings.Repeat(" ", gap) + timeAgo

			if row.filteredPos == m.cursor {
				// Pad to full width for background highlight
				if len(line) < m.width {
					line += strings.Repeat(" ", m.width-len(line))
				}
				b.WriteString(selectedStyle.Render(line))
			} else {
				b.WriteString(normalStyle.Render(line))
			}
			b.WriteByte('\n')
		}
	}

	b.WriteByte('\n')

	// Preview panel — render ANSI content directly with a simple separator
	if m.showPreview && previewHeight > 0 {
		// Draw separator line
		b.WriteString(separatorStyle.Render(strings.Repeat("─", m.width)))
		b.WriteByte('\n')

		previewContent := ""
		selectedKey := m.selectedPreviewKey()
		if selectedKey != "" && m.previewFor == selectedKey {
			previewContent = m.preview
		}
		if previewContent == "" && selectedKey != "" {
			previewContent = dimStyle.Render("Loading preview...")
		}

		// Show tail of preview (most recent output), leave 1 line for separator
		lines := strings.Split(previewContent, "\n")
		maxLines := previewHeight - 1
		if maxLines < 1 {
			maxLines = 1
		}
		if len(lines) > maxLines {
			lines = lines[len(lines)-maxLines:]
		}
		// Truncate lines by visible width (skip ANSI escapes when counting)
		for i, line := range lines {
			lines[i] = truncateVisible(line, m.width)
		}

		b.WriteString(strings.Join(lines, "\n"))
	}

	return b.String()
}

func sectionDivider(label string, width int) string {
	line := "  " + label
	if width > len(line)+1 {
		line += " " + strings.Repeat("─", width-len(line)-1)
	}
	return separatorStyle.Render(line)
}

// --- Fuzzy matching ---

// fuzzyMatch does simple subsequence matching (like fzf's basic algorithm).
func fuzzyMatch(text, pattern string) bool {
	pi := 0
	for ti := 0; ti < len(text) && pi < len(pattern); ti++ {
		if text[ti] == pattern[pi] {
			pi++
		}
	}
	return pi == len(pattern)
}

func helpText() string {
	return `  Agent Manager Help

  Keybindings
    Up/Down     Move selection
    Enter       Attach active session or restore inactive session
    Esc/q       Exit without action
    Ctrl-N      Create new session
    Ctrl-X      Kill selected active session
    Ctrl-R      Refresh session list
    ?           Show this help

  Type to filter sessions (fuzzy match)

  In tmux session
    Prefix + 1-9  Jump to sidebar slot N
    Prefix + a  Switch to last am session
    Prefix + n  Open new-session popup
    Prefix + s  Open am browser popup
    Prefix + x  Kill current am session
    Prefix + d  Detach from session
    Prefix Up/Down
                Switch panes (agent/shell)
    :am         Open am browser (tmux command)`
}

// truncateVisible truncates a string to maxWidth visible characters,
// preserving ANSI escape sequences (they contribute zero visible width).
func truncateVisible(s string, maxWidth int) string {
	visible := 0
	inEsc := false
	var out strings.Builder
	out.Grow(len(s))
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if ch == '\x1b' {
			inEsc = true
			out.WriteByte(ch)
			continue
		}
		if inEsc {
			out.WriteByte(ch)
			// CSI sequences end with a letter; OSC ends with BEL
			if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '\x07' {
				inEsc = false
			}
			continue
		}
		if visible >= maxWidth {
			break
		}
		out.WriteByte(ch)
		visible++
	}
	return out.String()
}
