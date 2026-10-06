package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

// Tests of the New session section (newrows.go) inside the browser model:
// keys in, rows / cursor / output out. The text editing itself is bubbles'
// textinput and is not re-tested here.

func key(k tea.KeyType) tea.KeyMsg { return tea.KeyMsg{Type: k} }

func runes(s string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func paste(s string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s), Paste: true}
}

// testModel is a browser of 100x30 with the given sessions and a launcher
// with cfg, agent claude, a fixed recent list, and a provider that finds
// nothing.
func testModel(t *testing.T, cfg sessions.Config, entries []sessions.Entry, frecent []string) model {
	t.Helper()
	m := newModel()
	m.width, m.height = 100, 30
	m.launch = newLauncher(cfg, t.TempDir(), t.TempDir(), "claude")
	m.launch.suggest = func(string) []sessions.DirSuggestion { return nil }
	m = update(m, sessionsLoadedMsg{entries: entries})
	return update(m, frecentMsg{paths: frecent})
}

func update(m model, msg tea.Msg) model {
	mm, _ := m.Update(msg)
	return mm.(model)
}

func press(m model, keys ...tea.KeyMsg) model {
	for _, k := range keys {
		m = update(m, k)
	}
	return m
}

func typeText(m model, s string) model {
	for _, r := range s {
		m = update(m, runes(string(r)))
	}
	return m
}

func existingDir(t *testing.T) string {
	t.Helper()
	d := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

// activeEntry is a running session; its display starts with the tmux name,
// as LoadBrowserEntries builds it.
func activeEntry(name, dir, display string) sessions.Entry {
	return sessions.Entry{
		TmuxSession: sessions.TmuxSession{Name: name},
		Meta:        sessions.Session{Name: name, Directory: dir},
		Kind:        sessions.EntryActive,
		Display:     name + " " + display + " (1m ago)",
		DisplayBase: name + " " + display,
		TimeAgo:     "1m ago",
	}
}

func inactiveEntry(sid, dir, display string) sessions.Entry {
	return sessions.Entry{
		Kind:             sessions.EntryInactive,
		Meta:             sessions.Session{Directory: dir, AgentType: "claude"},
		RestoreSessionID: sid,
		Display:          display + " (2h ago)",
		DisplayBase:      display,
		TimeAgo:          "2h ago",
	}
}

// newRows is the New session section, in order.
func newRows(m model) []newRow {
	var out []newRow
	for _, it := range m.items {
		if it.isNew() {
			out = append(out, it.row)
		}
	}
	return out
}

func selected(t *testing.T, m model) listItem {
	t.Helper()
	it, ok := m.selectedItem()
	if !ok {
		t.Fatalf("nothing selected (items=%d cursor=%d)", len(m.items), m.cursor)
	}
	return it
}

func splitOutput(t *testing.T, out string) (dir, agent, flags string) {
	t.Helper()
	parts := strings.Split(out, "\x1f")
	if len(parts) != 4 || parts[0] != "__NEW_SESSION__" {
		t.Fatalf("output = %q, want __NEW_SESSION__ + 3 fields", out)
	}
	return parts[1], parts[2], parts[3]
}

func TestNewAgentChoice(t *testing.T) {
	t.Setenv("AM_DEFAULT_AGENT", "")
	if l := newLauncher(sessions.Config{DefaultAgent: "pi"}, "", "", ""); l.agent != "pi" {
		t.Errorf("agent = %q, want the configured default", l.agent)
	}
	if l := newLauncher(sessions.Config{}, "", "", "cursor-agent"); l.agent != "cursor" {
		t.Errorf("agent = %q, want the alias normalized", l.agent)
	}
	l := newLauncher(sessions.Config{}, "", "", "nosuch")
	if l.agent != l.agents[0] {
		t.Errorf("agent = %q, want the first type for an unknown prefill", l.agent)
	}
	if agents := strings.Join(l.agents, ","); !strings.Contains(agents, "cursor") || strings.Contains(agents, "cursor-agent") {
		t.Errorf("agents %q: want cursor, not its alias", agents)
	}

	// Tab cycles forward, Shift-Tab back, wrapping; the divider names the
	// agent and Enter on a directory row launches with it.
	dir := existingDir(t)
	m := testModel(t, sessions.Config{}, nil, []string{dir})
	first := m.launch.agent
	m = press(m, key(tea.KeyTab))
	if m.launch.agent == first {
		t.Fatal("tab did not change the agent")
	}
	second := m.launch.agent
	m = press(m, key(tea.KeyShiftTab), key(tea.KeyShiftTab))
	if m.launch.agent != m.launch.agents[len(m.launch.agents)-1] {
		t.Errorf("shift-tab from the first: %q, want a wrap to the last", m.launch.agent)
	}
	m = press(m, key(tea.KeyTab), key(tea.KeyTab))
	if m.launch.agent != second {
		t.Errorf("agent = %q, want %q", m.launch.agent, second)
	}
	if !strings.Contains(m.View(), "New "+second+" session") {
		t.Errorf("divider does not name %s:\n%s", second, m.View())
	}
	m = press(m, key(tea.KeyEnter))
	if gotDir, agent, flags := splitOutput(t, m.output); gotDir != dir || agent != second || flags != "" {
		t.Errorf("output = %q %q %q", gotDir, agent, flags)
	}
}

func TestNewSectionOrderAndIdleRows(t *testing.T) {
	var recent []string
	for i := 0; i < 5; i++ {
		recent = append(recent, existingDir(t))
	}
	cfg := sessions.Config{Presets: map[string]sessions.Preset{
		"review": {Agent: "claude", Directory: "@"},
		"bisect": {Directory: recent[4]},
	}}
	entries := []sessions.Entry{
		inactiveEntry("sid-1", "/tmp/old", "old/main [claude] done"),
		activeEntry("am-a", "/tmp/a", "a/main [claude] live"),
	}
	m := testModel(t, cfg, entries, recent)

	// Running, then New (3 recent directories, then the presets by name),
	// then inactive.
	var got []string
	for _, it := range m.items {
		switch {
		case !it.isNew():
			got = append(got, m.entries[it.entry].Meta.Directory)
		case it.row.kind == newPreset:
			got = append(got, "preset:"+it.row.preset)
		default:
			got = append(got, it.row.value)
		}
	}
	want := []string{"/tmp/a", recent[0], recent[1], recent[2], "preset:bisect", "preset:review", "/tmp/old"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("items = %v\nwant    %v", got, want)
	}
	// The browser opens on the first session, as before.
	if it := selected(t, m); it.isNew() || m.entries[it.entry].Name != "am-a" {
		t.Errorf("cursor = %d, want the running session", m.cursor)
	}
	rows, _ := m.listRows()
	var dividers []string
	for _, r := range rows {
		if r.divider {
			dividers = append(dividers, r.label)
		}
	}
	if strings.Join(dividers, "|") != "New claude session|Inactive sessions" {
		t.Errorf("dividers = %v", dividers)
	}
}

func TestNewOnlyStartsOnNewSection(t *testing.T) {
	dir := existingDir(t)
	m := newModel()
	m.width, m.height = 100, 30
	m.startNew = true
	m.launch = newLauncher(sessions.Config{}, t.TempDir(), t.TempDir(), "claude")
	// The recent list arrives before the sessions; the cursor stays on the
	// New section when they land.
	m = update(m, frecentMsg{paths: []string{dir}})
	m = update(m, sessionsLoadedMsg{entries: []sessions.Entry{activeEntry("am-a", "/tmp/a", "a/main [claude] x")}})
	if it := selected(t, m); !it.isNew() || it.row.value != dir {
		t.Fatalf("cursor on %+v, want the first recent directory", it)
	}
	if !strings.Contains(m.View(), "launch") {
		t.Error("enter pill does not say launch")
	}
	m = press(m, key(tea.KeyEnter))
	if gotDir, _, _ := splitOutput(t, m.output); gotDir != dir {
		t.Errorf("dir = %q, want %q", gotDir, dir)
	}

	// Esc quits with no output.
	m = newModel()
	m.startNew = true
	mm, cmd := m.Update(key(tea.KeyEsc))
	if mm.(model).output != "" || cmd == nil {
		t.Errorf("esc: output=%q cmd=%v, want quit with no output", mm.(model).output, cmd)
	}
}

func TestCursorPrefersExistingSession(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	tools := filepath.Join(root, "tools")
	for _, d := range []string{proj, tools} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	entries := []sessions.Entry{
		activeEntry("am-p", proj, "proj/main [claude] fix"),
		inactiveEntry("sid-t", tools, "tools/main [claude] old work"),
	}
	m := testModel(t, sessions.Config{}, entries, []string{proj, tools})

	// "proj" starts the session's display after its tmux name and the
	// directory's basename (tier 4 both): the running session, listed
	// first, wins the tie.
	m = typeText(m, "proj")
	if it := selected(t, m); it.isNew() {
		t.Errorf("proj: cursor on %+v, want the running session", it.row)
	}
	if len(newRows(m)) != 1 || newRows(m)[0].value != proj {
		t.Errorf("proj: new rows = %v", newRows(m))
	}
	// Against a closed session the directory wins the same tie: Enter starts
	// a session rather than restoring an old conversation.
	m = press(m, key(tea.KeyCtrlU))
	m = typeText(m, "tools")
	if it := selected(t, m); !it.isNew() || it.row.value != tools {
		t.Errorf("tools: cursor on %+v, want the tools directory", it)
	}
	// A query only the closed session matches selects it.
	m = press(m, key(tea.KeyCtrlU))
	m = typeText(m, "old work")
	if it := selected(t, m); it.isNew() || m.entries[it.entry].RestoreSessionID != "sid-t" {
		t.Errorf("old work: cursor on %+v, want the closed session", it)
	}

	// After a manual move the cursor stays on its row when the list reloads.
	m = press(m, key(tea.KeyCtrlU), key(tea.KeyDown), key(tea.KeyDown))
	before := m.selectedPreviewKey()
	m = update(m, sessionsLoadedMsg{entries: append([]sessions.Entry{activeEntry("am-new", "/tmp/n", "n/main [claude] y")}, entries...)})
	if got := m.selectedPreviewKey(); got != before {
		t.Errorf("reload moved the cursor from %q to %q", before, got)
	}
}

func TestPlaceQueryShowsWhoIsThere(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	if err := os.MkdirAll(filepath.Join(proj, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	moved := activeEntry("am-m", "/elsewhere", "elsewhere/main [claude] moved")
	moved.Meta.Workdir = proj
	entries := []sessions.Entry{
		activeEntry("am-p", proj, "proj/main [claude] fix"),
		moved,
		activeEntry("am-o", "/other", "other/main [claude] unrelated"),
	}
	m := testModel(t, sessions.Config{}, entries, nil)
	m = typeText(m, proj)

	// The sessions working in the path are listed above the New section; the
	// cursor goes to the directory row, which counts them.
	var names []string
	for _, it := range m.items {
		if !it.isNew() {
			names = append(names, m.entries[it.entry].Name)
		}
	}
	if strings.Join(names, ",") != "am-p,am-m" {
		t.Errorf("sessions for the path = %v, want am-p,am-m", names)
	}
	it := selected(t, m)
	if !it.isNew() || it.row.value != proj {
		t.Fatalf("cursor on %+v, want the typed directory", it)
	}
	if !strings.Contains(it.row.label, "2 running") {
		t.Errorf("label = %q, want 2 running", it.row.label)
	}
	m = press(m, key(tea.KeyEnter))
	if gotDir, _, _ := splitOutput(t, m.output); gotDir != proj {
		t.Errorf("dir = %q", gotDir)
	}
}

func TestCtrlNSeedsTheSessionDirectory(t *testing.T) {
	work := existingDir(t)
	other := existingDir(t)
	e := activeEntry("am-w", "/launched/here", "here/main [claude] x")
	e.Meta.Workdir = work
	m := testModel(t, sessions.Config{}, []sessions.Entry{e}, []string{other, work})

	m = press(m, key(tea.KeyCtrlN))
	it := selected(t, m)
	if !it.isNew() || it.row.value != work {
		t.Fatalf("ctrl-n: cursor on %+v, want the session's workdir", it)
	}
	if rows := newRows(m); len(rows) != 2 || rows[1].value != other {
		t.Errorf("seed not deduplicated against the recent list: %v", rows)
	}
	if mm := press(m, key(tea.KeyEnter)); !strings.Contains(mm.output, "\x1f"+work+"\x1f") {
		t.Errorf("enter output = %q, want %s", mm.output, work)
	}
	// Ctrl-N on a New row only moves the cursor; typing drops the seed.
	m = press(m, key(tea.KeyDown), key(tea.KeyCtrlN))
	if it := selected(t, m); it.row.value != work {
		t.Errorf("ctrl-n on a new row: cursor on %q", it.row.value)
	}
	m = typeText(m, "zzz")
	if len(newRows(m)) != 0 {
		t.Errorf("seed kept after typing: %v", newRows(m))
	}
}

func TestNewValidation(t *testing.T) {
	t.Setenv("AM_DIR_PROVIDER", "")
	// A missing path matches no row; Enter says so and the list stays open.
	m := testModel(t, sessions.Config{}, nil, nil)
	m = typeText(m, "/definitely/missing/dir")
	m = press(m, key(tea.KeyEnter))
	if m.output != "" || !strings.Contains(m.errMsg, "Directory does not exist: /definitely/missing/dir") {
		t.Fatalf("missing dir: output=%q err=%q", m.output, m.errMsg)
	}
	if !strings.Contains(m.View(), "Directory does not exist") {
		t.Error("error line not shown")
	}
	m = typeText(m, "x")
	if m.errMsg != "" {
		t.Errorf("errMsg kept after typing: %q", m.errMsg)
	}

	// A @spec is refused without a provider, naming the config key.
	m = testModel(t, sessions.Config{}, nil, nil)
	m = typeText(m, "@48351")
	m = press(m, key(tea.KeyEnter))
	if m.output != "" || !strings.Contains(m.errMsg, "dir_provider") || !strings.Contains(m.errMsg, "@48351") {
		t.Errorf("@spec without provider: output=%q err=%q", m.output, m.errMsg)
	}
	// With a provider the @spec reaches the output untouched, with no flags.
	m = testModel(t, sessions.Config{DirProvider: "true"}, nil, nil)
	m = typeText(m, "@48351")
	m = press(m, key(tea.KeyEnter))
	if dir, _, flags := splitOutput(t, m.output); dir != "@48351" || flags != "" {
		t.Errorf("@spec output dir=%q flags=%q", dir, flags)
	}

	// ~ expands in the output.
	m = testModel(t, sessions.Config{}, nil, nil)
	if err := os.MkdirAll(filepath.Join(m.launch.home, "proj"), 0o755); err != nil {
		t.Fatal(err)
	}
	m = typeText(m, "~/proj")
	m = press(m, key(tea.KeyEnter))
	if dir, _, _ := splitOutput(t, m.output); dir != filepath.Join(m.launch.home, "proj") {
		t.Errorf("~ dir = %q", dir)
	}

	// A preset without a directory says how to give one.
	cfg := sessions.Config{Presets: map[string]sessions.Preset{"bare": {Agent: "pi"}}}
	m = testModel(t, cfg, nil, nil)
	m = typeText(m, "bare")
	m = press(m, key(tea.KeyEnter))
	if m.output != "" || !strings.Contains(m.errMsg, "am new -p bare <dir>") {
		t.Errorf("dir-less preset: output=%q err=%q", m.output, m.errMsg)
	}
}

func TestNewPathQuery(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"alpha", "alpha/one", "alpha/two", "beta"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	m := testModel(t, sessions.Config{}, nil, []string{filepath.Join(root, "beta")})
	m = typeText(m, filepath.Join(root, "alpha"))
	// The typed directory comes first (Enter must not pick a child), then its
	// children.
	rows := newRows(m)
	if len(rows) < 3 || rows[0].value != filepath.Join(root, "alpha") {
		t.Fatalf("rows = %v", rows)
	}
	if rows[1].value != filepath.Join(root, "alpha", "one") || rows[2].value != filepath.Join(root, "alpha", "two") {
		t.Errorf("children = %v", rows[1:])
	}
	m = press(m, key(tea.KeyEnter))
	if dir, _, _ := splitOutput(t, m.output); dir != filepath.Join(root, "alpha") {
		t.Errorf("dir = %q", dir)
	}
	// A prefix completes against the parent.
	m = testModel(t, sessions.Config{}, nil, nil)
	m = typeText(m, filepath.Join(root, "al"))
	if rows := newRows(m); len(rows) != 1 || rows[0].value != filepath.Join(root, "alpha") {
		t.Errorf("prefix: %v", rows)
	}
}

func TestNewProvider(t *testing.T) {
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
	// typeDrive types and runs each pending provider fetch synchronously, as
	// the program would.
	typeDrive := func(m model, s string) model {
		for _, r := range s {
			mm, cmd := m.Update(runes(string(r)))
			m = mm.(model)
			if pm := providerCmdMsg(cmd); pm != nil {
				m = update(m, *pm)
			}
		}
		return m
	}
	cfg := sessions.Config{DirProvider: "fake"}
	entries := []sessions.Entry{activeEntry("am-48", "/tmp/w", "w/48351 [claude] fix bbr")}
	m := testModel(t, cfg, entries, []string{"/tmp/x"})
	m.launch.suggest = suggest

	// Bare @: the provider's defaults, empty spec first, rendered as "@"; no
	// session matches an empty spec.
	m = typeDrive(m, "@")
	rows := newRows(m)
	if len(rows) != 2 || rows[0].value != "@" || rows[0].label != "new copy on trunk" || rows[1].value != "@trunk" {
		t.Fatalf("bare @: %v", rows)
	}
	if len(m.items) != 2 {
		t.Errorf("bare @ lists sessions: %d items", len(m.items))
	}
	if dir, _, _ := splitOutput(t, press(m, key(tea.KeyEnter)).output); dir != "@" {
		t.Errorf("bare @ output dir = %q", dir)
	}

	// @48: the session already on 48351 is listed above the suggestions, the
	// cursor still lands on the first suggestion; one provider run per
	// distinct partial.
	m = typeDrive(m, "48")
	if len(m.items) != 3 || m.items[0].isNew() {
		t.Fatalf("@48: items = %+v, want the session then two suggestions", m.items)
	}
	if it := selected(t, m); !it.isNew() || it.row.value != "@48351" {
		t.Errorf("@48: cursor on %+v", it)
	}
	m = press(m, key(tea.KeyDown))
	if it := selected(t, m); it.row.label != "PR #48372 gw retry" {
		t.Errorf("down: %+v", it.row)
	}
	m = typeDrive(m, "3")
	m = press(m, key(tea.KeyBackspace))
	if m.filter.Value() != "@48" || calls["48"] != 1 {
		t.Errorf("after backspace to @48: value=%q calls=%v, want cached", m.filter.Value(), calls)
	}

	// No match: the typed spec is the one row, and Enter submits it.
	m = testModel(t, cfg, nil, nil)
	m.launch.suggest = suggest
	m = typeDrive(m, "@zzz")
	if rows := newRows(m); len(rows) != 1 || rows[0].value != "@zzz" {
		t.Fatalf("no match: %v", rows)
	}
	if dir, _, _ := splitOutput(t, press(m, key(tea.KeyEnter)).output); dir != "@zzz" {
		t.Errorf("fallback dir = %q", dir)
	}

	// While the fetch is pending the typed spec is offered, and the late
	// answer for an abandoned query does not disturb the current list.
	m = testModel(t, cfg, nil, nil)
	m.launch.suggest = suggest
	mm, cmd := m.Update(runes("@"))
	m = mm.(model)
	if rows := newRows(m); len(rows) != 1 || rows[0].value != "@" {
		t.Errorf("pending: %v", rows)
	}
	m = typeText(m, "zzz")
	if pm := providerCmdMsg(cmd); pm != nil {
		m = update(m, *pm)
	}
	if rows := newRows(m); len(rows) != 1 || rows[0].value != "@zzz" {
		t.Errorf("late answer changed the list: %v", rows)
	}

	// Without a provider only the typed spec is offered and nothing runs.
	t.Setenv("AM_DIR_PROVIDER", "")
	m = testModel(t, sessions.Config{}, nil, nil)
	ran := false
	m.launch.suggest = func(string) []sessions.DirSuggestion { ran = true; return nil }
	m = typeDrive(m, "@48")
	if rows := newRows(m); ran || len(rows) != 1 || rows[0].value != "@48" {
		t.Errorf("no provider: ran=%v rows=%v", ran, rows)
	}
}

// providerCmdMsg runs a key's Cmd (a Batch of the textinput's, the fetch,
// and the preview) and returns the provider answer among them, if any.
func providerCmdMsg(cmd tea.Cmd) *providerMsg {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if pm, ok := msg.(providerMsg); ok {
		return &pm
	}
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, c := range batch {
			if pm := providerCmdMsg(c); pm != nil {
				return pm
			}
		}
	}
	return nil
}

func TestNewPresetRows(t *testing.T) {
	tools := existingDir(t)
	cfg := sessions.Config{Presets: map[string]sessions.Preset{
		"review":  {Agent: "claude", Directory: "@", Args: []string{"--model", "opus"}},
		"scratch": {Agent: "pi", Directory: tools, Shell: true},
	}}
	m := testModel(t, cfg, nil, nil)
	m = typeText(m, "scr")
	rows := newRows(m)
	if len(rows) != 1 || rows[0].kind != newPreset || rows[0].preset != "scratch" {
		t.Fatalf("scr: rows = %v", rows)
	}
	if !strings.Contains(rows[0].label, "pi") {
		t.Errorf("label %q does not name the preset's agent", rows[0].label)
	}
	// The preset's own agent wins over the list's choice.
	m = press(m, key(tea.KeyTab), key(tea.KeyEnter))
	dir, agent, flags := splitOutput(t, m.output)
	if dir != tools || agent != "pi" || flags != "--preset=scratch" {
		t.Errorf("output = %q %q %q", dir, agent, flags)
	}
}

func TestNewRowKeys(t *testing.T) {
	dir := existingDir(t)
	m := testModel(t, sessions.Config{}, nil, nil)

	// A paste drops its trailing line breaks.
	m = update(m, paste(dir+"\n"))
	if m.filter.Value() != dir {
		t.Errorf("pasted value = %q, want %q", m.filter.Value(), dir)
	}
	m = update(m, paste("\r\n"))
	if m.filter.Value() != dir {
		t.Errorf("pasting a bare newline changed the value to %q", m.filter.Value())
	}

	// Ctrl-X on a New row does nothing; the one-key agent launches are gone
	// (Ctrl-L edits nothing and launches nothing).
	mm, cmd := m.Update(key(tea.KeyCtrlX))
	if cmd != nil || mm.(model).output != "" {
		t.Errorf("ctrl-x on a new row: cmd=%v output=%q", cmd, mm.(model).output)
	}
	if mm, _ = m.Update(key(tea.KeyCtrlL)); mm.(model).output != "" {
		t.Errorf("ctrl-l launched: %q", mm.(model).output)
	}

	// Rows show the directory under ~ and the session pill says switch on a
	// session.
	m = testModel(t, sessions.Config{}, []sessions.Entry{activeEntry("am-a", "/tmp/a", "a/main [claude] x")}, nil)
	sub := filepath.Join(m.launch.home, "code", "proj")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	m = update(m, frecentMsg{paths: []string{sub}})
	v := m.View()
	for _, want := range []string{"switch", "+ ~/code/proj", "New claude session"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q:\n%s", want, v)
		}
	}
}
