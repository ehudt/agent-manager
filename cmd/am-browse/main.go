package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
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

	// --new: open with the cursor on the New session section (am new with no
	// arguments). The prefill flags seed the query, the agent, and the task.
	newOnly   bool
	newPrefix string
	newAgent  string
	newTask   string
)

func init() {
	flag.StringVar(&previewCmd, "preview-cmd", "", "Script to run for preview content")
	flag.StringVar(&killCmd, "kill-cmd", "", "Script to run for kill (ctrl-x)")
	flag.StringVar(&clientName, "client-name", "", "tmux client name (for kill-and-switch)")
	flag.BoolVar(&benchmark, "benchmark", false, "Print time-to-first-frame and exit")
	flag.BoolVar(&newOnly, "new", false, "Start on the New session section")
	flag.StringVar(&newPrefix, "dir", "", "Prefill the query with a directory")
	flag.StringVar(&newAgent, "agent", "", "Agent for new sessions")
	flag.StringVar(&newTask, "task", "", "Task passed through with a new session")
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
	env := sessions.LoadEnv()
	m.launch = newLauncher(sessions.LoadConfig(env.AmDir), env.AmDir, env.Home, newAgent, newTask)
	if newOnly {
		m.startNew = true
		m.filter.SetValue(newPrefix)
		m.filter.CursorEnd()
	}
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

type killDoneMsg struct{}

type recoveryTickMsg struct{}

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
	errorStyle     lipgloss.Style

	// The renderer the styles come from; newModel builds the filter's
	// textinput styles from it too.
	ttyRenderer = lipgloss.DefaultRenderer()
)

// initStyles creates all styles from a renderer tied to the real tty,
// so color detection works even when stdout is captured by the caller.
func initStyles(r *lipgloss.Renderer) {
	ttyRenderer = r
	accentStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))                                     // cyan accent bar
	titleStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("15"))                                      // bright white
	selectedStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("10")).Background(lipgloss.Color("235")) // green on subtle dark bg
	normalStyle = r.NewStyle()
	dimStyle = r.NewStyle().Foreground(lipgloss.Color("8"))                                                   // dim
	keyPillStyle = r.NewStyle().Bold(true).Foreground(lipgloss.Color("14")).Background(lipgloss.Color("236")) // cyan on dark bg
	keyActionStyle = r.NewStyle().Foreground(lipgloss.Color("8"))                                             // dim
	separatorStyle = r.NewStyle().Foreground(lipgloss.Color("8"))
	helpOverlay = r.NewStyle().Padding(1, 2).Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("14"))
	errorStyle = r.NewStyle().Foreground(lipgloss.Color("9")) // red
}

// --- Model ---

type model struct {
	entries     []sessions.Entry
	filtered    []int      // indices into entries matching the query: active, interrupted, inactive
	items       []listItem // the selectable rows in display order; the cursor indexes it
	cursor      int
	place       bool // the cursor follows the best match, until the user moves it
	startNew    bool // --new: under an empty query the cursor starts on the New session section
	filter      textinput.Model
	launch      launcher // the New session section (newrows.go)
	errMsg      string   // a launch the section refused; cleared by the next key
	preview     string
	previewFor  string // preview key whose content is loaded
	showPreview bool
	showHelp    bool
	width       int
	height      int
	output      string // what to print on exit
	loading     bool
}

// listItem is one selectable row: a session entry, or a launch target of
// the New session section.
type listItem struct {
	entry int // index into entries; -1 for a New session row
	row   newRow
	tier  int // match quality against the query
}

func (it listItem) isNew() bool { return it.entry < 0 }

func newModel() model {
	ti := textinput.New()
	ti.Placeholder = "type to filter, or a path / @spec for a new session..."
	ti.Prompt = "/ "
	ti.PromptStyle = accentStyle
	// textinput's own styles come from lipgloss's default renderer, which
	// probes stdout: captured by the caller, it reports no color support and
	// the cursor's reverse video is dropped, leaving no visible cursor.
	ti.Cursor.Style = ttyRenderer.NewStyle()
	ti.TextStyle = ttyRenderer.NewStyle()
	ti.PlaceholderStyle = ttyRenderer.NewStyle().Foreground(lipgloss.Color("240"))
	ti.CompletionStyle = ttyRenderer.NewStyle().Foreground(lipgloss.Color("240"))
	ti.Focus()
	ti.Cursor.SetMode(cursor.CursorStatic)

	return model{
		filter:      ti,
		launch:      newLauncher(sessions.Config{}, "", "", "", ""),
		place:       true,
		showPreview: true,
		loading:     true,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(loadSessions, m.launch.loadFrecent())
}

func loadSessions() tea.Msg {
	entries := sessions.LoadBrowserEntries()
	return sessionsLoadedMsg{entries: entries}
}

func recoveryTick() tea.Cmd {
	return tea.Tick(350*time.Millisecond, func(time.Time) tea.Msg {
		return recoveryTickMsg{}
	})
}

func hasRestoringEntries(entries []sessions.Entry) bool {
	for _, entry := range entries {
		if entry.Kind == sessions.EntryRestoring {
			return true
		}
	}
	return false
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
		if entry.Kind == sessions.EntryRestoring {
			return previewLoadedMsg{key: key, content: "Restoring this interrupted session…"}
		}
		if entry.Kind == sessions.EntryBlocked {
			content := entry.RecoveryError
			if content == "" {
				content = "Session ended during this boot. Press Enter to retry recovery."
			} else {
				content += "\n\nPress Enter to retry, or Ctrl-X to forget this open session."
			}
			return previewLoadedMsg{key: key, content: content}
		}
		if previewCmd == "" || entry.Name == "" {
			return previewLoadedMsg{key: key, content: ""}
		}
		cmd := exec.Command(previewCmd, entry.Name)
		out, _ := cmd.CombinedOutput()
		return previewLoadedMsg{key: key, content: string(out)}
	}
}

// loadNewPreview describes a New session row (launcher.describe), listing
// the sessions, running or closed, that worked in its directory.
func (m model) loadNewPreview(r newRow) tea.Cmd {
	l := m.launch
	var here []string
	if r.kind == newDir {
		path := l.expand(r.value)
		for _, e := range m.entries {
			if e.Meta.EffectiveDir() != path && e.Meta.Directory != path {
				continue
			}
			mark := "running"
			if e.Kind != sessions.EntryActive {
				mark = "closed "
			}
			here = append(here, mark+"  "+e.Display)
		}
	}
	key := r.key()
	return func() tea.Msg {
		return previewLoadedMsg{key: key, content: l.describe(r, here)}
	}
}

func killSession(sessionName string) tea.Cmd {
	return func() tea.Msg {
		if killCmd == "" || sessionName == "" {
			return killDoneMsg{}
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
		return killDoneMsg{}
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
		cmds := []tea.Cmd{m.applyFilter(), m.requestPreview()}
		if hasRestoringEntries(m.entries) {
			cmds = append(cmds, recoveryTick())
		}
		return m, tea.Batch(cmds...)

	case frecentMsg:
		m.launch.frecent = msg.paths
		m.launch.frecentLoaded = true
		return m, tea.Batch(m.applyFilter(), m.requestPreview())

	case providerMsg:
		m.launch.providerCache[msg.query] = msg.rows
		delete(m.launch.providerPending, msg.query)
		if m.filter.Value() == msg.query {
			return m, tea.Batch(m.applyFilter(), m.requestPreview())
		}
		return m, nil

	case recoveryTickMsg:
		return m, loadSessions

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
		return m.handleKey(msg)
	}

	// Pass other messages to textinput
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	return m, cmd
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Help overlay captures all keys
	if m.showHelp {
		m.showHelp = false
		return m, nil
	}
	m.errMsg = ""

	switch msg.Type {
	case tea.KeyEsc, tea.KeyCtrlC:
		m.output = ""
		return m, tea.Quit

	case tea.KeyEnter:
		return m.enter()

	case tea.KeyTab, tea.KeyShiftTab:
		step := 1
		if msg.Type == tea.KeyShiftTab {
			step = -1
		}
		m.launch.cycleAgent(step)
		return m, m.applyFilter() // preset rows without an agent name it

	case tea.KeyCtrlN:
		cmd := m.jumpNew()
		return m, tea.Batch(cmd, m.requestPreview())

	case tea.KeyCtrlH:
		if m.moveToFirstKind(sessions.EntryInactive) {
			m.place = false
			return m, m.requestPreview()
		}
		return m, nil

	case tea.KeyCtrlX:
		if entry, ok := m.selectedEntry(); ok &&
			(entry.Kind == sessions.EntryBlocked || entry.Kind == sessions.EntryRestoring) {
			m.output = "__FORGET_RECOVERY__\x1f" + entry.Meta.LogicalID
			return m, tea.Quit
		}
		if s := m.selectedSession(); s != "" {
			m.place = false
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
			m.place = false
			return m, m.requestPreview()
		}
		return m, nil

	case tea.KeyDown:
		if m.cursor < len(m.items)-1 {
			m.cursor++
			m.place = false
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
	m.filter, cmd = m.filter.Update(trimPaste(msg))
	if m.filter.Value() != oldVal {
		m.launch.seed = ""
		m.place = true
		return m, tea.Batch(cmd, m.applyFilter(), m.requestPreview())
	}
	return m, cmd
}

// enter performs the selected row's action: switch to a running session,
// restore a closed one, retry an interrupted one, or launch a new one.
func (m model) enter() (tea.Model, tea.Cmd) {
	it, ok := m.selectedItem()
	if !ok {
		if q := m.filter.Value(); isPathQuery(q) {
			m.errMsg = "Directory does not exist: " + q
		}
		return m, nil
	}
	if it.isNew() {
		out, errMsg := m.launch.launch(it.row)
		if errMsg != "" {
			m.errMsg = errMsg
			return m, nil
		}
		m.output = out
		return m, tea.Quit
	}
	entry := m.entries[it.entry]
	switch entry.Kind {
	case sessions.EntryInactive:
		m.output = "__RESTORE__\x1f" + entry.Meta.Directory + "\x1f" + entry.RestoreSessionID + "\x1f" + entry.Meta.AgentType
	case sessions.EntryBlocked:
		m.output = "__RETRY_RECOVERY__\x1f" + entry.Meta.LogicalID
	case sessions.EntryRestoring:
		return m, nil
	default:
		m.output = entry.Name
	}
	return m, tea.Quit
}

// jumpNew moves the cursor to the New session section. On a session row it
// first pins that session's directory as the section's first row, so Ctrl-N
// Enter starts another session where the highlighted one works.
func (m *model) jumpNew() tea.Cmd {
	if it, ok := m.selectedItem(); ok && !it.isNew() {
		if dir := m.entries[it.entry].Meta.EffectiveDir(); dir != "" {
			m.launch.seed = dir
		}
	}
	cmd := m.applyFilter()
	if i := m.firstNew(); i >= 0 {
		m.cursor = i
		m.place = false
	}
	return cmd
}

// applyFilter rebuilds the list for the query: the matching sessions per
// section, the New session rows, and their order (running, interrupted, new,
// inactive). With m.place the cursor goes to the best match; otherwise it
// stays on the row it was on. The Cmd is a dir_provider fetch, if one is due.
func (m *model) applyFilter() tea.Cmd {
	raw := m.filter.Value()
	query := strings.ToLower(raw)
	prev := ""
	if !m.place {
		prev = m.selectedPreviewKey()
	}

	type hit struct {
		idx  int
		tier int
		rec  int64
	}
	var active, interrupted, inactive []hit
	for i, e := range m.entries {
		tier := m.entryTier(e, query)
		if tier == 0 {
			continue
		}
		h := hit{idx: i, tier: tier, rec: e.RecencyUnix}
		switch e.Kind {
		case sessions.EntryInactive:
			inactive = append(inactive, h)
		case sessions.EntryRestoring, sessions.EntryBlocked:
			interrupted = append(interrupted, h)
		default:
			active = append(active, h)
		}
	}
	// An empty query keeps the canonical order (active by activity, then
	// inactive); a query ranks each section by tier, then recency, so the
	// section boundaries stay put.
	if query != "" {
		byScore := func(s []hit) func(a, b int) bool {
			return func(a, b int) bool {
				if s[a].tier != s[b].tier {
					return s[a].tier > s[b].tier
				}
				return s[a].rec > s[b].rec
			}
		}
		sort.SliceStable(active, byScore(active))
		sort.SliceStable(interrupted, byScore(interrupted))
		sort.SliceStable(inactive, byScore(inactive))
	}

	newRows, cmd := m.launch.rows(raw, m.liveDirs())
	m.filtered = m.filtered[:0]
	items := make([]listItem, 0, len(active)+len(interrupted)+len(newRows)+len(inactive))
	for _, s := range [][]hit{active, interrupted} {
		for _, h := range s {
			m.filtered = append(m.filtered, h.idx)
			items = append(items, listItem{entry: h.idx, tier: h.tier})
		}
	}
	for _, r := range newRows {
		items = append(items, listItem{entry: -1, row: r, tier: r.tier})
	}
	for _, h := range inactive {
		m.filtered = append(m.filtered, h.idx)
		items = append(items, listItem{entry: h.idx, tier: h.tier})
	}
	m.items = items

	if m.place {
		m.cursor = m.bestItem(raw)
	} else {
		m.cursor = m.findKey(prev)
	}
	return cmd
}

// entryTier is a session's match quality for the (lowercased) query. A
// plain query matches the display string; an @spec query matches its spec
// text there by substring (a session already on that branch or PR); a path
// query matches the sessions working in or under that path.
func (m model) entryTier(e sessions.Entry, query string) int {
	if query == "" {
		return 4
	}
	if isPathQuery(query) {
		p := strings.ToLower(m.launch.absPath(query))
		if strings.HasPrefix(strings.ToLower(e.Meta.Directory), p) ||
			(e.Meta.Workdir != "" && strings.HasPrefix(strings.ToLower(e.Meta.Workdir), p)) {
			return 2
		}
		return 0
	}
	haystack := strings.ToLower(e.Display)
	switch e.Kind {
	case sessions.EntryInactive:
		haystack += " inactive restore closed"
	case sessions.EntryRestoring, sessions.EntryBlocked:
		haystack += " interrupted recovery restoring blocked"
	}
	if strings.HasPrefix(query, "@") {
		spec := query[1:]
		if spec == "" {
			return 0
		}
		if tier := displayTier(e, haystack, spec); tier >= 2 {
			return tier
		}
		return 0
	}
	return displayTier(e, haystack, query)
}

// displayTier matches a session's haystack. A running session's display
// starts with its tmux name (am-xxxxxx); the text after it is scored too,
// so a project name ranks a running session the way it ranks the closed
// ones (which lack the name) and the directory rows (their basename).
func displayTier(e sessions.Entry, haystack, query string) int {
	tier := matchTier(haystack, query)
	if e.Name != "" {
		if rest := strings.TrimPrefix(haystack, strings.ToLower(e.Name)+" "); rest != haystack {
			tier = maxInt(tier, matchTier(rest, query))
		}
	}
	return tier
}

// liveDirs counts the running sessions per working directory.
func (m model) liveDirs() map[string]int {
	live := map[string]int{}
	for _, e := range m.entries {
		if e.Kind == sessions.EntryActive {
			if dir := e.Meta.EffectiveDir(); dir != "" {
				live[dir]++
			}
		}
	}
	return live
}

// bestItem is where the cursor goes for a query: the New session section
// for a path or @spec (and for an empty query under --new), else the first
// row with the best match tier — so on a tie an existing session wins over
// starting a duplicate.
func (m model) bestItem(raw string) int {
	if isPlaceQuery(raw) || (raw == "" && m.startNew) {
		if i := m.firstNew(); i >= 0 {
			return i
		}
	}
	best, at := 0, 0
	for i, it := range m.items {
		if it.tier > best {
			best, at = it.tier, i
		}
	}
	return at
}

// findKey is the position of the row with the given key, else the cursor
// clamped to the list.
func (m model) findKey(key string) int {
	if key != "" {
		for i, it := range m.items {
			if m.itemKey(it) == key {
				return i
			}
		}
	}
	if m.cursor >= len(m.items) {
		return maxInt(0, len(m.items)-1)
	}
	return m.cursor
}

func (m model) firstNew() int {
	for i, it := range m.items {
		if it.isNew() {
			return i
		}
	}
	return -1
}

// matchTier returns a coarse match quality for query against text (both already
// lowercased): 4=prefix, 3=word-boundary prefix, 2=substring, 1=subsequence,
// 0=no match. Higher is a better match.
func matchTier(text, query string) int {
	switch {
	case strings.HasPrefix(text, query):
		return 4
	case wordPrefix(text, query):
		return 3
	case strings.Contains(text, query):
		return 2
	case fuzzyMatch(text, query):
		return 1
	default:
		return 0
	}
}

// wordPrefix reports whether query starts a word in text, where word boundaries
// are the separators that appear in display strings: space, '/', '[', '-'.
func wordPrefix(text, query string) bool {
	for i := 0; i+len(query) <= len(text); i++ {
		if i > 0 {
			switch text[i-1] {
			case ' ', '/', '[', '-':
			default:
				continue
			}
		}
		if strings.HasPrefix(text[i:], query) {
			return true
		}
	}
	return false
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// rowsThroughNew is how many list rows (dividers included) the list needs
// to show everything down to the last New session row; 0 without any.
func (m model) rowsThroughNew() int {
	rows, _ := m.listRows()
	for i := len(rows) - 1; i >= 0; i-- {
		if !rows[i].divider && m.items[rows[i].item].isNew() {
			return i + 1
		}
	}
	return 0
}

type listRow struct {
	divider bool
	label   string
	item    int // index into items
}

func (m model) selectedItem() (listItem, bool) {
	if m.cursor < 0 || m.cursor >= len(m.items) {
		return listItem{}, false
	}
	return m.items[m.cursor], true
}

func (m model) selectedEntry() (sessions.Entry, bool) {
	it, ok := m.selectedItem()
	if !ok || it.isNew() {
		return sessions.Entry{}, false
	}
	return m.entries[it.entry], true
}

func (m model) selectedSession() string {
	entry, ok := m.selectedEntry()
	if !ok || entry.Kind != sessions.EntryActive {
		return ""
	}
	return entry.Name
}

func (m model) selectedPreviewKey() string {
	it, ok := m.selectedItem()
	if !ok {
		return ""
	}
	return m.itemKey(it)
}

func (m model) itemKey(it listItem) string {
	if it.isNew() {
		return it.row.key()
	}
	return previewKey(m.entries[it.entry])
}

func previewKey(entry sessions.Entry) string {
	if entry.Kind == sessions.EntryInactive {
		if entry.RestoreSessionID == "" {
			return ""
		}
		return "inactive:" + entry.RestoreSessionID
	}
	if entry.Kind == sessions.EntryRestoring || entry.Kind == sessions.EntryBlocked {
		if entry.Meta.LogicalID == "" {
			return ""
		}
		return "recovery:" + entry.Meta.LogicalID + ":" + string(entry.Kind)
	}
	if entry.Name == "" {
		return ""
	}
	return "active:" + entry.Name
}

func (m *model) moveToFirstKind(kind sessions.EntryKind) bool {
	for pos, it := range m.items {
		if !it.isNew() && m.entries[it.entry].Kind == kind {
			m.cursor = pos
			return true
		}
	}
	return false
}

func (m model) entryCounts() (active, restoring, blocked, inactive int) {
	for _, entry := range m.entries {
		switch entry.Kind {
		case sessions.EntryActive:
			active++
		case sessions.EntryRestoring:
			restoring++
		case sessions.EntryBlocked:
			blocked++
		case sessions.EntryInactive:
			inactive++
		}
	}
	return active, restoring, blocked, inactive
}

func (m model) listRows() ([]listRow, int) {
	rows := make([]listRow, 0, len(m.items)+3)
	cursorRow := -1
	recoveryDividerAdded := false
	newDividerAdded := false
	inactiveDividerAdded := false
	for pos, it := range m.items {
		if it.isNew() {
			if !newDividerAdded {
				rows = append(rows, listRow{divider: true, label: "New " + m.launch.agent + " session"})
				newDividerAdded = true
			}
		} else {
			kind := m.entries[it.entry].Kind
			if (kind == sessions.EntryRestoring || kind == sessions.EntryBlocked) && !recoveryDividerAdded {
				rows = append(rows, listRow{divider: true, label: "Interrupted sessions"})
				recoveryDividerAdded = true
			}
			if kind == sessions.EntryInactive && !inactiveDividerAdded {
				rows = append(rows, listRow{divider: true, label: "Inactive sessions"})
				inactiveDividerAdded = true
			}
		}
		if pos == m.cursor {
			cursorRow = len(rows)
		}
		rows = append(rows, listRow{item: pos})
	}
	return rows, cursorRow
}

func (m model) requestPreview() tea.Cmd {
	it, ok := m.selectedItem()
	if !ok {
		return nil
	}
	key := m.itemKey(it)
	if key == "" || key == m.previewFor {
		return nil
	}
	if it.isNew() {
		return m.loadNewPreview(it.row)
	}
	return loadPreview(m.entries[it.entry])
}

// enterAction names what Enter does on the selected row, for the key pills.
func (m model) enterAction() string {
	it, ok := m.selectedItem()
	if !ok {
		return "open"
	}
	if it.isNew() {
		return "launch"
	}
	switch m.entries[it.entry].Kind {
	case sessions.EntryInactive:
		return "restore"
	case sessions.EntryBlocked:
		return "retry"
	case sessions.EntryRestoring:
		return "wait"
	}
	return "switch"
}

// rowText is a row's two columns: the base (the session display, or the
// launch target) and the right-hand part (the age, or the target's label).
func (m model) rowText(it listItem) (base, right string) {
	if !it.isNew() {
		entry := m.entries[it.entry]
		return entry.DisplayBase, "(" + entry.TimeAgo + ")"
	}
	r := it.row
	switch r.kind {
	case newPreset:
		return "+ ★ " + r.preset, r.label
	case newSpec:
		return "+ " + r.value, r.label
	}
	return "+ " + m.launch.abbrev(m.launch.expand(r.value)), r.label
}

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	var b strings.Builder

	// Header: accent bar + title + session count
	b.WriteByte('\n')
	activeCount, restoringCount, blockedCount, inactiveCount := m.entryCounts()
	countParts := []string{fmt.Sprintf("%d active", activeCount)}
	if restoringCount > 0 {
		countParts = append(countParts, fmt.Sprintf("%d restoring", restoringCount))
	}
	if blockedCount > 0 {
		countParts = append(countParts, fmt.Sprintf("%d blocked", blockedCount))
	}
	if inactiveCount > 0 {
		countParts = append(countParts, fmt.Sprintf("%d inactive", inactiveCount))
	}
	countLabel := strings.Join(countParts, ", ")
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
		{"?", "help"}, {"⏎", m.enterAction()}, {"⇥", "agent"}, {"^N", "new"}, {"^X", "kill"}, {"^R", "refresh"},
	}
	for i, k := range keys {
		b.WriteString(keyPillStyle.Render(" " + k.key + " "))
		b.WriteString(keyActionStyle.Render(" " + k.action))
		if i < len(keys)-1 {
			b.WriteString("  ")
		}
	}
	b.WriteByte('\n')

	// Filter input, then a blank line or the error a launch was refused with
	b.WriteByte('\n')
	b.WriteString("   ")
	b.WriteString(m.filter.View())
	b.WriteByte('\n')
	if m.errMsg != "" {
		b.WriteString("   " + errorStyle.Render(truncRunesTo(m.errMsg, m.width-4)))
	}
	b.WriteByte('\n')

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
		// Room for the sessions above the New section and the section itself,
		// up to half the screen; the inactive sessions below it scroll.
		if want := m.rowsThroughNew(); want > listHeight {
			listHeight = maxInt(listHeight, minInt(want, available/2))
		}
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
	if len(m.items) == 0 {
		switch {
		case m.loading:
			b.WriteString(dimStyle.Render("  Loading sessions..."))
		case m.filter.Value() != "":
			b.WriteString(dimStyle.Render("  No matches"))
		default:
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

		// Find the longest base among visible rows to set the right column's
		// position: one column for the sessions' ages, one for the New rows'
		// labels (which are longer, and would be cut at the age column).
		maxBaseLen, maxNewLen := 0, 0
		for i := start; i < end; i++ {
			row := rows[i]
			if row.divider {
				continue
			}
			base, _ := m.rowText(m.items[row.item])
			n := len([]rune(base))
			if m.items[row.item].isNew() {
				maxNewLen = maxInt(maxNewLen, n)
			} else {
				maxBaseLen = maxInt(maxBaseLen, n)
			}
		}
		// Right column starts 2 tabs (16 chars) after the longest base, capped to terminal width
		timeCol := maxBaseLen + 16 // 16 ≈ two tabs of breathing room
		maxTimeCol := m.width - 14 // leave room for "(XXh XXm ago)"
		if maxTimeCol < 10 {
			maxTimeCol = 10
		}
		if timeCol > maxTimeCol {
			timeCol = maxTimeCol
		}
		labelCol := maxNewLen + 6
		if maxLabelCol := maxInt(10, m.width-24); labelCol > maxLabelCol {
			labelCol = maxLabelCol
		}

		for i := start; i < end; i++ {
			row := rows[i]
			if row.divider {
				b.WriteString(sectionDivider(row.label, m.width))
				b.WriteByte('\n')
				continue
			}

			it := m.items[row.item]
			base, right := m.rowText(it)
			selected := row.item == m.cursor

			prefix := "  "
			if selected {
				prefix = "> "
			}

			col := timeCol
			if it.isNew() {
				col = labelCol
			}
			// Truncate base if it would overlap the right column
			maxBase := col - 2 // 2 = prefix width
			if maxBase < 10 {
				maxBase = 10
			}
			if len([]rune(base)) > maxBase {
				base = string([]rune(base)[:maxBase])
			}
			gap := col - len([]rune(base))
			if gap < 2 {
				gap = 2
			}
			lead := prefix + base + strings.Repeat(" ", gap)
			right = truncRunesTo(right, m.width-len([]rune(lead)))

			if selected {
				// Pad to full width for background highlight
				line := lead + right
				if n := len([]rune(line)); n < m.width {
					line += strings.Repeat(" ", m.width-n)
				}
				b.WriteString(selectedStyle.Render(line))
			} else if it.isNew() {
				b.WriteString(normalStyle.Render(lead) + dimStyle.Render(right))
			} else {
				b.WriteString(normalStyle.Render(lead + right))
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

		// A session shows the tail of its pane (the most recent output), a
		// launch target its description from the top. Leave 1 line for the
		// separator.
		lines := strings.Split(previewContent, "\n")
		maxLines := previewHeight - 1
		if maxLines < 1 {
			maxLines = 1
		}
		if len(lines) > maxLines {
			if it, ok := m.selectedItem(); ok && it.isNew() {
				lines = lines[:maxLines]
			} else {
				lines = lines[len(lines)-maxLines:]
			}
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
    Enter       Switch to, restore, or retry a session; launch a new one
    Tab         Agent for new sessions (Shift-Tab: back)
    Esc/q       Exit without action
    Ctrl-N      New session section (on a session: a new one in its dir)
    Ctrl-H      Jump to the inactive sessions
    Ctrl-X      Kill active or forget blocked session
    Ctrl-R      Refresh session list
    Ctrl-P      Toggle the preview
    ?           Show this help

  Type to filter sessions and new-session targets
    text        sessions, recent directories, presets
    / ~ .       a path: the sessions under it, the directory, completions
    @spec       the dir_provider's suggestions

  In tmux session
    Prefix + 1-9  Jump to sidebar slot N
    Prefix + a  Switch to last am session
    Prefix + n  Open the browser on New session
    Prefix + s  Open am browser popup
    Prefix + x  Kill current am session
    Prefix + d  Detach from session
    Prefix + ` + "`" + `  Toggle the shell panel
    Prefix Up/Down
                Switch panes (panel open)
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
