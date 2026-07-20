package sessions

import (
	"os"
	"path/filepath"
	"syscall"
)

// lockRegistry acquires the exclusive registry write lock shared with the
// bash side (lib/registry.sh:_registry_lock): flock(2) on
// $AM_DIR/sessions.json.lock. Every read-modify-write of sessions.json must
// run under it — the rename in writeRegistryAtomic is atomic, but without
// the lock two overlapping writers start from the same snapshot and the
// last rename silently erases the other's change (lost update).
//
// Returns nil when the lock cannot be taken (proceed unlocked, mirroring
// the bash fallback); unlockRegistry accepts nil.
func lockRegistry(amDir string) *os.File {
	f, err := os.OpenFile(filepath.Join(amDir, "sessions.json.lock"), os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil
	}
	return f
}

func unlockRegistry(f *os.File) {
	if f == nil {
		return
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
}
