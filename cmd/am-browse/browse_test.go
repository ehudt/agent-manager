package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

func TestFuzzyMatch(t *testing.T) {
	tests := []struct {
		text    string
		pattern string
		want    bool
	}{
		// Note: fuzzyMatch is called with lowered text in applyFilter()
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "fix", true},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "myp", true},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "abc", true},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "claude", true},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "mpfix", true}, // subsequence
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "zzz", false},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "xyz", false},
		{"", "a", false},
		{"abc", "", true}, // empty pattern matches everything
		{"", "", true},
	}
	for _, tt := range tests {
		got := fuzzyMatch(tt.text, tt.pattern)
		if got != tt.want {
			t.Errorf("fuzzyMatch(%q, %q) = %v, want %v", tt.text, tt.pattern, got, tt.want)
		}
	}
}

func TestHelpText(t *testing.T) {
	h := helpText()
	if h == "" {
		t.Error("helpText should not be empty")
	}
	// Should contain public key bindings
	for _, want := range []string{"Up/Down", "Enter", "Esc/q", "Ctrl-N", "Ctrl-X", "Ctrl-R", "?", "Prefix + 1-9"} {
		if !containsStr(h, want) {
			t.Errorf("helpText missing %q", want)
		}
	}
	for _, hidden := range []string{"Ctrl-H", "Ctrl-P"} {
		if containsStr(h, hidden) {
			t.Errorf("helpText should not advertise %q", hidden)
		}
	}
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 || findSubstring(s, sub))
}

func findSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// Test output protocol: model.output values
func TestOutputProtocol(t *testing.T) {
	// New model should have empty output
	m := newModel()
	if m.output != "" {
		t.Errorf("new model output = %q, want empty", m.output)
	}
}

func TestEnterInactiveOutputsRestoreProtocol(t *testing.T) {
	m := newModel()
	m.entries = []sessions.Entry{
		{
			Kind:             sessions.EntryInactive,
			Meta:             sessions.Session{Directory: "/tmp/my-site"},
			RestoreSessionID: "sid-123",
			Display:          "my-site [claude] task (1m ago)",
			DisplayBase:      "my-site [claude] task",
			TimeAgo:          "1m ago",
		},
	}
	m.applyFilter()

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	got := updated.(model).output
	want := "__RESTORE__\x1f/tmp/my-site\x1fsid-123"
	if got != want {
		t.Errorf("inactive enter output = %q, want %q", got, want)
	}
}

func TestCtrlHMovesToInactiveSection(t *testing.T) {
	m := newModel()
	m.entries = []sessions.Entry{
		{
			TmuxSession: sessions.TmuxSession{Name: "am-active"},
			Kind:        sessions.EntryActive,
			Display:     "am-active proj [codex] (1s ago)",
			DisplayBase: "am-active proj [codex]",
			TimeAgo:     "1s ago",
		},
		{
			Kind:             sessions.EntryInactive,
			Meta:             sessions.Session{Directory: "/tmp/proj"},
			RestoreSessionID: "sid-restore",
			Display:          "proj [claude] (2m ago)",
			DisplayBase:      "proj [claude]",
			TimeAgo:          "2m ago",
		},
	}
	m.applyFilter()

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyCtrlH})
	got := updated.(model)
	if got.cursor != 1 {
		t.Errorf("cursor after Ctrl-H = %d, want 1", got.cursor)
	}
}
