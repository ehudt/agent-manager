# Live state-detection lab

Drives a **real** Claude Code, Cursor Agent, or pi session through observable
am states inside an
isolated tmux server + state/registry sandbox, and records ground truth at 1s
resolution. This is the empirical layer of state-detection testing — the fast
layers (`tests/test_state.sh`, `tests/state_lab/`) encode what this lab observed.

Three runners:
- `run.sh` — Claude Code (7 scenarios, ~8 min)
- `run_cursor.sh` — Cursor Agent (6 independently selectable scenarios)
- `run_pi.sh` — pi (4 scenarios, ~5 min)

Not part of `test_all.sh`: they spend real tokens.

## When to run

- Agent updated (Claude Code, Cursor, or pi — verify signal contracts still hold)
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

# Cursor runner
./tests/live_lab/run_cursor.sh
LAB_SCENARIOS="c1 c2" ./tests/live_lab/run_cursor.sh
LAB_CURSOR_ARGS="--model auto" ./tests/live_lab/run_cursor.sh
```

## Scenarios (Claude — `run.sh`)

| # | Drives | Verifies |
|---|--------|----------|
| s1 | fresh session, no prompt | `✳` title before any hook fires |
| s2 | allowlisted `sleep 25` turn | braille title while running; `Stop` → `ready` + `✳` |
| s3 | non-allowlisted command | `Notification[permission_prompt]` → `waiting_user`; title during dialog |
| s4 | background shell (`run_in_background`) | `Stop` `background_tasks` → `background`; self-heal to `ready` on completion |
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
| p1 | fresh session, no prompt | `session_start` → `ready` state file (no .sid with `--no-session`) |
| p2 | prompt round-trip | `agent_start` → `running`, `agent_settled` → `ready` |
| p3 | `sleep 200` (> 180s quiet) | ungated hook read: resolved state NEVER leaves `running` during long tool call |
| p4 | quit pi → shell | shell-pane check precedence: resolved state == `idle` despite stale hook file |

## Scenarios (Cursor — `run_cursor.sh`)

| # | Drives | Verifies |
|---|--------|----------|
| c1 | fresh trusted workspace | `sessionStart`, conversation sidecar, initial title |
| c2 | prompt round-trip | `beforeSubmitPrompt` → running; response/stop → waiting |
| c3 | forced shell approval | hook/title behavior while permission UI is pending |
| c4 | AskQuestion | behavior while an in-turn question is pending |
| c5 | subagent turn | tool/response activity and settle behavior |
| c6 | native `--resume` | conversation identity survives relaunch |
| c7 | background task | Ready title + footer task count → `background`, then `ready` |

Cursor 2026.08.11 exposed stable terminal-title suffixes for `✅ Ready`,
`⏳ Working`, and `❓ Waiting for you`; production uses these signals alongside
lifecycle hooks. Its forced permission dialog still showed `⏳ Working`, so it
remains `running`. Cursor exposes no background-work lifecycle event; the
resolver narrowly reads the CLI-owned footer task count while the title says
Ready. Older Cursor releases without suffixes fall back to hooks.

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
  (canonical state `waiting_user`) and shows the `✳` title. This is why
  permission and custom questions are not separate public states.
