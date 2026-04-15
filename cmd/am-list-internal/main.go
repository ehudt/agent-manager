package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Registry matches the sessions.json structure.
type Registry struct {
	Sessions map[string]Session `json:"sessions"`
}

// Session holds per-session metadata from the registry.
type Session struct {
	Name      string `json:"name"`
	Directory string `json:"directory"`
	Branch    string `json:"branch"`
	AgentType string `json:"agent_type"`
	Task      string `json:"task"`
}

// tmuxSession holds parsed tmux list-sessions output.
type tmuxSession struct {
	Name     string
	Activity int64
}

func main() {
	socket := envOr("AM_TMUX_SOCKET", "agent-manager")
	amDir := envOr("AM_DIR", filepath.Join(homeDir(), ".agent-manager"))
	prefix := envOr("AM_SESSION_PREFIX", "am-")

	// 1. Get tmux sessions
	sessions := listTmuxSessions(socket, prefix)
	if len(sessions) == 0 {
		return
	}

	// 2. Sort by activity descending (most recent first)
	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].Activity > sessions[j].Activity
	})

	// 3. Read registry
	registry := readRegistry(filepath.Join(amDir, "sessions.json"))

	// 4. Format and output
	now := time.Now().Unix()
	for _, s := range sessions {
		meta := registry.Sessions[s.Name]
		line := formatLine(s, meta, now)
		fmt.Println(line)
	}
}

// listTmuxSessions runs tmux list-sessions and returns matching sessions.
func listTmuxSessions(socket, prefix string) []tmuxSession {
	cmd := exec.Command("tmux", "-L", socket, "list-sessions", "-F", "#{session_name} #{session_activity}")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var sessions []tmuxSession
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		if len(parts) != 2 {
			continue
		}
		name := parts[0]
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		activity, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			continue
		}
		sessions = append(sessions, tmuxSession{Name: name, Activity: activity})
	}
	return sessions
}

// readRegistry parses sessions.json, returning an empty registry on any error.
func readRegistry(path string) Registry {
	reg := Registry{Sessions: make(map[string]Session)}
	data, err := os.ReadFile(path)
	if err != nil {
		return reg
	}
	// Ignore parse errors — return empty registry
	_ = json.Unmarshal(data, &reg)
	if reg.Sessions == nil {
		reg.Sessions = make(map[string]Session)
	}
	return reg
}

// formatLine produces one output line matching the bash _fzf_list_display format.
func formatLine(s tmuxSession, meta Session, now int64) string {
	var display strings.Builder
	display.WriteString(s.Name)

	if meta.Directory != "" {
		display.WriteByte(' ')
		display.WriteString(filepath.Base(meta.Directory))
	}
	if meta.Branch != "" {
		display.WriteByte('/')
		display.WriteString(meta.Branch)
	}

	display.WriteString(" [")
	if meta.AgentType != "" {
		display.WriteString(meta.AgentType)
	} else {
		display.WriteString("unknown")
	}
	display.WriteByte(']')

	if meta.Task != "" {
		display.WriteByte(' ')
		display.WriteString(meta.Task)
	}

	display.WriteString(" (")
	display.WriteString(formatTimeAgo(now - s.Activity))
	display.WriteByte(')')

	return s.Name + "|" + display.String()
}

// formatTimeAgo matches the bash inline time formatting exactly.
func formatTimeAgo(idle int64) string {
	if idle < 0 {
		return "just now"
	}
	if idle < 60 {
		return fmt.Sprintf("%ds ago", idle)
	}
	if idle < 3600 {
		return fmt.Sprintf("%dm ago", idle/60)
	}
	if idle < 86400 {
		h := idle / 3600
		m := (idle % 3600) / 60
		if m == 0 {
			return fmt.Sprintf("%dh ago", h)
		}
		return fmt.Sprintf("%dh %dm ago", h, m)
	}
	return fmt.Sprintf("%dd ago", idle/86400)
}

// envOr returns the environment variable value or a default.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// homeDir returns the user's home directory.
func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	// Fallback (shouldn't happen on macOS/Linux)
	h, _ := os.UserHomeDir()
	return h
}
