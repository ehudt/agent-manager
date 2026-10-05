package sessions

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Directory candidates for the new-session form's Directory field: the Go
// twin of lib/fzf.sh's _list_directories without branch annotations.

// repoScanRoots are the trees RepoScan searches for git repositories, under
// $HOME (lib/fzf.sh _dir_repo_scan).
var repoScanRoots = []string{"code", "projects", "src", "dev", "work"}

// FrecentDirs is the launch-time candidate list: the working directory,
// zoxide's ranking (top 30), and the cached repository scan, deduplicated in
// that order. Loaded once per form; the form filters it as the user types.
func FrecentDirs(amDir, home string) []string {
	var paths []string
	if cwd, err := os.Getwd(); err == nil {
		paths = append(paths, cwd)
	}
	if zoxide, err := exec.LookPath("zoxide"); err == nil {
		cmd := exec.Command(zoxide, "query", "-l")
		if out, err := cmd.Output(); err == nil {
			for i, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
				if i >= 30 {
					break
				}
				if line != "" {
					paths = append(paths, line)
				}
			}
		}
	}
	paths = append(paths, RepoScanCached(amDir, home)...)
	return dedupStrings(paths)
}

// RepoScanCached serves the repository list from $AM_DIR/.dir_repo_cache
// (one path per line) and refreshes it in the background when older than
// $AM_DIR_REPO_CACHE_TTL seconds (default 1h). A cold cache yields nothing —
// zoxide still fills the list — and is built for the next open. The bash
// _dir_repo_scan_cached reads and writes the same file.
func RepoScanCached(amDir, home string) []string {
	cache := filepath.Join(amDir, ".dir_repo_cache")
	ttl := time.Hour
	if v := os.Getenv("AM_DIR_REPO_CACHE_TTL"); v != "" {
		if d, err := time.ParseDuration(v + "s"); err == nil {
			ttl = d
		}
	}
	var paths []string
	fresh := false
	if data, err := os.ReadFile(cache); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
			if line != "" {
				paths = append(paths, line)
			}
		}
		if st, err := os.Stat(cache); err == nil && time.Since(st.ModTime()) < ttl {
			fresh = true
		}
	}
	if !fresh {
		go func() {
			found := RepoScan(home)
			tmp := fmt.Sprintf("%s.tmp.%d", cache, os.Getpid())
			if err := os.WriteFile(tmp, []byte(strings.Join(found, "\n")+"\n"), 0o644); err == nil {
				_ = os.Rename(tmp, cache)
			}
		}()
	}
	return paths
}

// RepoScan finds git repositories up to three levels under the scan roots,
// at most 20 per root (lib/fzf.sh _dir_repo_scan). Slow on large trees;
// callers go through RepoScanCached.
func RepoScan(home string) []string {
	var found []string
	for _, root := range repoScanRoots {
		dir := filepath.Join(home, root)
		if st, err := os.Stat(dir); err != nil || !st.IsDir() {
			continue
		}
		n := 0
		var walk func(path string, depth int)
		walk = func(path string, depth int) {
			if n >= 20 || depth > 3 {
				return
			}
			entries, err := os.ReadDir(path)
			if err != nil {
				return
			}
			for _, e := range entries {
				if !e.IsDir() {
					continue
				}
				if e.Name() == ".git" {
					found = append(found, path)
					n++
					if n >= 20 {
						return
					}
					continue
				}
				walk(filepath.Join(path, e.Name()), depth+1)
			}
		}
		walk(dir, 1)
	}
	return found
}

// PathCompletions lists directories for a path-like query (starting with
// `/`, `~` or `.`): the children of the directory it names, or the entries
// of its parent whose names start with its last component. Hidden entries
// are listed only when that component starts with a dot. Empty for any
// other query.
func PathCompletions(query, home string) []string {
	if query == "" {
		return nil
	}
	switch query[0] {
	case '/', '~', '.':
	default:
		return nil
	}
	base := query
	if strings.HasPrefix(base, "~") {
		base = home + base[1:]
	}
	var parent, prefix string
	if st, err := os.Stat(base); err == nil && st.IsDir() {
		parent, prefix = base, ""
	} else {
		parent, prefix = filepath.Dir(base), filepath.Base(base)
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() {
			if info, err := os.Stat(filepath.Join(parent, name)); err != nil || !info.IsDir() {
				continue
			}
		}
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		if strings.HasPrefix(name, ".") && !strings.HasPrefix(prefix, ".") {
			continue
		}
		out = append(out, filepath.Join(parent, name))
	}
	sort.Strings(out)
	return out
}

// dedupStrings keeps the first occurrence of each string, in order.
func dedupStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}
