package sessions

import (
	"path/filepath"
)

// Env is the process-environment view every maintenance entry point shares:
// where the stores live and which tmux server to ask. LoadEnv reads the same
// variables lib/utils.sh derives its paths from, with the same defaults, so
// the bash wrappers (lib/registry.sh, lib/utils.sh) and the Go binaries agree
// on every path without passing them as flags.
type Env struct {
	AmDir       string // $AM_DIR (default ~/.agent-manager)
	StateDir    string // $AM_STATE_DIR (default /tmp/am-state)
	IdentityDir string // $AM_IDENTITY_DIR (default $AM_DIR/identities)
	SessionsLog string // $AM_SESSIONS_LOG (default $AM_DIR/sessions_log.jsonl)
	Socket      string // $AM_TMUX_SOCKET (default agent-manager)
	Prefix      string // $AM_SESSION_PREFIX (default am-)
	Home        string // $HOME
}

// LoadEnv builds the Env from the process environment.
func LoadEnv() Env {
	amDir := EnvOr("AM_DIR", filepath.Join(HomeDir(), ".agent-manager"))
	return Env{
		AmDir:       amDir,
		StateDir:    EnvOr("AM_STATE_DIR", "/tmp/am-state"),
		IdentityDir: EnvOr("AM_IDENTITY_DIR", filepath.Join(amDir, "identities")),
		SessionsLog: EnvOr("AM_SESSIONS_LOG", filepath.Join(amDir, "sessions_log.jsonl")),
		Socket:      EnvOr("AM_TMUX_SOCKET", "agent-manager"),
		Prefix:      EnvOr("AM_SESSION_PREFIX", "am-"),
		Home:        HomeDir(),
	}
}

// RegistryPath is $AM_DIR/sessions.json.
func (e Env) RegistryPath() string { return filepath.Join(e.AmDir, "sessions.json") }

// SnapshotsDir is $AM_DIR/snapshots (bash AM_SNAPSHOTS_DIR, not overridable
// separately).
func (e Env) SnapshotsDir() string { return filepath.Join(e.AmDir, "snapshots") }

// ListLive lists the am-* sessions on the configured tmux server.
func (e Env) ListLive() []TmuxSession { return ListTmuxSessions(e.Socket, e.Prefix) }

// LiveSet is ListLive as a name set.
func (e Env) LiveSet() map[string]struct{} {
	live := e.ListLive()
	set := make(map[string]struct{}, len(live))
	for _, s := range live {
		set[s.Name] = struct{}{}
	}
	return set
}
