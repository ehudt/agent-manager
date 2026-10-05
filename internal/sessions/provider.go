package sessions

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// DirSuggestion is one candidate a directory provider offers for a partial
// `@spec`: the spec (without its @) and a label for display.
type DirSuggestion struct {
	Spec  string
	Label string
}

// DirProviderSuggest runs `<provider> suggest <partial>` the way
// lib/agents.sh agent_dir_suggest does: `bash -c '<provider> "$@"' _ suggest
// <partial>` with AM_SESSION_NAME blanked (a provider that relabels the
// calling session must not retag a dispatcher), stdin closed, stderr
// dropped. The provider runs in its own process group and the whole group is
// killed at the timeout — killing only the top process leaves its children
// holding the pipe. Empty output (no provider, no match, timeout) is not an
// error; a timeout or a failing provider is one `suggest.fail` event.
func DirProviderSuggest(amDir, provider, partial string, timeout time.Duration) []DirSuggestion {
	if provider == "" {
		return nil
	}
	partial = strings.TrimPrefix(partial, "@")
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-c", provider+` "$@"`, "_", "suggest", partial)
	cmd.Env = append(os.Environ(), "AM_SESSION_NAME=")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 200 * time.Millisecond
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		rc := "1"
		if ctx.Err() != nil {
			rc = "124"
		} else if ee, ok := err.(*exec.ExitError); ok {
			rc = fmt.Sprint(ee.ExitCode())
		}
		EventLog(amDir, "suggest.fail", "-", "partial=@"+partial, "rc="+rc,
			fmt.Sprintf("timeout=%g", timeout.Seconds()))
		return nil
	}
	return ParseDirSuggestions(out.String())
}

// ParseDirSuggestions splits provider output into suggestions: one
// `<spec>\t<label>` per line, blank lines skipped, a line without a tab is a
// spec with no label.
func ParseDirSuggestions(text string) []DirSuggestion {
	var rows []DirSuggestion
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		spec, label, _ := strings.Cut(line, "\t")
		rows = append(rows, DirSuggestion{Spec: spec, Label: label})
	}
	return rows
}
