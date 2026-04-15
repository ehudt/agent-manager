package main

import (
	"testing"
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
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "mpfix", true},  // subsequence
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "zzz", false},
		{"am-abc123 myproject/main [claude] fix bug (5m ago)", "xyz", false},
		{"", "a", false},
		{"abc", "", true},   // empty pattern matches everything
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
	// Should contain key bindings
	for _, want := range []string{"Enter", "Ctrl-N", "Ctrl-X", "Ctrl-H", "Ctrl-R", "Ctrl-P"} {
		if !containsStr(h, want) {
			t.Errorf("helpText missing %q", want)
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
