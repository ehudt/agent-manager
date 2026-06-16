package sessions

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const titleScanThrottle = 60 * time.Second
const titleMaxLen = 60

var leadingNonAlnum = regexp.MustCompile(`^[^[:alnum:]]+`)

// RefreshTitles updates the registry task field for each live tmux session.
// Reads the agent pane title; for Claude sessions, falls back to the first
// user message in the Claude JSONL when the pane title is empty/invalid.
// Throttled to once per 60s via $AM_DIR/.title_scan_last (shared with the
// bash auto_title_scan to avoid concurrent writes).
func RefreshTitles(amDir, socket string, sessions []TmuxSession) {
	if len(sessions) == 0 {
		return
	}

	markerPath := filepath.Join(amDir, ".title_scan_last")
	now := time.Now()
	if last, ok := readScanMarker(markerPath); ok {
		if now.Sub(last) < titleScanThrottle {
			return
		}
	}
	if err := os.WriteFile(markerPath, []byte(strconv.FormatInt(now.Unix(), 10)), 0o644); err != nil {
		return
	}

	regPath := filepath.Join(amDir, "sessions.json")
	registry := ReadRegistry(regPath)
	if len(registry.Sessions) == 0 {
		return
	}

	home := homeDir()
	stateDir := EnvOr("AM_STATE_DIR", "/tmp/am-state")

	var updated bool
	for _, s := range sessions {
		meta, ok := registry.Sessions[s.Name]
		if !ok {
			continue
		}

		title := readPaneTitle(socket, s.Name+":.{top}")
		title = leadingNonAlnum.ReplaceAllString(title, "")
		if !titleValid(title) {
			if meta.AgentType == "claude" && meta.Directory != "" {
				// Resolve THIS session's Claude id so two sessions sharing
				// one directory don't both inherit the newest JSONL's first
				// message as their title.
				sid := resolveClaudeSessionID(home, stateDir, s.Name, meta.Directory, meta.CreatedAt)
				// strict: when the id can't be pinned, don't guess from a
				// directory with multiple JSONLs (would inherit a sibling's task).
				fallback := claudeFirstUserMessage(meta.Directory, sid, true)
				if len(fallback) > titleMaxLen {
					fallback = fallback[:titleMaxLen]
				}
				if titleValid(fallback) {
					title = fallback
				} else {
					continue
				}
			} else {
				continue
			}
		}

		if title == meta.Task {
			continue
		}
		meta.Task = title
		registry.Sessions[s.Name] = meta
		updated = true
	}

	if !updated {
		return
	}
	writeRegistryAtomic(regPath, registry)
}

func readScanMarker(path string) (time.Time, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}, false
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(ts, 0), true
}

func readPaneTitle(socket, target string) string {
	cmd := exec.Command("tmux", "-L", socket, "display-message", "-p", "-t", target, "#{pane_title}")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

func titleValid(t string) bool {
	if t == "" || len(t) > titleMaxLen {
		return false
	}
	return !strings.ContainsRune(t, '\n')
}

func writeRegistryAtomic(path string, reg Registry) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".sessions.*.json.tmp")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(reg); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return
	}
	_ = os.Rename(tmpName, path)
}

// claudeFirstUserMessage mirrors lib/utils.sh:claude_first_user_message.
// Returns the first user-message text (>10 chars) from a Claude JSONL for the
// given directory, with tags stripped and whitespace collapsed. When sessionID
// is given and its JSONL exists, that exact file is read (disambiguating
// multiple sessions in one directory); otherwise the newest JSONL is used.
func claudeFirstUserMessage(directory, sessionID string, strict bool) string {
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(homeDir(), ".claude", "projects", projectPath)

	var target string
	if sessionID != "" {
		cand := filepath.Join(claudeDir, sessionID+".jsonl")
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			target = cand
		}
	}

	if target == "" {
		entries, err := os.ReadDir(claudeDir)
		if err != nil {
			return ""
		}
		var jsonls []os.DirEntry
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".jsonl") {
				jsonls = append(jsonls, e)
			}
		}
		// strict: only fall back when there's exactly one JSONL — otherwise
		// it's ambiguous which belongs to this session.
		if strict && len(jsonls) != 1 {
			return ""
		}
		var newestMod time.Time
		for _, e := range jsonls {
			info, err := e.Info()
			if err != nil {
				continue
			}
			if target == "" || info.ModTime().After(newestMod) {
				target = filepath.Join(claudeDir, e.Name())
				newestMod = info.ModTime()
			}
		}
	}
	if target == "" {
		return ""
	}

	f, err := os.Open(target)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	count := 0
	for scanner.Scan() && count < 10 {
		line := scanner.Bytes()
		if !strings.Contains(string(line), `"type":"user"`) {
			continue
		}
		count++
		var rec struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		text := extractContent(rec.Message.Content)
		text = cleanContent(text)
		if len(text) > 10 {
			return text
		}
	}
	return ""
}

func extractContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var arr []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &arr); err == nil {
		var parts []string
		for _, p := range arr {
			if p.Type == "text" && p.Text != "" {
				parts = append(parts, p.Text)
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

var tagRe = regexp.MustCompile(`<[^>]*>[^<]*</[^>]*>|<[^>]*>`)

func cleanContent(s string) string {
	s = tagRe.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimSpace(s)
}

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}

var validSessionID = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// resolveClaudeSessionID mirrors lib/registry.sh:_sessions_log_detect_id_for_session.
// Prefers the hook-written .sid sidecar (authored by the agent pane itself);
// falls back to the newest directory JSONL whose mtime is at or after the am
// session's creation time. Older same-directory JSONLs belong to prior
// sessions, so they're skipped. Returns "" when nothing matches (caller then
// falls back to the newest JSONL).
func resolveClaudeSessionID(home, stateDir, sessionName, dir, createdAt string) string {
	sidPath := filepath.Join(stateDir, sessionName+".sid")
	if b, err := os.ReadFile(sidPath); err == nil {
		sid := strings.TrimSpace(string(b))
		if validSessionID.MatchString(sid) && claudeJSONLExists(home, dir, sid) {
			return sid
		}
		// Sidecar present but stale/invalid: do not guess from mtime.
		return ""
	}

	projectDir := filepath.Join(home, ".claude", "projects", encodedClaudeProjectDir(dir))
	entries, err := os.ReadDir(projectDir)
	if err != nil {
		return ""
	}
	minTime := parseSessionLogTime(createdAt)
	var best string
	var bestMod time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if !minTime.IsZero() && info.ModTime().Before(minTime) {
			continue
		}
		sid := strings.TrimSuffix(e.Name(), ".jsonl")
		if !validSessionID.MatchString(sid) {
			continue
		}
		if best == "" || info.ModTime().After(bestMod) {
			best = sid
			bestMod = info.ModTime()
		}
	}
	return best
}
