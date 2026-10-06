# state_lab — state-detection harness

Isolated rig for reproducing and debugging session-state-detection edge cases
without touching the user's live `am` sessions or paying Claude inference
costs. The cases run in the regular suite through `tests/test_state_lab.sh`
(worker 4 of `tests/test_all.sh`).

## Run

```sh
tests/state_lab/run.sh                  # all cases
tests/state_lab/run.sh 12-unknown       # prefix-match a single case
tests/state_lab/run.sh --list           # case names
LAB_KEEP=true tests/state_lab/run.sh CASE   # keep LAB_DIR after run
```

Each case is a self-contained shell script under `cases/`. Sourcing
`lab.sh` + calling `lab_init` sets up an isolated temp `AM_DIR`,
`AM_REGISTRY`, `AM_STATE_DIR`, `HOME` and a dedicated tmux socket; the
matching `lab_cleanup` is wired via `trap`.

## What it drives

The resolver reads two real inputs: the hook state file and the tmux/ps
view of the pane. The lab runs the real `lib/hooks/state-hook.sh` and the
real `_state_resolve`, with the tmux side virtual: a session registered
with `lab_register` is "alive", its pane is never a shell, and no tmux
server is needed.

| Helper | Does |
|---|---|
| `lab_register <session> <dir> [agent] [branch] [task]` | registry row + virtual live session; prints the resolved directory |
| `lab_hook <session> <event_json>` | runs the real hook script with `AM_SESSION_NAME` set |
| `lab_hook_age <session> <seconds>` | backdates the state file's mtime |

## Probes

| Probe | Calls |
|---|---|
| `probe_hook <session>` | reads `$AM_STATE_DIR/<session>` (`<missing>` when absent) |
| `probe_resolve <session> <agent> <dir>` | `_state_resolve`, non-bulk path (forks tmux/ps itself) |
| `probe_resolve_titled <session> <agent> <dir> <title>` | `_state_resolve`, bulk path with an injected pane title (drives the title-glyph layer) |

## Assertions

`lab_assert <expected> <actual> <msg>` — green PASS / red FAIL;
`lab_report` prints the tally and returns the failure count.

## Cases

- `12-unknown-state.sh` — hook-silent agent resolves to `unknown`, a stale
  `running` stays `running` (ungated), a fresh `ready` is `ready`. The only
  test of the non-bulk resolver path's failed-`display-message` branch.
- `13-background-wait.sh` — the real hook writes `background` from a Stop
  payload's `background_tasks`, the real resolver reads it, and the re-fired
  Stop heals it to `ready`. The only place the hook's written vocabulary
  meets the resolver's read (`tests/test_state_hooks.sh` checks the hook's
  output, `tests/test_state.sh` writes the resolver's input with `printf`).

The pane-scrape and JSONL layers, and the cases that covered them, were
removed in 476d563 when the resolver collapsed to hook + process tree; the
remaining per-row coverage lives in `tests/test_state.sh` and
`tests/test_state_hooks.sh` (see `docs/test-value-plan.md`).
