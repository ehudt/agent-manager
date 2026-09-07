package sessions

import (
	"os"
	"path/filepath"
	"strings"
)

// Conversation identity. A session's conversation id comes only from the
// sidecar its own hook wrote: the ephemeral $AM_STATE_DIR/<session>.sid, or
// the durable $AM_IDENTITY_DIR/<session>.sid mirrored for reboot recovery
// (preferred when present — /tmp is gone after a reboot). There is no
// directory-based guess: the transcript store is shared with other am
// sessions and with agents started outside am, so the newest transcript in
// it is not this session. Until the first hook fires the session has no
// identity, no transcript-derived title, and nothing to restore.

// sidecarFirstLine reads the first line of <session><suffix>, durable copy
// first. "" when neither file exists.
func (e Env) sidecarFirstLine(session, suffix string) string {
	for _, dir := range []string{e.IdentityDir, e.StateDir} {
		if dir == "" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, session+suffix))
		if err != nil {
			continue
		}
		return strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
	}
	return ""
}

// SidecarID mirrors lib/registry.sh:_sessions_log_sidecar_id: the hook-written
// conversation id, validated against the id character set, unverified.
func (e Env) SidecarID(session string) string {
	sid := e.sidecarFirstLine(session, ".sid")
	if validSessionID.MatchString(sid) {
		return sid
	}
	return ""
}

// SidecarTranscript mirrors _sessions_log_sidecar_transcript: the Cursor
// hook's transcript_path, kept only when absolute and present on disk.
func (e Env) SidecarTranscript(session string) string {
	p := e.sidecarFirstLine(session, ".transcript")
	if p == "" || !filepath.IsAbs(p) {
		return ""
	}
	if st, err := os.Stat(p); err != nil || st.IsDir() {
		return ""
	}
	return p
}

// storeJSONLExists is the per-layout existence check behind JSONLExists and
// the restorable filter. A layout of "none" (Codex: no stable local rollout
// path) accepts any well-formed id. Cursor accepts the hook-reported
// transcript path first, then its standard per-project layout.
func storeJSONLExists(home, store, dir, sid, transcript string) bool {
	switch store {
	case "none":
		return validSessionID.MatchString(sid)
	case "pi":
		return piJSONLExists(home, dir, sid)
	case "cursor":
		return cursorJSONLExists(home, dir, sid, transcript)
	case "claude":
		return claudeJSONLExists(home, dir, sid)
	}
	return false
}

// JSONLExists backs the bash _sessions_log_jsonl_exists wrapper: does the
// agent's transcript for (dir, sid) still exist? The layout comes from the
// agent's manifest `store` field (empty agent = claude).
func (e Env) JSONLExists(dir, sid, agent, transcript string) bool {
	return storeJSONLExists(e.Home, agentSpec(agent).Store, dir, sid, transcript)
}

// DetectID backs the bash _sessions_log_detect_id_for_session wrapper: the sidecar id,
// verified against the transcript store (no store: unverified). "" when the
// session has no sidecar or its transcript is gone — never a substitute.
func (e Env) DetectID(session, dir, agent string) string {
	spec := agentSpec(agent)
	sid := e.SidecarID(session)
	if sid == "" {
		return ""
	}
	if !spec.HasStore() {
		return sid
	}
	transcript := ""
	if spec.Store == "cursor" {
		transcript = e.SidecarTranscript(session)
	}
	if storeJSONLExists(e.Home, spec.Store, dir, sid, transcript) {
		return sid
	}
	return ""
}

// FirstMessage is the first user message of exactly the transcript bound to
// a session: `am-core first-message`, backing the bash
// claude/pi/cursor_first_user_message wrappers. No id (Cursor: no id and no
// transcript path) → ""; so does an agent without a transcript store.
func FirstMessage(agent, dir, sid, transcript string) string {
	switch agentSpec(agent).Store {
	case "pi":
		return piFirstUserMessage(dir, sid)
	case "cursor":
		return cursorFirstUserMessage(dir, sid, transcript)
	case "claude":
		return claudeFirstUserMessage(dir, sid)
	}
	return ""
}
