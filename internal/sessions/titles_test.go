package sessions

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
		"✳ Fix the bug":        "Fix the bug",
		"⠐ Working on it":      "Working on it",
		">>> Clean up":         "Clean up",
		"already clean":        "already clean",
		"   spaces and stuff":  "spaces and stuff",
		"":                     "",
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

	got := claudeFirstUserMessage(directory)
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

	got := claudeFirstUserMessage(directory)
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

	got := claudeFirstUserMessage(directory)
	if got != "This is the real user task description" {
		t.Errorf("got %q, want non-short message", got)
	}
}

func TestClaudeFirstUserMessageMissingDir(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	if got := claudeFirstUserMessage("/nonexistent/dir/xyz"); got != "" {
		t.Errorf("got %q, want empty for missing dir", got)
	}
}
