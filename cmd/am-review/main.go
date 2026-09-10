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

	"github.com/charmbracelet/bubbles/textinput"
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

	base    sessions.Checkpoint
	stat    sessions.ReviewStat
	moved   string
	files   []sessions.FileStat
	sel     int
	fileTop int // first visible file row

	// Base checkpoint picker (`s`): from pins the checkpoint the diff is
	// measured since ("" = the baseline, like `am diff`; an id = a one-off
	// view like `am diff --checkpoint`, nothing recorded).
	from       string
	picking    bool
	picks      []sessions.Checkpoint          // newest first
	pickStats  map[string]sessions.ReviewStat // checkpoint id → change from it to the worktree
	pickBase   string                         // baseline id at load time
	pickSel    int
	pickTyping bool // `/`: a commit-ish is being typed
	pickInput  textinput.Model

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

	// Hunk-to-prompt (`c`): the note being typed for noteTarget.
	noting     bool
	note       textinput.Model
	noteTarget noteTarget
	sending    bool
}

// noteTarget pins what a note is about while the user types: the file, the
// hunk's new-side range, and the hunk text as shown (the diff may reload
// under the note when the agent keeps editing).
type noteTarget struct {
	path      string
	lineRange string
	hunkText  string
}

type sentMsg struct {
	target noteTarget
	res    sendResult
	err    error
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

type checkpointsMsg struct {
	st    sessions.ReviewState
	stats map[string]sessions.ReviewStat
	err   error
}

// commitPickMsg is a commit the user typed in the picker, resolved and sized.
type commitPickMsg struct {
	rev  string
	cp   sessions.Checkpoint
	stat sessions.ReviewStat
	ok   bool
}

type baselineMsg struct {
	cp  sessions.Checkpoint
	err error
}

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
	m.note = textinput.New()
	m.note.Prompt = ""
	m.note.CharLimit = 2000
	m.pickInput = textinput.New()
	m.pickInput.Prompt = ""
	m.pickInput.CharLimit = 200
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
// With a picked base (m.from) it measures since that checkpoint instead and
// records nothing: the tab keeps tracking the real baseline.
func (m model) measure() tea.Cmd {
	env, session, dir, from := m.env, m.session, m.dir, m.from
	return func() tea.Msg {
		cp, rs, moved, err := env.ReviewMeasure(session, dir, from, from == "")
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

// loadCheckpoints reads the session's checkpoint chain for the picker and
// sizes the change from each checkpoint to the worktree (one snapshot, one
// numstat per row), so a base can be chosen by what it would show.
func (m model) loadCheckpoints() tea.Cmd {
	session, dir := m.session, m.dir
	return func() tea.Msg {
		_, _, _ = sessions.ReviewSync(dir, session) // record a HEAD move first, so the list is current
		st, err := sessions.ReviewRead(dir, session)
		if err != nil {
			return checkpointsMsg{st: st, err: err}
		}
		stats := map[string]sessions.ReviewStat{}
		if cur, err := sessions.WorktreeTree(dir); err == nil {
			for _, cp := range st.Checkpoints {
				if rs, err := sessions.ReviewStatTrees(dir, cp.Tree, cur); err == nil {
					stats[cp.ID] = rs
				}
			}
		}
		return checkpointsMsg{st: st, stats: stats}
	}
}

// resolveCommit turns a typed commit-ish into a virtual checkpoint row for
// the picker, sized like the chain rows.
func (m model) resolveCommit(rev string) tea.Cmd {
	dir := m.dir
	return func() tea.Msg {
		cp, ok := sessions.CommitCheckpoint(dir, rev)
		if !ok {
			return commitPickMsg{rev: rev}
		}
		var rs sessions.ReviewStat
		if cur, err := sessions.WorktreeTree(dir); err == nil {
			rs, _ = sessions.ReviewStatTrees(dir, cp.Tree, cur)
		}
		return commitPickMsg{rev: rev, cp: cp, stat: rs, ok: true}
	}
}

// setBaseline moves the baseline ref to checkpoint id; the following measure
// (from == "") records the new count on the registry row.
func (m model) setBaseline(id string) tea.Cmd {
	session, dir := m.session, m.dir
	return func() tea.Msg {
		cp, err := sessions.ReviewSetBaseline(dir, session, id)
		return baselineMsg{cp: cp, err: err}
	}
}

// send delivers the note for target through am (see note.go).
func (m model) send(target noteTarget, note string) tea.Cmd {
	amPath, session := m.amPath, m.session
	text := noteMessage(target.path, target.lineRange, target.hunkText, note)
	return func() tea.Msg {
		res, err := sendNote(amPath, session, text)
		return sentMsg{target: target, res: res, err: err}
	}
}

// currentNoteTarget is the hunk under the cursor, or the selected file alone
// when it has no hunks (binary, or the diff is still loading).
func (m model) currentNoteTarget() (noteTarget, bool) {
	if len(m.files) == 0 {
		return noteTarget{}, false
	}
	t := noteTarget{path: m.files[m.sel].Path}
	if m.doc.Path == t.path && m.hunk >= 0 && m.hunk < len(m.doc.Hunks) {
		t.lineRange = m.doc.Hunks[m.hunk].lineRange()
		t.hunkText = m.doc.hunkText(m.hunk, noteHunkLimit)
	}
	return t, true
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
		m.from = "" // the new baseline is what to look at now
		m.measuring = true
		return m, m.measure()

	case checkpointsMsg:
		if msg.err != nil {
			m.flash(styleErr.Render("checkpoints: " + msg.err.Error()))
			return m, nil
		}
		if len(msg.st.Checkpoints) == 0 {
			m.flash(styleDim.Render("no checkpoints yet"))
			return m, nil
		}
		m.picks, m.pickStats, m.pickBase = msg.st.Checkpoints, msg.stats, msg.st.BaselineID()
		if m.pickStats == nil {
			m.pickStats = map[string]sessions.ReviewStat{}
		}
		m.pickSel = 0
		for i, cp := range m.picks { // start on the base shown now
			if cp.ID == m.base.ID {
				m.pickSel = i
				break
			}
		}
		m.picking, m.pickTyping = true, false
		m.msg = ""
		return m, nil

	case commitPickMsg:
		if !m.picking {
			return m, nil
		}
		if !msg.ok {
			m.flash(styleErr.Render("no commit " + msg.rev))
			return m, nil
		}
		// One row per commit: re-typing an id re-selects its row.
		m.pickStats[msg.cp.ID] = msg.stat
		for i, cp := range m.picks {
			if cp.ID == msg.cp.ID {
				m.pickSel = i
				return m, nil
			}
		}
		m.picks = append([]sessions.Checkpoint{msg.cp}, m.picks...)
		m.pickSel = 0
		return m, nil

	case baselineMsg:
		if msg.err != nil {
			m.flash(styleErr.Render("baseline: " + msg.err.Error()))
			return m, nil
		}
		m.flash(styleOK.Render("baseline moved to the " + msg.cp.Kind + " checkpoint " + shortID(msg.cp.ID)))
		m.from = ""
		m.measuring = true
		return m, m.measure()

	case sentMsg:
		m.sending = false
		where := msg.target.path
		if msg.target.lineRange != "" {
			where += " " + msg.target.lineRange
		}
		switch {
		case msg.err != nil:
			m.flash(styleErr.Render("not sent: " + msg.err.Error()))
		case msg.res.queued:
			m.flash(styleOK.Render("agent busy — note on " + where + " queued, sent when it is ready"))
		default:
			m.flash(styleOK.Render("note on " + where + " sent to the agent"))
		}
		return m, nil

	case tea.KeyMsg:
		if m.noting {
			return m.handleNoteKey(msg)
		}
		if m.picking {
			return m.handlePickKey(msg)
		}
		return m.handleKey(msg)
	}
	return m, nil
}

// handlePickKey drives the base checkpoint picker: Enter measures since the
// highlighted checkpoint (a one-off view; the baseline row returns to the
// default), b makes it the baseline, / types a commit to add as a row, Esc
// goes back.
func (m model) handlePickKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.pickTyping {
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "esc":
			m.pickTyping = false
			m.pickInput.Blur()
			return m, nil
		case "enter":
			rev := strings.TrimSpace(m.pickInput.Value())
			if rev == "" {
				m.pickTyping = false
				m.pickInput.Blur()
				return m, nil
			}
			m.pickTyping = false
			m.pickInput.Blur()
			m.flash(styleDim.Render("resolving " + rev + "…"))
			return m, m.resolveCommit(rev)
		}
		var cmd tea.Cmd
		m.pickInput, cmd = m.pickInput.Update(msg)
		return m, cmd
	}
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc", "q", "s":
		m.picking = false
		return m, nil
	case "/", ":":
		m.pickTyping = true
		m.msg = ""
		m.pickInput.Reset()
		return m, m.pickInput.Focus()
	case "j", "down":
		if m.pickSel < len(m.picks)-1 {
			m.pickSel++
		}
		return m, nil
	case "k", "up":
		if m.pickSel > 0 {
			m.pickSel--
		}
		return m, nil
	case "g", "home":
		m.pickSel = 0
		return m, nil
	case "G", "end":
		m.pickSel = len(m.picks) - 1
		return m, nil
	case "enter":
		cp := m.picks[m.pickSel]
		m.picking = false
		if cp.ID == m.pickBase {
			m.from = ""
			m.flash(styleDim.Render("measuring since the baseline"))
		} else {
			m.from = cp.ID
			m.flash(styleDim.Render("measuring since the " + cp.Kind + " checkpoint " + shortID(cp.ID) + " (baseline unchanged)"))
		}
		m.measuring = true
		return m, m.measure()
	case "b":
		cp := m.picks[m.pickSel]
		m.picking = false
		if cp.ID == m.pickBase {
			m.from = ""
			m.flash(styleDim.Render("already the baseline"))
			m.measuring = true
			return m, m.measure()
		}
		m.flash(styleDim.Render("moving the baseline…"))
		return m, m.setBaseline(cp.ID)
	}
	return m, nil
}

// handleNoteKey drives the note line: Enter sends, Esc cancels, everything
// else edits the text.
func (m model) handleNoteKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		m.noting = false
		m.note.Blur()
		m.flash(styleDim.Render("note cancelled"))
		return m, nil
	case "enter":
		note := strings.TrimSpace(m.note.Value())
		if note == "" {
			m.flash(styleDim.Render("type a note first (esc cancels)"))
			return m, nil
		}
		m.noting = false
		m.note.Blur()
		m.sending = true
		m.flash(styleDim.Render("sending…"))
		return m, m.send(m.noteTarget, note)
	}
	var cmd tea.Cmd
	m.note, cmd = m.note.Update(msg)
	return m, cmd
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
	case "s":
		m.flash(styleDim.Render("loading checkpoints…"))
		return m, m.loadCheckpoints()
	case "a":
		if m.stat.Files == 0 {
			m.flash(styleDim.Render("nothing to acknowledge"))
			return m, nil
		}
		return m, m.ack()
	case "c":
		if m.sending {
			m.flash(styleDim.Render("still sending the previous note"))
			return m, nil
		}
		target, ok := m.currentNoteTarget()
		if !ok {
			m.flash(styleDim.Render("no change to comment on"))
			return m, nil
		}
		m.noteTarget = target
		m.noting = true
		m.msg = ""
		m.note.Reset()
		return m, m.note.Focus()
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
	// j/k always walk the files and ]/[ always walk the hunks, whichever pane
	// has focus; the arrows follow the focused pane (files, or hunks in the
	// diff). Line scrolling is space/b, ctrl+d/u, g/G.
	case "j":
		return m.selectFile(m.sel + 1)
	case "k":
		return m.selectFile(m.sel - 1)
	case "down":
		if m.focus == focusFiles {
			return m.selectFile(m.sel + 1)
		}
		m.gotoHunk(m.hunk + 1)
		return m, nil
	case "up":
		if m.focus == focusFiles {
			return m.selectFile(m.sel - 1)
		}
		m.gotoHunk(m.hunk - 1)
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

// gotoHunk scrolls the viewport so hunk i's header is the top line. Focus
// stays where it is: hunk keys work from the file list too.
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
		return styleDim.Render("No unreviewed changes since the "+m.base.Kind+" checkpoint.") +
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
	if m.picking {
		return m.pickView()
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
		if m.from != "" && m.base.ID == m.from { // only once the pick is what is measured
			rest += styleKey.Render(" [picked base — s to change]")
		}
	}
	if m.measuring {
		rest += styleDim.Render(" ⟳")
	}
	return truncStyled(left+rest, m.width)
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
	if m.noting {
		where := m.noteTarget.path
		if m.noteTarget.lineRange != "" {
			where += " " + m.noteTarget.lineRange
		}
		label := styleKey.Render("note") + styleDim.Render(" on "+where+" → agent: ")
		labelW := lipgloss.Width(label)
		m.note.Width = m.width - labelW - 1
		if m.note.Width < 10 {
			// Too narrow for the location: keep the input usable.
			label = styleKey.Render("note: ")
			m.note.Width = m.width - lipgloss.Width(label) - 1
		}
		return label + m.note.View()
	}
	if m.msg != "" {
		return truncStyled(m.msg, m.width)
	}
	// Focus-aware: the arrows and tab hints name what they act on now. Order
	// is importance — fitHints drops from the end on narrow panes.
	hint := func(k, what string) string { return styleKey.Render(k) + styleDim.Render(" "+what) }
	arrows, other := "file", "diff"
	if m.focus == focusDiff {
		arrows, other = "hunk", "files"
	}
	parts := []string{
		hint("j/k", "file"),
		hint("]/[", "hunk"),
		hint("↑↓", arrows),
		hint("c", "note→agent"),
		hint("a", "reviewed"),
		hint("s", "since…"),
		hint("tab", other),
		hint("r", "refresh"),
		hint("q", "close"),
		hint("?", "help"),
	}
	pos := ""
	if m.hunk >= 0 && m.hunk < len(m.doc.Hunks) {
		pos = styleDim.Render(fmt.Sprintf("hunk %d/%d %s", m.hunk+1, len(m.doc.Hunks), m.doc.Hunks[m.hunk].lineRange()))
	}
	return fitHints(parts, pos, m.width)
}

func (m model) helpView() string {
	lines := []string{
		styleTitle.Render("am review — what the agent changed since you last looked"),
		"",
		"  j / k            next / previous file (from either pane; also J / K, n / p)",
		"  ] / [            next / previous hunk (from either pane)",
		"  ↑ / ↓            in the focused pane: files in the file list, hunks in the diff",
		"  tab, enter       move focus between the file list and the diff",
		"  space, b, g, G   page down / page up / top / bottom of the diff (ctrl+d / ctrl+u too)",
		"  c                note on the hunk under the cursor → the agent (am send: file, lines,",
		"                   hunk, your note; queued with am send --queue while the agent is busy)",
		"  a                mark the working copy reviewed (am diff --ack): new baseline",
		"  s                pick the base the diff is measured since: the checkpoint chain of",
		"                   `am diff --list`, each row with the change it would show; Enter views",
		"                   from it, b makes it the baseline, / types any commit to add as a row",
		"  r                re-measure now (the pane also refreshes on every tool event)",
		"  q                close the pane (prefix+v or `am review` reopens it)",
		"",
		styleDim.Render("Baseline: the working copy at launch, then whatever you acknowledged; a branch"),
		styleDim.Render("switch moves it to the new branch as checked out, a rebase re-anchors it below the"),
		styleDim.Render("agent's rewritten commits. `am diff --list` shows the chain."),
		"",
		styleDim.Render("any key to return"),
	}
	return strings.Join(lines, "\n")
}

// pickView lists the checkpoint chain, newest first: * marks the baseline,
// the highlighted row is the one Enter / b act on.
func (m model) pickView() string {
	now := time.Now().Unix()
	lines := []string{
		truncStyled(styleTitle.Render("since which checkpoint? ")+styleDim.Render("j/k move · Enter view from it · b make it the baseline · / a commit · esc back"), m.width),
		styleDim.Render(truncRunes(checkpointHeader(), m.width)),
	}
	footer := ""
	switch {
	case m.pickTyping:
		label := styleKey.Render("commit") + styleDim.Render(" (sha, branch, HEAD~3, …): ")
		m.pickInput.Width = m.width - lipgloss.Width(label) - 1
		if m.pickInput.Width < 10 {
			label = styleKey.Render("commit: ")
			m.pickInput.Width = m.width - lipgloss.Width(label) - 1
		}
		footer = label + m.pickInput.View()
	case m.msg != "":
		footer = truncStyled(m.msg, m.width)
	}
	rows := m.height - len(lines)
	if footer != "" {
		rows--
	}
	if rows < 1 {
		rows = 1
	}
	top := 0
	if m.pickSel >= rows {
		top = m.pickSel - rows + 1
	}
	for i := top; i < len(m.picks) && i < top+rows; i++ {
		row := truncRunes(checkpointRow(m.picks[i], m.pickStats[m.picks[i].ID], m.pickBase, m.base.ID, now), m.width)
		if i == m.pickSel {
			row = styleSel.Render(padRight(row, m.width))
		}
		lines = append(lines, row)
	}
	if footer != "" {
		lines = append(lines, footer)
	}
	return strings.Join(lines, "\n")
}
