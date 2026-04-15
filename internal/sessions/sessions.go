// Package sessions provides shared session list/registry logic
// used by both am-list-internal and am-browse.
package sessions

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

// TmuxSession holds parsed tmux list-sessions output.
type TmuxSession struct {
	Name     string
	Activity int64
}

// Entry combines tmux session + registry metadata + formatted display.
type Entry struct {
	TmuxSession
	Meta    Session
	Display string // formatted display string (without session_name| prefix)
}

// ListTmuxSessions runs tmux list-sessions and returns matching sessions.
func ListTmuxSessions(socket, prefix string) []TmuxSession {
	cmd := exec.Command("tmux", "-L", socket, "list-sessions", "-F", "#{session_name} #{session_activity}")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var sessions []TmuxSession
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
		sessions = append(sessions, TmuxSession{Name: name, Activity: activity})
	}
	return sessions
}

// ReadRegistry parses sessions.json, returning an empty registry on any error.
func ReadRegistry(path string) Registry {
	reg := Registry{Sessions: make(map[string]Session)}
	data, err := os.ReadFile(path)
	if err != nil {
		return reg
	}
	_ = json.Unmarshal(data, &reg)
	if reg.Sessions == nil {
		reg.Sessions = make(map[string]Session)
	}
	return reg
}

// FormatDisplay produces the display portion of a session line (no pipe prefix).
func FormatDisplay(s TmuxSession, meta Session, now int64) string {
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
	display.WriteString(FormatTimeAgo(now - s.Activity))
	display.WriteByte(')')

	return display.String()
}

// FormatLine produces one pipe-delimited output line: session_name|display
func FormatLine(s TmuxSession, meta Session, now int64) string {
	return s.Name + "|" + FormatDisplay(s, meta, now)
}

// FormatTimeAgo matches the bash inline time formatting exactly.
func FormatTimeAgo(idle int64) string {
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

// EnvOr returns the environment variable value or a default.
func EnvOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// HomeDir returns the user's home directory.
func HomeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}

// LoadEntries fetches tmux sessions, reads registry, and returns sorted entries
// ready for display. This is the main entry point for both binaries.
func LoadEntries() []Entry {
	socket := EnvOr("AM_TMUX_SOCKET", "agent-manager")
	amDir := EnvOr("AM_DIR", filepath.Join(HomeDir(), ".agent-manager"))
	prefix := EnvOr("AM_SESSION_PREFIX", "am-")

	sessions := ListTmuxSessions(socket, prefix)
	if len(sessions) == 0 {
		return nil
	}

	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].Activity > sessions[j].Activity
	})

	registry := ReadRegistry(filepath.Join(amDir, "sessions.json"))
	now := time.Now().Unix()

	entries := make([]Entry, len(sessions))
	for i, s := range sessions {
		meta := registry.Sessions[s.Name]
		entries[i] = Entry{
			TmuxSession: s,
			Meta:        meta,
			Display:     FormatDisplay(s, meta, now),
		}
	}
	return entries
}
