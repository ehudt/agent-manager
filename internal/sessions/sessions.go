// Package sessions provides shared session list/registry logic
// used by both am-list-internal and am-browse.
package sessions

import (
	"bufio"
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
	CreatedAt string `json:"created_at"`
}

// TmuxSession holds parsed tmux list-sessions output.
type TmuxSession struct {
	Name     string
	Activity int64
}

type EntryKind string

const (
	EntryActive   EntryKind = "active"
	EntryInactive EntryKind = "inactive"
)

// SessionLogEntry matches one JSONL row from sessions_log.jsonl.
type SessionLogEntry struct {
	SessionName  string `json:"session_name"`
	SessionID    string `json:"session_id"`
	Directory    string `json:"directory"`
	Branch       string `json:"branch"`
	AgentType    string `json:"agent_type"`
	Task         string `json:"task"`
	CreatedAt    string `json:"created_at"`
	ClosedAt     string `json:"closed_at"`
	SnapshotFile string `json:"snapshot_file"`
}

// Entry combines session metadata + formatted display for browser rows.
type Entry struct {
	TmuxSession
	Meta        Session
	Kind        EntryKind
	Display     string // formatted display string (without session_name| prefix)
	DisplayBase string // display without the trailing time-ago portion
	TimeAgo     string // e.g. "3m ago" — split out for right-alignment in TUI
	RecencyUnix int64  // unix recency key (active: tmux activity; inactive: closed_at)

	// Inactive restore rows.
	RestoreSessionID string
	SnapshotPath     string
}

// ListTmuxSessions runs tmux list-sessions and returns matching sessions.
func ListTmuxSessions(socket, prefix string) []TmuxSession {
	cmd := exec.Command("tmux", "-L", socket, "list-sessions", "-F", "#{session_name} #{session_activity}")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var sessions []TmuxSession
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
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
	return FormatDisplayBase(s, meta) + " (" + FormatTimeAgo(now-s.Activity) + ")"
}

// FormatDisplayBase produces the display string without the trailing time-ago portion.
func FormatDisplayBase(s TmuxSession, meta Session) string {
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

	return display.String()
}

// FormatRestorableDisplayBase produces the display string for a closed session
// without the trailing time-ago portion.
func FormatRestorableDisplayBase(log SessionLogEntry) string {
	var display strings.Builder
	if log.Directory != "" {
		display.WriteString(filepath.Base(log.Directory))
	} else if log.SessionID != "" {
		display.WriteString(log.SessionID)
	}
	if log.Branch != "" {
		display.WriteByte('/')
		display.WriteString(log.Branch)
	}

	display.WriteString(" [")
	if log.AgentType != "" {
		display.WriteString(log.AgentType)
	} else {
		display.WriteString("unknown")
	}
	display.WriteByte(']')

	if log.Task != "" {
		display.WriteByte(' ')
		display.WriteString(log.Task)
	}

	return display.String()
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

// LoadEntries fetches active tmux sessions, reads registry, and returns sorted
// entries ready for display. This is the main entry point for am-list-internal.
func LoadEntries() []Entry {
	socket := EnvOr("AM_TMUX_SOCKET", "agent-manager")
	amDir := EnvOr("AM_DIR", filepath.Join(HomeDir(), ".agent-manager"))
	prefix := EnvOr("AM_SESSION_PREFIX", "am-")

	tmuxSessions := ListTmuxSessions(socket, prefix)
	return loadActiveEntries(amDir, socket, tmuxSessions, time.Now())
}

// LoadBrowserEntries returns active sessions followed by restorable inactive
// Claude sessions for the interactive session switcher.
func LoadBrowserEntries() []Entry {
	socket := EnvOr("AM_TMUX_SOCKET", "agent-manager")
	amDir := EnvOr("AM_DIR", filepath.Join(HomeDir(), ".agent-manager"))
	prefix := EnvOr("AM_SESSION_PREFIX", "am-")
	home := HomeDir()

	tmuxSessions := ListTmuxSessions(socket, prefix)
	live := make(map[string]bool, len(tmuxSessions))
	for _, s := range tmuxSessions {
		live[s.Name] = true
	}

	now := time.Now()
	active := loadActiveEntries(amDir, socket, tmuxSessions, now)
	inactive := LoadRestorableEntries(amDir, home, live, now)
	return append(active, inactive...)
}

func loadActiveEntries(amDir, socket string, tmuxSessions []TmuxSession, now time.Time) []Entry {
	// Reap orphan registry rows + hook state files for tmux sessions that are
	// gone. Throttled (60s, shared with bash registry_gc via .gc_last) so it's
	// cheap on the hot fzf-reload path. Runs even when no live sessions remain
	// so the last orphan rows get cleaned up.
	stateDir := EnvOr("AM_STATE_DIR", "/tmp/am-state")
	ReapOrphans(amDir, stateDir, tmuxSessions)

	if len(tmuxSessions) == 0 {
		return nil
	}

	sort.Slice(tmuxSessions, func(i, j int) bool {
		return tmuxSessions[i].Activity > tmuxSessions[j].Activity
	})

	// Refresh registry task fields from pane titles (and Claude JSONL fallback)
	// before reading. Throttled to once per 60s via shared marker file, so this
	// is cheap on the hot fzf-reload path.
	RefreshTitles(amDir, socket, tmuxSessions)

	registry := ReadRegistry(filepath.Join(amDir, "sessions.json"))
	nowUnix := now.Unix()

	entries := make([]Entry, len(tmuxSessions))
	for i, s := range tmuxSessions {
		meta := registry.Sessions[s.Name]
		timeAgo := FormatTimeAgo(nowUnix - s.Activity)
		entries[i] = Entry{
			TmuxSession: s,
			Meta:        meta,
			Kind:        EntryActive,
			Display:     FormatDisplay(s, meta, nowUnix),
			DisplayBase: FormatDisplayBase(s, meta),
			TimeAgo:     timeAgo,
			RecencyUnix: s.Activity,
		}
	}
	return entries
}

// LoadRestorableEntries reads sessions_log.jsonl and returns closed Claude
// sessions that still have a backing Claude JSONL available for resume.
func LoadRestorableEntries(amDir, home string, liveSessions map[string]bool, now time.Time) []Entry {
	return restorableEntriesFromLog(
		ReadSessionLog(EnvOr("AM_SESSIONS_LOG", filepath.Join(amDir, "sessions_log.jsonl"))),
		amDir,
		home,
		liveSessions,
		now,
	)
}

// ReadSessionLog parses sessions_log.jsonl, skipping malformed lines.
func ReadSessionLog(path string) []SessionLogEntry {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	var entries []SessionLogEntry
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var entry SessionLogEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue
		}
		entries = append(entries, entry)
	}
	return entries
}

func restorableEntriesFromLog(logs []SessionLogEntry, amDir, home string, liveSessions map[string]bool, now time.Time) []Entry {
	if home == "" {
		home = HomeDir()
	}

	seenIDs := make(map[string]bool)
	var entries []Entry
	for i := len(logs) - 1; i >= 0; i-- {
		log := logs[i]
		if (log.AgentType != "claude" && log.AgentType != "pi") || log.SessionID == "" {
			continue
		}
		if liveSessions != nil && liveSessions[log.SessionName] {
			continue
		}
		if seenIDs[log.SessionID] {
			continue
		}
		exists := false
		if log.AgentType == "pi" {
			exists = piJSONLExists(home, log.Directory, log.SessionID)
		} else {
			exists = claudeJSONLExists(home, log.Directory, log.SessionID)
		}
		if !exists {
			continue
		}

		seenIDs[log.SessionID] = true
		base := FormatRestorableDisplayBase(log)
		ref := parseSessionLogTime(log.ClosedAt)
		if ref.IsZero() {
			ref = parseSessionLogTime(log.CreatedAt)
		}
		age := int64(0)
		recency := int64(0)
		if !ref.IsZero() {
			recency = ref.Unix()
			age = now.Unix() - recency
		}
		timeAgo := FormatTimeAgo(age)

		snapshotPath := ""
		if log.SnapshotFile != "" {
			candidate := filepath.Join(amDir, log.SnapshotFile)
			if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
				snapshotPath = candidate
			}
		}

		entries = append(entries, Entry{
			Meta: Session{
				Name:      log.SessionName,
				Directory: log.Directory,
				Branch:    log.Branch,
				AgentType: log.AgentType,
				Task:      log.Task,
			},
			Kind:             EntryInactive,
			Display:          base + " (" + timeAgo + ")",
			DisplayBase:      base,
			TimeAgo:          timeAgo,
			RecencyUnix:      recency,
			RestoreSessionID: log.SessionID,
			SnapshotPath:     snapshotPath,
		})
	}
	return entries
}

func parseSessionLogTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}
	}
	return t
}

func claudeJSONLExists(home, dir, sessionID string) bool {
	if home == "" || dir == "" || sessionID == "" {
		return false
	}
	projectDir := filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir))
	st, err := os.Stat(filepath.Join(projectDir, sessionID+".jsonl"))
	return err == nil && !st.IsDir()
}

func encodedClaudeProjectDir(dir string) string {
	resolved := dir
	if abs, err := filepath.Abs(dir); err == nil {
		if st, statErr := os.Stat(abs); statErr == nil && st.IsDir() {
			if realPath, evalErr := filepath.EvalSymlinks(abs); evalErr == nil {
				resolved = realPath
			} else {
				resolved = abs
			}
		}
	}
	return strings.NewReplacer("/", "-", ".", "-").Replace(resolved)
}

func piSessionsRoot(home string) string {
	if v := os.Getenv("AM_PI_SESSIONS_DIR"); v != "" {
		return v
	}
	return filepath.Join(home, ".pi", "agent", "sessions")
}

// encodedPiSessionDir mirrors pi's session-manager cwd encoding:
// "--" + path minus leading separator, with / \ : replaced by -, + "--".
// Dots are preserved (unlike Claude's encoding).
func encodedPiSessionDir(dir string) string {
	resolved := dir
	if abs, err := filepath.Abs(dir); err == nil {
		if st, statErr := os.Stat(abs); statErr == nil && st.IsDir() {
			if realPath, evalErr := filepath.EvalSymlinks(abs); evalErr == nil {
				resolved = realPath
			} else {
				resolved = abs
			}
		}
	}
	resolved = strings.TrimLeft(resolved, "/\\")
	return "--" + strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(resolved) + "--"
}

func piJSONLExists(home, dir, sessionID string) bool {
	if home == "" || dir == "" || sessionID == "" {
		return false
	}
	pattern := filepath.Join(piSessionsRoot(home), encodedPiSessionDir(dir), "*_"+sessionID+".jsonl")
	matches, err := filepath.Glob(pattern)
	return err == nil && len(matches) > 0
}
