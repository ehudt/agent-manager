package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
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

	if err := os.MkdirAll(filepath.Join(amDir, "snapshots"), 0o755); err != nil {
		t.Fatalf("mkdir snapshots: %v", err)
	}
	if err := os.WriteFile(filepath.Join(amDir, "snapshots", "sid-dup.txt"), []byte("snapshot"), 0o644); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	logs := []SessionLogEntry{
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
	if len(entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(entries))
	}

	if entries[0].Kind != EntryInactive || entries[0].RestoreSessionID != "sid-dup" {
		t.Fatalf("first entry = %#v, want newest sid-dup inactive", entries[0])
	}
	if entries[0].DisplayBase != "my-site/main [claude] Duplicate new" {
		t.Errorf("first DisplayBase = %q", entries[0].DisplayBase)
	}
	if entries[0].TimeAgo != "30s ago" {
		t.Errorf("first TimeAgo = %q, want 30s ago", entries[0].TimeAgo)
	}
	if entries[0].SnapshotPath != filepath.Join(amDir, "snapshots", "sid-dup.txt") {
		t.Errorf("first SnapshotPath = %q", entries[0].SnapshotPath)
	}

	if entries[1].RestoreSessionID != "sid-old" {
		t.Errorf("second RestoreSessionID = %q, want sid-old", entries[1].RestoreSessionID)
	}
	if entries[1].TimeAgo != "1d ago" {
		t.Errorf("second TimeAgo = %q, want 1d ago", entries[1].TimeAgo)
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
