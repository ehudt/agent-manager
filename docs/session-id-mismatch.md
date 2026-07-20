# Session-id mismatch (restore resumes the wrong conversation)

Status: **still reproduces sometimes** (as of 2026-07) despite several fixes.
This note records what has been fixed, where the residual holes are, and
exactly what to capture when it happens again.

## Symptom

An inactive (closed) session's log entry carries the session id of a
*different* conversation — usually another session that ran in the **same
directory** — so `am restore` resumes the wrong conversation, and/or the
title/snapshot shown in the restore picker belongs to a sibling session.

## What's already fixed

| Commit | Fix |
|---|---|
| `3fbebd6` | `claude_session_id` moved off the shared registry to a per-session sidecar (`$AM_STATE_DIR/<session>.sid`), written by the agent pane's own hooks — authoritative when present |
| `f4541ff` | Restore snapshots keyed correctly for duplicate directories |
| `6640867` | Status-bar same-dir title mixup |
| `5ca0724` | Restore picker resuming the wrong same-directory session |
| (scan) | `sessions_log_scan` treats the sidecar as authoritative and *corrects* a previously guessed sid that disagrees; `_sessions_log_dir_is_shared` gates the mtime guess when another registered same-agent session shares the directory |

## Residual suspects (why it can still happen)

1. **No sidecar yet → mtime guess.** The sidecar only exists after a
   lifecycle hook fires. A session that is launched and closed quickly, or
   where hooks never fire (hooks not installed, sandbox edge cases, pi
   before the extension loads), falls back to the newest-mtime JSONL guess
   in `_sessions_log_detect_id` — which in a shared directory grabs
   whichever conversation wrote most recently.
2. **`_sessions_log_dir_is_shared` only sees *registered* sessions.** It
   checks the live registry for another same-agent session in the same
   directory. If the same-dir sibling was already killed and GC'd, the
   directory looks unshared and the mtime guess proceeds — right into the
   closed sibling's JSONL.
3. **Sidecar rejected on flush lag.** `sessions_log_scan` discards the
   sidecar sid when its JSONL doesn't exist on disk yet
   (`lib/registry.sh`, sid backfill: "sidecar present but JSONL pending").
   That is deliberate (don't log an unverifiable sid), but if the scan then
   later runs when the sidecar is *gone* (state-dir GC after kill), only
   the guess path remains.

## Diagnostic capture — do this BEFORE restoring

When a mismatch shows up, snapshot the evidence first; restoring overwrites
mtimes and appends to the JSONL:

```bash
d=~/am-mismatch-$(date +%s); mkdir -p "$d"
cp ~/.agent-manager/sessions_log.jsonl "$d/"
cp -r /tmp/am-state "$d/am-state" 2>/dev/null
# For the affected project directory (encode: / and . both become -):
ls -lT ~/.claude/projects/<encoded-dir>/ > "$d/jsonl-mtimes.txt"   # macOS
# ls -l --time-style=full-iso on Linux
head -1 ~/.claude/projects/<encoded-dir>/*.jsonl > "$d/jsonl-heads.txt"
```

Then determine which path produced the bad sid:

- `sessions_log.jsonl`: find the session's entry — is `session_id` empty,
  wrong, or right-but-picker-showed-wrong? Compare `created_at` with the
  JSONL mtimes.
- `am-state/<session>.sid`: present? matches the logged sid? If absent →
  suspect 1 or 2 (guess path). If present and correct → the bug is on the
  read side (picker/restore), not detection.
- `jsonl-heads.txt`: each JSONL's first line carries its `sessionId` —
  match conversations to sids.

Also useful: `AM_HOOK_DEBUG=1` (hooks that fire but exit without writing —
registry miss / missing `AM_SESSION_NAME` / cwd mismatch surface in
`$AM_DIR/.hook-debug.log`). A session whose hooks all bailed never gets a
sidecar → guess path (suspect 1).

## Fix directions (once a repro pins the path)

- Suspect 1/2: make the guess stricter — refuse the mtime guess whenever the
  project dir contains >1 JSONL newer than session creation, regardless of
  registry sharing (closed siblings included). The sessions log itself knows
  about closed same-dir sessions; use it as the sharing check.
- Suspect 3: persist the last verified sid (or the pending sidecar value)
  into the sessions log as `session_id_candidate` instead of dropping it,
  and let a later scan promote it once the JSONL appears.
- Read side: if evidence shows detection was right and restore picked wrong,
  audit `fzf_restore_picker` / `sessions_log_restorable` ordering and
  dedup-by-directory behavior.
