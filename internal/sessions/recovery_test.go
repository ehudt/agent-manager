package sessions

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDesiredEntriesExposeProgressAndFailuresInOrder(t *testing.T) {
	t.Setenv("AM_MACHINE_ID", "")
	store := DesiredStore{
		SchemaVersion: 1,
		Sessions: map[string]DesiredSession{
			"later": {
				LogicalID:        "later",
				SessionName:      "am-later",
				DesiredState:     "open",
				AgentType:        "claude",
				ProjectDirectory: "/tmp/later",
				Task:             "later task",
				OrderKey:         2,
				RecoveryState:    "blocked",
				RecoveryError:    "directory unavailable",
			},
			"first": {
				LogicalID:        "first",
				SessionName:      "am-first",
				DesiredState:     "open",
				AgentType:        "cursor",
				ProjectDirectory: "/tmp/first",
				Task:             "first task",
				OrderKey:         1,
				RecoveryState:    "restoring",
			},
			"live": {
				LogicalID:     "live",
				SessionName:   "am-live",
				DesiredState:  "open",
				AgentType:     "pi",
				OrderKey:      3,
				RecoveryState: "live",
			},
		},
	}

	entries := desiredEntriesFromStore(store, map[string]bool{"am-live": true})
	if len(entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(entries))
	}
	if entries[0].Kind != EntryRestoring || entries[0].Meta.Name != "am-first" {
		t.Fatalf("first entry = %#v, want ordered restoring entry", entries[0])
	}
	if entries[1].Kind != EntryBlocked || entries[1].RecoveryError != "directory unavailable" {
		t.Fatalf("second entry = %#v, want actionable blocked entry", entries[1])
	}
}

func TestDesiredOpenSessionIDsSuppressInactiveDuplicates(t *testing.T) {
	t.Setenv("AM_MACHINE_ID", "machine-a")
	store := DesiredStore{
		Sessions: map[string]DesiredSession{
			"open": {
				DesiredState: "open",
				SessionID:    "sid-open",
				MachineID:    "machine-a",
			},
			"closed": {
				DesiredState: "closed",
				SessionID:    "sid-closed",
				MachineID:    "machine-a",
			},
			"remote": {
				DesiredState: "open",
				SessionID:    "sid-remote",
				MachineID:    "machine-b",
			},
		},
	}
	ids := desiredOpenSessionIDs(store)
	if !ids["sid-open"] || ids["sid-closed"] || ids["sid-remote"] {
		t.Fatalf("desired IDs = %#v, want only sid-open", ids)
	}
}

func TestLoadBrowserEntriesReadsDesiredStoreAndSuppressesHistoryDuplicate(t *testing.T) {
	amDir := t.TempDir()
	home := t.TempDir()
	t.Setenv("AM_DIR", amDir)
	t.Setenv("HOME", home)
	t.Setenv("AM_TMUX_SOCKET", "am-recovery-test-no-server")
	t.Setenv("AM_SESSION_PREFIX", "am-")
	t.Setenv("AM_MACHINE_ID", "machine-a")

	writeJSONDocument(t, filepath.Join(amDir, "desired_sessions.json"), map[string]any{
		"schema_version": float64(1),
		"next_order":     float64(2),
		"sessions": map[string]any{
			"am-interrupted": map[string]any{
				"logical_id":          "am-interrupted",
				"session_name":        "am-interrupted",
				"desired_state":       "open",
				"agent_type":          "codex",
				"project_directory":   "/tmp",
				"effective_directory": "/tmp",
				"task":                "recover me",
				"order_key":           float64(1),
				"session_id":          "codex-shared-id",
				"machine_id":          "machine-a",
				"recovery_state":      "restoring",
			},
			"am-other-machine": map[string]any{
				"logical_id":          "am-other-machine",
				"session_name":        "am-other-machine",
				"desired_state":       "open",
				"agent_type":          "codex",
				"project_directory":   "/tmp",
				"effective_directory": "/tmp",
				"order_key":           float64(2),
				"session_id":          "codex-other-id",
				"machine_id":          "machine-b",
				"recovery_state":      "blocked",
			},
		},
	})
	logLine := `{"session_name":"am-interrupted","session_id":"codex-shared-id","directory":"/tmp","agent_type":"codex"}` + "\n"
	if err := os.WriteFile(filepath.Join(amDir, "sessions_log.jsonl"), []byte(logLine), 0o644); err != nil {
		t.Fatal(err)
	}

	entries := LoadBrowserEntries()
	if len(entries) != 1 {
		t.Fatalf("browser entries = %#v, want one desired row without inactive duplicate", entries)
	}
	if entries[0].Kind != EntryRestoring || entries[0].Meta.LogicalID != "am-interrupted" {
		t.Fatalf("browser recovery entry = %#v", entries[0])
	}
}
