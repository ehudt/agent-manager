package sessions

import (
	"os"
	"path/filepath"
	"strings"
)

// GitHeadBranch mirrors lib/utils.sh:git_head_branch — a fork-free branch
// lookup. It walks up from dir to the nearest .git (a directory, or the
// pointer file a worktree/submodule carries) and reads HEAD. Returns the
// branch name, an 8-char sha for a detached HEAD, or "" when dir is missing
// or outside a repository.
func GitHeadBranch(dir string) string {
	if dir == "" {
		return ""
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return ""
	}
	gitDir := ""
	for cur := filepath.Clean(dir); ; {
		dotGit := filepath.Join(cur, ".git")
		if fi, err := os.Stat(dotGit); err == nil {
			if fi.IsDir() {
				gitDir = dotGit
				break
			}
			data, err := os.ReadFile(dotGit)
			if err != nil {
				return ""
			}
			line := firstLine(string(data))
			line = strings.TrimPrefix(line, "gitdir: ")
			if !filepath.IsAbs(line) {
				line = filepath.Join(cur, line)
			}
			gitDir = line
			break
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return ""
		}
		cur = parent
	}
	data, err := os.ReadFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	head := firstLine(string(data))
	if strings.HasPrefix(head, "ref: refs/heads/") {
		return strings.TrimPrefix(head, "ref: refs/heads/")
	}
	if isHexPrefix(head, 40) {
		return head[:8]
	}
	return ""
}

func firstLine(s string) string {
	return strings.TrimRight(strings.SplitN(s, "\n", 2)[0], "\r")
}

func isHexPrefix(s string, n int) bool {
	if len(s) < n {
		return false
	}
	for _, c := range s[:n] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
