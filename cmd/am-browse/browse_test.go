package main

import (
	"strings"
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

func TestMatchTier(t *testing.T) {
	const text = "myproject/main [claude] fix bug (5m ago)"
	tests := []struct {
		query string
		want  int
	}{
		{"myproject", 4}, // prefix of the whole display
		{"main", 3},      // word-boundary prefix (after '/')
		{"claude", 3},    // word-boundary prefix (after '[')
		{"fix", 3},       // word-boundary prefix (after ' ')
		{"lau", 2},       // substring, not at a word boundary
		{"mpfix", 1},     // subsequence only
		{"zzz", 0},       // no match
	}
	for _, tt := range tests {
		if got := matchTier(text, tt.query); got != tt.want {
			t.Errorf("matchTier(%q, %q) = %d, want %d", text, tt.query, got, tt.want)
		}
	}
}

func TestWordPrefix(t *testing.T) {
	tests := []struct {
		text, query string
		want        bool
	}{
		{"a/proj", "proj", true},  // after '/'
		{"x [proj]", "proj", true}, // after '['
		{"foo-proj", "proj", true}, // after '-'
		{"foo proj", "proj", true}, // after ' '
		{"aprojx", "proj", false},  // mid-word
	}
	for _, tt := range tests {
		if got := wordPrefix(tt.text, tt.query); got != tt.want {
			t.Errorf("wordPrefix(%q, %q) = %v, want %v", tt.text, tt.query, got, tt.want)
		}
	}
}

// applyFilter ranks matches by coarse tier first, then by recency (most recent
// wins ties) — within the active list here.
func TestApplyFilterRanksByTierThenRecency(t *testing.T) {
	m := newModel()
	m.entries = []sessions.Entry{
		{Kind: sessions.EntryActive, Display: "proj-old [c]", RecencyUnix: 100},   // tier 4
		{Kind: sessions.EntryActive, Display: "proj-new [c]", RecencyUnix: 500},   // tier 4, more recent
		{Kind: sessions.EntryActive, Display: "x/proj mid [c]", RecencyUnix: 300}, // tier 3
		{Kind: sessions.EntryActive, Display: "aprojx [c]", RecencyUnix: 999},     // tier 2, recent but worse tier
	}
	m.filter.SetValue("proj")
	m.applyFilter()

	wantOrder := []string{"proj-new [c]", "proj-old [c]", "x/proj mid [c]", "aprojx [c]"}
	gotOrder := make([]string, len(m.filtered))
	for i, idx := range m.filtered {
		gotOrder[i] = m.entries[idx].Display
	}
	if strings.Join(gotOrder, "|") != strings.Join(wantOrder, "|") {
		t.Errorf("ranked order = %v, want %v", gotOrder, wantOrder)
	}
}

// The active/inactive split is preserved even when an inactive entry matches
// better: all active hits precede all inactive hits (so the divider stays put).
func TestApplyFilterKeepsActiveInactiveSplit(t *testing.T) {
	m := newModel()
	m.entries = []sessions.Entry{
		{Kind: sessions.EntryActive, Display: "p_qr_os_j [c]", RecencyUnix: 100},  // tier 1 (subsequence)
		{Kind: sessions.EntryInactive, Display: "proj-restore [c]", RecencyUnix: 999}, // tier 4
	}
	m.filter.SetValue("proj")
	m.applyFilter()

	if len(m.filtered) != 2 {
		t.Fatalf("filtered len = %d, want 2", len(m.filtered))
	}
	if got := m.entries[m.filtered[0]].Kind; got != sessions.EntryActive {
		t.Errorf("first result kind = %v, want active (split must be preserved)", got)
	}
	if got := m.entries[m.filtered[1]].Kind; got != sessions.EntryInactive {
		t.Errorf("second result kind = %v, want inactive", got)
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
			Meta:             sessions.Session{Directory: "/tmp/my-site", AgentType: "claude"},
			RestoreSessionID: "sid-123",
			Display:          "my-site [claude] task (1m ago)",
			DisplayBase:      "my-site [claude] task",
			TimeAgo:          "1m ago",
		},
	}
	m.applyFilter()

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	got := updated.(model).output
	want := "__RESTORE__\x1f/tmp/my-site\x1fsid-123\x1fclaude"
	if got != want {
		t.Errorf("inactive enter output = %q, want %q", got, want)
	}
}

// View must never render more lines than the terminal height: a taller view
// makes the popup jump a line up and down as the preview content length flips
// between the 1-line "Loading preview..." placeholder and a full pane capture.
func TestViewFitsTerminalHeight(t *testing.T) {
	m := newModel()
	m.width = 80
	m.height = 30
	m.loading = false
	for i := range 20 {
		name := "am-active" + string(rune('a'+i))
		m.entries = append(m.entries, sessions.Entry{
			TmuxSession: sessions.TmuxSession{Name: name},
			Kind:        sessions.EntryActive,
			Display:     name + " proj [claude] task (1m ago)",
			DisplayBase: name + " proj [claude] task",
			TimeAgo:     "1m ago",
		})
	}
	m.applyFilter()

	longPreview := strings.Repeat("preview line\n", 100)
	for _, preview := range []string{"", "Loading preview...", longPreview} {
		for cursor := 0; cursor < len(m.entries); cursor++ {
			m.cursor = cursor
			m.preview = preview
			m.previewFor = m.selectedPreviewKey()
			view := m.View()
			if got := strings.Count(view, "\n") + 1; got > m.height {
				t.Fatalf("cursor=%d previewLines=%d: view is %d lines, terminal height is %d",
					cursor, strings.Count(preview, "\n"), got, m.height)
			}
		}
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
