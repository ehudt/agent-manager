package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestFormatTimeAgo(t *testing.T) {
	tests := []struct {
		idle int64
		want string
	}{
		{-5, "just now"},
		{0, "0s ago"},
		{30, "30s ago"},
		{59, "59s ago"},
		{60, "1m ago"},
		{119, "1m ago"},
		{120, "2m ago"},
		{3599, "59m ago"},
		{3600, "1h ago"},
		{3660, "1h 1m ago"},
		{7200, "2h ago"},
		{7260, "2h 1m ago"},
		{86400, "1d ago"},
		{172800, "2d ago"},
	}
	for _, tt := range tests {
		got := FormatTimeAgo(tt.idle)
		if got != tt.want {
			t.Errorf("FormatTimeAgo(%d) = %q, want %q", tt.idle, got, tt.want)
		}
	}
}

func TestFormatDisplay(t *testing.T) {
	s := TmuxSession{Name: "am-abc123", Activity: 1000}
	meta := Session{
		Directory: "/home/user/myproject",
		Branch:    "main",
		AgentType: "claude",
		Task:      "Fix the bug",
	}
	now := int64(1060)
	display := FormatDisplay(s, meta, now)

	if display != "am-abc123 myproject/main [claude] Fix the bug (1m ago)" {
		t.Errorf("FormatDisplay got: %q", display)
	}
}

func TestFormatDisplayDefaults(t *testing.T) {
	s := TmuxSession{Name: "am-xyz", Activity: 1000}
	meta := Session{} // empty metadata
	now := int64(1010)
	display := FormatDisplay(s, meta, now)

	if display != "am-xyz [unknown] (10s ago)" {
		t.Errorf("FormatDisplay (empty meta) got: %q", display)
	}
}

func TestFormatRestorableDisplayBase(t *testing.T) {
	log := SessionLogEntry{
		Directory: "/home/user/my-site",
		Branch:    "main",
		AgentType: "claude",
		Task:      "Fix restore flow",
	}
	display := FormatRestorableDisplayBase(log)
	if display != "my-site/main [claude] Fix restore flow" {
		t.Errorf("FormatRestorableDisplayBase got: %q", display)
	}
}

func TestReadRegistryMissing(t *testing.T) {
	reg := ReadRegistry("/nonexistent/path.json")
	if reg.Sessions == nil {
		t.Error("ReadRegistry should return non-nil Sessions map")
	}
	if len(reg.Sessions) != 0 {
		t.Errorf("ReadRegistry should return empty map, got %d entries", len(reg.Sessions))
	}
}

func TestReadRegistryValid(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sessions.json")

	reg := Registry{
		Sessions: map[string]Session{
			"am-abc": {
				Name:      "am-abc",
				Directory: "/tmp/test",
				Branch:    "dev",
				AgentType: "claude",
				Task:      "Test task",
			},
		},
	}
	data, _ := json.Marshal(reg)
	os.WriteFile(path, data, 0644)

	got := ReadRegistry(path)
	if len(got.Sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(got.Sessions))
	}
	s := got.Sessions["am-abc"]
	if s.Task != "Test task" {
		t.Errorf("expected task 'Test task', got %q", s.Task)
	}
}

func TestRegistryRoundTripPreservesKnownAndFutureMetadata(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sessions.json")
	want := registryMetadataDocument("am-abc", "Test task")
	writeJSONDocument(t, path, want)

	reg := ReadRegistry(path)
	session := reg.Sessions["am-abc"]
	if session.LogicalID != "logical-abc" || session.OrderKey != "000001" {
		t.Fatalf("known recovery metadata was not decoded: %#v", session)
	}

	writeRegistryAtomic(path, reg)
	got := readJSONDocument(t, path)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("registry metadata changed across read/rewrite:\n got: %#v\nwant: %#v", got, want)
	}
}

func registryMetadataDocument(name, task string) map[string]any {
	return map[string]any{
		"schema_version": float64(2),
		"registry_meta": map[string]any{
			"future": []any{"value", float64(7), true},
		},
		"sessions": map[string]any{
			name: map[string]any{
				"name":       name,
				"directory":  "/nonexistent/am-test",
				"branch":     "dev",
				"agent_type": "claude",
				"task":       task,
				"created_at": "2026-08-28T07:00:00Z",
				// Fields written by releases before 0.18 must survive a rewrite.
				"yolo_mode":          "true",
				"sandbox_mode":       "true",
				"container_name":     name,
				"worktree_path":      "/container/worktree",
				"worktree_host_path": "/host/worktree",
				"worktree_name":      "feature-recovery",
				"logical_id":         "logical-abc",
				"order_key":          "000001",
				"future_metadata": map[string]any{
					"nested": []any{float64(1), "two", false},
				},
			},
		},
	}
}

func TestReadRegistryBadJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sessions.json")
	os.WriteFile(path, []byte("not json"), 0644)

	reg := ReadRegistry(path)
	if reg.Sessions == nil {
		t.Error("ReadRegistry should return non-nil Sessions map on bad JSON")
	}
}

func TestRestorableEntriesFromLog(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	root := t.TempDir()
	dir := filepath.Join(root, "my-site")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir project: %v", err)
	}

	writeClaudeJSONL(t, home, dir, "sid-old")
	writeClaudeJSONL(t, home, dir, "sid-dup")
	writeClaudeJSONL(t, home, dir, "sid-live")
	writeClaudeJSONL(t, home, dir, "sid-long")

	if err := os.MkdirAll(filepath.Join(amDir, "snapshots"), 0o755); err != nil {
		t.Fatalf("mkdir snapshots: %v", err)
	}
	if err := os.WriteFile(filepath.Join(amDir, "snapshots", "sid-dup.txt"), []byte("snapshot"), 0o644); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	logs := []SessionLogEntry{
		{
			// Launched first, closed last: must lead the list even though
			// every other entry sits after it in the log.
			SessionName: "am-long",
			SessionID:   "sid-long",
			Directory:   dir,
			AgentType:   "claude",
			Task:        "Long-lived",
			CreatedAt:   "2026-01-01T08:00:00Z",
			ClosedAt:    "2026-01-02T11:59:45Z",
		},
		{
			SessionName: "am-old",
			SessionID:   "sid-old",
			Directory:   dir,
			Branch:      "main",
			AgentType:   "claude",
			Task:        "Old task",
			ClosedAt:    "2026-01-01T12:00:00Z",
		},
		{
			SessionName: "am-live",
			SessionID:   "sid-live",
			Directory:   dir,
			AgentType:   "claude",
			Task:        "Live task",
			ClosedAt:    "2026-01-02T11:00:00Z",
		},
		{
			SessionName: "am-missing",
			SessionID:   "sid-missing",
			Directory:   dir,
			AgentType:   "claude",
			Task:        "Missing JSONL",
			ClosedAt:    "2026-01-02T11:30:00Z",
		},
		{
			SessionName: "am-dup-old",
			SessionID:   "sid-dup",
			Directory:   dir,
			AgentType:   "claude",
			Task:        "Duplicate old",
			ClosedAt:    "2026-01-02T10:00:00Z",
		},
		{
			SessionName:  "am-dup-new",
			SessionID:    "sid-dup",
			Directory:    dir,
			Branch:       "main",
			AgentType:    "claude",
			Task:         "Duplicate new",
			ClosedAt:     "2026-01-02T11:59:30Z",
			SnapshotFile: "snapshots/sid-dup.txt",
		},
	}

	now := time.Date(2026, 1, 2, 12, 0, 0, 0, time.UTC)
	entries := restorableEntriesFromLog(logs, amDir, home, map[string]bool{"am-live": true}, now)
	if len(entries) != 3 {
		t.Fatalf("len(entries) = %d, want 3", len(entries))
	}

	// Most recently closed first, regardless of log (launch) order.
	if entries[0].Kind != EntryInactive || entries[0].RestoreSessionID != "sid-long" {
		t.Fatalf("first entry = %#v, want the most recently closed sid-long", entries[0])
	}
	if entries[0].TimeAgo != "15s ago" {
		t.Errorf("first TimeAgo = %q, want 15s ago", entries[0].TimeAgo)
	}

	if entries[1].RestoreSessionID != "sid-dup" {
		t.Fatalf("second entry = %#v, want newest sid-dup inactive", entries[1])
	}
	if entries[1].DisplayBase != "my-site/main [claude] Duplicate new" {
		t.Errorf("second DisplayBase = %q", entries[1].DisplayBase)
	}
	if entries[1].TimeAgo != "30s ago" {
		t.Errorf("second TimeAgo = %q, want 30s ago", entries[1].TimeAgo)
	}
	if entries[1].SnapshotPath != filepath.Join(amDir, "snapshots", "sid-dup.txt") {
		t.Errorf("second SnapshotPath = %q", entries[1].SnapshotPath)
	}

	if entries[2].RestoreSessionID != "sid-old" {
		t.Errorf("third RestoreSessionID = %q, want sid-old", entries[2].RestoreSessionID)
	}
	if entries[2].TimeAgo != "1d ago" {
		t.Errorf("third TimeAgo = %q, want 1d ago", entries[2].TimeAgo)
	}
}

// A conversation resumed in another directory keeps its file in the original
// directory's store. The row is restorable through the hook-recorded path,
// or — when no hook fired after the move — through the store-wide id search.
func TestRestorableEntriesFollowRelocatedClaudeTranscript(t *testing.T) {
	home := t.TempDir()
	origDir := filepath.Join(home, "orig-copy")
	newDir := filepath.Join(home, "new-copy")
	if err := os.MkdirAll(newDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeClaudeJSONL(t, home, origDir, "sid-path")
	writeClaudeJSONL(t, home, origDir, "sid-search")
	logs := []SessionLogEntry{
		{SessionName: "am-path", SessionID: "sid-path", Directory: newDir, AgentType: "claude",
			TranscriptPath: claudeStandardTranscriptPath(home, origDir, "sid-path"), ClosedAt: "2026-01-02T12:00:00Z"},
		{SessionName: "am-search", SessionID: "sid-search", Directory: newDir, AgentType: "claude", ClosedAt: "2026-01-02T11:00:00Z"},
		{SessionName: "am-nowhere", SessionID: "sid-nowhere", Directory: newDir, AgentType: "claude", ClosedAt: "2026-01-02T10:00:00Z"},
	}
	entries := restorableEntriesFromLog(logs, home, home, map[string]bool{}, time.Now())
	if len(entries) != 2 || entries[0].RestoreSessionID != "sid-path" || entries[1].RestoreSessionID != "sid-search" {
		t.Fatalf("restorable = %#v, want sid-path and sid-search", entries)
	}
	if entries[0].RestoreNote != "" {
		t.Errorf("new-copy exists with no recorded branch: note = %q, want none", entries[0].RestoreNote)
	}
}

// The restore row warns when its checkout is gone or now holds another
// branch; Enter then opens the relocation prompt instead of resuming.
func TestRestoreNote(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "ref: refs/heads/other\n")
	plain := filepath.Join(root, "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ dir, branch, want string }{
		{filepath.Join(root, "gone"), "feature-a", "dir gone"},
		{filepath.Join(root, "gone"), "", "dir gone"},
		{repo, "feature-a", "on other"},
		{repo, "other", ""},
		{repo, "", ""},
		{repo, "1a2b3c4d", ""}, // pre-0.38 row closed on a detached HEAD: not a branch
		{plain, "feature-a", ""}, // not a repository: nothing to judge
		{"", "feature-a", ""},
	}
	for _, c := range cases {
		if got := RestoreNote(c.dir, c.branch); got != c.want {
			t.Errorf("RestoreNote(%q, %q) = %q, want %q", c.dir, c.branch, got, c.want)
		}
	}

	home := t.TempDir()
	writeClaudeJSONL(t, home, repo, "sid-repo")
	logs := []SessionLogEntry{{SessionName: "am-repo", SessionID: "sid-repo", Directory: repo, Branch: "feature-a", AgentType: "claude", Task: "Fix it"}}
	entries := restorableEntriesFromLog(logs, home, home, map[string]bool{}, time.Now())
	if len(entries) != 1 || entries[0].RestoreNote != "on other" {
		t.Fatalf("entries = %#v, want one row noted 'on other'", entries)
	}
	if entries[0].DisplayBase != "repo/feature-a [claude] Fix it ⚠ on other" {
		t.Errorf("DisplayBase = %q", entries[0].DisplayBase)
	}
}

func writeClaudeJSONL(t *testing.T, home, dir, sessionID string) {
	t.Helper()
	projectDir := filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir))
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatalf("mkdir claude project: %v", err)
	}
	if err := os.WriteFile(filepath.Join(projectDir, sessionID+".jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write claude jsonl: %v", err)
	}
}

func writeJSONDocument(t *testing.T, path string, document map[string]any) {
	t.Helper()
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("marshal JSON document: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write JSON document: %v", err)
	}
}

func readJSONDocument(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read JSON document: %v", err)
	}
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatalf("decode JSON document: %v", err)
	}
	return document
}

func TestEnvOr(t *testing.T) {
	// Unset key should return default
	os.Unsetenv("__TEST_ENVOR_KEY__")
	if got := EnvOr("__TEST_ENVOR_KEY__", "default"); got != "default" {
		t.Errorf("EnvOr unset = %q, want 'default'", got)
	}

	// Set key should return value
	os.Setenv("__TEST_ENVOR_KEY__", "custom")
	defer os.Unsetenv("__TEST_ENVOR_KEY__")
	if got := EnvOr("__TEST_ENVOR_KEY__", "default"); got != "custom" {
		t.Errorf("EnvOr set = %q, want 'custom'", got)
	}
}

func TestRestorableEntriesIncludePi(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		resolved = dir
	}
	sid := "0199cccc-0000-0000-0000-000000000001"
	piDir := filepath.Join(home, ".pi", "agent", "sessions", encodedPiSessionDir(resolved))
	if err := os.MkdirAll(piDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(piDir, "2026-07-19T08-00-00-000Z_"+sid+".jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	logs := []SessionLogEntry{
		{SessionName: "am-pi1", SessionID: sid, Directory: resolved, AgentType: "pi", CreatedAt: "2026-07-19T08:00:00Z"},
		{SessionName: "am-pi2", SessionID: "0199cccc-0000-0000-0000-000000000002", Directory: resolved, AgentType: "pi", CreatedAt: "2026-07-19T08:00:00Z"},
	}
	entries := restorableEntriesFromLog(logs, home, home, map[string]bool{}, time.Now())
	if len(entries) != 1 {
		t.Fatalf("want 1 restorable pi entry, got %d", len(entries))
	}
	if entries[0].RestoreSessionID != sid {
		t.Fatalf("wrong sid: %s", entries[0].RestoreSessionID)
	}
}

func TestRestorableEntriesIncludeCursorTranscript(t *testing.T) {
	home := t.TempDir()
	transcript := filepath.Join(t.TempDir(), "cursor-1.jsonl")
	if err := os.WriteFile(transcript, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !cursorJSONLExists(home, home, "cursor-resumed-id", transcript) {
		t.Fatal("hook-reported Cursor transcript should remain valid after resume id changes")
	}
	logs := []SessionLogEntry{
		{SessionName: "am-cursor1", SessionID: "cursor-1", TranscriptPath: transcript, Directory: home, AgentType: "cursor"},
		{SessionName: "am-cursor2", SessionID: "cursor-2", TranscriptPath: filepath.Join(home, "missing.jsonl"), Directory: home, AgentType: "cursor"},
	}
	entries := restorableEntriesFromLog(logs, home, home, map[string]bool{}, time.Now())
	if len(entries) != 1 {
		t.Fatalf("want 1 restorable Cursor entry, got %d", len(entries))
	}
	if entries[0].RestoreSessionID != "cursor-1" {
		t.Fatalf("wrong sid: %s", entries[0].RestoreSessionID)
	}
}

func TestRestorableEntriesIncludeCodexExactID(t *testing.T) {
	logs := []SessionLogEntry{
		{SessionName: "am-codex1", SessionID: "codex-1", Directory: "/tmp", AgentType: "codex"},
	}
	entries := restorableEntriesFromLog(logs, t.TempDir(), t.TempDir(), map[string]bool{}, time.Now())
	if len(entries) != 1 || entries[0].RestoreSessionID != "codex-1" {
		t.Fatalf("Codex restorable entries = %#v, want exact id", entries)
	}
}

func TestEncodedPiSessionDir(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"/Users/x.y/code/proj", "--Users-x.y-code-proj--"},
		{"//foo", "---foo--"},
	}
	for _, tt := range tests {
		got := encodedPiSessionDir(tt.input)
		if got != tt.want {
			t.Errorf("encodedPiSessionDir(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestStoreDirAndTranscriptPath(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AM_PI_SESSIONS_DIR", filepath.Join(home, "pi-sessions"))
	env := Env{AmDir: filepath.Join(home, ".agent-manager"), Home: home}

	claudeStore := filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir))
	if got := env.StoreDir("claude", dir); got != claudeStore {
		t.Errorf("StoreDir claude = %q, want %q", got, claudeStore)
	}
	if got := env.StoreDir("codex", dir); got != "" {
		t.Errorf("StoreDir codex = %q, want empty", got)
	}
	wantClaude := filepath.Join(claudeStore, "sid-1.jsonl")
	if got := env.TranscriptPath("claude", dir, "sid-1", ""); got != wantClaude {
		t.Errorf("TranscriptPath claude = %q, want %q", got, wantClaude)
	}
	if got := env.TranscriptPath("claude", dir, "", ""); got != "" {
		t.Errorf("TranscriptPath claude without id = %q, want empty", got)
	}
	cursorPath := filepath.Join(home, "cursor-transcript.jsonl")
	if got := env.TranscriptPath("cursor", dir, "sid-1", cursorPath); got != cursorPath {
		t.Errorf("TranscriptPath cursor hook path = %q, want %q", got, cursorPath)
	}

	piStore := env.StoreDir("pi", dir)
	if err := os.MkdirAll(piStore, 0o755); err != nil {
		t.Fatal(err)
	}
	piFile := filepath.Join(piStore, "2026-01-01T00-00-00-000Z_sid-pi.jsonl")
	if err := os.WriteFile(piFile, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := env.TranscriptPath("pi", dir, "sid-pi", ""); got != piFile {
		t.Errorf("TranscriptPath pi = %q, want %q", got, piFile)
	}
}

func TestFormatDisplayBaseUsesWorkdir(t *testing.T) {
	s := TmuxSession{Name: "am-wd"}
	meta := Session{Directory: "/repos/wekapp", Branch: "pr-42", AgentType: "claude", Task: "fix"}
	if got := FormatDisplayBase(s, meta); got != "am-wd wekapp/pr-42 [claude] fix" {
		t.Errorf("without workdir: %q", got)
	}
	meta.Workdir = "/pool/pink-wekapp"
	if got := FormatDisplayBase(s, meta); got != "am-wd pink-wekapp/pr-42 [claude] fix" {
		t.Errorf("with workdir: %q", got)
	}
}
