# Plan 05: Codex Config Sync Flow (No Live RW Mount)

Related findings: [H-01]
Status: Open

## Current state

Implemented (~40%):
- Codex config mounted from sandbox-local path (`~/.sb/codex/config.toml`) when available
- Fallback to host-global `~/.codex/config.toml` when sandbox-local copy does not exist
- `am sandbox identity init` seeds `~/.sb/codex/` from host config (copy-on-init via `_sandbox_copy_if_missing`)

TODO:
- Config mount is read-write by default; should be `:ro`
- No explicit `am sandbox config import` / `am sandbox config export` commands
- No safe export flow with backup and confirmation

## Goal
Prevent sandbox sessions from directly mutating host `~/.codex/config.toml` while preserving an explicit workflow for config updates.

## Scope
- `lib/sandbox.sh` (`sandbox_start` mount logic)
- `am` CLI (new `am sandbox config` subcommands)

## Implementation Steps
1. Mount Codex config read-only in `sandbox_start()`:
   - Change the config.toml mount from rw to `:ro`.
2. Add explicit config sync commands in `am`:
   - `am sandbox config import` (host -> sandbox-local copy)
   - `am sandbox config export` (sandbox-local -> host copy)
3. Sandbox-local copy already stored at `~/.sb/codex/config.toml`; container edits should write there.
4. Add safe export flow:
   - Backup current host config before overwrite.
   - Show diff and require explicit confirmation.

## Validation
1. Confirm sandbox cannot directly write host-mounted config during normal run.
2. Confirm import copies host config into sandbox-local path.
3. Confirm export creates backup and updates host config only through explicit command.

## Acceptance Criteria
- Host config is not live-writable from container default session.
- Config updates occur only through explicit import/export actions.
- Backup exists for each export overwrite action.
