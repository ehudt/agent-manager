package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeTmux installs a tmux stand-in on PATH that answers display-message
// (pane title) and capture-pane (pane text) per target from files under
// root/titles and root/panes, and fails list-sessions (no server). Returns
// setters for the two maps.
func fakeTmux(t *testing.T) (setTitle, setPane func(target, text string)) {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{"titles", "panes"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	script := `#!/bin/sh
cmd=""; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) target="$2"; shift ;;
    display-message|capture-pane|list-sessions) cmd="$1" ;;
  esac
  shift
done
case "$cmd" in
  display-message) cat "` + root + `/titles/$target" 2>/dev/null; exit 0 ;;
  capture-pane) cat "` + root + `/panes/$target" 2>/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
`
	binDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(binDir, "tmux"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	set := func(sub string) func(target, text string) {
		return func(target, text string) {
			if err := os.WriteFile(filepath.Join(root, sub, target), []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	return set("titles"), set("panes")
}

func slogAppend(t *testing.T, path string, fields map[string]any) {
	t.Helper()
	base := map[string]any{
		"session_id": "", "branch": "main", "task": "", "closed_at": nil,
		"snapshot_file": "", "transcript_path": "", "created_at": "2026-07-19T08:00:00Z",
	}
	for k, v := range fields {
		base[k] = v
	}
	b, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	f.Write(append(b, '\n'))
}

func slogField(t *testing.T, path, session, field string) string {
	t.Helper()
	for _, l := range readSlog(path) {
		if l.get("session_name") == session {
			return l.get(field)
		}
	}
	return ""
}

func slogNames(t *testing.T, path string) []string {
	t.Helper()
	var names []string
	for _, l := range readSlog(path) {
		names = append(names, l.get("session_name"))
	}
	return names
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

func writeClaudeTranscript(t *testing.T, home, dir, sid, text string) {
	t.Helper()
	writeFile(t, filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir), sid+".jsonl"),
		`{"sessionId":"`+sid+`","type":"user","message":{"content":"`+text+`"}}`+"\n")
}

// --- RestoreScan ---------------------------------------------------------

// Mirrors tests/test_registry.sh test_auto_title_scan 10-15 + the Cursor
// binding: the hook sidecar is the only source of a session's conversation
// id; it corrects a wrong logged id, and without one nothing is guessed from
// the directory's transcript store.
func TestRestoreScanBindsIDFromSidecarOnly(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	env := testEnv(t, amDir)
	_, setPane := fakeTmux(t)
	proj := filepath.Join(t.TempDir(), "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(env.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}

	reg := Registry{Sessions: map[string]Session{
		"am-stale":   {Name: "am-stale", Directory: proj, AgentType: "claude"},
		"am-sidecar": {Name: "am-sidecar", Directory: proj, AgentType: "claude"},
		"am-pending": {Name: "am-pending", Directory: proj, AgentType: "claude"},
		"am-wrong":   {Name: "am-wrong", Directory: proj, AgentType: "claude", Task: "task w", Branch: "feat"},
		"am-shared":  {Name: "am-shared", Directory: proj, AgentType: "claude"},
		"am-nolog":   {Name: "am-nolog", Directory: proj, AgentType: "claude"},
		"am-bash":    {Name: "am-bash", Directory: proj, AgentType: "bash"},
	}}
	writeRegistryAtomic(env.RegistryPath(), reg)
	for _, n := range []string{"am-stale", "am-sidecar", "am-pending", "am-wrong", "am-shared", "am-bash"} {
		slogAppend(t, env.SessionsLog, map[string]any{"session_name": n, "directory": proj, "agent_type": reg.Sessions[n].AgentType})
		setPane(n+":.{top-left}", "snapshot for "+n+"\n")
	}

	// Transcripts sitting in the shared per-directory store.
	writeClaudeTranscript(t, home, proj, "sid-old", "Old session")
	writeClaudeTranscript(t, home, proj, "sid-correct", "Correct session")
	writeClaudeTranscript(t, home, proj, "sid-other", "Other same-dir session")
	writeClaudeTranscript(t, home, proj, "sid-wrong", "Wrong conversation")
	writeClaudeTranscript(t, home, proj, "sid-right", "Right conversation")
	writeClaudeTranscript(t, home, proj, "sid-ambiguous", "Whose is this?")

	writeFile(t, filepath.Join(env.StateDir, "am-sidecar.sid"), "sid-correct")
	writeFile(t, filepath.Join(env.StateDir, "am-pending.sid"), "sid-pending") // no transcript yet
	writeFile(t, filepath.Join(env.StateDir, "am-wrong.sid"), "sid-right")
	// am-wrong was logged with a guessed id that the sidecar now contradicts.
	env.applySlogUpdates([]slogUpdate{{"am-wrong", "session_id", "sid-wrong"}})

	env.RestoreScan(true)

	if got := slogField(t, env.SessionsLog, "am-stale", "session_id"); got != "" {
		t.Errorf("stale: id guessed from directory store: %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-stale", "snapshot_file"); got != "snapshots/am-stale.txt" {
		t.Errorf("stale: snapshot keyed by session name until the id is known, got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-sidecar", "session_id"); got != "sid-correct" {
		t.Errorf("sidecar: got %q, want sid-correct", got)
	}
	if got := slogField(t, env.SessionsLog, "am-sidecar", "snapshot_file"); got != "snapshots/sid-correct.txt" {
		t.Errorf("sidecar: snapshot keyed by the sidecar id, got %q", got)
	}
	if b, _ := os.ReadFile(filepath.Join(amDir, "snapshots", "sid-correct.txt")); !strings.Contains(string(b), "snapshot for am-sidecar") {
		t.Errorf("sidecar: snapshot content = %q", b)
	}
	if got := slogField(t, env.SessionsLog, "am-pending", "session_id"); got != "" {
		t.Errorf("pending sidecar without transcript: got %q, want empty", got)
	}
	if got := slogField(t, env.SessionsLog, "am-pending", "snapshot_file"); got != "snapshots/am-pending.txt" {
		t.Errorf("pending: snapshot by session name, got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-wrong", "session_id"); got != "sid-right" {
		t.Errorf("sidecar corrects a wrong logged id: got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-wrong", "snapshot_file"); got != "snapshots/sid-right.txt" {
		t.Errorf("corrected id re-keys the snapshot: got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-wrong", "task"); got != "task w" {
		t.Errorf("task synced into the log: got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-wrong", "branch"); got != "feat" {
		t.Errorf("branch synced into the log: got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-shared", "session_id"); got != "" {
		t.Errorf("shared directory: no guess, got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-bash", "snapshot_file"); got != "" {
		t.Errorf("non-resumable agent is not scanned, got %q", got)
	}
	if fileExists(filepath.Join(amDir, "snapshots", "am-nolog.txt")) {
		t.Errorf("session without a log entry must not be snapshotted")
	}
	if !fileExists(filepath.Join(amDir, ".restore_scan_last")) {
		t.Errorf(".restore_scan_last not stamped")
	}

	// A snapshot still keyed by session name is renamed once the id lands.
	writeFile(t, filepath.Join(amDir, "snapshots", "am-pending.txt"), "old\n")
	writeClaudeTranscript(t, home, proj, "sid-pending", "Now it exists")
	env.RestoreScan(true)
	if got := slogField(t, env.SessionsLog, "am-pending", "session_id"); got != "sid-pending" {
		t.Errorf("pending → bound once the transcript exists: got %q", got)
	}
	if fileExists(filepath.Join(amDir, "snapshots", "am-pending.txt")) {
		t.Errorf("name-keyed snapshot left behind after re-key")
	}
	if got := slogField(t, env.SessionsLog, "am-pending", "snapshot_file"); got != "snapshots/sid-pending.txt" {
		t.Errorf("re-keyed snapshot_file = %q", got)
	}
}

func TestRestoreScanCursorTranscriptSidecar(t *testing.T) {
	amDir := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	env := testEnv(t, amDir)
	_, setPane := fakeTmux(t)
	if err := os.MkdirAll(env.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	transcript := filepath.Join(t.TempDir(), "cursor-sid.jsonl")
	writeFile(t, transcript, `{"role":"user","message":{"content":[{"type":"text","text":"<user_query>Implement Cursor title fallback</user_query>"}]}}`+"\n")
	proj := filepath.Join(amDir, "cursor-project")
	writeRegistryAtomic(env.RegistryPath(), Registry{Sessions: map[string]Session{
		"am-cur": {Name: "am-cur", Directory: proj, AgentType: "cursor"},
	}})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-cur", "directory": proj, "agent_type": "cursor"})
	writeFile(t, filepath.Join(env.StateDir, "am-cur.sid"), "cursor-sid")
	writeFile(t, filepath.Join(env.StateDir, "am-cur.transcript"), transcript)
	setPane("am-cur:.{top-left}", "cursor pane\n")

	env.TitleScan(true)

	if got := slogField(t, env.SessionsLog, "am-cur", "transcript_path"); got != transcript {
		t.Errorf("transcript_path bound from sidecar: got %q", got)
	}
	if got := slogField(t, env.SessionsLog, "am-cur", "session_id"); got != "cursor-sid" {
		t.Errorf("cursor id verified via the transcript path: got %q", got)
	}
	if got := ReadRegistry(env.RegistryPath()).Sessions["am-cur"].Task; got != "Implement Cursor title fallback" {
		t.Errorf("Cursor status-only title falls back to the exact transcript: got %q", got)
	}
}

// The restore scan runs on its own marker: a fresh .title_scan_last (stamped
// by another scanner) must not starve it, and vice versa.
func TestRestoreScanThrottleIndependentOfTitleMarker(t *testing.T) {
	amDir := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	env := testEnv(t, amDir)
	setTitle, setPane := fakeTmux(t)
	writeRegistryAtomic(env.RegistryPath(), Registry{Sessions: map[string]Session{
		"am-13": {Name: "am-13", Directory: "/tmp/project13", AgentType: "claude", Task: "task 13"},
	}})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-13", "directory": "/tmp/project13", "agent_type": "claude"})
	setTitle("am-13:.{top-left}", "Title that must not land\n")
	setPane("am-13:.{top-left}", "snapshot for am-13\n")

	now := strconv.FormatInt(time.Now().Unix(), 10)
	writeFile(t, filepath.Join(amDir, ".title_scan_last"), now)
	env.TitleScan(false)

	if got := slogField(t, env.SessionsLog, "am-13", "snapshot_file"); got != "snapshots/am-13.txt" {
		t.Errorf("restore half ran despite fresh title marker: snapshot_file=%q", got)
	}
	if got := ReadRegistry(env.RegistryPath()).Sessions["am-13"].Task; got != "task 13" {
		t.Errorf("title half stayed throttled: task=%q", got)
	}

	// Now the reverse: restore marker fresh, title marker gone.
	os.Remove(filepath.Join(amDir, ".title_scan_last"))
	os.Remove(filepath.Join(amDir, "snapshots", "am-13.txt"))
	writeFile(t, filepath.Join(amDir, ".restore_scan_last"), now)
	env.TitleScan(false)
	if got := ReadRegistry(env.RegistryPath()).Sessions["am-13"].Task; got != "Title that must not land" {
		t.Errorf("title half ran: task=%q", got)
	}
	if fileExists(filepath.Join(amDir, "snapshots", "am-13.txt")) {
		t.Errorf("restore half rewrote a snapshot while throttled")
	}
}

// Title scan: pane title wins, leading symbols stripped, hysteresis keeps an
// existing task through an invalid title, first-message fallback only with a
// bound id, no fallback for agents without a transcript store.
func TestRefreshTitlesTitleSources(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	env := testEnv(t, amDir)
	setTitle, _ := fakeTmux(t)
	if err := os.MkdirAll(env.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	proj8 := "/tmp/jsonl-fallback-test-8"
	writeClaudeTranscript(t, home, proj8, "test", "Investigate JSONL fallback path")
	writeClaudeTranscript(t, home, proj8, "stranger", "A stranger conversation in the same dir")
	proj9 := "/tmp/jsonl-fallback-test-9"
	writeClaudeTranscript(t, home, proj9, "test", "Should not appear")

	writeRegistryAtomic(env.RegistryPath(), Registry{Sessions: map[string]Session{
		"am-1": {Name: "am-1", Directory: "/tmp/project", AgentType: "claude"},
		"am-3": {Name: "am-3", Directory: "/tmp/project", AgentType: "claude"},
		"am-5": {Name: "am-5", Directory: "/tmp/scanproject", AgentType: "codex"},
		"am-6": {Name: "am-6", Directory: "/tmp/project", AgentType: "claude", Task: "Existing Title"},
		"am-7": {Name: "am-7", Directory: "/tmp/project", AgentType: "claude"},
		"am-8": {Name: "am-8", Directory: proj8, AgentType: "claude"},
		"am-9": {Name: "am-9", Directory: proj9, AgentType: "codex"},
		"am-h": {Name: "am-h", Directory: "/tmp/project", AgentType: "claude", Task: "Keep me"},
	}})
	setTitle("am-1:.{top-left}", "Fix the login bug in auth\n")
	setTitle("am-3:.{top-left}", "\n")
	setTitle("am-5:.{top-left}", "First scanned title\n")
	setTitle("am-6:.{top-left}", "Existing Title\n")
	setTitle("am-7:.{top-left}", ">>> Clean up the mess\n")
	setTitle("am-h:.{top-left}", "Claude Code\n")

	RefreshTitles(env, true)
	reg := ReadRegistry(env.RegistryPath())
	want := map[string]string{
		"am-1": "Fix the login bug in auth",
		"am-3": "",
		"am-5": "First scanned title",
		"am-6": "Existing Title",
		"am-7": "Clean up the mess",
		"am-8": "", // transcript exists but no bound id
		"am-9": "",
		"am-h": "Keep me",
	}
	for name, task := range want {
		if got := reg.Sessions[name].Task; got != task {
			t.Errorf("%s: task=%q, want %q", name, got, task)
		}
	}

	// Throttled: a new title does not land; forced: it does.
	setTitle("am-3:.{top-left}", "Throttle test title\n")
	RefreshTitles(env, false)
	if got := ReadRegistry(env.RegistryPath()).Sessions["am-3"].Task; got != "" {
		t.Errorf("throttled scan applied a title: %q", got)
	}
	writeFile(t, filepath.Join(env.StateDir, "am-8.sid"), "test\n")
	RefreshTitles(env, true)
	reg = ReadRegistry(env.RegistryPath())
	if got := reg.Sessions["am-3"].Task; got != "Throttle test title" {
		t.Errorf("forced scan: am-3 task=%q", got)
	}
	if got := reg.Sessions["am-8"].Task; got != "Investigate JSONL fallback path" {
		t.Errorf("bound id → first-message fallback: am-8 task=%q", got)
	}
}

func TestRefreshTitlesNonGitWorkdirBlanksBranch(t *testing.T) {
	amDir := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	env := testEnv(t, amDir)
	fakeTmux(t)
	launch := filepath.Join(t.TempDir(), "launch")
	writeFile(t, filepath.Join(launch, ".git", "HEAD"), "ref: refs/heads/main\n")
	plain := filepath.Join(t.TempDir(), "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(env.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeRegistryAtomic(env.RegistryPath(), Registry{Sessions: map[string]Session{
		"am-wd": {Name: "am-wd", Directory: launch, Branch: "main", AgentType: "claude"},
	}})
	writeFile(t, filepath.Join(env.StateDir, "am-wd.cwd"), plain)
	RefreshTitles(env, true)
	got := ReadRegistry(env.RegistryPath()).Sessions["am-wd"]
	if got.Workdir != plain || got.Branch != "" {
		t.Errorf("non-git workdir: workdir=%q branch=%q, want %q/\"\"", got.Workdir, got.Branch, plain)
	}
}

// Titler tracing is opt-in and the throttled path never logs; the debug logs
// are capped from the unthrottled path (mirrors test_titler_log_gated).
func TestTitlerLogGatedAndCapped(t *testing.T) {
	amDir := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	env := testEnv(t, amDir)
	fakeTmux(t)
	log := filepath.Join(amDir, "titler.log")

	t.Setenv("AM_TITLER_DEBUG", "")
	RefreshTitles(env, true)
	if fileExists(log) {
		t.Fatalf("titler.log written without AM_TITLER_DEBUG")
	}
	t.Setenv("AM_TITLER_DEBUG", "1")
	RefreshTitles(env, true)
	b, _ := os.ReadFile(log)
	if !strings.Contains(string(b), "scan start") {
		t.Fatalf("enabled log lacks 'scan start': %q", b)
	}
	before := len(b)
	RefreshTitles(env, false)
	b, _ = os.ReadFile(log)
	if len(b) != before {
		t.Fatalf("throttled scan logged: %q", b[before:])
	}

	big := filepath.Join(amDir, ".hook-debug.log")
	line := strings.Repeat("x", 99) + "\n"
	f, _ := os.Create(big)
	for i := 0; i < (21*1024*1024)/len(line)+1; i++ {
		f.WriteString(line)
	}
	f.Close()
	RefreshTitles(env, true)
	st, _ := os.Stat(big)
	if st.Size() > 10*1024*1024 {
		t.Fatalf("oversized debug log not capped: %d", st.Size())
	}
}

// capLog: bounded append-only logs (the contract the bash am_log_cap had).
func TestCapLog(t *testing.T) {
	root := t.TempDir()
	log := filepath.Join(root, "x.log")
	var sb strings.Builder
	for i := 1; i <= 300; i++ {
		sb.WriteString("line " + strconv.Itoa(1000 + i)[1:] + " padding padding\n")
	}
	writeFile(t, log, sb.String())
	before, _ := os.Stat(log)
	capLog(log, 100000)
	after, _ := os.Stat(log)
	if before.Size() != after.Size() {
		t.Fatalf("file under the cap rewritten")
	}
	capLog(log, 2000)
	b, _ := os.ReadFile(log)
	if len(b) == 0 || len(b) > 1000 {
		t.Fatalf("oversized file cut to at most half the cap, got %d", len(b))
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if lines[len(lines)-1] != "line 300 padding padding" {
		t.Fatalf("newest line lost: %q", lines[len(lines)-1])
	}
	if !strings.HasPrefix(lines[0], "line ") || !strings.HasSuffix(lines[0], " padding padding") {
		t.Fatalf("first kept line is partial: %q", lines[0])
	}
	capLog(filepath.Join(root, "nope.log"), 10)
	entries, _ := os.ReadDir(root)
	if len(entries) != 1 {
		t.Fatalf("temp file left behind: %v", entries)
	}
}

// --- GC ------------------------------------------------------------------

// Mirrors tests/test_registry.sh test_registry_gc_extras: sessions-log GC
// rules, snapshot age gate, temp sweeps, and the throttled path.
func TestGCExtras(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	env := testEnv(t, amDir)
	fakeTmux(t)
	snaps := env.SnapshotsDir()
	if err := os.MkdirAll(snaps, 0o755); err != nil {
		t.Fatal(err)
	}
	liveDir := t.TempDir()
	writeClaudeTranscript(t, home, liveDir, "sid-kept", "keep me around please")
	gone := filepath.Join(t.TempDir(), "gone")
	recent := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-stale-1", "session_id": "sid-gone", "directory": gone, "agent_type": "claude", "created_at": "2026-04-01T00:00:00Z", "snapshot_file": "snapshots/sid-gone.txt"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-stale-2", "session_id": "sid-gone-2", "directory": gone, "agent_type": "claude", "created_at": "2026-04-01T00:00:00Z"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-kept", "session_id": "sid-kept", "directory": liveDir, "agent_type": "claude", "created_at": "2026-04-01T00:00:00Z", "snapshot_file": "snapshots/sid-kept.txt"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-fresh", "session_id": "", "directory": liveDir, "agent_type": "claude", "created_at": recent})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-old-noid", "session_id": "", "directory": liveDir, "agent_type": "claude", "created_at": "2026-04-01T00:00:00Z"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-shell", "session_id": "", "directory": liveDir, "agent_type": "bash", "created_at": "2026-04-01T00:00:00Z"})
	// A line this version does not understand survives untouched.
	f, _ := os.OpenFile(env.SessionsLog, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("not json at all\n")
	f.Close()

	old := time.Now().Add(-2 * time.Hour)
	for _, n := range []string{"sid-kept.txt", "orphan-old.txt", "orphan-fresh.txt", "sid-gone.txt"} {
		writeFile(t, filepath.Join(snaps, n), "x\n")
	}
	os.Chtimes(filepath.Join(snaps, "sid-kept.txt"), old, old)
	os.Chtimes(filepath.Join(snaps, "orphan-old.txt"), old, old)

	for _, n := range []string{".sessions-log.leakOLD", ".sessions-log.leakNEW", ".dir_repo_cache.tmp.111", ".dir_repo_cache.tmp.222", "titler.log.AbCdEf", "titler.log"} {
		writeFile(t, filepath.Join(amDir, n), "")
	}
	for _, n := range []string{".sessions-log.leakOLD", ".dir_repo_cache.tmp.111", "titler.log.AbCdEf", "titler.log"} {
		os.Chtimes(filepath.Join(amDir, n), old, old)
	}

	if removed := env.GC(true); removed != 0 {
		t.Errorf("no registry rows, removed=%d", removed)
	}

	got := strings.Join(slogNames(t, env.SessionsLog), " ")
	if got != "am-kept am-fresh am-shell " {
		t.Errorf("sessions log after gc: %q", got)
	}
	if b, _ := os.ReadFile(env.SessionsLog); !strings.Contains(string(b), "not json at all") {
		t.Errorf("opaque line dropped")
	}
	if !fileExists(filepath.Join(amDir, ".gc_extras_last")) {
		t.Errorf(".gc_extras_last not stamped")
	}
	checks := map[string]bool{
		filepath.Join(snaps, "sid-kept.txt"):            true,
		filepath.Join(snaps, "orphan-old.txt"):          false,
		filepath.Join(snaps, "orphan-fresh.txt"):        true,
		filepath.Join(snaps, "sid-gone.txt"):            false,
		filepath.Join(amDir, ".sessions-log.leakOLD"):   false,
		filepath.Join(amDir, ".sessions-log.leakNEW"):   true,
		filepath.Join(amDir, ".dir_repo_cache.tmp.111"): false,
		filepath.Join(amDir, ".dir_repo_cache.tmp.222"): true,
		filepath.Join(amDir, "titler.log.AbCdEf"):       false,
		filepath.Join(amDir, "titler.log"):              true,
		env.SessionsLog:                                 true,
	}
	for path, want := range checks {
		if fileExists(path) != want {
			t.Errorf("%s exists=%v, want %v", filepath.Base(path), !want, want)
		}
	}

	// Throttled: nothing swept, marker untouched, 0 reported.
	before, _ := os.ReadFile(filepath.Join(amDir, ".gc_extras_last"))
	writeFile(t, filepath.Join(amDir, ".sessions-log.leakAGAIN"), "")
	os.Chtimes(filepath.Join(amDir, ".sessions-log.leakAGAIN"), old, old)
	if removed := env.GC(false); removed != 0 {
		t.Errorf("throttled gc reported %d", removed)
	}
	after, _ := os.ReadFile(filepath.Join(amDir, ".gc_extras_last"))
	if string(before) != string(after) {
		t.Errorf("throttled gc rewrote the marker")
	}
	if !fileExists(filepath.Join(amDir, ".sessions-log.leakAGAIN")) {
		t.Errorf("throttled gc swept a temp")
	}
}

// The two halves throttle independently: a fresh .gc_last (stamped by the
// browser's reaper) must not starve the extras, and the grace window keeps a
// just-registered row (mirrors test_registry_gc).
func TestGCHalvesAndGrace(t *testing.T) {
	amDir := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	env := testEnv(t, amDir)
	fakeTmux(t) // list-sessions fails → nothing live
	if err := os.MkdirAll(env.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	writeRegistryAtomic(env.RegistryPath(), Registry{Sessions: map[string]Session{
		"am-young": {Name: "am-young", Directory: "/tmp/x", AgentType: "claude", CreatedAt: now.Format(time.RFC3339)},
		"am-old-1": {Name: "am-old-1", Directory: "/tmp/x", AgentType: "claude", CreatedAt: "2020-01-01T00:00:00Z"},
		"am-old-2": {Name: "am-old-2", Directory: "/tmp/x", AgentType: "claude", CreatedAt: "2020-01-01T00:00:00Z"},
	}})
	writeFile(t, filepath.Join(env.StateDir, "am-orphan"), "ready")
	writeFile(t, filepath.Join(env.StateDir, "am-orphan.sid"), "uuid-orphan")
	writeFile(t, filepath.Join(env.StateDir, "am-orphan.cwd"), "/tmp")
	writeFile(t, filepath.Join(env.StateDir, "other-prefix"), "ready")

	writeFile(t, filepath.Join(amDir, ".gc_last"), strconv.FormatInt(now.Unix(), 10))
	if removed := env.GC(false); removed != 0 {
		t.Errorf("rows half ran despite fresh .gc_last: removed=%d", removed)
	}
	if n := len(ReadRegistry(env.RegistryPath()).Sessions); n != 3 {
		t.Errorf("registry rows reaped while throttled: %d left", n)
	}
	for _, n := range []string{"am-orphan", "am-orphan.sid", "am-orphan.cwd"} {
		if fileExists(filepath.Join(env.StateDir, n)) {
			t.Errorf("extras sweep left %s despite fresh .gc_last", n)
		}
	}
	if !fileExists(filepath.Join(env.StateDir, "other-prefix")) {
		t.Errorf("state file outside the session prefix removed")
	}

	if removed := env.GC(true); removed != 2 {
		t.Errorf("forced gc removed %d, want 2 (grace keeps the young row)", removed)
	}
	reg := ReadRegistry(env.RegistryPath())
	if _, ok := reg.Sessions["am-young"]; !ok || len(reg.Sessions) != 1 {
		t.Errorf("after forced gc: %v", reg.Sessions)
	}
	t.Setenv("AM_GC_GRACE_SECS", "0")
	if removed := env.GC(true); removed != 1 {
		t.Errorf("grace 0: removed %d, want 1", removed)
	}
}

func TestIsLogCapTemp(t *testing.T) {
	cases := map[string]bool{
		"titler.log.AbCdEf": true, "titler.log": false, ".hook-debug.log.123456": true,
		"x.log.12345": false, "x.log.1234567": false, "sessions_log.jsonl": false,
	}
	for in, want := range cases {
		if got := isLogCapTemp(in); got != want {
			t.Errorf("isLogCapTemp(%q)=%v want %v", in, got, want)
		}
	}
}

// --- Restorable ----------------------------------------------------------

func TestRestorableRawLines(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	env := testEnv(t, amDir)
	fakeTmux(t)
	dir := t.TempDir()
	writeClaudeTranscript(t, home, dir, "sid-a", "hello there world")
	writeClaudeTranscript(t, home, dir, "sid-b", "hello there world")
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-a1", "session_id": "sid-a", "directory": dir, "agent_type": "claude", "task": "first"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-gone", "session_id": "sid-gone", "directory": dir, "agent_type": "claude"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-noid", "session_id": "", "directory": dir, "agent_type": "claude"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-b", "session_id": "sid-b", "directory": dir, "agent_type": "claude"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-a2", "session_id": "sid-a", "directory": dir, "agent_type": "claude", "task": "resumed"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-codex", "session_id": "codex-1", "directory": "/tmp", "agent_type": "codex"})
	slogAppend(t, env.SessionsLog, map[string]any{"session_name": "am-shell", "session_id": "x", "directory": dir, "agent_type": "bash"})

	raw, _ := os.ReadFile(env.SessionsLog)
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")

	got := env.Restorable()
	want := []string{lines[5], lines[4], lines[3]} // codex, am-a2, am-b — newest first, sid-a once
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("restorable:\n got %q\nwant %q", got, want)
	}
}
