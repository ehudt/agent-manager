package sessions

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const defaultGCGraceSecs = 5

// ReapOrphans removes registry entries whose tmux session is no longer alive
// and deletes their hook state file and identity sidecars. Throttled once per
// 60s via $amDir/.gc_last. The sessions log is not touched here — the extras
// half of Env.GC handles it on its own marker (.gc_extras_last).
//
// listLive is called *inside* the registry lock: agent_launch creates the
// tmux session before registry_add (which takes this lock), so a row that
// exists while we hold the lock always has its session in a snapshot taken
// now. Rows younger than AM_GC_GRACE_SECS (default 5) are left alone as
// well, for any writer that registers before its session exists.
//
// Returns the number of registry rows removed.
func ReapOrphans(amDir, stateDir string, listLive func() []TmuxSession) int {
	removed, _ := reapOrphans(amDir, stateDir, listLive, time.Now(), false)
	return removed
}

// reapOrphans is ReapOrphans with an injectable clock and a force switch that
// bypasses the marker. It also returns the live set it observed (nil when it
// did not run) so a caller can reuse it.
func reapOrphans(amDir, stateDir string, listLive func() []TmuxSession, now time.Time, force bool) (int, map[string]struct{}) {
	markerPath := filepath.Join(amDir, ".gc_last")
	if !force && !markerDue(markerPath, now) {
		return 0, nil
	}
	if err := stampMarker(markerPath, now); err != nil {
		return 0, nil
	}

	// One locked read-modify-write on sessions.json (lock shared with bash
	// registry_add/update/remove), tmux snapshot inside it.
	lock := lockRegistry(amDir)
	defer unlockRegistry(lock)

	liveSet := make(map[string]struct{})
	if listLive != nil {
		for _, s := range listLive() {
			liveSet[s.Name] = struct{}{}
		}
	}

	regPath := filepath.Join(amDir, "sessions.json")
	registry := ReadRegistry(regPath)
	if len(registry.Sessions) == 0 {
		return 0, liveSet
	}

	cutoff := now.Add(-gcGrace())
	var removed int
	for name, meta := range registry.Sessions {
		if _, ok := liveSet[name]; ok {
			continue
		}
		if created, err := time.Parse(time.RFC3339, meta.CreatedAt); err == nil && !created.Before(cutoff) {
			continue
		}
		delete(registry.Sessions, name)
		if stateDir != "" && isSafeSessionName(name) {
			_ = os.Remove(filepath.Join(stateDir, name))
			_ = os.Remove(filepath.Join(stateDir, name+".sid"))
			_ = os.Remove(filepath.Join(stateDir, name+".transcript"))
			_ = os.Remove(filepath.Join(stateDir, name+".cwd"))
			_ = os.Remove(filepath.Join(stateDir, name+".bg"))
		}
		removed++
	}

	if removed == 0 {
		return 0, liveSet
	}
	writeRegistryAtomic(regPath, registry)
	return removed, liveSet
}

// gcGrace is AM_GC_GRACE_SECS (default 5s).
func gcGrace() time.Duration {
	if v := os.Getenv("AM_GC_GRACE_SECS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return time.Duration(n) * time.Second
		}
	}
	return defaultGCGraceSecs * time.Second
}

// isSafeSessionName guards the state-file remove against path traversal in
// case a registry key was tampered with.
func isSafeSessionName(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	if strings.ContainsAny(name, "/\\") {
		return false
	}
	return true
}
