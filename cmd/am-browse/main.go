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
		entries := sessions.LoadEntries()
		elapsed := time.Since(startTime)
		fmt.Fprintf(os.Stderr, "am-browse: %d sessions loaded in %s\n", len(entries), elapsed)
		return
	}

	m := newModel()
	p := tea.NewProgram(m, tea.WithAltScreen())

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
	session string
	content string
}

type killDoneMsg struct {
	session string
}

// --- Styles ---

var (
	headerStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))  // cyan
	selectedStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("10"))  // green
	normalStyle    = lipgloss.NewStyle()
	dimStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))              // dim
	previewBorder  = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("8"))
	helpOverlay    = lipgloss.NewStyle().Padding(1, 2).Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("14"))
)

// --- Model ---

type model struct {
	entries     []sessions.Entry
	filtered    []int // indices into entries
	cursor      int
	filter      textinput.Model
	preview     string
	previewFor  string // session name whose preview is loaded
	showPreview bool
	showHelp    bool
	width       int
	height      int
	output      string // what to print on exit
	loading     bool
}

func newModel() model {
	ti := textinput.New()
	ti.Placeholder = "Type to filter..."
	ti.Prompt = "> "
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
	entries := sessions.LoadEntries()
	return sessionsLoadedMsg{entries: entries}
}

func loadPreview(sessionName string) tea.Cmd {
	return func() tea.Msg {
		if previewCmd == "" || sessionName == "" {
			return previewLoadedMsg{session: sessionName, content: ""}
		}
		cmd := exec.Command(previewCmd, sessionName)
		out, _ := cmd.CombinedOutput()
		return previewLoadedMsg{session: sessionName, content: string(out)}
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
		if msg.session == m.selectedSession() {
			m.preview = msg.content
			m.previewFor = msg.session
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
			if s := m.selectedSession(); s != "" {
				m.output = s
				return m, tea.Quit
			}
			return m, nil

		case tea.KeyCtrlN:
			m.output = "__NEW__"
			return m, tea.Quit

		case tea.KeyCtrlH:
			m.output = "__RESTORE__"
			return m, tea.Quit

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
		if query == "" || fuzzyMatch(strings.ToLower(e.Display), query) {
			m.filtered = append(m.filtered, i)
		}
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = max(0, len(m.filtered)-1)
	}
}

func (m model) selectedSession() string {
	if len(m.filtered) == 0 || m.cursor >= len(m.filtered) {
		return ""
	}
	return m.entries[m.filtered[m.cursor]].Name
}

func (m model) requestPreview() tea.Cmd {
	s := m.selectedSession()
	if s == "" || s == m.previewFor {
		return nil
	}
	return loadPreview(s)
}

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	var b strings.Builder

	// Header
	header := headerStyle.Render("Agent Sessions") + "  " +
		dimStyle.Render("?:help  Enter:attach  ^N:new  ^X:kill  ^H:restore")
	b.WriteString(header)
	b.WriteByte('\n')

	// Filter input
	b.WriteString(m.filter.View())
	b.WriteByte('\n')

	// Calculate layout
	headerLines := 2 // header + filter
	listHeight := m.height - headerLines
	previewHeight := 0
	if m.showPreview && m.height > 10 {
		previewHeight = (m.height * 3) / 4
		if previewHeight > m.height-headerLines-3 {
			previewHeight = m.height - headerLines - 3
		}
		listHeight = m.height - headerLines - previewHeight
	}
	if listHeight < 1 {
		listHeight = 1
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
		// Scroll window
		start := 0
		if m.cursor >= listHeight {
			start = m.cursor - listHeight + 1
		}
		end := start + listHeight
		if end > len(m.filtered) {
			end = len(m.filtered)
		}

		for i := start; i < end; i++ {
			entry := m.entries[m.filtered[i]]
			line := entry.Display
			if len(line) > m.width-4 {
				line = line[:m.width-4]
			}

			if i == m.cursor {
				b.WriteString(selectedStyle.Render("> " + line))
			} else {
				b.WriteString(normalStyle.Render("  " + line))
			}
			b.WriteByte('\n')
		}
	}

	// Preview panel
	if m.showPreview && previewHeight > 0 {
		previewContent := m.preview
		if previewContent == "" && m.selectedSession() != "" {
			previewContent = dimStyle.Render("Loading preview...")
		}

		// Truncate preview to fit
		lines := strings.Split(previewContent, "\n")
		maxLines := previewHeight - 2 // border
		if maxLines < 0 {
			maxLines = 0
		}
		if len(lines) > maxLines {
			lines = lines[:maxLines]
		}
		previewContent = strings.Join(lines, "\n")

		styled := previewBorder.
			Width(m.width - 2).
			Height(previewHeight - 2).
			Render(previewContent)
		b.WriteString(styled)
	}

	return b.String()
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

  Navigation
    Up/Down     Move selection
    Enter       Attach to selected session
    Esc/q       Exit without action

  Actions
    Ctrl-N      Create new session
    Ctrl-H      Restore a closed session
    Ctrl-X      Kill selected session
    Ctrl-R      Refresh session list

  View
    Ctrl-P      Toggle preview panel
    ?           Show this help

  Type to filter sessions (fuzzy match)

  In tmux session
    Prefix + a  Switch to last am session
    Prefix + n  Open new-session popup
    Prefix + s  Open am browser popup
    Prefix + x  Kill current am session
    Prefix + d  Detach from session`
}

