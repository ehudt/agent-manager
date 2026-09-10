package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Hunk-to-prompt: `c` on a hunk opens a one-line note; Enter sends the note
// with the file, the new-side line range, and the hunk itself to the
// session's agent through `am send`, mid-turn included (the harness steers
// on it or queues it). am refuses only while a dialog is up or the agent is
// still starting (exit 4); the pane then falls back to `am send --queue`,
// which delivers when the agent is ready. An idle
// or dead session (exit 2) has no agent to talk to and is reported as such.

// noteHunkLimit caps the hunk lines quoted in the prompt.
const noteHunkLimit = 80

// noteMessage renders the prompt sent to the agent.
func noteMessage(path, lineRange, hunkText, note string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Review note on %s", path)
	if lineRange != "" {
		fmt.Fprintf(&b, " %s", lineRange)
	}
	b.WriteString(":\n")
	b.WriteString(strings.TrimSpace(note))
	b.WriteString("\n")
	if hunkText != "" {
		b.WriteString("\n```diff\n")
		b.WriteString(strings.TrimRight(hunkText, "\n"))
		b.WriteString("\n```\n")
	}
	return b.String()
}

// sendResult is what happened to a note.
type sendResult struct {
	queued bool // a dialog was up (or the agent starting); a helper delivers when it is ready
}

// sendNote delivers text to session through am. The prompt travels on stdin
// so its length and content never meet argv or a shell.
func sendNote(amPath, session, text string) (sendResult, error) {
	if amPath == "" {
		return sendResult{}, errors.New("am not available (pane started without --am)")
	}
	run := func(args ...string) (int, string) {
		cmd := exec.Command(amPath, args...)
		cmd.Env = os.Environ()
		cmd.Stdin = strings.NewReader(text)
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		err := cmd.Run()
		code := 0
		if err != nil {
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				code = ee.ExitCode()
			} else {
				return -1, err.Error()
			}
		}
		return code, strings.TrimSpace(out.String())
	}
	code, out := run("send", session)
	switch code {
	case 0:
		return sendResult{}, nil
	case 4:
		if qcode, qout := run("send", "--queue", session); qcode != 0 {
			return sendResult{}, fmt.Errorf("queue failed: %s", lastLine(qout))
		}
		return sendResult{queued: true}, nil
	case 2:
		return sendResult{}, errors.New("no running agent in this session")
	default:
		return sendResult{}, fmt.Errorf("am send: %s", lastLine(out))
	}
}

// lastLine is the final non-empty line of s (am's error is its last line).
func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return s
}
