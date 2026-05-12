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
				fallback := claudeFirstUserMessage(meta.Directory)
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
// Returns the first user-message text (>10 chars) from the newest Claude
// JSONL for the given directory, with tags stripped and whitespace collapsed.
func claudeFirstUserMessage(directory string) string {
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	claudeDir := filepath.Join(homeDir(), ".claude", "projects", projectPath)

	entries, err := os.ReadDir(claudeDir)
	if err != nil {
		return ""
	}
	var newest string
	var newestMod time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if newest == "" || info.ModTime().After(newestMod) {
			newest = filepath.Join(claudeDir, e.Name())
			newestMod = info.ModTime()
		}
	}
	if newest == "" {
		return ""
	}

	f, err := os.Open(newest)
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

