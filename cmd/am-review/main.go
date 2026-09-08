// am-review is the collapsible review pane of an am session (`am review`,
// prefix+v): a bubbletea TUI that shows what the agent changed since the
// session's review baseline (lib/review.sh, internal/sessions/review.go) —
// the changed files with their line counts and the unified diff of the
// selected one — and refreshes itself when the state hook's .dirty sidecar
// moves (every tool event), so an edit shows up within a second without
// polling git. `a` acknowledges (new baseline) through `am diff --ack`, so the
// tab count and registry follow.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

const (
	focusFiles = iota
	focusDiff
)

// Full re-measure every fullEvery ticks even without a .dirty change: catches
// `am diff --ack` / `--reset` run elsewhere and edits by agents without hooks.
const fullEvery = 15

var (
	styleTitle   = lipgloss.NewStyle().Bold(true)
	styleDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	styleAdd     = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleDel     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleHunk    = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	styleCurHunk = lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true).Reverse(true)
	styleSel     = lipgloss.NewStyle().Reverse(true)
	styleSelDim  = lipgloss.NewStyle().Bold(true)
	styleErr     = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	styleOK      = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleKey     = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
)

type model struct {
	env     sessions.Env
	session string
	dir     string
	amPath  string
	poll    time.Duration

	width, height int
	focus         int
	showHelp      bool

	base  sessions.Checkpoint
	stat  sessions.ReviewStat
	moved string
	files []sessions.FileStat
	sel   int
	fileTop int // first visible file row

	doc  diffDoc
	vp   viewport.Model
	hunk int

	measuring bool
	loading   string // path whose diff is being loaded
	dirtyAt   time.Time
	ticks     int
	err       string
	msg       string
	msgAt     time.Time
}

type tickMsg time.Time

type measuredMsg struct {
	base  sessions.Checkpoint
	stat  sessions.ReviewStat
	moved string
	files []sessions.FileStat
	err   error
}

type diffMsg struct {
	path string
	text string
	err  error
}

type ackMsg struct{ err error }

func main() {
	var (
		session  = flag.String("session", os.Getenv("AM_SESSION_NAME"), "am session name")
		dir      = flag.String("dir", "", "repository directory (the session's effective directory)")
		amPath   = flag.String("am", "", "path to the am entry point (for --ack)")
		amDir    = flag.String("am-dir", "", "override $AM_DIR")
		stateDir = flag.String("state-dir", "", "override $AM_STATE_DIR")
		poll     = flag.Duration("poll", time.Second, "how often to check the .dirty sidecar")
	)
	flag.Parse()
	if *session == "" || *dir == "" {
		fmt.Fprintln(os.Stderr, "usage: am-review --session <name> --dir <dir> [--am <path>]")
		os.Exit(2)
	}
	env := sessions.LoadEnv()
	if *amDir != "" {
		env.AmDir = *amDir
	}
	if *stateDir != "" {
		env.StateDir = *stateDir
	}
	m := model{env: env, session: *session, dir: *dir, amPath: *amPath, poll: *poll, hunk: -1}
	m.vp = viewport.New(80, 20)
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "am-review:", err)
		os.Exit(1)
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.measure(), m.tick())
}

func (m model) tick() tea.Cmd {
	return tea.Tick(m.poll, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) dirtyPath() string {
	return filepath.Join(m.env.StateDir, m.session+".dirty")
}

// measure re-syncs checkpoints, measures the unreviewed change (recording it
// on the registry row so the tab agrees with the pane), and lists the files.
func (m model) measure() tea.Cmd {
	env, session, dir := m.env, m.session, m.dir
	return func() tea.Msg {
		cp, rs, moved, err := env.ReviewMeasure(session, dir, "", true)
		if err != nil {
			return measuredMsg{err: err}
		}
		files, ferr := sessions.ReviewFileStats(dir, rs.BaseTree, rs.CurTree)
		if ferr != nil {
			return measuredMsg{err: ferr}
		}
		return measuredMsg{base: cp, stat: rs, moved: moved, files: files}
	}
}

func (m model) loadDiff(path string) tea.Cmd {
	dir, base, cur := m.dir, m.stat.BaseTree, m.stat.CurTree
	return func() tea.Msg {
		text, err := sessions.ReviewFileDiff(dir, base, cur, path)
		return diffMsg{path: path, text: text, err: err}
	}
}

// ack runs `am diff --ack <session>` (registry count, sidebar redraw) when am
// is known, else acknowledges through the store directly.
func (m model) ack() tea.Cmd {
	env, session, dir, amPath := m.env, m.session, m.dir, m.amPath
	return func() tea.Msg {
		if amPath != "" {
			cmd := exec.Command(amPath, "diff", "--ack", session)
			cmd.Env = os.Environ()
			if out, err := cmd.CombinedOutput(); err != nil {
				return ackMsg{err: fmt.Errorf("%s", strings.TrimSpace(string(out)))}
			}
			return ackMsg{}
		}
		if _, err := sessions.ReviewAck(dir, session); err != nil {
			return ackMsg{err: err}
		}
		env.ReviewRecord(session, sessions.ReviewStat{}, time.Now())
		return ackMsg{}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.layout()
		m.renderDiff()
		return m, nil

	case tickMsg:
		m.ticks++
		var cmd tea.Cmd
		if !m.measuring {
			fi, err := os.Stat(m.dirtyPath())
			dirty := err == nil && fi.ModTime().After(m.dirtyAt)
			if dirty {
				m.dirtyAt = fi.ModTime()
			}
			if dirty || m.ticks%fullEvery == 0 {
				m.measuring = true
				cmd = m.measure()
			}
		}
		if m.msg != "" && time.Since(m.msgAt) > 6*time.Second {
			m.msg = ""
		}
		return m, tea.Batch(m.tick(), cmd)

	case measuredMsg:
		m.measuring = false
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		m.err = ""
		m.base, m.stat, m.moved, m.files = msg.base, msg.stat, msg.moved, msg.files
		m.layout() // the stacked file list grows with the file count
		if m.sel >= len(m.files) {
			m.sel = len(m.files) - 1
		}
		if m.sel < 0 {
			m.sel = 0
		}
		if len(m.files) == 0 {
			m.doc = diffDoc{}
			m.hunk = -1
			m.renderDiff()
			return m, nil
		}
		return m, m.loadDiff(m.files[m.sel].Path)

	case diffMsg:
		if len(m.files) == 0 || msg.path != m.files[m.sel].Path {
			return m, nil // stale: selection moved on
		}
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		prevPath := m.doc.Path
		m.doc = parseDiff(msg.path, msg.text)
		if prevPath != msg.path {
			m.vp.GotoTop()
			m.hunk = m.doc.hunkAt(0)
			if m.hunk < 0 && len(m.doc.Hunks) > 0 {
				m.hunk = 0
			}
		} else if m.hunk >= len(m.doc.Hunks) {
			m.hunk = len(m.doc.Hunks) - 1
		}
		m.renderDiff()
		return m, nil

	case ackMsg:
		if msg.err != nil {
			m.flash(styleErr.Render("ack failed: " + msg.err.Error()))
			return m, nil
		}
		m.flash(styleOK.Render("reviewed — baseline moved to the working copy"))
		m.measuring = true
		return m, m.measure()

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m *model) flash(s string) {
	m.msg, m.msgAt = s, time.Now()
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.showHelp {
		m.showHelp = false
		return m, nil
	}
	switch msg.String() {
	case "q", "ctrl+c", "esc":
		return m, tea.Quit
	case "?":
		m.showHelp = true
		return m, nil
	case "tab":
		if m.focus == focusFiles {
			m.focus = focusDiff
		} else {
			m.focus = focusFiles
		}
		m.renderDiff()
		return m, nil
	case "enter":
		m.focus = focusDiff
		m.renderDiff()
		return m, nil
	case "r":
		m.measuring = true
		m.flash(styleDim.Render("refreshing…"))
		return m, m.measure()
	case "a":
		if m.stat.Files == 0 {
			m.flash(styleDim.Render("nothing to acknowledge"))
			return m, nil
		}
		return m, m.ack()
	case "J", "n":
		return m.selectFile(m.sel + 1)
	case "K", "p":
		return m.selectFile(m.sel - 1)
	case "]":
		m.gotoHunk(m.hunk + 1)
		return m, nil
	case "[":
		m.gotoHunk(m.hunk - 1)
		return m, nil
	case "g":
		m.vp.GotoTop()
		m.syncHunk()
		return m, nil
	case "G":
		m.vp.GotoBottom()
		m.syncHunk()
		return m, nil
	case "pgdown", " ", "f", "ctrl+d":
		m.vp.PageDown()
		m.syncHunk()
		return m, nil
	case "pgup", "b", "ctrl+u":
		m.vp.PageUp()
		m.syncHunk()
		return m, nil
	case "j", "down":
		if m.focus == focusFiles {
			return m.selectFile(m.sel + 1)
		}
		m.vp.ScrollDown(1)
		m.syncHunk()
		return m, nil
	case "k", "up":
		if m.focus == focusFiles {
			return m.selectFile(m.sel - 1)
		}
		m.vp.ScrollUp(1)
		m.syncHunk()
		return m, nil
	}
	return m, nil
}

func (m model) selectFile(i int) (tea.Model, tea.Cmd) {
	if len(m.files) == 0 {
		return m, nil
	}
	if i < 0 {
		i = 0
	}
	if i >= len(m.files) {
		i = len(m.files) - 1
	}
	if i == m.sel {
		return m, nil
	}
	m.sel = i
	return m, m.loadDiff(m.files[m.sel].Path)
}

// gotoHunk scrolls the viewport so hunk i's header is the top line.
func (m *model) gotoHunk(i int) {
	if len(m.doc.Hunks) == 0 {
		return
	}
	if i < 0 {
		i = 0
	}
	if i >= len(m.doc.Hunks) {
		i = len(m.doc.Hunks) - 1
	}
	m.hunk = i
	m.focus = focusDiff
	m.renderDiff()
	m.vp.SetYOffset(m.doc.Hunks[i].Start)
}

// syncHunk makes the current hunk the one at the top of the viewport.
func (m *model) syncHunk() {
	if h := m.doc.hunkAt(m.vp.YOffset); h >= 0 && h != m.hunk {
		m.hunk = h
		m.renderDiff()
	}
}

// --- layout -----------------------------------------------------------

func (m model) sideBySide() bool { return m.width >= 90 }

// filesWidth is the file column width in side-by-side mode.
func (m model) filesWidth() int {
	w := m.width / 3
	if w < 24 {
		w = 24
	}
	if w > 44 {
		w = 44
	}
	return w
}

func (m model) bodyHeight() int {
	h := m.height - 2 // header + footer
	if h < 1 {
		h = 1
	}
	return h
}

// filesRows is the height of the stacked file list.
func (m model) filesRows() int {
	n := len(m.files)
	if n == 0 {
		n = 1
	}
	if n > 8 {
		n = 8
	}
	if max := m.bodyHeight() / 2; n > max && max >= 1 {
		n = max
	}
	return n
}

func (m *model) layout() {
	if m.sideBySide() {
		m.vp.Width = m.width - m.filesWidth() - 1
		m.vp.Height = m.bodyHeight()
	} else {
		m.vp.Width = m.width
		m.vp.Height = m.bodyHeight() - m.filesRows() - 1
	}
	if m.vp.Width < 1 {
		m.vp.Width = 1
	}
	if m.vp.Height < 1 {
		m.vp.Height = 1
	}
}

// renderDiff styles the parsed diff for the viewport at its current width.
func (m *model) renderDiff() {
	w := m.vp.Width
	if len(m.doc.Lines) == 0 {
		m.vp.SetContent(m.emptyDiffText())
		return
	}
	out := make([]string, len(m.doc.Lines))
	cur := -1
	if m.hunk >= 0 && m.hunk < len(m.doc.Hunks) {
		cur = m.doc.Hunks[m.hunk].Start
	}
	for i, l := range m.doc.Lines {
		t := truncRunes(l, w)
		switch {
		case i == cur:
			out[i] = styleCurHunk.Render(padRight(t, w))
		case strings.HasPrefix(l, "@@"):
			out[i] = styleHunk.Render(t)
		case strings.HasPrefix(l, "+++") || strings.HasPrefix(l, "---") ||
			strings.HasPrefix(l, "diff --git") || strings.HasPrefix(l, "index ") ||
			strings.HasPrefix(l, "new file") || strings.HasPrefix(l, "deleted file") ||
			strings.HasPrefix(l, "old mode") || strings.HasPrefix(l, "new mode") ||
			strings.HasPrefix(l, "Binary files"):
			out[i] = styleDim.Render(t)
		case strings.HasPrefix(l, "+"):
			out[i] = styleAdd.Render(t)
		case strings.HasPrefix(l, "-"):
			out[i] = styleDel.Render(t)
		default:
			out[i] = t
		}
	}
	m.vp.SetContent(strings.Join(out, "\n"))
}

func (m model) emptyDiffText() string {
	if m.err != "" {
		return styleErr.Render(truncRunes(m.err, m.vp.Width))
	}
	if len(m.files) == 0 {
		if m.base.ID == "" {
			return styleDim.Render("measuring…")
		}
		return styleDim.Render("No unreviewed changes since the " + m.base.Kind + " checkpoint.") +
			"\n" + styleDim.Render("This pane refreshes when the agent edits a file.")
	}
	if m.files[m.sel].Binary {
		return styleDim.Render("Binary file.")
	}
	return styleDim.Render("loading…")
}

// --- view -------------------------------------------------------------

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	if m.showHelp {
		return m.helpView()
	}
	var b strings.Builder
	b.WriteString(m.headerView())
	b.WriteString("\n")
	if m.sideBySide() {
		fw := m.filesWidth()
		files := m.fileRows(fw, m.bodyHeight())
		diff := strings.Split(m.vp.View(), "\n")
		sep := styleDim.Render("│")
		for i := 0; i < m.bodyHeight(); i++ {
			row := ""
			if i < len(files) {
				row = files[i]
			} else {
				row = strings.Repeat(" ", fw)
			}
			d := ""
			if i < len(diff) {
				d = diff[i]
			}
			b.WriteString(row + sep + d + "\n")
		}
	} else {
		rows := m.fileRows(m.width, m.filesRows())
		for _, r := range rows {
			b.WriteString(r + "\n")
		}
		b.WriteString(styleDim.Render(strings.Repeat("─", m.width)) + "\n")
		b.WriteString(m.vp.View() + "\n")
	}
	b.WriteString(m.footerView())
	return b.String()
}

func (m model) headerView() string {
	now := time.Now().Unix()
	left := styleTitle.Render(m.session)
	var rest string
	switch {
	case m.err != "" && m.base.ID == "":
		rest = styleErr.Render(m.err)
	case m.base.ID == "":
		rest = styleDim.Render("measuring…")
	default:
		rest = " " + statLine(m.stat.Files, m.stat.Added, m.stat.Deleted) +
			styleDim.Render(" since the "+m.base.Kind+" checkpoint "+shortID(m.base.ID)+" ("+ago(m.base.Time, now)+")")
		if m.moved != "" && m.moved != "-" {
			rest += styleDim.Render("; HEAD moved: " + m.moved)
		}
	}
	if m.measuring {
		rest += styleDim.Render(" ⟳")
	}
	return truncRunes(left+rest, m.width)
}

func shortID(id string) string {
	if len(id) > 7 {
		return id[:7]
	}
	return id
}

// fileRows renders the file list, keeping the selection visible.
func (m model) fileRows(w, h int) []string {
	rows := make([]string, 0, h)
	if len(m.files) == 0 {
		msg := "no changed files"
		if m.base.ID == "" {
			msg = ""
		}
		rows = append(rows, padRight(styleDim.Render(truncRunes(msg, w)), w))
		return rows
	}
	top := m.fileTop
	if m.sel < top {
		top = m.sel
	}
	if m.sel >= top+h {
		top = m.sel - h + 1
	}
	if top < 0 {
		top = 0
	}
	for i := top; i < len(m.files) && len(rows) < h; i++ {
		f := m.files[i]
		var counts string
		if f.Binary {
			counts = "  bin  "
		} else {
			counts = fmt.Sprintf("%4s %-4s", "+"+itoa(f.Added), "−"+itoa(f.Deleted))
		}
		pathW := w - len([]rune(counts)) - 2
		if pathW < 4 {
			pathW = 4
		}
		line := " " + counts + " " + tailPath(f.Path, pathW)
		line = padRight(truncRunes(line, w), w)
		switch {
		case i == m.sel && m.focus == focusFiles:
			line = styleSel.Render(line)
		case i == m.sel:
			line = styleSelDim.Render(line)
		default:
			// colour the counts only
			line = " " + styleAdd.Render(counts[:4]) + " " + styleDel.Render(counts[5:]) + line[len(counts)+1:]
		}
		rows = append(rows, line)
	}
	return rows
}

func itoa(n int) string { return fmt.Sprintf("%d", n) }

func (m model) footerView() string {
	if m.msg != "" {
		return truncRunes(m.msg, m.width)
	}
	hint := func(k, what string) string { return styleKey.Render(k) + styleDim.Render(" "+what) }
	parts := []string{
		hint("j/k", "file"),
		hint("]/[", "hunk"),
		hint("tab", "focus"),
		hint("a", "reviewed"),
		hint("r", "refresh"),
		hint("q", "close"),
		hint("?", "help"),
	}
	if m.hunk >= 0 && m.hunk < len(m.doc.Hunks) {
		parts = append(parts, styleDim.Render(fmt.Sprintf("hunk %d/%d %s", m.hunk+1, len(m.doc.Hunks), m.doc.Hunks[m.hunk].lineRange())))
	}
	return truncRunes(strings.Join(parts, "  "), m.width)
}

func (m model) helpView() string {
	lines := []string{
		styleTitle.Render("am review — what the agent changed since you last looked"),
		"",
		"  j / k, ↑ / ↓     next / previous file (in the file list); scroll the diff otherwise",
		"  J / K, n / p     next / previous file from anywhere",
		"  ] / [            next / previous hunk",
		"  tab, enter       move focus between the file list and the diff",
		"  space, b, g, G   page down / page up / top / bottom of the diff",
		"  a                mark the working copy reviewed (am diff --ack): new baseline",
		"  r                re-measure now (the pane also refreshes on every tool event)",
		"  q                close the pane (prefix+v or `am review` reopens it)",
		"",
		styleDim.Render("Baseline: the working copy at launch, then whatever you acknowledged; a branch"),
		styleDim.Render("switch moves it to the new branch as checked out. `am diff --list` shows the chain."),
		"",
		styleDim.Render("any key to return"),
	}
	return strings.Join(lines, "\n")
}
