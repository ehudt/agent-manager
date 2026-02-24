# Agent Manager

Architecture and key functions: @AGENTS.md

## Commands

- Run tests: `./tests/test_all.sh`
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)

## Code style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- `SCRIPT_DIR` is overwritten when sourcing `lib/agents.sh` — if you need a stable reference, save it before sourcing
- Tests source libs directly — test helpers like `registry_exists` live in `test_all.sh`, not in production code