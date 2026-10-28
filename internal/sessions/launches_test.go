package sessions

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func writeLaunch(t *testing.T, dir, id, body string, files map[string]string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, id+".json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	for ext, content := range files {
		if err := os.WriteFile(filepath.Join(dir, id+ext), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLoadLaunchEntries(t *testing.T) {
	amDir := t.TempDir()
	dir := LaunchesDir(amDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(10_000, 0)
	live := strconv.Itoa(os.Getpid())

	// A worker that is alive: starting, with the prompt's first line shown.
	writeLaunch(t, dir, "9000-live",
		`{"id":"9000-live","target":"@48351","agent":"claude","prompt_chars":20,"created_at":9000,"state":"running"}`,
		map[string]string{".pid": live + "\n", ".prompt": "fix the flaky test\nthen push"})
	// A worker that is gone: failed, with a reason, though the record says running.
	writeLaunch(t, dir, "8000-dead",
		`{"id":"8000-dead","target":"/tmp/proj","agent":"pi","created_at":8000,"state":"running"}`,
		map[string]string{".pid": "999999999"})
	// Marked failed by the worker: its own error stays.
	writeLaunch(t, dir, "7000-fail",
		`{"id":"7000-fail","target":"@fail","agent":"claude","created_at":7000,"state":"failed","error":"cannot resolve fail"}`,
		nil)
	// No pid file yet: the starter is between spawn and the pid write.
	writeLaunch(t, dir, "9990-new",
		`{"id":"9990-new","target":"@new","agent":"claude","created_at":9990,"state":"running"}`, nil)
	// No pid file long after the start: nothing will finish it.
	writeLaunch(t, dir, "5000-orphan",
		`{"id":"5000-orphan","target":"@orphan","agent":"claude","created_at":5000,"state":"running"}`, nil)
	// Not a record.
	writeLaunch(t, dir, "junk", `not json`, nil)

	entries := LoadLaunchEntries(amDir, now)
	var got []string
	for _, e := range entries {
		got = append(got, e.LaunchID+"="+string(e.Kind))
	}
	want := "9990-new=launching 9000-live=launching 8000-dead=launch_failed 7000-fail=launch_failed 5000-orphan=launch_failed"
	if strings.Join(got, " ") != want {
		t.Fatalf("entries = %v\nwant      %s", got, want)
	}

	liveEntry := entries[1]
	if liveEntry.DisplayBase != "◌ @48351 [claude] fix the flaky test" || liveEntry.TimeAgo != "starting" {
		t.Errorf("live row: base=%q time=%q", liveEntry.DisplayBase, liveEntry.TimeAgo)
	}
	if liveEntry.LaunchPrompt != "fix the flaky test\nthen push" || liveEntry.LaunchLog != filepath.Join(dir, "9000-live.log") {
		t.Errorf("live row: prompt=%q log=%q", liveEntry.LaunchPrompt, liveEntry.LaunchLog)
	}
	dead := entries[2]
	if dead.DisplayBase != "⚠ proj [pi]" || !strings.Contains(dead.LaunchError, "exited") {
		t.Errorf("dead row: base=%q err=%q", dead.DisplayBase, dead.LaunchError)
	}
	if fail := entries[3]; fail.LaunchError != "cannot resolve fail" || !strings.Contains(fail.Display, "cannot resolve fail") {
		t.Errorf("failed row: err=%q display=%q", fail.LaunchError, fail.Display)
	}

	if got := LoadLaunchEntries(t.TempDir(), now); len(got) != 0 {
		t.Errorf("no launches dir: %d entries", len(got))
	}
}
