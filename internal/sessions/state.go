package sessions

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// PaneInfo holds the agent pane attributes needed for bulk state resolution.
type PaneInfo struct {
	PID     string
	Created int64
	Title   string
}

// ProcTree holds a point-in-time process table snapshot for shell-pane checks.
type ProcTree struct {
	Comm     map[string]string
	Children map[string][]string
}

// IsShell returns true when pid and all of its direct children are plain shells.
func (p ProcTree) IsShell(pid string) bool {
	if pid == "" || len(p.Comm) == 0 {
		return false
	}
	comm, ok := p.Comm[pid]
	if !ok || !isShellComm(comm) {
		return false
	}
	for _, child := range p.Children[pid] {
		if !isShellComm(p.Comm[child]) {
			return false
		}
	}
	return true
}

func isShellComm(comm string) bool {
	base := filepath.Base(strings.TrimSpace(comm))
	base = strings.TrimPrefix(base, "-")
	switch base {
	case "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh":
		return true
	}
	return false
}

// ListSessionPanes queries tmux once for the top untagged agent pane of each
// session matching prefix, skipping _amshell and _amreview windows.
func ListSessionPanes(socket, prefix string) map[string]PaneInfo {
	args := []string{}
	if socket != "" {
		args = append(args, "-L", socket)
	}
	args = append(args, "list-panes", "-a", "-F", "#{session_name}|#{pane_at_top}|#{window_name}|#{pane_pid}|#{@am_role}|#{session_created}|#{pane_title}")
	out, err := exec.Command("tmux", args...).Output()
	if err != nil {
		return nil
	}
	panes := make(map[string]PaneInfo)
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 7)
		if len(parts) < 7 {
			continue
		}
		sname, atTop, wname, pid, role, createdStr, title := parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
		if !strings.HasPrefix(sname, prefix) {
			continue
		}
		if wname == "_amshell" || wname == "_amreview" || role != "" || atTop != "1" {
			continue
		}
		if _, exists := panes[sname]; exists {
			continue
		}
		created, _ := strconv.ParseInt(createdStr, 10, 64)
		panes[sname] = PaneInfo{
			PID:     pid,
			Created: created,
			Title:   title,
		}
	}
	return panes
}

// SnapshotProcTree captures pid, ppid, and comm from ps in a single call.
func SnapshotProcTree() ProcTree {
	pt := ProcTree{
		Comm:     make(map[string]string),
		Children: make(map[string][]string),
	}
	out, err := exec.Command("ps", "-eo", "pid=,ppid=,comm=").Output()
	if err != nil {
		return pt
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, ppid := fields[0], fields[1]
		comm := strings.Join(fields[2:], " ")
		pt.Comm[pid] = comm
		pt.Children[ppid] = append(pt.Children[ppid], pid)
	}
	return pt
}

// ReadHookState reads the first line and mtime of $StateDir/<session>.
func ReadHookState(stateDir, session string) (string, int64) {
	if stateDir == "" || session == "" {
		return "", 0
	}
	p := filepath.Join(stateDir, session)
	st, err := os.Stat(p)
	if err != nil {
		return "", 0
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return "", 0
	}
	line := string(data)
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	line = strings.TrimSpace(line)
	switch line {
	case "running", "ready", "waiting_user", "background":
		return line, st.ModTime().Unix()
	}
	return "", 0
}

func fileExistsNonEmpty(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Size() > 0
}

func (e Env) hasIdentitySidecar(session string) bool {
	if e.StateDir != "" && fileExistsNonEmpty(filepath.Join(e.StateDir, session+".sid")) {
		return true
	}
	if e.IdentityDir != "" && fileExistsNonEmpty(filepath.Join(e.IdentityDir, session+".sid")) {
		return true
	}
	return false
}

func claudeTitleSignal(title string) string {
	for _, r := range title {
		if r == '✳' {
			return "attention"
		}
		if (r >= 0x2800 && r <= 0x28ff) || (r >= 0x25d0 && r <= 0x25d3) {
			return "busy"
		}
		break
	}
	return "none"
}

func cursorTitleSignal(title string) string {
	switch {
	case strings.HasSuffix(title, "✅ Ready"):
		return "ready"
	case strings.HasSuffix(title, "⏳ Working"):
		return "running"
	case strings.HasSuffix(title, "❓ Waiting for you"):
		return "waiting_user"
	}
	return "none"
}

// ResolveSessionState resolves a live session's canonical state and state-entry
// timestamp from bulk pane/process snapshots and the hook state file.
func ResolveSessionState(env Env, name string, meta Session, activity, now int64, panes map[string]PaneInfo, procs ProcTree) (string, int64) {
	raw, mtime := ReadHookState(env.StateDir, name)
	pane, hasPane := panes[name]

	if hasPane && pane.PID != "" && procs.IsShell(pane.PID) {
		if pane.Created > 0 && now-pane.Created < 5 {
			return "starting", 0
		}
		return "idle", 0
	}

	agentType := meta.AgentType
	if agentType == "" {
		agentType = "claude"
	}
	spec, _ := Agent(agentType)
	if hasPane {
		switch spec.TitleState {
		case "glyph":
			switch claudeTitleSignal(pane.Title) {
			case "busy":
				if raw == "waiting_user" {
					return "waiting_user", mtime
				}
				return "running", mtime
			case "attention":
				if raw == "" && !env.hasIdentitySidecar(name) {
					return "ready", 0
				}
			}
		case "suffix":
			if sig := cursorTitleSignal(pane.Title); sig != "none" {
				if sig == "running" && raw == "waiting_user" {
					return "waiting_user", mtime
				}
				if sig == "ready" && raw == "background" {
					return "background", mtime
				}
				return sig, mtime
			}
		}
	}

	if spec.TurnBoundary == "reliable" {
		if raw != "" {
			return raw, mtime
		}
		if len(panes) == 0 {
			return "", 0
		}
		return "unknown", 0
	}

	switch raw {
	case "ready", "waiting_user", "background":
		return raw, mtime
	case "running":
		ref := mtime
		if activity > ref {
			ref = activity
		}
		if now-ref <= 180 {
			return "running", mtime
		}
	}
	if len(panes) == 0 {
		return "", 0
	}
	return "unknown", 0
}

// EnrichActiveStates populates Entry.State and state-entry TimeAgo on active
// browser rows using one bulk tmux list-panes call, one ps snapshot, and the
// hook state files under env.StateDir.
func EnrichActiveStates(env Env, entries []Entry, nowUnix int64) {
	if len(entries) == 0 {
		return
	}
	panes := ListSessionPanes(env.Socket, env.Prefix)
	var procs ProcTree
	if len(panes) > 0 {
		procs = SnapshotProcTree()
	}
	for i := range entries {
		if entries[i].Kind != EntryActive {
			continue
		}
		state, stateMtime := ResolveSessionState(env, entries[i].Name, entries[i].Meta, entries[i].Activity, nowUnix, panes, procs)
		entries[i].State = state
		if (state == "waiting_user" || state == "ready" || state == "running" || state == "background") && stateMtime > 0 {
			entries[i].TimeAgo = FormatTimeAgo(nowUnix - stateMtime)
			entries[i].Display = entries[i].DisplayBase + " (" + entries[i].TimeAgo + ")"
		}
	}
}
