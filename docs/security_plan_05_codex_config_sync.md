# Plan 05: Codex Config Sync Flow (No Live RW Mount)

Related findings: [H-01]  
Status: Open

## Goal
Prevent sandbox sessions from directly mutating host `~/.codex/config.toml` while preserving an explicit workflow for config updates.

## Scope
- `sb`
- `entrypoint.sh` (if needed)
- `README.md`

## Implementation Steps
1. Change default mount behavior in `sb`:
   - mount host `~/.codex/config.toml` read-only (`:ro`) when mounted.
2. Add explicit config sync commands:
   - `sb <dir> --import-codex-config` (host -> sandbox copy)
   - `sb <dir> --export-codex-config` (sandbox -> host copy)
3. Store editable sandbox copy in sandbox-local state path.
4. Add safe export flow:
   - backup current host config before overwrite
   - show diff and require explicit confirmation where possible.
5. Update documentation for import/export usage and recovery path.

## Validation
1. Confirm sandbox cannot directly write host-mounted config during normal run.
2. Confirm import copies host config into sandbox working location.
3. Confirm export creates backup and updates host config only through explicit command.

## Acceptance Criteria
- Host config is not live-writable from container default session.
- Config updates occur only through explicit import/export actions.
- Backup exists for each export overwrite action.
