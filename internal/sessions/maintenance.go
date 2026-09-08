package sessions

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Periodic maintenance — the work behind `am-core tick`, called from the 5s
// status-bar tick and the `am list`/`am status` paths (through the bash
// wrappers auto_title_scan / sessions_log_scan / registry_gc). Each piece
// throttles on its own marker in $AM_DIR so the pieces cannot starve each
// other and the state hook can force a rescan by deleting a marker:
//
//	.title_scan_last   RefreshTitles (task / workdir / branch)
//	.restore_scan_last RestoreScan (snapshots, session-id binding, task/branch sync)
//	.gc_last           registry rows + hook state files of dead sessions
//	.gc_extras_last    sessions-log GC, unreferenced snapshots, orphan state files, leaked temps
//
// A forced run bypasses every marker and re-stamps it.

const (
	maintenanceThrottle = 60 * time.Second
	debugLogCap         = 20 * 1024 * 1024
	snapshotLines       = 50
	snapshotOrphanAge   = 10 * time.Minute
	tempSlogAge         = 60 * time.Second
	tempMiscAge         = time.Hour
	slogNoIDGrace       = 24 * time.Hour
)

// markerDue reports whether the throttle marker is older than the throttle
// window (or missing/unparseable). It never writes.
func markerDue(path string, now time.Time) bool {
	last, ok := readScanMarker(path)
	return !ok || now.Sub(last) >= maintenanceThrottle
}

func stampMarker(path string, now time.Time) error {
	return os.WriteFile(path, []byte(strconv.FormatInt(now.Unix(), 10)), 0o644)
}

// Tick is one status-bar tick: title/workdir refresh, restore scan, GC.
func (e Env) Tick(force bool) {
	e.TitleScan(force)
	e.GC(force)
}

// TitleScan backs the bash auto_title_scan wrapper: the title refresh, then the restore
// scan even when the title half was throttled (it has its own marker).
func (e Env) TitleScan(force bool) {
	RefreshTitles(e, force)
	e.RestoreScan(force)
}

// --- Titler trace log ---------------------------------------------------

func titlerEnabled() bool { return os.Getenv("AM_TITLER_DEBUG") == "1" }

// titlerLog appends one trace line, only when
// AM_TITLER_DEBUG=1 (ungated it wrote a line per 5s tick; 84MB observed).
func (e Env) titlerLog(format string, args ...any) {
	if !titlerEnabled() {
		return
	}
	f, err := os.OpenFile(filepath.Join(e.AmDir, "titler.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, args...))
}

// capDebugLogs keeps the opt-in trace logs bounded (20MB each, newest half
// kept). Called from the unthrottled title-scan path only.
func (e Env) capDebugLogs() {
	for _, name := range []string{"titler.log", ".state-debug.log", ".hook-debug.log"} {
		capLog(filepath.Join(e.AmDir, name), debugLogCap)
	}
}

// capLog bounds an append-only log: once the file exceeds max bytes,
// keep its last max/2 bytes minus the partial first line, via temp + rename.
// Never fails the caller.
func capLog(path string, max int64) {
	st, err := os.Stat(path)
	if err != nil || st.IsDir() || st.Size() <= max {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		return
	}
	keep := max / 2
	buf := make([]byte, keep)
	n, err := f.ReadAt(buf, st.Size()-keep)
	f.Close()
	if err != nil && n <= 0 {
		return
	}
	buf = buf[:n]
	if i := bytes.IndexByte(buf, '\n'); i >= 0 {
		buf = buf[i+1:]
	} else {
		buf = nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".")
	if err != nil {
		return
	}
	name := tmp.Name()
	if _, err := tmp.Write(buf); err != nil {
		tmp.Close()
		os.Remove(name)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
	}
}

// --- Restore scan --------------------------------------------------------

// RestoreScan backs the bash sessions_log_scan wrapper: for every live registry session
// of a resumable agent that has a sessions-log entry, bind the conversation
// id from the hook sidecar (authoritative — it corrects a wrong logged id and
// tracks forked resumes; with no sidecar there is no guess), capture a
// rolling pane snapshot keyed by that id (by session name until it is
// known), and sync task and branch into the log so the restore picker shows
// the branch the session ended on. Throttled on .restore_scan_last.
func (e Env) RestoreScan(force bool) {
	if _, err := os.Stat(e.SessionsLog); err != nil {
		return
	}
	now := time.Now()
	marker := filepath.Join(e.AmDir, ".restore_scan_last")
	if !force && !markerDue(marker, now) {
		return
	}
	_ = stampMarker(marker, now)

	registry := ReadRegistry(e.RegistryPath())
	entries := lastSlogEntries(readSlog(e.SessionsLog))

	names := make([]string, 0, len(registry.Sessions))
	for name, meta := range registry.Sessions {
		if !isRestorableAgent(meta.AgentType) {
			continue
		}
		if _, ok := entries[name]; !ok {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)

	var updates []slogUpdate
	snapCount := 0
	for _, name := range names {
		meta := registry.Sessions[name]
		entry := entries[name]
		sid := entry.get("session_id")
		transcript := entry.get("transcript_path")

		spec := agentSpec(meta.AgentType)
		if spec.Store == "cursor" {
			if sc := e.SidecarTranscript(name); sc != "" && sc != transcript {
				updates = append(updates, slogUpdate{name, "transcript_path", sc})
				transcript = sc
				e.titlerLog("  %s: bound transcript_path from sidecar", name)
			}
		}

		sidecar := ""
		if meta.Directory != "" {
			sidecar = e.SidecarID(name)
			if sidecar != "" && spec.HasStore() && !e.JSONLExists(meta.Directory, sidecar, meta.AgentType, transcript) {
				sidecar = ""
			}
		}
		if sidecar != "" && sidecar != sid {
			updates = append(updates, slogUpdate{name, "session_id", sidecar})
			e.titlerLog("  %s: session_id %s -> %s (sidecar)", name, orEmpty(sid), sidecar)
			sid = sidecar
		} else if sid == "" && meta.Directory != "" {
			if detected := e.DetectID(name, meta.Directory, meta.AgentType); detected != "" {
				updates = append(updates, slogUpdate{name, "session_id", detected})
				e.titlerLog("  %s: backfilled session_id=%s", name, detected)
				sid = detected
			}
		}

		// Re-key a snapshot still named after the session once the id is known.
		if sid != "" {
			old := filepath.Join(e.SnapshotsDir(), name+".txt")
			if st, err := os.Stat(old); err == nil && !st.IsDir() {
				if err := os.Rename(old, filepath.Join(e.SnapshotsDir(), sid+".txt")); err == nil {
					updates = append(updates, slogUpdate{name, "snapshot_file", snapshotRel(sid)})
				}
			}
		}

		key := sid
		if key == "" {
			key = name
		}
		if snap := e.writeSnapshot(name, key); snap != "" {
			if snap != entry.get("snapshot_file") {
				updates = append(updates, slogUpdate{name, "snapshot_file", snap})
			}
			snapCount++
		}
	}
	e.titlerLog("  snapshots captured: %d", snapCount)

	for _, name := range names {
		meta := registry.Sessions[name]
		if meta.Task != "" {
			updates = append(updates, slogUpdate{name, "task", meta.Task})
		}
		if meta.Branch != "" {
			updates = append(updates, slogUpdate{name, "branch", meta.Branch})
		}
	}
	e.applySlogUpdates(updates)
}

func orEmpty(s string) string {
	if s == "" {
		return "<empty>"
	}
	return s
}

// writeSnapshot mirrors bash sessions_log_snapshot: the last 50 lines of the
// agent pane, written to snapshots/<key>.txt. Returns the log-relative path,
// or "" when the pane yields nothing (session gone).
func (e Env) writeSnapshot(session, key string) string {
	out, err := exec.Command("tmux", "-L", e.Socket, "capture-pane", "-t", session+":.{top}",
		"-p", "-e", "-S", "-"+strconv.Itoa(snapshotLines), "-E", "-").Output()
	if err != nil {
		return ""
	}
	content := strings.TrimRight(string(out), "\n")
	if content == "" {
		return ""
	}
	if err := os.MkdirAll(e.SnapshotsDir(), 0o755); err != nil {
		return ""
	}
	rel := snapshotRel(key)
	if err := os.WriteFile(filepath.Join(e.AmDir, rel), []byte(content+"\n"), 0o644); err != nil {
		return ""
	}
	return rel
}

// --- GC -------------------------------------------------------------------

// GC backs the bash registry_gc wrapper: two independently throttled halves. Rows —
// registry entries and hook state files of sessions tmux no longer lists,
// one locked rewrite with the tmux snapshot taken inside the lock and a
// grace window for rows registered before their session exists
// (AM_GC_GRACE_SECS, default 5). Extras — orphan state files/sidecars, the
// sessions log, unreferenced snapshots, and leaked temp files. Returns the
// number of registry rows removed (0 when fully throttled).
func (e Env) GC(force bool) int {
	now := time.Now()
	rowsMarker := filepath.Join(e.AmDir, ".gc_last")
	extrasMarker := filepath.Join(e.AmDir, ".gc_extras_last")
	runRows, runExtras := true, true
	if !force {
		runRows = markerDue(rowsMarker, now)
		runExtras = markerDue(extrasMarker, now)
	}
	if !runRows && !runExtras {
		return 0
	}

	removed := 0
	var live map[string]struct{}
	if runRows {
		removed, live = reapOrphans(e.AmDir, e.StateDir, e.ListLive, now, force)
	}
	if runExtras {
		_ = stampMarker(extrasMarker, now)
		if live == nil {
			live = e.LiveSet()
		}
		e.sweepOrphanStateFiles(live)
		e.SessionsLogGC()
		e.SnapshotGC(now)
		e.sweepTemps(now)
	}
	if removed > 0 {
		fmt.Fprintf(os.Stderr, "info: Cleaned up %d stale registry entries\n", removed)
	}
	return removed
}

// sweepOrphanStateFiles removes hook state files and sidecars whose session
// (name with any .sid/.transcript/.cwd/.bg suffix stripped) is not live.
func (e Env) sweepOrphanStateFiles(live map[string]struct{}) {
	entries, err := os.ReadDir(e.StateDir)
	if err != nil {
		return
	}
	for _, de := range entries {
		if !de.Type().IsRegular() {
			continue
		}
		name := de.Name()
		if e.Prefix != "" && !strings.HasPrefix(name, e.Prefix) {
			continue
		}
		session := name
		for _, suffix := range []string{".sid", ".transcript", ".cwd", ".bg", ".dirty", ".head"} {
			session = strings.TrimSuffix(session, suffix)
		}
		if _, ok := live[session]; ok {
			continue
		}
		_ = os.Remove(filepath.Join(e.StateDir, name))
	}
}

// SessionsLogGC backs the bash sessions_log_gc wrapper: drop entries whose transcript
// no longer exists (and their snapshot), and id-less entries of resumable
// agents older than 24h (the id backfill never happened). Locked rewrite.
func (e Env) SessionsLogGC() int {
	if _, err := os.Stat(e.SessionsLog); err != nil {
		return 0
	}
	lock := lockRegistry(e.AmDir)
	defer unlockRegistry(lock)

	lines := readSlog(e.SessionsLog)
	cutoff := time.Now().UTC().Add(-slogNoIDGrace).Format("2006-01-02T15:04:05Z")
	kept := lines[:0]
	removed := 0
	for i := range lines {
		l := lines[i]
		keep := true
		agent := l.get("agent_type")
		sid := l.get("session_id")
		dir := l.get("directory")
		if isRestorableAgent(agent) && sid != "" && dir != "" {
			keep = e.JSONLExists(dir, sid, agent, l.get("transcript_path"))
		} else if isRestorableAgent(agent) && sid == "" {
			if created := l.get("created_at"); created != "" && created < cutoff {
				keep = false
			}
		}
		if keep {
			kept = append(kept, l)
			continue
		}
		if snap := l.get("snapshot_file"); snap != "" {
			_ = os.Remove(filepath.Join(e.AmDir, snap))
		}
		// The conversation is gone for good, so its review checkpoints
		// (refs/am/<session>/* in the repo) will never be diffed again.
		if name := l.get("session_name"); name != "" && dir != "" {
			ReviewDrop(dir, name)
		}
		removed++
	}
	if removed == 0 && len(kept) == len(lines) {
		return 0
	}
	if err := writeSlog(e.AmDir, e.SessionsLog, kept); err != nil {
		return 0
	}
	if removed > 0 {
		fmt.Fprintf(os.Stderr, "info: Sessions log: pruned %d stale entries\n", removed)
	}
	return removed
}

// SnapshotGC removes snapshots/*.txt
// that no log entry references and that are older than 10 minutes (the
// restore scan writes a snapshot before recording its name; live sessions
// rewrite theirs every scan).
func (e Env) SnapshotGC(now time.Time) int {
	dir := e.SnapshotsDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	referenced := make(map[string]struct{})
	for _, l := range readSlog(e.SessionsLog) {
		if snap := l.get("snapshot_file"); snap != "" {
			referenced[filepath.Base(snap)] = struct{}{}
		}
	}
	removed := 0
	for _, de := range entries {
		if !de.Type().IsRegular() || !strings.HasSuffix(de.Name(), ".txt") {
			continue
		}
		if _, ok := referenced[de.Name()]; ok {
			continue
		}
		info, err := de.Info()
		if err != nil || now.Sub(info.ModTime()) <= snapshotOrphanAge {
			continue
		}
		if os.Remove(filepath.Join(dir, de.Name())) == nil {
			removed++
		}
	}
	if removed > 0 {
		fmt.Fprintf(os.Stderr, "info: Snapshots: removed %d unreferenced files\n", removed)
	}
	return removed
}

// sweepTemps removes leftovers of interrupted writers in $AM_DIR: sessions-log
// temps older than 60s, detached repo-scan temps (.dir_repo_cache.tmp.*) and
// log-cap temps (<log>.XXXXXX) older than 1h.
func (e Env) sweepTemps(now time.Time) {
	entries, err := os.ReadDir(e.AmDir)
	if err != nil {
		return
	}
	for _, de := range entries {
		if !de.Type().IsRegular() {
			continue
		}
		name := de.Name()
		var maxAge time.Duration
		switch {
		case strings.HasPrefix(name, ".sessions-log."):
			maxAge = tempSlogAge
		case strings.HasPrefix(name, ".dir_repo_cache.tmp."):
			maxAge = tempMiscAge
		case isLogCapTemp(name):
			maxAge = tempMiscAge
		default:
			continue
		}
		info, err := de.Info()
		if err != nil || now.Sub(info.ModTime()) <= maxAge {
			continue
		}
		_ = os.Remove(filepath.Join(e.AmDir, name))
	}
}

// isLogCapTemp matches the shell glob `*.log.??????`.
func isLogCapTemp(name string) bool {
	i := strings.LastIndex(name, ".log.")
	if i < 0 {
		return false
	}
	return len(name)-(i+len(".log.")) == 6
}

// --- Restore picker ------------------------------------------------------

// Restorable backs the bash sessions_log_restorable wrapper: the raw JSONL lines of
// sessions that can be resumed — resumable agent, id known, not live in
// tmux, transcript still present — newest first, one line per conversation
// id.
func (e Env) Restorable() []string {
	lines := readSlog(e.SessionsLog)
	if len(lines) == 0 {
		return nil
	}
	live := e.LiveSet()
	seen := make(map[string]struct{})
	var out []string
	for i := len(lines) - 1; i >= 0; i-- {
		l := lines[i]
		agent := l.get("agent_type")
		sid := l.get("session_id")
		if !isRestorableAgent(agent) || sid == "" {
			continue
		}
		if _, ok := live[l.get("session_name")]; ok {
			continue
		}
		if _, ok := seen[sid]; ok {
			continue
		}
		if !e.JSONLExists(l.get("directory"), sid, agent, l.get("transcript_path")) {
			continue
		}
		seen[sid] = struct{}{}
		out = append(out, l.raw)
	}
	return out
}
