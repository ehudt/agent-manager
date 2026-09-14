package sessions

import (
	"os"
	"path/filepath"
	"strings"
)

// findGitDir walks up from dir to the nearest .git (a directory, or the
// pointer file a worktree/submodule carries) and returns its path. The path
// may lie outside dir for a pointer file. "" when dir is missing or outside a
// repository.
func findGitDir(dir string) string {
	if dir == "" {
		return ""
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return ""
	}
	for cur := filepath.Clean(dir); ; {
		dotGit := filepath.Join(cur, ".git")
		if fi, err := os.Stat(dotGit); err == nil {
			if fi.IsDir() {
				return dotGit
			}
			data, err := os.ReadFile(dotGit)
			if err != nil {
				return ""
			}
			line := strings.TrimPrefix(firstLine(string(data)), "gitdir: ")
			if !filepath.IsAbs(line) {
				line = filepath.Join(cur, line)
			}
			return line
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return ""
		}
		cur = parent
	}
}

// GitHeadBranch is the branch lookup behind `am-core branch`: a fork-free
// read of the nearest .git/HEAD. Returns the branch name, an 8-char sha for a
// detached HEAD, or "" when dir is missing or outside a repository.
func GitHeadBranch(dir string) string {
	gitDir := findGitDir(dir)
	if gitDir == "" {
		return ""
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

// HeadSignal is the hook's `.head` sidecar value: the raw HEAD line, plus the
// resolved commit sha when HEAD is a symbolic ref (a linked worktree resolves
// through commondir). Written by `am-core head-signal` and compared against
// the sidecar so a HEAD movement records exactly one review checkpoint. ""
// outside a repository or with no readable HEAD.
func HeadSignal(dir string) string {
	gitDir := findGitDir(dir)
	if gitDir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	head := firstLine(string(data))
	if head == "" {
		return ""
	}
	if strings.HasPrefix(head, "ref: ") {
		ref := strings.TrimPrefix(head, "ref: ")
		sha := readFirstLine(filepath.Join(gitDir, ref))
		if sha == "" {
			if common := readFirstLine(filepath.Join(gitDir, "commondir")); common != "" {
				if !filepath.IsAbs(common) {
					common = filepath.Join(gitDir, common)
				}
				sha = readFirstLine(filepath.Join(common, ref))
			}
		}
		head += " " + sha
	}
	return head
}

func readFirstLine(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return firstLine(string(data))
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