package sessions

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func mkdirs(t *testing.T, root string, dirs ...string) {
	t.Helper()
	for _, d := range dirs {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPathCompletions(t *testing.T) {
	root := t.TempDir()
	mkdirs(t, root, "alpha/one", "alpha/two", "alpha/.hidden", "beta")
	if err := os.WriteFile(filepath.Join(root, "alpha", "file.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	join := func(parts ...string) string { return filepath.Join(append([]string{root}, parts...)...) }

	// A directory lists its children (no files, no hidden entries).
	got := PathCompletions(join("alpha"), "")
	if want := []string{join("alpha", "one"), join("alpha", "two")}; strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("children = %v, want %v", got, want)
	}
	// A prefix completes against the parent.
	got = PathCompletions(join("al"), "")
	if len(got) != 1 || got[0] != join("alpha") {
		t.Errorf("prefix = %v", got)
	}
	// A dot prefix shows hidden entries.
	got = PathCompletions(join("alpha", ".h"), "")
	if len(got) != 1 || got[0] != join("alpha", ".hidden") {
		t.Errorf("hidden = %v", got)
	}
	// ~ expands against home.
	got = PathCompletions("~/be", root)
	if len(got) != 1 || got[0] != join("beta") {
		t.Errorf("~ = %v", got)
	}
	// Non-path queries and unreadable parents give nothing.
	if got := PathCompletions("alpha", root); got != nil {
		t.Errorf("plain word = %v", got)
	}
	if got := PathCompletions("/definitely/missing/x", ""); got != nil {
		t.Errorf("missing parent = %v", got)
	}
	if got := PathCompletions("", root); got != nil {
		t.Errorf("empty = %v", got)
	}
}

func TestRepoScan(t *testing.T) {
	home := t.TempDir()
	// .git up to three levels under a root (find -maxdepth 3 in the bash
	// twin): code/deep/c yes, code/deep/er/d no; other/ is not a scan root.
	mkdirs(t, home, "code/a/.git", "code/b/.git", "code/deep/c/.git", "code/deep/er/d/.git", "src/x/.git", "other/y/.git")
	got := RepoScan(home)
	want := map[string]bool{
		filepath.Join(home, "code", "a"):         true,
		filepath.Join(home, "code", "b"):         true,
		filepath.Join(home, "code", "deep", "c"): true,
		filepath.Join(home, "src", "x"):          true,
	}
	for _, p := range got {
		if !want[p] {
			t.Errorf("unexpected repo %q", p)
		}
		delete(want, p)
	}
	for p := range want {
		t.Errorf("missing repo %q", p)
	}
}

func TestRepoScanCached(t *testing.T) {
	home := t.TempDir()
	mkdirs(t, home, "code/a/.git")
	amDir := t.TempDir()
	cache := filepath.Join(amDir, ".dir_repo_cache")

	// Cold cache: nothing now, built in the background for the next open.
	if got := RepoScanCached(amDir, home); len(got) != 0 {
		t.Errorf("cold cache returned %v", got)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if data, err := os.ReadFile(cache); err == nil && strings.Contains(string(data), filepath.Join(home, "code", "a")) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("cache was not built")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Warm cache: served from the file.
	got := RepoScanCached(amDir, home)
	if len(got) != 1 || got[0] != filepath.Join(home, "code", "a") {
		t.Errorf("warm cache = %v", got)
	}
	// Stale cache: the old list is served while a refresh runs.
	if err := os.WriteFile(cache, []byte("/stale/entry\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AM_DIR_REPO_CACHE_TTL", "0")
	if got := RepoScanCached(amDir, home); len(got) != 1 || got[0] != "/stale/entry" {
		t.Errorf("stale cache = %v, want the old list", got)
	}
}

func TestFrecentDirsDedups(t *testing.T) {
	home := t.TempDir()
	amDir := t.TempDir()
	cwd, _ := os.Getwd()
	if err := os.WriteFile(filepath.Join(amDir, ".dir_repo_cache"), []byte(cwd+"\n/tmp/repo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir()) // no zoxide
	got := FrecentDirs(amDir, home)
	seen := map[string]int{}
	for _, p := range got {
		seen[p]++
	}
	if seen[cwd] != 1 || seen["/tmp/repo"] != 1 || got[0] != cwd {
		t.Errorf("FrecentDirs = %v", got)
	}
}
