package main

// The new-session form: a screen of the browser (Ctrl-N) and the whole
// program under --new (`am new` with no arguments). Two stages, as the bash
// form it replaced (lib/form.sh, until 0.38): a directory-first launcher —
// the Directory field with its suggestions, Enter launches — and, behind
// Tab, the options (Preset when any exist, Directory, Agent, Task) with a
// navigate/edit mode. The result is one protocol line on stdout:
// __NEW_SESSION__␟directory␟agent␟flags␟task, parsed by cmd_browse and
// cmd_new; flags carries --preset=<name> when a preset was picked.

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

type formStage int

const (
	stageLauncher formStage = iota
	stageOptions
)

type formMode int

const (
	modeNavigate formMode = iota
	modeEdit
)

type formField int

const (
	fieldPreset formField = iota
	fieldDirectory
	fieldAgent
	fieldTask
)

func (f formField) label() string {
	switch f {
	case fieldPreset:
		return "Preset"
	case fieldDirectory:
		return "Directory"
	case fieldAgent:
		return "Agent"
	default:
		return "Task"
	}
}

// formResult is what one update did to the form's lifecycle.
type formResult int

const (
	formContinue formResult = iota
	formCancel
	formSubmit
)

// dirCandidate is one row under the Directory field: the value Enter/Tab
// put in the field (a path, or `@spec`) and a dim label after it.
type dirCandidate struct {
	value string
	label string
}

// formDirsMsg delivers the frecent directory list (loaded once, off the UI
// thread).
type formDirsMsg struct{ paths []string }

// formProviderMsg delivers the provider's suggestions for one `@` query.
type formProviderMsg struct {
	query string
	rows  []sessions.DirSuggestion
}

const (
	formMaxCandidates = 50
	formLabelWidth    = 14 // "%-14s" of "Directory:"
	formHeaderLines   = 4  // title, two hint lines, blank
)

// launchShortcuts are the launcher's one-key launches: the key launches the
// highlighted directory with that agent.
var launchShortcuts = map[string]string{
	"ctrl+l": "claude",
	"ctrl+x": "codex",
	"ctrl+r": "cursor",
	"ctrl+p": "pi",
	"ctrl+o": "opencode",
}

type newForm struct {
	cfg        sessions.Config
	amDir      string
	home       string
	standalone bool // --new: Esc quits; in the browser it returns to the list

	agents  []string // select options, sorted
	presets []string // "-" + names; nil when no preset exists
	fields  []formField

	preset string
	agent  string
	dir    textinput.Model
	task   textinput.Model

	stage  formStage
	mode   formMode
	cursor int // index into fields (options stage)

	frecent         []string
	frecentLoaded   bool
	filtered        []dirCandidate
	highlight       int
	scroll          int
	providerCache   map[string][]sessions.DirSuggestion // by query, with the @
	providerPending map[string]bool
	suggest         func(partial string) []sessions.DirSuggestion

	errMsg string
	output string
	width  int
	height int
}

// newNewForm builds the form with its prefill (any may be empty; the agent
// falls back to the configured default).
func newNewForm(cfg sessions.Config, amDir, home, dir, agent, task string, standalone bool) newForm {
	f := newForm{
		cfg:             cfg,
		amDir:           amDir,
		home:            home,
		standalone:      standalone,
		stage:           stageLauncher,
		mode:            modeEdit,
		providerCache:   map[string][]sessions.DirSuggestion{},
		providerPending: map[string]bool{},
	}
	f.agents = sessions.AgentTypes() // manifest order, like AM_AGENT_TYPES
	if names := cfg.PresetNames(); len(names) > 0 {
		f.presets = append([]string{"-"}, names...)
		f.fields = append(f.fields, fieldPreset)
	}
	f.fields = append(f.fields, fieldDirectory, fieldAgent, fieldTask)
	f.preset = "-"

	if agent == "" {
		agent = cfg.DefaultAgentType()
	}
	agent = sessions.NormalizeAgent(agent)
	if _, ok := sessions.Agent(agent); !ok && len(f.agents) > 0 {
		agent = f.agents[0]
	}
	f.agent = agent

	f.dir = newFormInput()
	f.dir.Placeholder = "path, or @spec for the dir_provider"
	if strings.HasPrefix(dir, "~") {
		dir = home + dir[1:]
	}
	f.dir.SetValue(dir)
	f.dir.Focus()
	f.task = newFormInput()
	f.task.SetValue(task)

	provider := cfg.DirProviderCmd()
	f.suggest = func(partial string) []sessions.DirSuggestion {
		return sessions.DirProviderSuggest(amDir, provider, partial, sessions.DirSuggestTimeout())
	}
	f.cursor = f.fieldIndex(fieldDirectory)
	return f
}

func newFormInput() textinput.Model {
	ti := textinput.New()
	ti.Prompt = ""
	ti.Cursor.Style = ttyRenderer.NewStyle()
	ti.TextStyle = ttyRenderer.NewStyle()
	ti.PlaceholderStyle = ttyRenderer.NewStyle().Foreground(lipgloss.Color("240"))
	ti.CompletionStyle = ttyRenderer.NewStyle().Foreground(lipgloss.Color("240"))
	ti.Cursor.SetMode(cursor.CursorStatic)
	return ti
}

// init loads the frecent directory list.
func (f newForm) init() tea.Cmd {
	if f.frecentLoaded {
		return nil
	}
	amDir, home := f.amDir, f.home
	return func() tea.Msg {
		return formDirsMsg{paths: sessions.FrecentDirs(amDir, home)}
	}
}

func (f newForm) fieldIndex(field formField) int {
	for i, x := range f.fields {
		if x == field {
			return i
		}
	}
	return 0
}

func (f newForm) focusedField() formField {
	if f.stage == stageLauncher {
		return fieldDirectory
	}
	if f.cursor < 0 || f.cursor >= len(f.fields) {
		return fieldDirectory
	}
	return f.fields[f.cursor]
}

func (f newForm) update(msg tea.Msg) (newForm, tea.Cmd, formResult) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		f.width, f.height = msg.Width, msg.Height
		return f, nil, formContinue
	case formDirsMsg:
		f.frecent = msg.paths
		f.frecentLoaded = true
		return f, f.refilter(), formContinue
	case formProviderMsg:
		f.providerCache[msg.query] = msg.rows
		delete(f.providerPending, msg.query)
		if f.dir.Value() == msg.query {
			return f, f.refilter(), formContinue
		}
		return f, nil, formContinue
	case tea.KeyMsg:
		return f.handleKey(msg)
	}
	return f, nil, formContinue
}

func (f newForm) handleKey(msg tea.KeyMsg) (newForm, tea.Cmd, formResult) {
	if f.stage == stageLauncher {
		return f.keyLauncher(msg)
	}
	if f.mode == modeEdit {
		return f.keyOptionsEdit(msg)
	}
	return f.keyOptionsNav(msg)
}

// keyLauncher: the directory-first stage. Enter / Ctrl-S launch with the
// current agent, Ctrl-L/X/R/P/O with a named one, Tab opens the options,
// Up/Down move through the suggestions, Esc cancels; everything else edits
// the Directory field.
func (f newForm) keyLauncher(msg tea.KeyMsg) (newForm, tea.Cmd, formResult) {
	key := msg.String()
	if agent, ok := launchShortcuts[key]; ok {
		f.acceptHighlight()
		f.agent = agent
		return f.submit()
	}
	switch key {
	case "esc", "ctrl+c":
		return f, nil, formCancel
	case "enter", "ctrl+s":
		f.acceptHighlight()
		return f.submit()
	case "tab":
		f.acceptHighlight()
		f.openOptions()
		return f, nil, formContinue
	case "up":
		if f.highlight > 0 {
			f.highlight--
			f.ensureHighlightVisible()
		}
		return f, nil, formContinue
	case "down":
		if f.highlight < len(f.filtered)-1 {
			f.highlight++
			f.ensureHighlightVisible()
		}
		return f, nil, formContinue
	}
	before := f.dir.Value()
	var cmd tea.Cmd
	f.dir, cmd = f.dir.Update(trimPaste(msg))
	if f.dir.Value() != before {
		f.highlight, f.scroll = 0, 0
		f.errMsg = ""
		return f, tea.Batch(cmd, f.refilter()), formContinue
	}
	return f, cmd, formContinue
}

// keyOptionsNav: moving between the option fields. Enter edits a text field,
// returns to the launcher from Directory, launches from a select; Left /
// Right / Space cycle a select; Ctrl-S launches; Esc goes back.
func (f newForm) keyOptionsNav(msg tea.KeyMsg) (newForm, tea.Cmd, formResult) {
	switch msg.String() {
	case "esc":
		f.closeOptions()
		return f, f.refilter(), formContinue
	case "ctrl+c":
		return f, nil, formCancel
	case "ctrl+s":
		return f.submit()
	case "up":
		if f.cursor > 0 {
			f.cursor--
		}
	case "down":
		if f.cursor < len(f.fields)-1 {
			f.cursor++
		}
	case "enter":
		switch f.focusedField() {
		case fieldDirectory:
			f.closeOptions()
			return f, f.refilter(), formContinue
		case fieldTask:
			f.mode = modeEdit
			return f, f.task.Focus(), formContinue
		default:
			return f.submit()
		}
	case "right", " ":
		f.cycleSelect(1)
	case "left":
		f.cycleSelect(-1)
	}
	return f, nil, formContinue
}

// keyOptionsEdit: typing into the Task field. Enter / Esc return to
// navigation, Ctrl-S launches.
func (f newForm) keyOptionsEdit(msg tea.KeyMsg) (newForm, tea.Cmd, formResult) {
	switch msg.String() {
	case "esc", "enter":
		f.mode = modeNavigate
		f.task.Blur()
		return f, nil, formContinue
	case "ctrl+c":
		return f, nil, formCancel
	case "ctrl+s":
		return f.submit()
	}
	var cmd tea.Cmd
	f.task, cmd = f.task.Update(trimPaste(msg))
	f.errMsg = ""
	return f, cmd, formContinue
}

// trimPaste drops the line breaks a paste ends with: a copied path usually
// carries one, and the field is a single line (the text input turns inner
// line breaks into spaces).
func trimPaste(msg tea.KeyMsg) tea.KeyMsg {
	if !msg.Paste {
		return msg
	}
	runes := msg.Runes
	for len(runes) > 0 && (runes[len(runes)-1] == '\n' || runes[len(runes)-1] == '\r') {
		runes = runes[:len(runes)-1]
	}
	msg.Runes = runes
	return msg
}

// openOptions accepts the highlighted directory and shows the option
// fields, focused on Preset when presets exist, else Agent.
func (f *newForm) openOptions() {
	f.stage = stageOptions
	f.mode = modeNavigate
	f.dir.Blur()
	f.task.Blur()
	if f.presets != nil {
		f.cursor = f.fieldIndex(fieldPreset)
	} else {
		f.cursor = f.fieldIndex(fieldAgent)
	}
}

// closeOptions returns to the launcher with the Directory field in edit.
func (f *newForm) closeOptions() {
	f.stage = stageLauncher
	f.mode = modeEdit
	f.cursor = f.fieldIndex(fieldDirectory)
	f.task.Blur()
	f.dir.Focus()
	f.highlight, f.scroll = 0, 0
}

// cycleSelect moves the focused select field by dir (+1 / -1), wrapping; a
// value not among the options snaps to the first one. Picking a preset
// fills the other fields.
func (f *newForm) cycleSelect(dir int) {
	var opts []string
	var cur *string
	switch f.focusedField() {
	case fieldPreset:
		opts, cur = f.presets, &f.preset
	case fieldAgent:
		opts, cur = f.agents, &f.agent
	default:
		return
	}
	if len(opts) == 0 {
		return
	}
	next := opts[0]
	for i, o := range opts {
		if o == *cur {
			next = opts[(i+dir+len(opts))%len(opts)]
			break
		}
	}
	*cur = next
	if f.focusedField() == fieldPreset {
		f.applyPreset(next)
	}
}

// applyPreset copies a preset's directory (path or @spec), agent, and task
// into the fields. Its agent args and shell flag travel to cmd_new as
// --preset=<name> in the output and are merged there.
func (f *newForm) applyPreset(name string) {
	p, ok := f.cfg.Presets[name]
	if !ok || name == "-" {
		return
	}
	if p.Directory != "" {
		f.dir.SetValue(p.Directory)
		f.dir.CursorEnd()
		f.highlight, f.scroll = 0, 0
	}
	if p.Agent != "" {
		f.agent = p.Agent
	}
	if p.Task != "" {
		f.task.SetValue(p.Task)
		f.task.CursorEnd()
	}
}

// acceptHighlight puts the highlighted candidate into the Directory field
// (Tab / Enter in the launcher). Nothing happens without candidates, so a
// typed value with no match is kept as is. The candidate list is left for
// the next refilter (the options stage does not show it).
func (f *newForm) acceptHighlight() {
	if len(f.filtered) == 0 {
		return
	}
	idx := f.highlight
	if idx < 0 || idx >= len(f.filtered) {
		idx = 0
	}
	f.dir.SetValue(f.filtered[idx].value)
	f.dir.CursorEnd() // SetValue keeps a cursor that is still in range
	f.highlight, f.scroll = 0, 0
}

// expandDir is the field value with a leading ~ expanded.
func (f newForm) expandDir(v string) string {
	if strings.HasPrefix(v, "~") {
		return f.home + v[1:]
	}
	return v
}

// submit validates and produces the output line. A `@spec` passes through
// unvalidated (cmd_new resolves it) once a dir_provider is configured; a
// plain path must exist. A failure is shown under the fields and the form
// stays open.
func (f newForm) submit() (newForm, tea.Cmd, formResult) {
	dir := f.expandDir(f.dir.Value())
	if strings.HasPrefix(dir, "@") {
		if f.cfg.DirProviderCmd() == "" {
			f.errMsg = fmt.Sprintf("No directory provider configured for %s (am config set dir_provider <cmd>)", dir)
			return f, nil, formContinue
		}
	} else if dir == "" || !isDir(dir) {
		shown := dir
		if shown == "" {
			shown = "<empty>"
		}
		f.errMsg = "Directory does not exist: " + shown
		return f, nil, formContinue
	}
	if _, ok := sessions.Agent(f.agent); !ok {
		f.errMsg = "Invalid agent type: " + f.agent
		return f, nil, formContinue
	}
	flags := ""
	if f.preset != "" && f.preset != "-" {
		flags = "--preset=" + f.preset
	}
	f.output = "__NEW_SESSION__\x1f" + dir + "\x1f" + f.agent + "\x1f" + flags + "\x1f" + f.task.Value()
	return f, nil, formSubmit
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// refilter rebuilds the candidate rows for the Directory field's value. A
// `@` query shows the provider's suggestions (fetched once per distinct
// text, off the UI thread; the returned Cmd is that fetch) as `@spec` rows,
// or the typed spec itself while they load and when there are none, so
// Enter still resolves it. Any other query filters the frecent list by
// substring; a path-like query (`/`, `~`, `.`) adds the directory it names
// first and the filesystem completions after.
func (f *newForm) refilter() tea.Cmd {
	q := f.dir.Value()
	f.filtered = f.filtered[:0]
	if strings.HasPrefix(q, "@") {
		rows, cached := f.providerCache[q]
		if cached && len(rows) > 0 {
			for i, r := range rows {
				if i >= formMaxCandidates {
					break
				}
				f.filtered = append(f.filtered, dirCandidate{value: "@" + r.Spec, label: r.Label})
			}
			return nil
		}
		f.filtered = append(f.filtered, dirCandidate{value: q, label: "resolve with dir_provider"})
		if cached || f.providerPending[q] {
			return nil
		}
		if f.cfg.DirProviderCmd() == "" {
			f.providerCache[q] = nil
			return nil
		}
		f.providerPending[q] = true
		suggest := f.suggest
		return func() tea.Msg {
			return formProviderMsg{query: q, rows: suggest(strings.TrimPrefix(q, "@"))}
		}
	}

	seen := map[string]bool{}
	add := func(value, label string) {
		if len(f.filtered) >= formMaxCandidates || seen[value] {
			return
		}
		seen[value] = true
		f.filtered = append(f.filtered, dirCandidate{value: value, label: label})
	}
	pathLike := q != "" && (q[0] == '/' || q[0] == '~' || q[0] == '.')
	if pathLike {
		if expanded := f.expandDir(q); isDir(expanded) {
			add(q, "")
		}
	}
	lq := strings.ToLower(q)
	for _, p := range f.frecent {
		if q == "" || strings.Contains(strings.ToLower(p), lq) {
			add(p, "")
		}
	}
	if pathLike {
		for _, p := range sessions.PathCompletions(q, f.home) {
			add(p, "")
		}
	}
	if f.highlight >= len(f.filtered) {
		f.highlight = 0
	}
	return nil
}

// visibleRows is how many suggestion rows fit under the Directory field.
func (f newForm) visibleRows() int {
	n := f.height - formHeaderLines - 3 // field row, error line, margin
	if n < 3 {
		n = 3
	}
	return n
}

// ensureHighlightVisible scrolls the suggestion window so the highlighted
// row is shown, accounting for the ▲/▼ indicator rows.
func (f *newForm) ensureHighlightVisible() {
	total := len(f.filtered)
	visible := f.visibleRows()
	if total <= visible {
		f.scroll = 0
		return
	}
	if f.highlight < f.scroll {
		f.scroll = f.highlight
		return
	}
	for {
		entryLines := visible
		if f.scroll > 0 {
			entryLines--
		}
		if f.scroll+entryLines < total {
			entryLines--
		}
		if f.highlight < f.scroll+entryLines {
			return
		}
		f.scroll++
	}
}

// --- rendering ---

func (f newForm) view() string {
	if f.width == 0 {
		return "Loading..."
	}
	var b strings.Builder
	if f.stage == stageLauncher {
		b.WriteString("  " + titleStyle.Render("New Session") + "\n")
		b.WriteString(dimStyle.Render(fmt.Sprintf("  Enter: launch %s  Ctrl-L: Claude  Ctrl-X: Codex", f.agent)) + "\n")
		b.WriteString(dimStyle.Render("  Ctrl-R: Cursor  Ctrl-P: Pi  Ctrl-O: opencode  Tab: options  Esc: cancel") + "\n")
	} else {
		b.WriteString("  " + titleStyle.Render("New Session — Options") + "\n")
		b.WriteString(dimStyle.Render("  ↑↓: move  ←→/Space: change  Enter: edit/launch") + "\n")
		b.WriteString(dimStyle.Render("  Ctrl-S: launch  Esc: back") + "\n")
	}
	b.WriteString("\n")

	for i, field := range f.fields {
		if f.stage == stageLauncher && field != fieldDirectory {
			continue
		}
		focused := f.stage == stageLauncher && field == fieldDirectory ||
			f.stage == stageOptions && i == f.cursor
		b.WriteString(f.renderField(field, focused))
		b.WriteString("\n")
		if field == fieldDirectory && f.stage == stageLauncher {
			b.WriteString(f.renderSuggestions())
		}
	}
	if f.errMsg != "" {
		b.WriteString("\n  " + formErrorStyle.Render(f.errMsg) + "\n")
	}
	return b.String()
}

// renderField draws one row: a focus prefix (» editing, > navigating), the
// label (highlighted when focused: blue in edit mode, gray in navigate),
// then the text input, the plain value, or the select's options.
func (f newForm) renderField(field formField, focused bool) string {
	prefix := "  "
	label := fmt.Sprintf("%-*s", formLabelWidth, field.label()+":")
	editing := focused && f.mode == modeEdit
	if focused {
		if editing {
			prefix = "» "
			label = formLabelEditStyle.Render(label)
		} else {
			prefix = "> "
			label = formLabelNavStyle.Render(label)
		}
	}
	valueWidth := f.width - 2 - formLabelWidth - 1
	if valueWidth < 10 {
		valueWidth = 10
	}
	var value string
	switch field {
	case fieldDirectory, fieldTask:
		ti := f.dir
		if field == fieldTask {
			ti = f.task
		}
		if editing {
			ti.Width = valueWidth - 1
			value = ti.View()
		} else {
			value = truncRunesTo(ti.Value(), valueWidth)
		}
	case fieldPreset, fieldAgent:
		opts, cur := f.agents, f.agent
		if field == fieldPreset {
			opts, cur = f.presets, f.preset
		}
		var parts []string
		for _, o := range opts {
			if o == cur {
				parts = append(parts, formSelectedStyle.Render(" "+o+" "))
			} else {
				parts = append(parts, dimStyle.Render(o))
			}
		}
		value = strings.Join(parts, " ")
	}
	return prefix + label + " " + value
}

// renderSuggestions draws the candidate rows under the Directory field, a
// window of visibleRows with ▲ N more / ▼ N more indicators when scrolled.
func (f newForm) renderSuggestions() string {
	var b strings.Builder
	total := len(f.filtered)
	visible := f.visibleRows()
	offset := f.scroll
	if total <= visible {
		offset = 0
	} else if maxOff := total - visible + 1; offset > maxOff {
		offset = maxOff
	}
	entryLines := visible
	above, below := false, false
	if offset > 0 {
		above = true
		entryLines--
	}
	if offset+entryLines < total {
		below = true
		entryLines--
	}
	if above {
		b.WriteString(dimStyle.Render(fmt.Sprintf("    ▲ %d more", offset)) + "\n")
	}
	for i := offset; i < offset+entryLines && i < total; i++ {
		c := f.filtered[i]
		path := truncRunesTo(c.value, f.width-4)
		if i == f.highlight {
			b.WriteString("    " + accentStyle.Render(path))
		} else {
			b.WriteString("    " + dimStyle.Render(path))
		}
		if c.label != "" && len([]rune(path))+len([]rune(c.label))+6 <= f.width {
			b.WriteString("  " + dimStyle.Render(c.label))
		}
		b.WriteString("\n")
	}
	if below {
		b.WriteString(dimStyle.Render(fmt.Sprintf("    ▼ %d more", total-offset-entryLines)) + "\n")
	}
	return b.String()
}

// truncRunesTo cuts a plain string to width cells with a trailing ….
func truncRunesTo(s string, width int) string {
	r := []rune(s)
	if width < 2 || len(r) <= width {
		return s
	}
	return string(r[:width-1]) + "…"
}
