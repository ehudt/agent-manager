package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

// Tests of the new-session form model (newform.go), the Go port of
// tests/test_form.sh: keys in, fields / stage / output out. The text
// editing itself is bubbles' textinput and is not re-tested here.

func key(k tea.KeyType) tea.KeyMsg { return tea.KeyMsg{Type: k} }

func runes(s string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func paste(s string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s), Paste: true}
}

// testForm is a form with a fixed frecent list, a stub provider, and a
// terminal of 80x24; cfg and the prefill as given.
func testForm(t *testing.T, cfg sessions.Config, dir, agent, task string, frecent []string) newForm {
	t.Helper()
	home := t.TempDir()
	f := newNewForm(cfg, t.TempDir(), home, dir, agent, task, false)
	f.width, f.height = 80, 24
	f.suggest = func(string) []sessions.DirSuggestion { return nil }
	f, _, _ = f.update(formDirsMsg{paths: frecent})
	return f
}

// press feeds keys and returns the form and the last result.
func press(f newForm, keys ...tea.KeyMsg) (newForm, formResult) {
	res := formContinue
	for _, k := range keys {
		f, _, res = f.update(k)
	}
	return f, res
}

func typeText(f newForm, s string) newForm {
	for _, r := range s {
		f, _, _ = f.update(runes(string(r)))
	}
	return f
}

func existingDir(t *testing.T) string {
	t.Helper()
	d := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func splitOutput(t *testing.T, out string) (dir, agent, flags, task string) {
	t.Helper()
	parts := strings.Split(out, "\x1f")
	if len(parts) != 5 || parts[0] != "__NEW_SESSION__" {
		t.Fatalf("output = %q, want __NEW_SESSION__ + 4 fields", out)
	}
	return parts[1], parts[2], parts[3], parts[4]
}

func TestFormFieldsAndAgents(t *testing.T) {
	f := testForm(t, sessions.Config{}, "/tmp/project", "claude", "", nil)
	if got := f.fields; len(got) != 3 || got[0] != fieldDirectory || got[1] != fieldAgent || got[2] != fieldTask {
		t.Errorf("fields = %v, want directory agent task", got)
	}
	if f.presets != nil {
		t.Errorf("presets = %v without any preset", f.presets)
	}
	agents := strings.Join(f.agents, ",")
	if !strings.Contains(agents, "cursor") {
		t.Errorf("agents %q lacks cursor", agents)
	}
	if strings.Contains(agents, "cursor-agent") {
		t.Errorf("agents %q lists the cursor alias", agents)
	}
	if f.stage != stageLauncher || f.mode != modeEdit || !f.dir.Focused() {
		t.Errorf("start: stage=%v mode=%v focused=%v, want launcher/edit/focused", f.stage, f.mode, f.dir.Focused())
	}
	if f.highlight != 0 {
		t.Errorf("highlight starts at %d", f.highlight)
	}
}

func TestFormDefaultAgent(t *testing.T) {
	t.Setenv("AM_DEFAULT_AGENT", "")
	f := testForm(t, sessions.Config{DefaultAgent: "pi"}, "", "", "", nil)
	if f.agent != "pi" {
		t.Errorf("agent = %q, want the configured default", f.agent)
	}
	f = testForm(t, sessions.Config{}, "", "cursor-agent", "", nil)
	if f.agent != "cursor" {
		t.Errorf("agent = %q, want the alias normalized", f.agent)
	}
	f = testForm(t, sessions.Config{}, "", "nosuch", "", nil)
	if f.agent != f.agents[0] {
		t.Errorf("agent = %q, want the first type for an unknown prefill", f.agent)
	}
}

func TestFormLauncherKeys(t *testing.T) {
	dir := existingDir(t)
	other := existingDir(t)

	// Enter accepts the highlighted directory and submits with the current agent.
	f := testForm(t, sessions.Config{}, "", "claude", "", []string{dir, other})
	f, res := press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("enter: result %v, want submit", res)
	}
	gotDir, agent, flags, task := splitOutput(t, f.output)
	if gotDir != dir || agent != "claude" || flags != "" || task != "" {
		t.Errorf("enter output = %q %q %q %q", gotDir, agent, flags, task)
	}

	// Down moves the highlight; Enter takes that row.
	f = testForm(t, sessions.Config{}, "", "claude", "", []string{dir, other})
	f, res = press(f, key(tea.KeyDown), key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("down+enter: result %v", res)
	}
	if gotDir, _, _, _ = splitOutput(t, f.output); gotDir != other {
		t.Errorf("down+enter dir = %q, want %q", gotDir, other)
	}

	// Ctrl-S submits too.
	f = testForm(t, sessions.Config{}, "", "claude", "", []string{dir})
	if _, res = press(f, key(tea.KeyCtrlS)); res != formSubmit {
		t.Errorf("ctrl-s: result %v, want submit", res)
	}

	// Esc cancels.
	f = testForm(t, sessions.Config{}, "", "claude", "", []string{dir})
	if _, res = press(f, key(tea.KeyEsc)); res != formCancel {
		t.Errorf("esc: result %v, want cancel", res)
	}

	// The agent shortcuts pick the agent and submit.
	for k, want := range map[tea.KeyType]string{
		tea.KeyCtrlL: "claude", tea.KeyCtrlX: "codex", tea.KeyCtrlR: "cursor",
		tea.KeyCtrlP: "pi", tea.KeyCtrlO: "opencode",
	} {
		f = testForm(t, sessions.Config{}, "", "claude", "", []string{dir})
		f, res = press(f, key(k))
		if res != formSubmit {
			t.Errorf("%v: result %v, want submit", k, res)
			continue
		}
		if _, agent, _, _ = splitOutput(t, f.output); agent != want {
			t.Errorf("%v: agent %q, want %q", k, agent, want)
		}
	}

	// Tab accepts the highlighted directory and opens the options on Agent.
	f = testForm(t, sessions.Config{}, "", "claude", "", []string{dir, other})
	f, res = press(f, key(tea.KeyDown), key(tea.KeyTab))
	if res != formContinue || f.stage != stageOptions || f.mode != modeNavigate {
		t.Fatalf("tab: res=%v stage=%v mode=%v", res, f.stage, f.mode)
	}
	if f.dir.Value() != other {
		t.Errorf("tab: directory %q, want the highlighted %q", f.dir.Value(), other)
	}
	if f.focusedField() != fieldAgent {
		t.Errorf("tab: focused %v, want agent", f.focusedField())
	}
	if f.dir.Focused() {
		t.Error("tab: directory still focused in the options")
	}
}

func TestFormOptionsNavigation(t *testing.T) {
	dir := existingDir(t)
	f := testForm(t, sessions.Config{}, dir, "claude", "", []string{dir})
	f, _ = press(f, key(tea.KeyTab)) // options, on Agent

	// Space / Right cycle forward, Left backward, wrapping.
	first := f.agent
	f, _ = press(f, key(tea.KeySpace))
	if f.agent == first {
		t.Error("space did not cycle the agent")
	}
	f, _ = press(f, key(tea.KeyLeft))
	if f.agent != first {
		t.Errorf("left: agent %q, want back to %q", f.agent, first)
	}
	f, _ = press(f, key(tea.KeyLeft))
	if f.agent != f.agents[len(f.agents)-1] {
		t.Errorf("left from first: %q, want wrap to the last", f.agent)
	}
	f, _ = press(f, key(tea.KeyRight))
	if f.agent != first {
		t.Errorf("right from last: %q, want wrap to the first", f.agent)
	}

	// Up/Down move between fields and clamp.
	f, _ = press(f, key(tea.KeyUp))
	if f.focusedField() != fieldDirectory {
		t.Errorf("up: %v, want directory", f.focusedField())
	}
	f, _ = press(f, key(tea.KeyUp))
	if f.focusedField() != fieldDirectory {
		t.Errorf("up at top: %v, want still directory", f.focusedField())
	}
	f, _ = press(f, key(tea.KeyDown), key(tea.KeyDown), key(tea.KeyDown))
	if f.focusedField() != fieldTask {
		t.Errorf("down past end: %v, want task", f.focusedField())
	}

	// Typing in navigate mode is ignored; Enter on Task edits; Enter / Esc
	// return to navigation; Ctrl-S submits from edit.
	f = typeText(f, "x")
	if f.task.Value() != "" {
		t.Errorf("nav typing changed the task to %q", f.task.Value())
	}
	f, res := press(f, key(tea.KeyEnter))
	if res != formContinue || f.mode != modeEdit || !f.task.Focused() {
		t.Fatalf("enter on task: res=%v mode=%v focused=%v", res, f.mode, f.task.Focused())
	}
	f = typeText(f, "Hi there")
	f, _ = press(f, key(tea.KeyBackspace))
	if f.task.Value() != "Hi ther" {
		t.Errorf("task = %q after typing and backspace", f.task.Value())
	}
	f, res = press(f, key(tea.KeyEsc))
	if res != formContinue || f.mode != modeNavigate {
		t.Errorf("esc in edit: res=%v mode=%v, want continue/navigate", res, f.mode)
	}
	f, _ = press(f, key(tea.KeyEnter))
	f, res = press(f, key(tea.KeyEnter))
	if res != formContinue || f.mode != modeNavigate {
		t.Errorf("enter in edit: res=%v mode=%v, want continue/navigate", res, f.mode)
	}
	f, _ = press(f, key(tea.KeyEnter))
	f, res = press(f, key(tea.KeyCtrlS))
	if res != formSubmit {
		t.Fatalf("ctrl-s in edit: %v", res)
	}
	if _, _, _, task := splitOutput(t, f.output); task != "Hi ther" {
		t.Errorf("task in output = %q", task)
	}

	// Enter on the Agent select submits (does not cycle).
	f = testForm(t, sessions.Config{}, dir, "claude", "", []string{dir})
	f, _ = press(f, key(tea.KeyTab))
	f, res = press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Errorf("enter on agent: %v, want submit", res)
	}
	if _, agent, _, _ := splitOutput(t, f.output); agent != "claude" {
		t.Errorf("enter on agent cycled to %q", agent)
	}

	// Enter on Directory, and Esc anywhere in navigation, close the options
	// and resume directory editing.
	f = testForm(t, sessions.Config{}, dir, "claude", "", []string{dir})
	f, _ = press(f, key(tea.KeyTab), key(tea.KeyUp), key(tea.KeyEnter))
	if f.stage != stageLauncher || f.mode != modeEdit || !f.dir.Focused() {
		t.Errorf("enter on directory: stage=%v mode=%v focused=%v", f.stage, f.mode, f.dir.Focused())
	}
	f, _ = press(f, key(tea.KeyTab), key(tea.KeyEsc))
	if f.stage != stageLauncher || !f.dir.Focused() {
		t.Errorf("esc in options: stage=%v focused=%v", f.stage, f.dir.Focused())
	}
	// Ctrl-C cancels from the options too.
	f, _ = press(f, key(tea.KeyTab))
	if _, res = press(f, key(tea.KeyCtrlC)); res != formCancel {
		t.Errorf("ctrl-c in options: %v", res)
	}
}

func TestFormValidation(t *testing.T) {
	t.Setenv("AM_DIR_PROVIDER", "")
	// A missing plain directory is rejected and the form stays open.
	f := testForm(t, sessions.Config{}, "", "claude", "", nil)
	f = typeText(f, "/definitely/missing/dir")
	f, res := press(f, key(tea.KeyEnter))
	if res != formContinue || f.output != "" {
		t.Fatalf("missing dir: res=%v output=%q", res, f.output)
	}
	if !strings.Contains(f.errMsg, "Directory does not exist: /definitely/missing/dir") {
		t.Errorf("errMsg = %q", f.errMsg)
	}
	// Typing clears the error.
	f = typeText(f, "x")
	if f.errMsg != "" {
		t.Errorf("errMsg kept after typing: %q", f.errMsg)
	}

	// Empty is rejected.
	f = testForm(t, sessions.Config{}, "", "claude", "", nil)
	f, _ = press(f, key(tea.KeyEnter))
	if !strings.Contains(f.errMsg, "<empty>") {
		t.Errorf("empty dir errMsg = %q", f.errMsg)
	}

	// A @spec is rejected without a provider, naming the config key.
	f = testForm(t, sessions.Config{}, "", "claude", "", nil)
	f = typeText(f, "@48351")
	f, res = press(f, key(tea.KeyEnter))
	if res != formContinue {
		t.Fatalf("@spec without provider: res=%v", res)
	}
	if !strings.Contains(f.errMsg, "dir_provider") || !strings.Contains(f.errMsg, "@48351") {
		t.Errorf("@spec without provider errMsg = %q", f.errMsg)
	}

	// With a provider the @spec reaches the output untouched, with no flags.
	f = testForm(t, sessions.Config{DirProvider: "true"}, "", "claude", "", nil)
	f = typeText(f, "@48351")
	f, res = press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("@spec with provider: res=%v err=%q", res, f.errMsg)
	}
	dir, _, flags, _ := splitOutput(t, f.output)
	if dir != "@48351" || flags != "" {
		t.Errorf("@spec output dir=%q flags=%q", dir, flags)
	}
	// A plain missing directory is still rejected with a provider.
	f = testForm(t, sessions.Config{DirProvider: "true"}, "", "claude", "", nil)
	f = typeText(f, "/definitely/missing")
	if _, res = press(f, key(tea.KeyEnter)); res != formContinue {
		t.Errorf("missing dir with provider: res=%v", res)
	}

	// ~ expands in the output.
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "proj"), 0o755); err != nil {
		t.Fatal(err)
	}
	f = newNewForm(sessions.Config{}, t.TempDir(), home, "", "claude", "", false)
	f.width, f.height = 80, 24
	f, _, _ = f.update(formDirsMsg{})
	f = typeText(f, "~/proj")
	f, res = press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("~ dir: res=%v err=%q", res, f.errMsg)
	}
	if dir, _, _, _ = splitOutput(t, f.output); dir != filepath.Join(home, "proj") {
		t.Errorf("~ dir = %q", dir)
	}
}

func TestFormSuggestions(t *testing.T) {
	var dirs []string
	for i := 0; i < 15; i++ {
		dirs = append(dirs, filepath.Join("/tmp/frecent", string(rune('a'+i))))
	}
	f := testForm(t, sessions.Config{}, "", "claude", "", dirs)
	f.height = 14 // visibleRows = 7
	if len(f.filtered) != 15 {
		t.Fatalf("filtered = %d, want all 15 for an empty query", len(f.filtered))
	}

	// Down moves and clamps; the window follows.
	f, _ = press(f, key(tea.KeyDown), key(tea.KeyDown))
	if f.highlight != 2 || f.scroll != 0 {
		t.Errorf("after 2 down: highlight=%d scroll=%d", f.highlight, f.scroll)
	}
	for i := 0; i < 20; i++ {
		f, _ = press(f, key(tea.KeyDown))
	}
	if f.highlight != 14 {
		t.Errorf("down clamps at %d, want 14", f.highlight)
	}
	if f.scroll == 0 {
		t.Error("scroll did not follow the highlight")
	}
	view := f.renderSuggestions()
	if !strings.Contains(view, "▲") || strings.Contains(view, "▼") {
		t.Errorf("at the bottom the view shows ▲ only: %q", view)
	}
	if !strings.Contains(view, dirs[14]) {
		t.Errorf("highlighted row not drawn: %q", view)
	}
	for i := 0; i < 20; i++ {
		f, _ = press(f, key(tea.KeyUp))
	}
	if f.highlight != 0 || f.scroll != 0 {
		t.Errorf("up clamps: highlight=%d scroll=%d", f.highlight, f.scroll)
	}

	// Typing filters by substring (case-insensitive) and resets the highlight.
	f, _ = press(f, key(tea.KeyDown), key(tea.KeyDown))
	f = typeText(f, "FRECENT/c")
	if f.highlight != 0 || len(f.filtered) != 1 || f.filtered[0].value != dirs[2] {
		t.Errorf("filter: highlight=%d filtered=%v", f.highlight, f.filtered)
	}
	// A cursor move keeps the highlight (the value did not change).
	f, _ = press(f, key(tea.KeyDown))
	before := f.highlight
	f, _ = press(f, key(tea.KeyLeft))
	if f.highlight != before {
		t.Errorf("cursor move reset the highlight: %d → %d", before, f.highlight)
	}
}

func TestFormPathQuery(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"alpha", "alpha/one", "alpha/two", "beta"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f := testForm(t, sessions.Config{}, "", "claude", "", []string{filepath.Join(root, "beta")})
	f = typeText(f, filepath.Join(root, "alpha"))
	// The typed directory comes first (Enter must not pick a child), then its
	// children.
	if len(f.filtered) < 3 || f.filtered[0].value != filepath.Join(root, "alpha") {
		t.Fatalf("filtered = %v", f.filtered)
	}
	if f.filtered[1].value != filepath.Join(root, "alpha", "one") || f.filtered[2].value != filepath.Join(root, "alpha", "two") {
		t.Errorf("children = %v", f.filtered[1:])
	}
	f, res := press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("enter: %v", res)
	}
	if dir, _, _, _ := splitOutput(t, f.output); dir != filepath.Join(root, "alpha") {
		t.Errorf("dir = %q", dir)
	}
	// A prefix completes against the parent.
	f = testForm(t, sessions.Config{}, "", "claude", "", nil)
	f = typeText(f, filepath.Join(root, "al"))
	if len(f.filtered) != 1 || f.filtered[0].value != filepath.Join(root, "alpha") {
		t.Errorf("prefix: %v", f.filtered)
	}
}

func TestFormProvider(t *testing.T) {
	calls := map[string]int{}
	suggest := func(partial string) []sessions.DirSuggestion {
		calls[partial]++
		switch {
		case partial == "":
			return []sessions.DirSuggestion{{Spec: "", Label: "new copy on trunk"}, {Spec: "trunk", Label: "default branch"}}
		case strings.HasPrefix(partial, "48"):
			return []sessions.DirSuggestion{{Spec: "48351", Label: "PR #48351 fix bbr"}, {Spec: "48372", Label: "PR #48372 gw retry"}}
		}
		return nil
	}
	// drive runs the pending provider Cmd synchronously, as the program would.
	drive := func(f newForm, cmd tea.Cmd) newForm {
		if cmd == nil {
			return f
		}
		if msg := cmd(); msg != nil {
			if pm, ok := msg.(formProviderMsg); ok {
				f, _, _ = f.update(pm)
			}
		}
		return f
	}
	typeDrive := func(f newForm, s string) newForm {
		for _, r := range s {
			var cmd tea.Cmd
			f, cmd, _ = f.update(runes(string(r)))
			f = drive(f, batchedProviderCmd(cmd))
		}
		return f
	}

	cfg := sessions.Config{DirProvider: "fake"}
	f := testForm(t, cfg, "", "claude", "", []string{"/tmp/x"})
	f.suggest = suggest

	// Bare @: the provider's defaults, empty spec first, rendered as "@".
	f = typeDrive(f, "@")
	if len(f.filtered) != 2 || f.filtered[0].value != "@" || f.filtered[0].label != "new copy on trunk" || f.filtered[1].value != "@trunk" {
		t.Fatalf("bare @: %v", f.filtered)
	}
	f, res := press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("enter on bare @: %v (%s)", res, f.errMsg)
	}
	if dir, _, _, _ := splitOutput(t, f.output); dir != "@" {
		t.Errorf("bare @ output dir = %q", dir)
	}

	// Candidates carry the @ and the label; Tab accepts the highlighted one;
	// one provider run per distinct partial.
	f = testForm(t, cfg, "", "claude", "", nil)
	f.suggest = suggest
	f = typeDrive(f, "@48")
	if len(f.filtered) != 2 || f.filtered[0].value != "@48351" || f.filtered[1].label != "PR #48372 gw retry" {
		t.Fatalf("@48: %v", f.filtered)
	}
	f, _ = press(f, key(tea.KeyDown), key(tea.KeyTab))
	if f.dir.Value() != "@48372" {
		t.Errorf("tab accepted %q, want @48372", f.dir.Value())
	}
	f, _ = press(f, key(tea.KeyEsc)) // back to the launcher, refilter
	f, _ = press(f, key(tea.KeyBackspace), key(tea.KeyBackspace), key(tea.KeyBackspace))
	if f.dir.Value() != "@48" || calls["48"] != 1 {
		t.Errorf("after backspace to @48: value=%q calls=%v, want cached", f.dir.Value(), calls)
	}

	// No match: the typed spec is the one fallback row, and Enter submits it.
	f = testForm(t, cfg, "", "claude", "", nil)
	f.suggest = suggest
	f = typeDrive(f, "@zzz")
	if len(f.filtered) != 1 || f.filtered[0].value != "@zzz" {
		t.Fatalf("no match: %v", f.filtered)
	}
	f, res = press(f, key(tea.KeyEnter))
	if res != formSubmit {
		t.Fatalf("enter on fallback: %v", res)
	}
	if dir, _, _, _ := splitOutput(t, f.output); dir != "@zzz" {
		t.Errorf("fallback dir = %q", dir)
	}

	// While the fetch is pending the typed spec is offered, and the late
	// answer for an abandoned query does not disturb the current list.
	f = testForm(t, cfg, "", "claude", "", nil)
	f.suggest = suggest
	f, cmd, _ := f.update(runes("@"))
	if len(f.filtered) != 1 || f.filtered[0].value != "@" {
		t.Errorf("pending: %v", f.filtered)
	}
	f = typeText(f, "zzz")
	f = drive(f, batchedProviderCmd(cmd))
	if len(f.filtered) != 1 || f.filtered[0].value != "@zzz" {
		t.Errorf("late answer changed the list: %v", f.filtered)
	}

	// Without a provider only the typed spec is offered and nothing runs.
	t.Setenv("AM_DIR_PROVIDER", "")
	f = testForm(t, sessions.Config{}, "", "claude", "", nil)
	ran := false
	f.suggest = func(string) []sessions.DirSuggestion { ran = true; return nil }
	f = typeDrive(f, "@48")
	if ran || len(f.filtered) != 1 || f.filtered[0].value != "@48" {
		t.Errorf("no provider: ran=%v filtered=%v", ran, f.filtered)
	}
}

// batchedProviderCmd unwraps the Batch the launcher returns on a value
// change (textinput cmd + the refilter's fetch) to the provider fetch.
func batchedProviderCmd(cmd tea.Cmd) tea.Cmd {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, c := range batch {
			if c == nil {
				continue
			}
			if m := c(); m != nil {
				if pm, ok := m.(formProviderMsg); ok {
					return func() tea.Msg { return pm }
				}
			}
		}
		return nil
	}
	if pm, ok := msg.(formProviderMsg); ok {
		return func() tea.Msg { return pm }
	}
	return nil
}

func TestFormPresets(t *testing.T) {
	tools := existingDir(t)
	cfg := sessions.Config{Presets: map[string]sessions.Preset{
		"review":  {Agent: "claude", Directory: "@", Args: []string{"--model", "opus"}},
		"scratch": {Agent: "pi", Directory: tools, Task: "poke around", Shell: true},
	}}
	f := testForm(t, cfg, "/tmp/project", "claude", "", nil)
	if len(f.fields) != 4 || f.fields[0] != fieldPreset {
		t.Fatalf("fields = %v, want preset first", f.fields)
	}
	if strings.Join(f.presets, ",") != "-,review,scratch" {
		t.Errorf("presets = %v", f.presets)
	}
	// Tab opens the options on Preset; Space cycles and fills the fields.
	f, _ = press(f, key(tea.KeyTab))
	if f.focusedField() != fieldPreset {
		t.Fatalf("tab focused %v, want preset", f.focusedField())
	}
	f, _ = press(f, key(tea.KeySpace))
	if f.preset != "review" || f.agent != "claude" || f.dir.Value() != "@" {
		t.Errorf("review: preset=%q agent=%q dir=%q", f.preset, f.agent, f.dir.Value())
	}
	f, _ = press(f, key(tea.KeySpace))
	if f.preset != "scratch" || f.agent != "pi" || f.dir.Value() != tools || f.task.Value() != "poke around" {
		t.Errorf("scratch: preset=%q agent=%q dir=%q task=%q", f.preset, f.agent, f.dir.Value(), f.task.Value())
	}
	f, res := press(f, key(tea.KeyCtrlS))
	if res != formSubmit {
		t.Fatalf("ctrl-s: %v (%s)", res, f.errMsg)
	}
	dir, agent, flags, task := splitOutput(t, f.output)
	if dir != tools || agent != "pi" || flags != "--preset=scratch" || task != "poke around" {
		t.Errorf("output = %q %q %q %q", dir, agent, flags, task)
	}
}

func TestFormPasteTrimsLineBreaks(t *testing.T) {
	dir := existingDir(t)
	f := testForm(t, sessions.Config{}, "", "claude", "", nil)
	f, _, _ = f.update(paste(dir + "\n"))
	if f.dir.Value() != dir {
		t.Errorf("pasted value = %q, want %q", f.dir.Value(), dir)
	}
	f, _, _ = f.update(paste("\r\n"))
	if f.dir.Value() != dir {
		t.Errorf("pasting a bare newline changed the value to %q", f.dir.Value())
	}
}

func TestFormView(t *testing.T) {
	dir := existingDir(t)
	f := testForm(t, sessions.Config{}, "", "claude", "", []string{dir})
	v := f.view()
	// Rows are cut to the width, so look for the path's head.
	for _, want := range []string{"New Session", "Directory:", dir[:20], "Enter: launch claude", "Tab: options"} {
		if !strings.Contains(v, want) {
			t.Errorf("launcher view lacks %q:\n%s", want, v)
		}
	}
	if strings.Contains(v, "Agent:") || strings.Contains(v, "Task:") {
		t.Errorf("launcher view shows the options:\n%s", v)
	}
	f, _ = press(f, key(tea.KeyTab))
	v = f.view()
	for _, want := range []string{"Options", "Agent:", "Task:", "Directory:"} {
		if !strings.Contains(v, want) {
			t.Errorf("options view lacks %q:\n%s", want, v)
		}
	}
	f.errMsg = "Directory does not exist: /nope"
	if !strings.Contains(f.view(), "Directory does not exist: /nope") {
		t.Error("error line not shown")
	}
}

func TestBrowserCtrlNOpensFormAndEscReturns(t *testing.T) {
	t.Setenv("AM_DIR", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	m := newModel()
	m.width, m.height = 80, 24
	m.loading = false
	mm, _ := m.Update(key(tea.KeyCtrlN))
	m = mm.(model)
	if m.form == nil {
		t.Fatal("ctrl-n did not open the form")
	}
	if m.output != "" {
		t.Errorf("ctrl-n set output %q", m.output)
	}
	if !strings.Contains(m.View(), "New Session") {
		t.Error("view does not show the form")
	}
	mm, _ = m.Update(key(tea.KeyEsc))
	m = mm.(model)
	if m.form != nil {
		t.Error("esc did not return to the list")
	}
	if m.output != "" {
		t.Errorf("esc from the form set output %q", m.output)
	}
}

func TestBrowserFormSubmitQuitsWithLine(t *testing.T) {
	t.Setenv("AM_DIR", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	dir := existingDir(t)
	m := newModel()
	m.width, m.height = 80, 24
	m.openForm(dir, "codex", "do it", true)
	mm, _ := m.Update(key(tea.KeyEnter))
	m = mm.(model)
	gotDir, agent, flags, task := splitOutput(t, m.output)
	if gotDir != dir || agent != "codex" || flags != "" || task != "do it" {
		t.Errorf("output = %q %q %q %q", gotDir, agent, flags, task)
	}
	// Standalone: Esc quits with no output.
	m = newModel()
	m.width, m.height = 80, 24
	m.openForm("", "", "", true)
	mm, cmd := m.Update(key(tea.KeyEsc))
	m = mm.(model)
	if m.output != "" || cmd == nil {
		t.Errorf("standalone esc: output=%q cmd=%v, want quit with no output", m.output, cmd)
	}
}
