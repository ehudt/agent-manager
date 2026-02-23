# Auto-Title Scanner Design

## Problem

`auto_title_session` spawns a background subshell per session that polls for JSONL messages, then calls `claude -p --model haiku`. The Haiku call hangs indefinitely, the subshell is hard to debug (output goes to `/dev/null`), and the timeout/watchdog logic is fragile.

## Solution

Replace per-session background subshells with a **piggyback scanner** that runs during existing user touchpoints (fzf open, `am list`). One scan processes all untitled sessions.

## Architecture

### New function: `auto_title_scan`

Runs alongside `registry_gc` at user touchpoints. Throttled to once per 60s via marker file (`$AM_DIR/.title_scan_last`).

**Per untitled session:**

1. Call `claude_first_user_message(directory)` — skip if empty
2. Generate fallback title (first sentence via sed) — write to registry + history immediately
3. Fire-and-forget: spawn background `claude -p --model haiku` with 30s watchdog to upgrade the title

### Fire-and-forget Haiku upgrade

```
fallback written to registry
  |
  v
( unset CLAUDECODE;
  title=$(printf msg | claude -p --model haiku "..." 2>/dev/null) &
  haiku_pid=$!
  ( command sleep 30 && kill $haiku_pid ) &
  watchdog=$!
  wait $haiku_pid
  kill $watchdog; wait $watchdog
  # if title valid, registry_update to upgrade
) >/dev/null 2>&1 &
```

The fallback is already persisted, so if Haiku hangs and the watchdog kills it, the session still has a title. If Haiku succeeds, it upgrades.

## What changes

### Removed
- `auto_title_session()` function from `agents.sh`
- Its call from `agent_launch`
- All per-session background subshell complexity

### Added
- `auto_title_scan()` in `registry.sh` — scan, write fallbacks, spawn upgrades
- Calls from fzf.sh entry points (alongside `registry_gc`)
- Debug log at `/tmp/am-titler.log`

### Unchanged
- `claude_first_user_message()` in utils.sh
- Registry/history functions
- Test helpers for title logic (fallback, stripping, validation)

## Throttling

Same pattern as `registry_gc`: marker file `$AM_DIR/.title_scan_last`, skip if <60s since last run. Force parameter available.

## Debuggability

All scan activity logs to `/tmp/am-titler.log` (timestamped). Visible with `tail -f /tmp/am-titler.log`.
