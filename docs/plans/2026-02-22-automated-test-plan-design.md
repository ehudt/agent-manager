# Automated Test Plan Design

**Date:** 2026-02-22
**Goal:** Regression safety net for agent-manager

## Decisions

- **Approach:** Extend existing `tests/test_all.sh` framework (no new dependencies)
- **Scope:** Unit tests + tmux integration tests in same suite
- **Agent stubs:** Replace real agents with a stub script (no API keys needed)
- **Focus:** Session lifecycle + broad coverage of likely breakage points

## Test Infrastructure

### Stub Agent

`tests/stub_agent.sh` — minimal script that acts like an AI agent. Prints a prompt, reads stdin, echoes back. Allows `agent_launch()` to run without real agents.

### Isolation

- Each integration test group uses a temp `AM_DIR` via `mktemp -d`
- Test sessions use `am-test-` prefix for easy identification and cleanup
- A `cleanup_test_sessions()` helper kills leftover `am-test-*` tmux sessions and removes test registry entries

### Teardown

Trap-based cleanup after each test group + global cleanup at suite end.

## Test Groups

### Group 1: Extended Unit Tests — utils.sh

| Test | Function | What it verifies |
|------|----------|------------------|
| format_time_ago edge cases | `format_time_ago()` | 0, negative, very large timestamps |
| truncate edge cases | `truncate()` | empty string, shorter than limit, exact limit |
| hash consistency | `generate_hash()` | same input → same output across calls |
| abspath edge cases | `abspath()` | relative paths, `.`, `..` |
| session title missing file | `get_claude_session_title()` | missing/empty/malformed JSONL |

### Group 2: Extended Unit Tests — registry.sh

| Test | Function | What it verifies |
|------|----------|------------------|
| duplicate add | `registry_add()` | adding same session name twice |
| get nonexistent | `registry_get_field()` | querying missing session |
| update nonexistent | `registry_update()` | updating missing session |
| remove nonexistent | `registry_remove()` | idempotent removal |
| malformed JSON | various | graceful failure on corrupted registry |
| rapid writes | `registry_add()` | two quick sequential adds don't corrupt |

### Group 3: Agent Unit Tests

| Test | Function | What it verifies |
|------|----------|------------------|
| commands per type | `agent_get_command()` | correct command for claude, codex, gemini |
| unsupported type | `agent_get_command()` | error on invalid agent type |
| yolo flags per type | `agent_get_yolo_flag()` | correct flag per agent |
| type validation | `agent_type_supported()` | valid and invalid types |
| name uniqueness | `generate_session_name()` | different dirs → different names |
| name format | `generate_session_name()` | `am-` prefix, 6-char hash |

### Group 4: Integration — Session Lifecycle

Uses real tmux + stub agent. Isolated AM_DIR.

| Test | What it does | What it verifies |
|------|-------------|------------------|
| launch | `agent_launch()` with stub | tmux session exists, registry entry created, two panes |
| list | launch → `fzf_list_json()` | session appears, fields correct |
| info | `agent_info()` | correct directory, agent type, status |
| kill | `agent_kill()` | tmux session gone, registry entry removed |
| kill all | launch 2 → `agent_kill_all()` | both sessions gone |
| launch directory | launch with specific dir | working directory correct in tmux |

### Group 5: Integration — CLI Commands

| Test | Command | What it verifies |
|------|---------|------------------|
| help | `am help` | exits 0, output contains "Usage" |
| version | `am version` | exits 0, matches version pattern |
| list json | `am list --json` | valid JSON output |
| new | `am new <dir>` with stub | creates session non-interactively |
| kill | `am kill <name>` | kills the right session |
| info | `am info <name>` | shows session details |
| attach bad name | `am attach nonexistent` | exits with error |

### Group 6: Integration — Registry GC

| Test | Setup | What it verifies |
|------|-------|------------------|
| stale cleanup | registry entries without tmux sessions | `registry_gc()` removes them |
| live preservation | entries with live tmux sessions | `registry_gc()` keeps them |
| throttling | two calls within 60s | second call is a no-op |

## Estimated Test Count

| Group | New Tests | Existing Tests |
|-------|-----------|----------------|
| Utils extended | ~8 | 8 |
| Registry extended | ~6 | 7 |
| Agent unit | ~6 | 4 |
| Session lifecycle | ~6 | 0 |
| CLI commands | ~7 | 3 |
| Registry GC | ~3 | 0 |
| **Total** | **~36** | **22** |

**Final total: ~58 tests** (up from 22 currently)

## Implementation Order

1. Test infrastructure (stub agent, isolation helpers, cleanup)
2. Extended unit tests (groups 1-3) — low risk, no tmux needed
3. Session lifecycle integration tests (group 4) — highest regression value
4. CLI command tests (group 5)
5. Registry GC tests (group 6)
