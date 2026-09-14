package sessions

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestGitHeadBranch(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	if err := os.MkdirAll(filepath.Join(repo, "sub", "deep"), 0o755); err != nil {
		t.Fatal(err)
	}

	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "ref: refs/heads/feature/x\n")
	if got := GitHeadBranch(repo); got != "feature/x" {
		t.Errorf("branch: got %q, want feature/x", got)
	}
	if got := GitHeadBranch(filepath.Join(repo, "sub", "deep")); got != "feature/x" {
		t.Errorf("subdir walk-up: got %q, want feature/x", got)
	}

	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "0123456789abcdef0123456789abcdef01234567\n")
	if got := GitHeadBranch(repo); got != "01234567" {
		t.Errorf("detached: got %q, want 01234567", got)
	}

	// Worktree: .git is a pointer file.
	wt := filepath.Join(root, "wt")
	writeFile(t, filepath.Join(wt, ".git"), "gitdir: "+filepath.Join(repo, ".git", "worktrees", "wt")+"\n")
	writeFile(t, filepath.Join(repo, ".git", "worktrees", "wt", "HEAD"), "ref: refs/heads/wt-branch\n")
	if got := GitHeadBranch(wt); got != "wt-branch" {
		t.Errorf("worktree pointer: got %q, want wt-branch", got)
	}

	// Submodule: relative pointer.
	sm := filepath.Join(repo, "sub", "mod")
	writeFile(t, filepath.Join(sm, ".git"), "gitdir: ../../.git/modules/mod\n")
	writeFile(t, filepath.Join(repo, ".git", "modules", "mod", "HEAD"), "ref: refs/heads/sm-branch\n")
	if got := GitHeadBranch(sm); got != "sm-branch" {
		t.Errorf("relative pointer: got %q, want sm-branch", got)
	}

	plain := filepath.Join(root, "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := GitHeadBranch(plain); got != "" {
		t.Errorf("non-repo: got %q, want empty", got)
	}
	if got := GitHeadBranch(filepath.Join(root, "missing")); got != "" {
		t.Errorf("missing dir: got %q, want empty", got)
	}
	if got := GitHeadBranch(""); got != "" {
		t.Errorf("empty arg: got %q, want empty", got)
	}
}

func TestHeadSignal(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "ref: refs/heads/main\n")
	writeFile(t, filepath.Join(repo, ".git", "refs", "heads", "main"), "abcdef0123456789abcdef0123456789abcdef01\n")
	want := "ref: refs/heads/main abcdef0123456789abcdef0123456789abcdef01"
	if got := HeadSignal(repo); got != want {
		t.Errorf("symbolic: got %q, want %q", got, want)
	}

	// Linked worktree: the working-dir .git file points at the gitdir, whose
// commondir points back at the main repository for the ref.
	wt := filepath.Join(root, "wt")
	wtGitDir := filepath.Join(repo, ".git", "worktrees", "wt")
	writeFile(t, filepath.Join(wt, ".git"), "gitdir: "+wtGitDir+"\n")
	writeFile(t, filepath.Join(wtGitDir, "HEAD"), "ref: refs/heads/wt-branch\n")
	writeFile(t, filepath.Join(wtGitDir, "commondir"), "../..\n")
	writeFile(t, filepath.Join(repo, ".git", "refs", "heads", "wt-branch"), "1111111111111111111111111111111111111111\n")
	if got := HeadSignal(wt); got != "ref: refs/heads/wt-branch 1111111111111111111111111111111111111111" {
		t.Errorf("worktree commondir: got %q", got)
	}

	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "7777777777777777777777777777777777777777\n")
	if got := HeadSignal(repo); got != "7777777777777777777777777777777777777777" {
		t.Errorf("detached: got %q", got)
	}

	if got := HeadSignal(filepath.Join(root, "plain")); got != "" {
		t.Errorf("non-repo: got %q, want empty", got)
	}
}
