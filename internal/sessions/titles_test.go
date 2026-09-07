package sessions

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestTitleValid(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"", false},
		{"hello", true},
		{strings.Repeat("a", 60), true},
		{strings.Repeat("a", 61), false},
		{"with\nnewline", false},
		{"normal task description", true},
		{"Claude Code", false}, // pre-summary placeholder, not a title
		{"Claude Code hooks question", true},
	}
	for _, c := range cases {
		if got := titleValid(c.in); got != c.want {
			t.Errorf("titleValid(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestNormalizeTitle(t *testing.T) {
	cases := []struct{ in, dir, want string }{
		{"Fix flaky test - 🔄 Reconnecting…", "/home/u/proj", "Fix flaky test"},
		{"Fix flaky test - proj", "/home/u/proj", "Fix flaky test"},
		{"Fix flaky test - proj - 🔄 Reconnecting", "/home/u/proj", "Fix flaky test"},
		{"Fix flaky test", "/home/u/proj", "Fix flaky test"},
		{"Fix flaky test - other", "/home/u/proj", "Fix flaky test - other"},
		{"Fix flaky test - proj", "", "Fix flaky test - proj"},
		{"Claude Code", "/home/u/proj", "Claude Code"},
	}
	for _, c := range cases {
		if got := normalizeTitle(c.in, c.dir); got != c.want {
			t.Errorf("normalizeTitle(%q, %q) = %q, want %q", c.in, c.dir, got, c.want)
		}
	}
}

func TestLeadingNonAlnumStrip(t *testing.T) {
	cases := map[string]string{
		"✳ Fix the bug":       "Fix the bug",
		"⠐ Working on it":     "Working on it",
		">>> Clean up":        "Clean up",
		"already clean":       "already clean",
		"   spaces and stuff": "spaces and stuff",
		"":                    "",
	}
	for in, want := range cases {
		got := leadingNonAlnum.ReplaceAllString(in, "")
		if got != want {
			t.Errorf("strip(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRefreshTitlesPreservesRegistryMetadata(t *testing.T) {
	amDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	want := registryMetadataDocument("am-title", "Old task")
	writeJSONDocument(t, regPath, want)

	binDir := t.TempDir()
	tmuxPath := filepath.Join(binDir, "tmux")
	if err := os.WriteFile(tmuxPath, []byte("#!/bin/sh\nprintf '%s\\n' 'Updated task'\n"), 0o755); err != nil {
		t.Fatalf("write fake tmux: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("AM_STATE_DIR", t.TempDir())

	wantSession := want["sessions"].(map[string]any)["am-title"].(map[string]any)
	wantSession["task"] = "Updated task"

	RefreshTitles(amDir, "test-socket", []TmuxSession{{Name: "am-title"}})

	got := readJSONDocument(t, regPath)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("RefreshTitles changed non-task registry metadata:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestClaudeFirstUserMessage(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/to/project"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// String content form
	content := `{"type":"user","message":{"content":"Fix the broken login flow in auth"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "session.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	got := claudeFirstUserMessage(directory, "session")
	if got != "Fix the broken login flow in auth" {
		t.Errorf("got %q, want %q", got, "Fix the broken login flow in auth")
	}
}

func TestClaudeFirstUserMessageArrayContent(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/project2"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Array content form (Claude Code newer JSONL schema)
	content := `{"type":"user","message":{"content":[{"type":"text","text":"Add JSONL fallback for tasks"}]}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "session.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	got := claudeFirstUserMessage(directory, "session")
	if got != "Add JSONL fallback for tasks" {
		t.Errorf("got %q, want %q", got, "Add JSONL fallback for tasks")
	}
}

func TestClaudeFirstUserMessageSkipsShort(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/project3"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// First entry is short; second is real
	content := `{"type":"user","message":{"content":"ok"}}` + "\n" +
		`{"type":"user","message":{"content":"This is the real user task description"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "session.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	got := claudeFirstUserMessage(directory, "session")
	if got != "This is the real user task description" {
		t.Errorf("got %q, want non-short message", got)
	}
}

// The length gate counts characters like bash's ${#cleaned}, not bytes: a
// 6-letter Hebrew message (12 bytes) must be rejected on both paths, an
// 11-letter one accepted.
func TestFirstUserMessageLengthGateCountsRunes(t *testing.T) {
	cases := []struct {
		name string
		text string
		want bool
	}{
		{"six hebrew letters (12 bytes)", "שלוםעו", false},
		{"ten hebrew letters (20 bytes)", "שלוםעולםאב", false},
		{"eleven hebrew letters", "שלוםעולםאבג", true},
		{"ten ascii letters", "abcdefghij", false},
		{"eleven ascii letters", "abcdefghijk", true},
	}
	for _, tc := range cases {
		if got := titleWorthy(tc.text); got != tc.want {
			t.Errorf("titleWorthy(%s) = %v, want %v", tc.name, got, tc.want)
		}
	}

	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	directory := "/some/path/hebrew"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Six Hebrew letters is 12 bytes: a byte count would take it as the
	// title; bash's character count skips it for the 11-letter message.
	content := `{"type":"user","message":{"content":"שלוםעו"}}` + "\n" +
		`{"type":"user","message":{"content":"שלוםעולםאבג"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "session.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := claudeFirstUserMessage(directory, "session"); got != "שלוםעולםאבג" {
		t.Errorf("claudeFirstUserMessage = %q, want the 11-letter message", got)
	}
}

func TestClaudeFirstUserMessageMissingDir(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	if got := claudeFirstUserMessage("/nonexistent/dir/xyz", "session"); got != "" {
		t.Errorf("got %q, want empty for missing dir", got)
	}
}

func TestClaudeFirstUserMessageDisambiguatesBySessionID(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/shared-dir"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Two conversations in one directory's store. Each session reads only
	// the transcript bound to it; the newer file is never "this session".
	older := `{"type":"user","message":{"content":"Older session original task"}}` + "\n"
	newer := `{"type":"user","message":{"content":"Newer session different task"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "aaaa-old.jsonl"), []byte(older), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(claudeDir, "bbbb-new.jsonl"), []byte(newer), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(claudeDir, "aaaa-old.jsonl"), old, old); err != nil {
		t.Fatal(err)
	}

	if got := claudeFirstUserMessage(directory, "aaaa-old"); got != "Older session original task" {
		t.Errorf("explicit id: got %q, want older session's message", got)
	}
	if got := claudeFirstUserMessage(directory, "bbbb-new"); got != "Newer session different task" {
		t.Errorf("explicit newer id: got %q, want newer session's message", got)
	}
	// No id → nothing, however many transcripts the store holds.
	if got := claudeFirstUserMessage(directory, ""); got != "" {
		t.Errorf("empty id: got %q, want empty", got)
	}
	// An id whose transcript is not there → nothing, no substitute.
	if got := claudeFirstUserMessage(directory, "does-not-exist"); got != "" {
		t.Errorf("missing id file: got %q, want empty", got)
	}
}

// A lone transcript in the store is still not evidence that it belongs to
// this session: an agent started outside am may have written it. The reader
// needs the bound id even then.
func TestClaudeFirstUserMessageRequiresBoundID(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/lone-dir"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"user","message":{"content":"Stranger's conversation in this directory"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "only.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := claudeFirstUserMessage(directory, ""); got != "" {
		t.Errorf("lone transcript without id: got %q, want empty", got)
	}
	if got := claudeFirstUserMessage(directory, "only"); got != "Stranger's conversation in this directory" {
		t.Errorf("lone transcript with its id: got %q", got)
	}
}

func TestPiTitleExtract(t *testing.T) {
	cases := []struct{ in, want string }{
		{"pi - Refactor auth - proj", "Refactor auth"},
		{"pi - a - b - proj", "a - b"},
		{"pi - proj", ""},
		{"pi", ""},
		{"plain title", "plain title"},
	}
	for _, c := range cases {
		if got := piTitleExtract(c.in); got != c.want {
			t.Errorf("piTitleExtract(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCursorTitleExtract(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Cursor Agent", ""},
		{"Shell Command", ""},
		{"Cursor Agent - ✅ Ready", ""},
		{"Shell Command - ⏳ Working .··", ""},
		{"Cursor Pong - ✅ Ready", "Cursor Pong"},
		{"Fix restore", "Fix restore"},
	}
	for _, c := range cases {
		if got := cursorTitleExtract(c.in); got != c.want {
			t.Errorf("cursorTitleExtract(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCursorFirstUserMessage(t *testing.T) {
	tmp := t.TempDir()
	transcript := filepath.Join(tmp, "conversation.jsonl")
	content := `{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>now</timestamp>\n<user_query>\nImplement exact Cursor restore\n</user_query>"}]}}` + "\n"
	if err := os.WriteFile(transcript, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := cursorFirstUserMessage("/unused", "cursor-id", transcript); got != "Implement exact Cursor restore" {
		t.Fatalf("cursorFirstUserMessage = %q", got)
	}
	if got := cursorFirstUserMessage("/unused", "", ""); got != "" {
		t.Fatalf("cursorFirstUserMessage without id or transcript = %q, want empty", got)
	}
}

func TestPiFirstUserMessage(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	dir := filepath.Join(tmp, "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		resolved = dir
	}
	piDir := filepath.Join(tmp, ".pi", "agent", "sessions", encodedPiSessionDir(resolved))
	if err := os.MkdirAll(piDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"session","version":3,"id":"x","cwd":"` + resolved + `"}
{"type":"message","id":"a1","message":{"role":"user","content":"Fix the flaky registry test"}}
`
	sid := "0199dddd-0000-0000-0000-000000000001"
	if err := os.WriteFile(filepath.Join(piDir, "2026-07-19T08-00-00-000Z_"+sid+".jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := piFirstUserMessage(resolved, sid); got != "Fix the flaky registry test" {
		t.Fatalf("piFirstUserMessage sid-pinned = %q", got)
	}
	// No id → nothing, even with a single transcript in the store.
	if got := piFirstUserMessage(resolved, ""); got != "" {
		t.Fatalf("piFirstUserMessage without id = %q, want empty", got)
	}
}

// Resolvers read only the sidecar the pane's own hook wrote; a transcript
// store full of other conversations yields no id.
func TestResolveSessionIDSidecarOnly(t *testing.T) {
	tmp := t.TempDir()
	home := filepath.Join(tmp, "home")
	stateDir := filepath.Join(tmp, "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	dir := "/some/path/shared"
	claudeDir := filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir))
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, sid := range []string{"stranger-1", "stranger-2", "mine"} {
		if err := os.WriteFile(filepath.Join(claudeDir, sid+".jsonl"), []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := resolveClaudeSessionID(home, stateDir, "am-x", dir); got != "" {
		t.Errorf("no sidecar: got %q, want empty", got)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "am-x.sid"), []byte("mine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolveClaudeSessionID(home, stateDir, "am-x", dir); got != "mine" {
		t.Errorf("sidecar: got %q, want mine", got)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "am-x.sid"), []byte("gone\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolveClaudeSessionID(home, stateDir, "am-x", dir); got != "" {
		t.Errorf("sidecar without transcript: got %q, want empty (no substitute)", got)
	}

	piDir := filepath.Join(piSessionsRoot(home), encodedPiSessionDir(dir))
	if err := os.MkdirAll(piDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(piDir, "2026-07-19T08-00-00-000Z_pi-stranger.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resolvePiSessionID(home, stateDir, "am-pi", dir); got != "" {
		t.Errorf("pi no sidecar: got %q, want empty", got)
	}
}

// RefreshTitles also refreshes workdir + branch: a checkout in place changes
// the branch, a .cwd sidecar naming another checkout sets workdir and reads the
// branch there, and coming home clears workdir. directory is never rewritten.
func TestRefreshTitlesWorkdirAndBranch(t *testing.T) {
	amDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	stateDir := t.TempDir()
	launch := filepath.Join(t.TempDir(), "launch")
	other := filepath.Join(t.TempDir(), "other")
	writeFile(t, filepath.Join(launch, ".git", "HEAD"), "ref: refs/heads/main\n")
	writeFile(t, filepath.Join(other, ".git", "HEAD"), "ref: refs/heads/feature\n")

	// Fake tmux prints an empty title; with an empty HOME the JSONL fallback
	// finds nothing, so only the workdir/branch half acts.
	binDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(binDir, "tmux"), []byte("#!/bin/sh\nprintf '\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("AM_STATE_DIR", stateDir)

	writeRegistryAtomic(regPath, Registry{Sessions: map[string]Session{
		"am-wd": {Name: "am-wd", Directory: launch, Branch: "main", AgentType: "claude"},
	}})
	refresh := func() Session {
		os.Remove(filepath.Join(amDir, ".title_scan_last"))
		RefreshTitles(amDir, "test-socket", []TmuxSession{{Name: "am-wd"}})
		return ReadRegistry(regPath).Sessions["am-wd"]
	}

	writeFile(t, filepath.Join(launch, ".git", "HEAD"), "ref: refs/heads/topic\n")
	got := refresh()
	if got.Branch != "topic" || got.Workdir != "" {
		t.Fatalf("checkout in place: branch=%q workdir=%q, want topic/\"\"", got.Branch, got.Workdir)
	}

	writeFile(t, filepath.Join(stateDir, "am-wd.cwd"), other)
	got = refresh()
	if got.Workdir != other || got.Branch != "feature" {
		t.Fatalf("sidecar elsewhere: workdir=%q branch=%q, want %q/feature", got.Workdir, got.Branch, other)
	}
	if got.Directory != launch {
		t.Fatalf("directory rewritten to %q", got.Directory)
	}

	writeFile(t, filepath.Join(stateDir, "am-wd.cwd"), launch)
	got = refresh()
	if got.Workdir != "" || got.Branch != "topic" {
		t.Fatalf("back home: workdir=%q branch=%q, want \"\"/topic", got.Workdir, got.Branch)
	}

	writeFile(t, filepath.Join(stateDir, "am-wd.cwd"), filepath.Join(other, "gone"))
	got = refresh()
	if got.Workdir != "" || got.Branch != "topic" {
		t.Fatalf("missing sidecar dir: workdir=%q branch=%q, want unchanged", got.Workdir, got.Branch)
	}

	// Sessions with no refresh to apply leave the file untouched.
	before, _ := os.Stat(regPath)
	got = refresh()
	after, _ := os.Stat(regPath)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatalf("no-op refresh rewrote the registry")
	}
}
