package sessions

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Sessions log (~/.agent-manager/sessions_log.jsonl): one JSON object per
// line, appended by bash sessions_log_append at launch and updated by field
// (last entry per session_name wins) from the restore scan, agent_kill, and
// `am restore`. Lines are kept verbatim unless a field changes, so metadata
// this version does not know about survives a rewrite. Every rewrite is
// temp-in-$AM_DIR + rename under the registry lock shared with bash
// (lib/registry.sh:_registry_lock), like the bash writers.

type slogLine struct {
	raw    string
	fields map[string]any // nil when the line is not a JSON object
	dirty  bool
}

func (l *slogLine) get(key string) string {
	if l.fields == nil {
		return ""
	}
	if s, ok := l.fields[key].(string); ok {
		return s
	}
	return ""
}

func (l *slogLine) set(key, value string) {
	if l.fields == nil {
		return
	}
	if cur, ok := l.fields[key].(string); ok && cur == value {
		return
	}
	l.fields[key] = value
	l.dirty = true
}

func (l *slogLine) encode() string {
	if !l.dirty {
		return l.raw
	}
	b, err := json.Marshal(l.fields)
	if err != nil {
		return l.raw
	}
	return string(b)
}

// readSlog parses the log; blank lines are dropped, malformed lines are kept
// opaque (fields == nil) so a rewrite never loses them.
func readSlog(path string) []slogLine {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var lines []slogLine
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		raw := sc.Text()
		if strings.TrimSpace(raw) == "" {
			continue
		}
		l := slogLine{raw: raw}
		var fields map[string]any
		if err := json.Unmarshal([]byte(raw), &fields); err == nil && fields != nil {
			l.fields = fields
		}
		lines = append(lines, l)
	}
	return lines
}

// writeSlog replaces the log atomically. The temp file lives in $AM_DIR under
// the .sessions-log.* name the GC temp sweep recognises, so a crash between
// create and rename is cleaned up like an interrupted bash writer.
func writeSlog(amDir, path string, lines []slogLine) error {
	tmp, err := os.CreateTemp(amDir, ".sessions-log.")
	if err != nil {
		return err
	}
	name := tmp.Name()
	w := bufio.NewWriter(tmp)
	for i := range lines {
		if _, err := w.WriteString(lines[i].encode()); err != nil {
			tmp.Close()
			os.Remove(name)
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			tmp.Close()
			os.Remove(name)
			return err
		}
	}
	if err := w.Flush(); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// slogUpdate is one pending field write for the last entry of a session.
type slogUpdate struct{ session, field, value string }

// applySlogUpdates mirrors N bash sessions_log_update calls in one locked
// rewrite: re-read the log under the lock, set each field on the last entry
// of its session, write once. No-op when nothing changes.
func (e Env) applySlogUpdates(updates []slogUpdate) {
	if len(updates) == 0 {
		return
	}
	if _, err := os.Stat(e.SessionsLog); err != nil {
		return
	}
	lock := lockRegistry(e.AmDir)
	defer unlockRegistry(lock)

	lines := readSlog(e.SessionsLog)
	last := make(map[string]int, len(lines))
	for i := range lines {
		if name := lines[i].get("session_name"); name != "" {
			last[name] = i
		}
	}
	changed := false
	for _, u := range updates {
		i, ok := last[u.session]
		if !ok {
			continue
		}
		lines[i].set(u.field, u.value)
		changed = changed || lines[i].dirty
	}
	if !changed {
		return
	}
	_ = writeSlog(e.AmDir, e.SessionsLog, lines)
}

// lastSlogEntries indexes the newest line per session_name.
func lastSlogEntries(lines []slogLine) map[string]*slogLine {
	out := make(map[string]*slogLine)
	for i := range lines {
		if name := lines[i].get("session_name"); name != "" {
			out[name] = &lines[i]
		}
	}
	return out
}

func isRestorableAgent(agent string) bool {
	switch agent {
	case "claude", "codex", "pi", "cursor":
		return true
	}
	return false
}

// snapshotRel is the log's snapshot_file form: "snapshots/<key>.txt".
func snapshotRel(key string) string { return filepath.ToSlash(filepath.Join("snapshots", key+".txt")) }
