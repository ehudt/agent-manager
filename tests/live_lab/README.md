# Live state-detection lab

Drives a **real** Claude Code or pi session through every am state inside an
isolated tmux server + state/registry sandbox, and records ground truth at 1s
resolution. This is the empirical layer of state-detection testing — the fast
layers (`tests/test_state.sh`, `tests/state_lab/`) encode what this lab observed.

Two runners:
- `run.sh` — Claude Code (7 scenarios, ~8 min)
- `run_pi.sh` — pi (4 scenarios, ~5 min)

Not part of `test_all.sh`: they spend real tokens.

## When to run

- Agent updated (Claude Code or pi — verify signal contracts still hold)
- Changing `lib/state.sh`, `lib/hooks/state-hook.sh`, or `lib/hooks/am-state.ts` semantics
- Harvesting fresh pane/title fixtures for the unit tests

## Usage

```bash
# Claude runner
./tests/live_lab/run.sh                    # all scenarios
LAB_SCENARIOS="s2 s4" ./tests/live_lab/run.sh   # subset
LAB_MODEL=sonnet ./tests/live_lab/run.sh        # different model

# Pi runner
./tests/live_lab/run_pi.sh                 # all scenarios
LAB_SCENARIOS="p1 p3" ./tests/live_lab/run_pi.sh   # subset
LAB_PI_ARGS="--provider anthropic --model claude-haiku-4-5" ./tests/live_lab/run_pi.sh
```

## Scenarios (Claude — `run.sh`)

| # | Drives | Verifies |
|---|--------|----------|
| s1 | fresh session, no prompt | `✳` title before any hook fires |
| s2 | allowlisted `sleep 25` turn | braille title while running; `Stop` → `waiting_input` + `✳` |
| s3 | non-allowlisted command | `Notification[permission_prompt]` → `waiting_permission`; title during dialog |
| s4 | background shell (`run_in_background`) | `Stop` `background_tasks` → `waiting_background`; self-heal to `waiting_input` on completion |
| s5 | AskUserQuestion mid-turn | hook + title while an in-turn dialog is pending; resume after answer |
| s6 | ctrl-b during a tool call | title flips to `✳` at true turn end even when hook routing is unreliable |
| s7 | `sleep 200` (> 180s gate) | hook file + tmux activity go stale on a live turn; title stays busy |

## Outputs (`results/<timestamp>/`)

- `report.txt` — per-scenario observations (title / hook state / status line at
  each phase marker)
- `timeline.tsv` — 1s samples: `ts scenario title_glyph hook_state hook_age
  activity_age status_line`
- `payloads.jsonl` — every hook payload Claude fired (tee'd via `--settings`)
- `snapshots/` — full pane captures taken on every state/title transition
  (fixture source for unit tests)

## Scenarios (Pi — `run_pi.sh`)

| # | Drives | Verifies |
|---|--------|----------|
| p1 | fresh session, no prompt | `session_start` → `waiting_input` state file (no .sid with `--no-session`) |
| p2 | prompt round-trip | `agent_start` → `running`, `agent_settled` → `waiting_input` |
| p3 | `sleep 200` (> 180s quiet) | ungated hook read: resolved state NEVER leaves `running` during long tool call |
| p4 | quit pi → shell | shell-pane check precedence: resolved state == `idle` despite stale hook file |

## Key empirical findings (2026-07-10, Claude Code 2.1.206)

- The pane title glyph (braille spinner = busy, `✳` = needs user) tracked the
  true state in **every** sample; the only mismatches were 1-second
  transition races against the hook file.
- tmux `session_activity` goes stale for minutes during long quiet tool calls
  on a live turn (observed 500s+), so it cannot serve as a liveness rescue
  for a stale `running` hook state. The state file mtime goes equally stale
  by design (hooks fire per tool, not per second).
- `Stop` payload `background_tasks` is reliable: present on every `Stop`,
  pruned when work finishes, and `Stop` re-fires on background completion.
- A pending AskUserQuestion dialog fires `Notification[permission_prompt]`
  (hook state `waiting_permission`) and shows the `✳` title.
