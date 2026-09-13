# Live state-detection lab

Drives a **real** Claude Code, Cursor Agent, pi, or opencode session through
observable am states inside an
isolated tmux server + state/registry sandbox, and records ground truth at 1s
resolution. This is the empirical layer of state-detection testing — the fast
layers (`tests/test_state.sh`, `tests/state_lab/`) encode what this lab observed.

Four runners:
- `run.sh` — Claude Code (7 scenarios, ~8 min)
- `run_cursor.sh` — Cursor Agent (6 independently selectable scenarios)
- `run_pi.sh` — pi (4 scenarios, ~5 min)
- `run_opencode.sh` — opencode (4 scenarios, ~5 min)

Not part of `test_all.sh`: they spend real tokens.

## When to run

- Agent updated (Claude Code, Cursor, pi, or opencode — verify signal contracts still hold)
- Changing `lib/state.sh`, `lib/hooks/state-hook.sh`, `lib/hooks/am-state.ts`, or `lib/hooks/opencode-state.js` semantics
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

# opencode runner
./tests/live_lab/run_opencode.sh
LAB_SCENARIOS="o1 o2" ./tests/live_lab/run_opencode.sh
LAB_OPENCODE_ARGS="--model openrouter/deepseek/deepseek-v4.1-flash" ./tests/live_lab/run_opencode.sh
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

## Scenarios (opencode — `run_opencode.sh`)

| # | Drives | Verifies |
|---|--------|----------|
| o1 | fresh TUI, no prompt | plugin init writes `ready` (opencode creates no session until the first prompt) |
| o2 | prompt round-trip | `session.status busy` → `running`; `session.status idle` → `ready`; first-message mirror populated, `.sid`/`.transcript` bound |
| o3 | `sleep 200` (> 180s quiet) | ungated plugin read: resolved state NEVER leaves `running` during a long tool call |
| o4 | ctrl-c opencode → shell | shell-pane check precedence: resolved state == `idle` despite a stale plugin state file |

opencode 1.18.30 runs state detection as an in-process plugin
(`lib/hooks/opencode-state.js`): `session.status` busy/idle are the turn
boundaries, `permission.asked`/`question.asked` → `waiting_user`, and the
TUI's `OC | <title>` pane title is parsed for the tab label. Post-turn title
generation emits a synthetic `message.updated` user message *after*
`session.idle`, so user messages must not be treated as turn starts — only
`session.status busy` is.

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
