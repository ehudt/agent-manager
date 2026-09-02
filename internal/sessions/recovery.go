package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

type DesiredStore struct {
	SchemaVersion int                       `json:"schema_version"`
	Sessions      map[string]DesiredSession `json:"sessions"`
}

type DesiredSession struct {
	LogicalID          string `json:"logical_id"`
	SessionName        string `json:"session_name"`
	DesiredState       string `json:"desired_state"`
	AgentType          string `json:"agent_type"`
	ProjectDirectory   string `json:"project_directory"`
	EffectiveDirectory string `json:"effective_directory"`
	Task               string `json:"task"`
	CreatedAt          string `json:"created_at"`
	OrderKey           int64  `json:"order_key"`
	SessionID          string `json:"session_id"`
	MachineID          string `json:"machine_id"`
	RecoveryState      string `json:"recovery_state"`
	RecoveryError      string `json:"recovery_error"`
}

func ReadDesiredStore(path string) DesiredStore {
	store := DesiredStore{Sessions: make(map[string]DesiredSession)}
	data, err := os.ReadFile(path)
	if err != nil {
		return store
	}
	if err := json.Unmarshal(data, &store); err != nil || store.SchemaVersion != 1 {
		return DesiredStore{Sessions: make(map[string]DesiredSession)}
	}
	if store.Sessions == nil {
		store.Sessions = make(map[string]DesiredSession)
	}
	return store
}

func desiredEntriesFromStore(store DesiredStore, live map[string]bool) []Entry {
	desired := make([]DesiredSession, 0, len(store.Sessions))
	currentMachine := os.Getenv("AM_MACHINE_ID")
	for _, session := range store.Sessions {
		if session.DesiredState != "open" || live[session.SessionName] ||
			(currentMachine != "" && session.MachineID != currentMachine) {
			continue
		}
		desired = append(desired, session)
	}
	sort.SliceStable(desired, func(i, j int) bool {
		if desired[i].OrderKey == desired[j].OrderKey {
			return desired[i].LogicalID < desired[j].LogicalID
		}
		return desired[i].OrderKey < desired[j].OrderKey
	})

	entries := make([]Entry, 0, len(desired))
	for _, session := range desired {
		name := session.SessionName
		if name == "" {
			name = session.LogicalID
		}
		dir := session.ProjectDirectory
		if session.EffectiveDirectory != "" {
			dir = session.EffectiveDirectory
		}
		meta := Session{
			Name:      name,
			Directory: dir,
			AgentType: session.AgentType,
			Task:      session.Task,
			LogicalID: session.LogicalID,
		}
		kind := EntryBlocked
		status := "interrupted"
		prefix := "⚠ "
		if session.RecoveryState == "queued" || session.RecoveryState == "restoring" {
			kind = EntryRestoring
			status = "restoring"
			prefix = "◌ "
		} else if session.RecoveryError != "" {
			status = "blocked"
		}
		base := prefix + FormatDisplayBase(TmuxSession{Name: name}, meta)
		display := base + " (" + status + ")"
		if session.RecoveryError != "" {
			display += " " + session.RecoveryError
		}
		entries = append(entries, Entry{
			Meta:             meta,
			Kind:             kind,
			Display:          display,
			DisplayBase:      base,
			TimeAgo:          status,
			RestoreSessionID: session.SessionID,
			RecoveryError:    session.RecoveryError,
		})
	}
	return entries
}

func desiredOpenSessionIDs(store DesiredStore) map[string]bool {
	ids := make(map[string]bool)
	currentMachine := os.Getenv("AM_MACHINE_ID")
	for _, session := range store.Sessions {
		if session.DesiredState == "open" && session.SessionID != "" &&
			(currentMachine == "" || session.MachineID == currentMachine) {
			ids[session.SessionID] = true
		}
	}
	return ids
}

func LoadDesiredStore(amDir string) DesiredStore {
	return ReadDesiredStore(EnvOr("AM_DESIRED_SESSIONS", filepath.Join(amDir, "desired_sessions.json")))
}
