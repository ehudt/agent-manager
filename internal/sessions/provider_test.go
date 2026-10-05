package sessions

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeProvider is tests/fake_dir_provider, the test double of the
// dir_provider contract.
func fakeProvider(t *testing.T) (provider, root string) {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	provider = filepath.Join(filepath.Dir(file), "..", "..", "tests", "fake_dir_provider")
	if _, err := os.Stat(provider); err != nil {
		t.Skip("tests/fake_dir_provider not found")
	}
	root = t.TempDir()
	t.Setenv("FAKE_PROVIDER_DIR", root)
	return provider, root
}

func TestParseDirSuggestions(t *testing.T) {
	rows := ParseDirSuggestions("\tnew copy on trunk\ntrunk\tdefault branch\n\nbare\n")
	if len(rows) != 3 {
		t.Fatalf("rows = %v", rows)
	}
	if rows[0].Spec != "" || rows[0].Label != "new copy on trunk" {
		t.Errorf("empty spec row = %+v", rows[0])
	}
	if rows[1].Spec != "trunk" || rows[1].Label != "default branch" {
		t.Errorf("row 1 = %+v", rows[1])
	}
	if rows[2].Spec != "bare" || rows[2].Label != "" {
		t.Errorf("label-less row = %+v", rows[2])
	}
	if rows := ParseDirSuggestions(""); rows != nil {
		t.Errorf("empty output = %v", rows)
	}
}

func TestDirProviderSuggest(t *testing.T) {
	provider, root := fakeProvider(t)
	amDir := t.TempDir()
	t.Setenv("AM_SESSION_NAME", "am-dispatcher")
	// The bash suite exports AM_EVENTS_LOG for every test; read the file
	// this test's events actually go to.
	eventsLog := filepath.Join(amDir, "events.log")
	t.Setenv("AM_EVENTS_LOG", eventsLog)

	rows := DirProviderSuggest(amDir, provider, "@48", time.Second)
	if len(rows) != 2 || rows[0].Spec != "48351" || rows[1].Label != "PR #48372 gw retry" {
		t.Errorf("@48 = %v", rows)
	}
	rows = DirProviderSuggest(amDir, provider, "", time.Second)
	if len(rows) != 2 || rows[0].Spec != "" || rows[1].Spec != "trunk" {
		t.Errorf("bare = %v", rows)
	}
	if rows := DirProviderSuggest(amDir, provider, "zzz", time.Second); rows != nil {
		t.Errorf("no match = %v", rows)
	}
	if rows := DirProviderSuggest(amDir, "", "48", time.Second); rows != nil {
		t.Errorf("no provider = %v", rows)
	}
	calls, _ := os.ReadFile(filepath.Join(root, "calls.log"))
	if got := strings.Count(string(calls), "suggest "); got != 3 {
		t.Errorf("provider ran %d times, want 3:\n%s", got, calls)
	}

	// A slow provider is cut off at the timeout, with one suggest.fail event.
	start := time.Now()
	rows = DirProviderSuggest(amDir, provider, "slow", 200*time.Millisecond)
	elapsed := time.Since(start)
	if rows != nil {
		t.Errorf("slow = %v, want nothing", rows)
	}
	if elapsed > 1500*time.Millisecond {
		t.Errorf("slow provider took %v, want the 200ms cut-off (it sleeps 3s)", elapsed)
	}
	events, _ := os.ReadFile(eventsLog)
	if !strings.Contains(string(events), "suggest.fail") || !strings.Contains(string(events), "rc=124") {
		t.Errorf("events.log lacks the timeout event:\n%s", events)
	}
}
