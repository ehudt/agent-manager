package sessions

import (
	"os"
	"path/filepath"
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
	}
	for _, c := range cases {
		if got := titleValid(c.in); got != c.want {
			t.Errorf("titleValid(%q) = %v, want %v", c.in, got, c.want)
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

	got := claudeFirstUserMessage(directory, "", false)
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

	got := claudeFirstUserMessage(directory, "", false)
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

	got := claudeFirstUserMessage(directory, "", false)
	if got != "This is the real user task description" {
		t.Errorf("got %q, want non-short message", got)
	}
}

func TestClaudeFirstUserMessageMissingDir(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	if got := claudeFirstUserMessage("/nonexistent/dir/xyz", "", false); got != "" {
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

	// Two sessions in one directory. The older one must keep its own title.
	older := `{"type":"user","message":{"content":"Older session original task"}}` + "\n"
	newer := `{"type":"user","message":{"content":"Newer session different task"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "aaaa-old.jsonl"), []byte(older), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(claudeDir, "bbbb-new.jsonl"), []byte(newer), 0o644); err != nil {
		t.Fatal(err)
	}
	// Make the "old" file the least recently modified so the newest-wins
	// fallback would otherwise pick the new file for both sessions.
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(claudeDir, "aaaa-old.jsonl"), old, old); err != nil {
		t.Fatal(err)
	}

	if got := claudeFirstUserMessage(directory, "aaaa-old", false); got != "Older session original task" {
		t.Errorf("explicit id: got %q, want older session's message", got)
	}
	// Empty id keeps newest-wins behavior.
	if got := claudeFirstUserMessage(directory, "", false); got != "Newer session different task" {
		t.Errorf("empty id: got %q, want newest message", got)
	}
	// Missing id file falls back to newest.
	if got := claudeFirstUserMessage(directory, "does-not-exist", false); got != "Newer session different task" {
		t.Errorf("missing id file: got %q, want newest message", got)
	}
	// strict + no usable id + multiple JSONLs → refuse to guess.
	if got := claudeFirstUserMessage(directory, "", true); got != "" {
		t.Errorf("strict ambiguous: got %q, want empty", got)
	}
	// strict + valid id still resolves.
	if got := claudeFirstUserMessage(directory, "aaaa-old", true); got != "Older session original task" {
		t.Errorf("strict with id: got %q, want older session's message", got)
	}
}

func TestClaudeFirstUserMessageStrictSingleJSONL(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	directory := "/some/path/lone-dir"
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(tmp, ".claude", "projects", projectPath)
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"user","message":{"content":"Only session here, unambiguous"}}` + "\n"
	if err := os.WriteFile(filepath.Join(claudeDir, "only.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	// One JSONL → strict is safe to use it even without an id.
	if got := claudeFirstUserMessage(directory, "", true); got != "Only session here, unambiguous" {
		t.Errorf("strict single: got %q, want the lone session's message", got)
	}
}
