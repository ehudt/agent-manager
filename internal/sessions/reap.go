package sessions

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const reapThrottle = 60 * time.Second

// ReapOrphans removes registry entries whose tmux session is no longer alive
// and deletes their hook state file and .sid sidecar. Throttled to once per
// 60s via $amDir/.gc_last (shared with the rows half of bash registry_gc so
// they coordinate). Sandbox containers and the sessions log are not touched
// here — the bash-only extras half of registry_gc handles those on its own
// marker (.gc_extras_last).
//
// Returns the number of registry rows removed.
func ReapOrphans(amDir, stateDir string, live []TmuxSession) int {
	return reapOrphansAt(amDir, stateDir, live, time.Now())
}

func reapOrphansAt(amDir, stateDir string, live []TmuxSession, now time.Time) int {
	markerPath := filepath.Join(amDir, ".gc_last")
	if last, ok := readScanMarker(markerPath); ok {
		if now.Sub(last) < reapThrottle {
			return 0
		}
	}
	if err := os.WriteFile(markerPath, []byte(strconv.FormatInt(now.Unix(), 10)), 0o644); err != nil {
		return 0
	}

	// Read-modify-write on sessions.json: hold the registry lock so a
	// concurrent bash registry_add/update/remove is not clobbered.
	lock := lockRegistry(amDir)
	defer unlockRegistry(lock)

	regPath := filepath.Join(amDir, "sessions.json")
	registry := ReadRegistry(regPath)
	if len(registry.Sessions) == 0 {
		return 0
	}

	liveSet := make(map[string]struct{}, len(live))
	for _, s := range live {
		liveSet[s.Name] = struct{}{}
	}

	var removed int
	for name := range registry.Sessions {
		if _, ok := liveSet[name]; ok {
			continue
		}
		delete(registry.Sessions, name)
		if stateDir != "" && isSafeSessionName(name) {
			_ = os.Remove(filepath.Join(stateDir, name))
			_ = os.Remove(filepath.Join(stateDir, name+".sid"))
		}
		removed++
	}

	if removed == 0 {
		return 0
	}
	writeRegistryAtomic(regPath, registry)
	return removed
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
