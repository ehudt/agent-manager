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

// SidecarID is the hook-written conversation id from the durable identity
// dir (preferred) or the ephemeral state dir, validated against the id
// character set, unverified.
func (e Env) SidecarID(session string) string {
	sid := e.sidecarFirstLine(session, ".sid")
	if validSessionID.MatchString(sid) {
		return sid
	}
	return ""
}

// SidecarTranscript is the hook-reported transcript_path (Claude, Cursor,
// opencode), kept only when absolute and present on disk.
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
// path) accepts any well-formed id. Cursor and Claude accept the
// hook-reported transcript path first, then their standard per-project
// layout (Claude also searches the whole store by id: a conversation resumed
// in another directory stays in its original project folder). opencode's
// hook writes a mirror path (the .transcript sidecar) under $AM_DIR, which is
// the only addressable copy of a SQLite-backed session.
func storeJSONLExists(amDir, home, store, dir, sid, transcript string) bool {
	switch store {
	case "none":
		return validSessionID.MatchString(sid)
	case "pi":
		return piJSONLExists(home, dir, sid)
	case "cursor":
		return cursorJSONLExists(home, dir, sid, transcript)
	case "opencode":
		return opencodeJSONLExists(amDir, home, sid, transcript)
	case "claude":
		return claudeJSONLExists(home, dir, sid, transcript)
	}
	return false
}

// JSONLExists backs the bash _sessions_log_jsonl_exists wrapper: does the
// agent's transcript for (dir, sid) still exist? The layout comes from the
// agent's manifest `store` field (empty agent = claude).
func (e Env) JSONLExists(dir, sid, agent, transcript string) bool {
	return storeJSONLExists(e.AmDir, e.Home, agentSpec(agent).Store, dir, sid, transcript)
}

// StoreDir is the directory holding an agent's transcripts for dir, from the
// manifest `store` layout: the Claude per-project store, Cursor's
// agent-transcripts dir, pi's session dir, or opencode's mirror root. "" for a
// layout am cannot address (codex, unknown).
func (e Env) StoreDir(agent, dir string) string {
	if dir == "" {
		return ""
	}
	switch agentSpec(agent).Store {
	case "claude":
		return filepath.Join(e.Home, ".claude", "projects", encodedClaudeProjectDir(dir))
	case "cursor":
		return cursorTranscriptsDir(e.Home, dir)
	case "pi":
		return filepath.Join(piSessionsRoot(e.Home), encodedPiSessionDir(dir))
	case "opencode":
		return opencodeMirrorRoot(e.AmDir, e.Home)
	}
	return ""
}

// TranscriptPath is where am would read the conversation for (agent, dir,
// sid): the hook-reported path when the layout stores one (Claude, Cursor,
// opencode), else the standard per-project path (Claude: the existing file
// anywhere in its store before the standard path, see claudeTranscriptPath).
// pi's filenames carry a timestamp prefix, so its match is globbed; "" when
// the layout cannot be addressed or nothing matches. Existence is the
// caller's check.
func (e Env) TranscriptPath(agent, dir, sid, transcript string) string {
	switch agentSpec(agent).Store {
	case "pi":
		if sid == "" {
			return ""
		}
		matches, _ := filepath.Glob(filepath.Join(e.StoreDir(agent, dir), "*_"+sid+".jsonl"))
		if len(matches) > 0 {
			return matches[0]
		}
	case "cursor":
		if transcript != "" {
			return transcript
		}
		if sid != "" {
			return cursorStandardTranscriptPath(e.Home, dir, sid)
		}
	case "opencode":
		if transcript != "" {
			return transcript
		}
		if sid != "" {
			return opencodeMirrorPath(e.AmDir, e.Home, sid)
		}
	case "claude":
		if sid != "" {
			if p := claudeTranscriptPath(e.Home, dir, sid, transcript); p != "" {
				return p
			}
			return claudeStandardTranscriptPath(e.Home, dir, sid)
		}
	}
	return ""
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
	if storeJSONLExists(e.AmDir, e.Home, spec.Store, dir, sid, e.SidecarTranscript(session)) {
		return sid
	}
	return ""
}

// FirstMessage is the first user message of exactly the transcript bound to
// a session: `am-core first-message`, backing the bash
// claude/pi/cursor/opencode_first_user_message wrappers. No id (Cursor: no id
// and no transcript path) → ""; so does an agent without a transcript store.
func FirstMessage(agent, dir, sid, transcript string) string {
	switch agentSpec(agent).Store {
	case "pi":
		return piFirstUserMessage(dir, sid)
	case "cursor":
		return cursorFirstUserMessage(dir, sid, transcript)
	case "opencode":
		return opencodeFirstUserMessage(sid, transcript)
	case "claude":
		return claudeFirstUserMessage(dir, sid, transcript)
	}
	return ""
}
