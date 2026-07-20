package sessions

import (
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The registry lock must serialize read-modify-write cycles across
// concurrent holders. Bash writers contend on the same
// $AM_DIR/sessions.json.lock via flock(2), so lost updates here mean lost
// registry rows in production.
func TestRegistryLockSerializesWriters(t *testing.T) {
	amDir := t.TempDir()
	counterPath := filepath.Join(amDir, "counter")
	if err := os.WriteFile(counterPath, []byte("0"), 0o644); err != nil {
		t.Fatalf("seed counter: %v", err)
	}

	const n = 16
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			lock := lockRegistry(amDir)
			defer unlockRegistry(lock)
			b, err := os.ReadFile(counterPath)
			if err != nil {
				t.Errorf("read counter: %v", err)
				return
			}
			v, _ := strconv.Atoi(string(b))
			time.Sleep(time.Millisecond) // widen the race window
			if err := os.WriteFile(counterPath, []byte(strconv.Itoa(v+1)), 0o644); err != nil {
				t.Errorf("write counter: %v", err)
			}
		}()
	}
	wg.Wait()

	b, _ := os.ReadFile(counterPath)
	if got := string(b); got != strconv.Itoa(n) {
		t.Errorf("counter = %s, want %d (lost updates -> lock does not serialize)", got, n)
	}
}

// ReapOrphans must not rewrite sessions.json while another process (e.g. a
// bash registry_update) holds the registry lock. A separate open() of the
// lock file creates a separate open file description, so flock contends
// even within one test process.
func TestReapOrphansWaitsForRegistryLock(t *testing.T) {
	amDir := t.TempDir()
	stateDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	writeRegistry(t, regPath, "am-dead")

	holder, err := os.OpenFile(filepath.Join(amDir, "sessions.json.lock"), os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open lock file: %v", err)
	}
	if err := syscall.Flock(int(holder.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatalf("hold lock: %v", err)
	}

	done := make(chan int, 1)
	go func() { done <- reapOrphansAt(amDir, stateDir, nil, time.Now()) }()

	time.Sleep(150 * time.Millisecond)
	if names := readRegistryNames(t, regPath); len(names) != 1 {
		t.Errorf("registry rewritten while lock held, got %v", names)
	}

	_ = syscall.Flock(int(holder.Fd()), syscall.LOCK_UN)
	holder.Close()

	select {
	case removed := <-done:
		if removed != 1 {
			t.Errorf("removed = %d, want 1", removed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("reap did not complete after lock release")
	}
	if names := readRegistryNames(t, regPath); len(names) != 0 {
		t.Errorf("registry should be empty post-reap, got %v", names)
	}
}
