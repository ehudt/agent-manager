package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
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

func TestFormatLine(t *testing.T) {
	s := TmuxSession{Name: "am-test", Activity: 100}
	meta := Session{
		Directory: "/tmp/proj",
		AgentType: "claude",
	}
	line := FormatLine(s, meta, 130)
	if line != "am-test|am-test proj [claude] (30s ago)" {
		t.Errorf("FormatLine got: %q", line)
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
