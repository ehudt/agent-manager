# state_lab — state-detection harness

Isolated rig for reproducing and debugging session-state-detection edge cases
without touching the user's live `am` sessions or paying Claude inference
costs.

## Run

```sh
tests/state_lab/run.sh                  # all cases
tests/state_lab/run.sh 01-jsonl         # prefix-match a single case
tests/state_lab/run.sh --list           # case names
LAB_KEEP=true tests/state_lab/run.sh CASE   # keep LAB_DIR after run
```

Each case is a self-contained shell script under `cases/`. Sourcing
`lab.sh` + calling `lab_init` sets up an isolated temp `AM_DIR`,
`AM_REGISTRY`, `AM_STATE_DIR`, `HOME` and a dedicated tmux socket; the
matching `lab_cleanup` is wired via `trap`.

## Drivers

Three drivers cover the three real input layers state detection reads from:

| Driver | Fakes | Helpers |
|---|---|---|
| Hook | `lib/hooks/state-hook.sh` invocations | `lab_hook`, `lab_hook_age` |
| JSONL | `~/.claude/projects/<encoded>/*.jsonl` | `lab_jsonl`, `jsonl_*` builders |
| Pane | `tmux_capture_pane` output | `lab_pane_paint`, `lab_pane_clear` |

Pane content is virtual (in-memory, override of `tmux_capture_pane`) — no
real tmux pane is required, which makes pane tests fast and deterministic.

## Probes

Use these inside a case to inspect each layer side-by-side:

| Probe | Calls |
|---|---|
| `probe_hook <session>` | reads `$AM_STATE_DIR/<session>` |
| `probe_jsonl <dir>` | `_state_from_jsonl` |
| `probe_pane <session> <agent>` | `_state_from_pane --skip-alive-check` |
| `probe_agent_get_state <session>` | `agent_get_state` (used by `am list --json`) |
| `probe_fast_state <session> <agent> <dir>` | `_agent_get_state_fast` (status-bar lean variant) |
| `probe_all <session> [agent]` | all of the above, formatted table |

## Assertions

`lab_assert <expected> <actual> <msg>` — green PASS / red FAIL.

`lab_xfail <expected> <actual> <msg>` — for known-broken paths: prints
XFAIL on mismatch (does not fail the run), XPASS when it suddenly passes
(prompt: promote to `lab_assert`, the bug is fixed).

## Current XFAILs

None — Phase 1 of `docs/state-detection-plan.md` cleared both originally
documented bugs (newest-mtime shadow, `tail -20` flood). All cases now run
under `lab_assert` and must stay green.
