package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func writeRegistry(t *testing.T, path string, names ...string) {
	t.Helper()
	reg := Registry{Sessions: map[string]Session{}}
	for _, n := range names {
		reg.Sessions[n] = Session{Name: n, Directory: "/tmp/x", AgentType: "claude"}
	}
	data, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func readRegistryNames(t *testing.T, path string) []string {
	t.Helper()
	reg := ReadRegistry(path)
	names := make([]string, 0, len(reg.Sessions))
	for n := range reg.Sessions {
		names = append(names, n)
	}
	return names
}

func TestReapOrphansRemovesDeadAndKeepsLive(t *testing.T) {
	amDir := t.TempDir()
	stateDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	writeRegistry(t, regPath, "am-live", "am-dead1", "am-dead2")

	// Seed hook state files and .sid sidecars for all three; dead ones should
	// be removed.
	for _, n := range []string{"am-live", "am-dead1", "am-dead2"} {
		if err := os.WriteFile(filepath.Join(stateDir, n), []byte("running"), 0o644); err != nil {
			t.Fatalf("seed state: %v", err)
		}
		if err := os.WriteFile(filepath.Join(stateDir, n+".sid"), []byte("uuid-"+n), 0o644); err != nil {
			t.Fatalf("seed sidecar: %v", err)
		}
	}

	live := []TmuxSession{{Name: "am-live", Activity: 1}}
	now := time.Now()
	removed := reapOrphansAt(amDir, stateDir, live, now)
	if removed != 2 {
		t.Errorf("removed = %d, want 2", removed)
	}

	got := readRegistryNames(t, regPath)
	if len(got) != 1 || got[0] != "am-live" {
		t.Errorf("registry after reap = %v, want [am-live]", got)
	}

	if _, err := os.Stat(filepath.Join(stateDir, "am-live")); err != nil {
		t.Errorf("live state file missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "am-live.sid")); err != nil {
		t.Errorf("live sidecar missing: %v", err)
	}
	for _, dead := range []string{"am-dead1", "am-dead2"} {
		if _, err := os.Stat(filepath.Join(stateDir, dead)); !os.IsNotExist(err) {
			t.Errorf("dead state file %s still present: err=%v", dead, err)
		}
		if _, err := os.Stat(filepath.Join(stateDir, dead+".sid")); !os.IsNotExist(err) {
			t.Errorf("dead sidecar %s.sid still present: err=%v", dead, err)
		}
	}
}

func TestReapOrphansThrottled(t *testing.T) {
	amDir := t.TempDir()
	stateDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	writeRegistry(t, regPath, "am-dead")

	// Marker pretends GC just ran.
	marker := filepath.Join(amDir, ".gc_last")
	if err := os.WriteFile(marker, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o644); err != nil {
		t.Fatalf("seed marker: %v", err)
	}

	removed := reapOrphansAt(amDir, stateDir, nil, time.Now())
	if removed != 0 {
		t.Errorf("throttled call should remove 0, got %d", removed)
	}
	if names := readRegistryNames(t, regPath); len(names) != 1 {
		t.Errorf("registry unchanged when throttled, got %v", names)
	}

	// 61s later -- throttle window expired.
	removed = reapOrphansAt(amDir, stateDir, nil, time.Now().Add(61*time.Second))
	if removed != 1 {
		t.Errorf("post-throttle removed = %d, want 1", removed)
	}
	if names := readRegistryNames(t, regPath); len(names) != 0 {
		t.Errorf("registry should be empty post-reap, got %v", names)
	}
}

func TestReapOrphansEmptyRegistry(t *testing.T) {
	amDir := t.TempDir()
	stateDir := t.TempDir()
	// no sessions.json at all
	removed := reapOrphansAt(amDir, stateDir, nil, time.Now())
	if removed != 0 {
		t.Errorf("empty registry should remove 0, got %d", removed)
	}
}

func TestReapOrphansAllDeadEmptiesRegistry(t *testing.T) {
	amDir := t.TempDir()
	stateDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	writeRegistry(t, regPath, "am-a", "am-b", "am-c")

	removed := reapOrphansAt(amDir, stateDir, nil, time.Now())
	if removed != 3 {
		t.Errorf("removed = %d, want 3", removed)
	}
	if names := readRegistryNames(t, regPath); len(names) != 0 {
		t.Errorf("registry should be empty, got %v", names)
	}
}

func TestIsSafeSessionName(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"am-abc123", true},
		{"", false},
		{".", false},
		{"..", false},
		{"../etc/passwd", false},
		{"foo/bar", false},
		{"foo\\bar", false},
	}
	for _, c := range cases {
		if got := isSafeSessionName(c.in); got != c.want {
			t.Errorf("isSafeSessionName(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
