# Session Restore Design

Restore closed or uncleanly terminated agent sessions from a browsable history
with pane snapshots for visual recall.

## Scope

- Claude sessions only (Codex/Gemini deferred).
- Sessions created through `am` only (bare `claude` CLI sessions excluded).

## Data Model

### Session Log: `~/.agent-manager/sessions_log.jsonl`

Append-only log of every session. One JSON object per line:

```json
{
  "session_name": "am-abc123",
  "session_id": "3b155991-eb0f-4e29-a18c-0d6f58891cf5",
  "directory": "/Users/ehud/code/project",
  "branch": "main",
  "agent_type": "claude",
  "task": "Fix auth bug",
  "created_at": "2026-04-14T12:00:00Z",
  "closed_at": "2026-04-14T13:30:00Z",
  "snapshot_file": "snapshots/3b155991-eb0f-4e29-a18c-0d6f58891cf5.txt"
}
```

Field notes:
- `session_id` — Claude conversation UUID (filename stem from
  `~/.claude/projects/<encoded-dir>/<uuid>.jsonl`).
- `closed_at` — set on clean kill via `agent_kill()`. Null/missing for
  unclean terminations.
- `snapshot_file` — relative to `~/.agent-manager/`. Points to the last
  captured pane text.
- Written at launch (deferred session_id — see below). Updated at close.

### Snapshots: `~/.agent-manager/snapshots/<session_id>.txt`

Plain text files containing the last captured pane output (~50 lines).
Overwritten on each rolling update. Deleted when the session log entry is
pruned.

## Lifecycle

### 1. Launch (`agent_launch`)

After session creation (Claude agent only):
- Append an entry to `sessions_log.jsonl` with `session_id: ""` (Claude
  hasn't started yet — JSONL doesn't exist).
- The session_id is backfilled on the first snapshot scan.

### 2. Rolling Snapshots (`auto_title_scan` piggyback)

During each title scan cycle (throttled to 60s):
- For each active `am-*` session:
  - Capture pane text via `tmux_capture_pane` (~50 lines).
  - If this is a Claude session and the log entry has no `session_id` yet,
    detect it from `_state_jsonl_path()` (filename stem).
  - Write pane text to `~/.agent-manager/snapshots/<session_id>.txt`.
    If session_id still unknown, use `<session_name>.txt` as fallback and
    rename once detected.

### 3. On Kill (`agent_kill`)

Before destroying the tmux session:
- Final pane snapshot capture.
- Update `sessions_log.jsonl`: set `closed_at`, confirm `session_id` and
  `snapshot_file` if not yet set.

### 4. GC (`registry_gc` extension)

Added to existing GC cycle:
- Read `sessions_log.jsonl`.
- For each entry with `agent_type == "claude"` and a `session_id`:
  - Check if `~/.claude/projects/<encoded-dir>/<session_id>.jsonl` exists.
  - If not, remove the entry and delete the snapshot file.
- Entries with no `session_id` and `created_at` older than 24 hours are
  also pruned (failed launches that never produced a JSONL).
- Rewrite the file atomically (tmp + mv), same pattern as `history_prune`.
- Throttled alongside existing GC (60s).

## UI

### CLI: `am restore`

Opens an fzf picker showing restorable sessions.

**Source:** `sessions_log.jsonl`, filtered to:
- `agent_type == "claude"`
- `session_id` is non-empty
- Claude JSONL file still exists on disk
- Session is not currently alive in tmux

**Display format:** `dirname/branch [claude] task (3d ago)`

Sorted by `closed_at` (or `created_at` if unclean) descending — most recent
first.

**Preview pane:** Contents of the snapshot file (last captured pane text).

**Enter:** Launches `am new <directory> -- --resume <session_id>` directly.
No form — strict resume.

### fzf_main Keybinding: Ctrl-H

Invokes the same restore picker inline. On selection, launches the restore
and returns to the fzf main loop (or attaches to the new session).

## Files Changed

| File | Change |
|------|--------|
| `lib/registry.sh` | New: `sessions_log_append`, `sessions_log_update`, `sessions_log_gc`, `sessions_log_restorable`. Extend `registry_gc` to call `sessions_log_gc`. |
| `lib/agents.sh` | `agent_launch`: append to sessions log. `agent_kill`: final snapshot + update log. |
| `lib/registry.sh` | `auto_title_scan`: add rolling snapshot capture + session_id backfill. |
| `lib/fzf.sh` | New: `fzf_restore_picker`. Add Ctrl-H binding to `fzf_main`. |
| `lib/state.sh` | Reuse `_state_encode_dir` and `_state_jsonl_path` (already public). |
| `am` | New `restore` command routing. |
| `lib/preview` | Snapshot preview for restore picker (may reuse or create new script). |
| `AGENTS.md` | Document new functions, CLI command, keybinding. |

## Non-Goals

- Restoring Codex or Gemini sessions (future work).
- Restoring bare `claude` sessions not created via `am`.
- Image-based screenshots (text snapshots only).
- Editing session metadata before restore (strict resume only).
