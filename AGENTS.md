# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Commands

- Run tests: `./tests/test_all.sh`
- Run tests (summary): `./tests/test_all.sh --summary` — suppresses PASS lines, shows only failures with details and a counts summary
- Run perf benchmark: `./tests/perf_test.sh` — standalone latency check for `am list-internal`; not part of `test_all.sh` and should not leave resources behind
- Run live state-detection labs: `tests/live_lab/run.sh` (Claude), `run_cursor.sh` (Cursor), and `run_pi.sh` (pi). They record hook payloads, pane titles, and transitions; they are opt-in and spend tokens.
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)
- Build the Go binaries: `make -s build` → `bin/am-list-internal`, `bin/am-browse`, `bin/am-core`, `bin/am-review`; `go vet ./... && go test ./...` for the Go side. `tests/test_all.sh` builds them first, because the bash maintenance wrappers exec `bin/am-core`

## Versioning

SemVer (`MAJOR.MINOR.PATCH`). Single source of truth: `AM_VERSION` in `am` (help text and `am --version` both read it — never hardcode a version string elsewhere).

When to bump (pre-1.0, so `MAJOR` stays `0`):

- **PATCH** (`0.2.0` → `0.2.1`) — bug fixes, doc/test/skill tweaks, internal refactors with no user-facing behavior change.
- **MINOR** (`0.2.0` → `0.3.0`) — new user-facing capability: a new `am` command/flag, a new pane/UI mode, restore/skill features, or a behavior change a user would notice.
- **MAJOR** — reserved; bump to `1.0.0` only on the first stability commitment.

How to bump: edit `AM_VERSION` in `am` in the same commit as the change that earns it; mention the bump in the commit body. Accumulate several small changes under one bump rather than bumping per-commit — bump when cutting a coherent batch.

## Code Style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- Registry writes must go through `registry_add/update/remove` (or Go's `lockRegistry`-wrapped paths) — a bare jq-rewrite of `sessions.json` bypasses the write lock and reintroduces lost updates. Don't spawn background jobs while `_registry_lock` is held (children inherit the lock fd and keep the lock alive until they exit)
- Periodic maintenance and store queries run in `bin/am-core`; the bash names (`auto_title_scan`, `registry_gc`, `sessions_log_scan`, `sessions_log_gc`, `sessions_log_restorable`, `_sessions_log_detect_id_for_session`, `_sessions_log_jsonl_exists`, `*_first_user_message`) are one-line wrappers. Consequences: a bash function stub for `tmux_pane_title` / `tmux_capture_pane` no longer reaches the scan (tests put a fake `tmux` on PATH via `setup_fake_tmux`); `am_core` passes `AM_DIR`, `AM_SESSIONS_LOG`, the socket, the prefix, and `AM_STATE_DIR` / `AM_IDENTITY_DIR` explicitly, so anything else the Go side reads (`AM_GC_GRACE_SECS`, `AM_TITLER_DEBUG`, `AM_PI_SESSIONS_DIR`, `AM_CURSOR_PROJECTS_DIR`, `HOME`) must be exported; a missing binary is one stderr line, and the periodic wrappers return 0 so the status-bar tick never fails
- Sourced libs derive their own dir as `_<MODULE>_LIB_DIR` from `AM_LIB_DIR` (exported by the `am` entry point); standalone scripts like `lib/status-bar` set their own `SCRIPT_DIR`
- Tests source libs directly — test helpers like `registry_exists` live in `test_helpers.sh`, not in production code
- The shell panel is optional and collapsible: sessions launch agent-only (override: `--shell` / `am config set shell true`), and hiding the panel parks its pane in the hidden `_amshell` window. Session-keyed pane enumeration (e.g. status-bar's bulk `list-panes -a`) must skip that window or the parked shell's pid clobbers the agent pid and flips running sessions to idle. Non-bulk `.{top-left}` targets resolve against the session's *current* window — briefly wrong only if a user manually navigates into `_amshell` (self-heals on toggle)
- Auxiliary panes carry a tmux pane option `@am_role` (`shell` / `review`); the agent pane is the untagged one. The review pane (`am review`, prefix+v) splits to the agent's *right*, so "at top" no longer identifies the agent: address it as `.{top-left}` (never `.{top}`, which tmux resolves in the *active* pane's column — with the review pane focused it names the review pane), enumerate with `#{@am_role}` and take the first untagged top pane (status-bar bulk path), and resolve shell/review targets through `tmux_session_pane_by_role`. Its hidden window is `_amreview`; skip it wherever `_amshell` is skipped
- Never overwrite a live Go binary in place (`cp` onto `bin/am-core`, `: > bin/…`): macOS invalidates the code signature of the mapped file and every process running it dies with SIGKILL (rc=137, "Taskgated Invalid Signature" in `~/Library/Logs/DiagnosticReports`). `go build -o` is safe (it unlinks and recreates); a copy must go to a sibling temp file and `mv` into place. The install test's binary restore did this and intermittently killed other workers' `am-core review-init` / title scans
- Pane environment (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, `AM_LOG_DIR`) is seeded at pane creation via tmux `-e` (`agent_pane_env` → `tmux_create_session` env args / `split-window -e`) plus the session environment. Never `send-keys` an `export` into a pane: even a space-prefixed one lingers as zsh's most recent history entry, and the vars must exist before the agent command runs. Requires tmux ≥ 3.2 (`display-popup` already did)
- A directory argument starting with `@` is a provider spec, not a path: `cmd_new` hands it to `agent_dir_resolve`, which runs the configured `dir_provider` as `<provider> resolve <spec>` (bash -c, `AM_SESSION_NAME` blanked) and uses its stdout. The form passes `@spec` through unvalidated in the directory field; provider suggestions come from `<provider> suggest <partial>` under `agent_dir_suggest`'s perl-alarm timeout (`AM_DIR_SUGGEST_TIMEOUT`, 0.3s) and are cached per typed partial for the life of the form. am never interprets a spec (PR number, branch, ...) — that is the provider's business
- jq's `//` treats `false` as missing: `(.notify // true)` is `true` for `"notify": false`. Read boolean config keys with `if has("k") then .k else default end` (see `_notify_maybe`, `am_auto_restore_enabled`)
- The test stub agent is a bash script, so the shell-pane check resolves stub sessions as `idle`. Tests that send to a stub pass `am send --force`; the plain form is exercised once to prove the refusal
- Review checkpoints live in the session's repository (`refs/am/<session>/*`), not under `$AM_DIR`: `agent_kill` and `registry_gc` leave them alone (restore adopts them under the new session name), only `SessionsLogGC` drops them with the log entry. `WorktreeTree` copies the real index to a temp file and must preserve its mtime (`os.Chtimes`) — git only re-hashes entries whose file mtime is not older than the index, so a fresh copy hides a same-size edit made in the second after a commit. Never run `git add`/`stash` against the real index from am; the whole point is that review never touches the user's git state
- The hook state dir (`AM_STATE_DIR`, default `/tmp/am-state`) is shared by every AM_DIR, tmux socket, and session prefix on the machine, so the GC orphan sweep must never run against it from a mis-pointed environment. Two fences: Go `sweepOrphanStateFiles` does nothing when tmux lists no session (an empty live set almost always means the wrong server, not an empty machine), and every test gets its own `AM_STATE_DIR` (per worker in `tests/test_all.sh`, a temp dir when a test file runs directly). A test that points `AM_DIR` elsewhere must not undo that. `$AM_DIR/gc.log` (always on, capped with the debug logs, `AM_GC_LOG` overrides the path) records every row and state file GC removes with the caller's argv, AM_DIR, socket, prefix and live-set size — grep it first when a live session's state file vanishes. 2026-09-08: `tests/test_bin_helpers.sh` ticked with a stub tmux and wiped every real hook file on each suite run; waiting `background` sessions (no tool events) then showed `ready` until their next hook event
- Registry `directory` is the *launch* cwd and must never be rewritten: it keys the Claude/Cursor/pi transcript store (`~/.claude/projects/<encoded-dir>/`), the title fallback, session-id detection, and `am restore`. Where the agent works *now* lives in the separate `workdir` field (empty = same as `directory`), fed by the state hook's `/tmp/am-state/<session>.cwd` sidecar (Claude stamps hook payloads with the Bash tool's tracked cwd — the process cwd and tmux `pane_current_path` never move) or by `am cd`. Labels and the branch refresh read `workdir` first; state detection and restore read `directory`

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, agent JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata (locked jq rewrites), sessions-log append/update/snapshot, and the thin bash wrappers (`am_tick`, `auto_title_scan`, `registry_gc`, `sessions_log_scan/gc/restorable`, detect-id, jsonl-exists) that exec `bin/am-core` |
| `lib/recovery.sh` | Durable desired-session store, boot/machine identity, reboot preflight, and progressive recovery worker |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/agents.manifest` | Agent adapter table (symlink to `internal/sessions/agents.manifest`, which Go embeds): per agent type, the launch command, aliases, prompt delivery (stdin/argv), resume-args template, transcript store layout, title parser, title→state signal, turn-boundary reliability, hook family, restore preflight, version binary, live lab. Bash reads it through `am_agent_field`; Go through `Agent()` / `AgentSpec`. Libs branch on these fields, not on agent names. The state hook reads it when run from the repo and falls back to an inline table (Cursor's byte copy runs outside the repo; `tests/test_agents.sh` keeps them equal) |
| `lib/form.sh` | tput-based new session form (two-mode: Navigate/Edit); shows a Preset select field first when any preset exists |
| `lib/presets.sh` | Named launch presets for `am new -p` (stored under `presets` in config.json): `am preset save/list/show/rm` |
| `lib/review.sh` | `am diff [session] [--ack\|--reset\|--list\|--checkpoint id] [--stat] [-- git args]`: resolves the session (argument, else the caller's pane), asks `am-core review-*` for the baseline/worktree trees and the numstat, prints the header to stderr and runs `git diff <base_tree> <cur_tree>` so the user's pager and diff tools apply. Also `review_init` / `review_adopt` wrappers for the lifecycle |
| `internal/sessions/review.go` | Review checkpoint store: per session a chain of commit objects under `refs/am/<session>/checkpoints` (kinds launch / ack / branch / head) plus `refs/am/<session>/baseline`, in the session's own repository. `WorktreeTree` (temp index copied from the real one, mtime preserved, `add -A`, `write-tree`), `ReviewInit/Ack/Sync/SetBaseline/ResetBaseline/Adopt/Drop`, `ReviewDiffStat`, `Env.ReviewMeasure` (records the registry `review_*` fields) |
| `lib/doctor.sh` | `am doctor [session] [--capture]`: one report with every state input (registry row, tmux panes/titles, hook sidecars, identity, transcript, process tree, desired record, resolver layer via `AM_STATE_DEBUG_SINK`) plus the version-drift canary (installed agents vs `tests/live_lab/VERIFIED`, observed hook payload keys vs the fields the hook reads) |
| `cmd/am-browse/main.go` | Compiled Go TUI session browser (bubbletea); primary UI for `am` |
| `cmd/am-list-internal/main.go` | Compiled Go binary for fast session list generation |
| `cmd/am-core/main.go` | Compiled Go back end of the bash maintenance and query wrappers: `tick` (title/workdir/branch refresh + restore scan + gc, one status-bar tick), `titles`, `restore-scan`, `gc`, `slog-gc`, `restorable`, `first-message`, `detect-id`, `jsonl-exists`. Paths from the environment (`AM_DIR`, `AM_STATE_DIR`, `AM_IDENTITY_DIR`, `AM_SESSIONS_LOG`, `AM_TMUX_SOCKET`, `AM_SESSION_PREFIX`, `HOME`) with utils.sh's defaults |
| `internal/sessions/` | Shared Go package: tmux queries, registry parsing and locking, formatting, title/workdir/branch refresh (`titles.go`), session identity and transcript readers (`identity.go`), sessions-log rewrites (`slog.go`), the periodic maintenance entry points and GC (`maintenance.go`, `reap.go`), environment/paths (`env.go`) |
| `lib/fzf.sh` | Browser launcher (`fzf_main`), directory picker, restore picker, `am list` helpers |
| `lib/preview` | Standalone preview script (extracts first user message, captures pane) |
| `lib/status-bar` | Standalone script: renders whole bottom bar as a clickable session-tab strip (idx, state glyph, dir/branch label, title, age). Adaptive layout, one fit shared by every tab (`_fit_strip`): rungs are full `dir/branch · title` → branch-or-dir `· title` (water-filled, ≥12 chars/field) → title only (label for untitled sessions) → no ages; fields truncate with a 1-col `…` and default branches (main/master) are hidden. Tab age is time-in-state (state-file mtime) for waiting_* and running sessions, tmux activity otherwise. The dir half of the label is the registry `workdir` (where the agent moved) when set, else `directory`. Also writes `@am_sidebar` (label-only pane-border variant). `AM_STATUS_WIDTH` overrides the client-width probe for tests and ad-hoc inspection. |
| `lib/strip-ansi` | Standalone script: strips ANSI escape codes from pane output |
| `lib/dir-preview` | Standalone preview script for directory picker fzf panel |
| `lib/config.sh` | User config: defaults, feature flags, persistent settings |
| `lib/state.sh` | Session state detection: title glyph + hook file + process tree, wait/poll |
| `lib/hooks/am-state.ts` | Pi extension: lifecycle events → am state files (session_start/agent_settled → ready, agent_start → running) |
| `tests/live_lab/run.sh`, `run_cursor.sh`, `run_pi.sh` | Empirical state labs for real agent sessions; each prints the installed agent version at the end so `tests/live_lab/VERIFIED` (the per-agent verified-version pins `am doctor` compares against) can be updated |
| `skills/agent-manager-dispatch/SKILL.md` | Claude/Cursor skill: teaches agents to use am for multi-session dispatch/orchestration |
| `skills/am-peek/SKILL.md` | Claude Code skill: teaches agents to read another session's full shell scrollback via `am peek --pane shell --history` |
| `bin/toggle-shell` | tmux helper (prefix+\`): toggle the collapsible shell panel — create on first use via `am shell`, then hide/show by parking the pane in the hidden `_amshell` window |
| `bin/toggle-review` | tmux helper (prefix+v): toggle the review pane via `am review` — create on first use, then park in / rejoin from the hidden `_amreview` window |
| `cmd/am-review/main.go`, `view.go`, `note.go` | Compiled Go TUI (bubbletea) for the review pane: `--session`, `--dir`, `--am` (for `a` → `am diff --ack` and `c` → `am send`), `--am-dir`, `--state-dir`, `--poll` (1s). Measures in-process (`ReviewMeasure` with record, `ReviewFileStats`, `ReviewFileDiff`), re-measures when the `.dirty` sidecar's mtime moves (and fully every few ticks), renders the file list (stacked above the diff on narrow panes, beside it when wide) and the selected file's parsed diff with hunk navigation. `c` opens a one-line note (bubbles textinput in the footer) pinned to the hunk under the cursor; Enter sends `noteMessage` (file, new-side line range, the hunk capped at 80 lines, the note) on stdin to `am send <session>`, falling back to `am send --queue` on exit 4 (agent busy) and reporting exit 2 (no agent) as an error |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/switch-cycle` | tmux helper: cycle next/prev in canonical sidebar order |
| `bin/switch-index` | tmux helper: jump to Nth slot in canonical sidebar order |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |
| `docs/` | Architecture docs, backlog, perf notes |

## Data Flow

```
am → fzf_main() → am-browse (Go TUI) → stdout protocol → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session(name, dir, VAR=VAL...) → registry_add() → tmux_send_keys()
am new @spec → agent_dir_resolve(@spec) → $dir_provider resolve spec → agent_launch(dir, ...)
form Directory "@par" → _form_filter_dir_suggestions → agent_dir_suggest(par) → $dir_provider suggest par (≤0.3s) → "@spec\tlabel" rows
am id → current_session() → $AM_SESSION_NAME, else attached session on the am tmux server
am cd [dir] → current_session() → agent_set_workdir() → .cwd sidecar + registry workdir/branch → am_refresh_sidebar_cache()
agent cd's (Bash tool) → Claude hook payload cwd → state-hook.sh writes /tmp/am-state/<session>.cwd → am-core tick (RefreshTitles) → registry workdir + branch (from .git/HEAD) → tab label
status-bar tick / am list → am_tick() → am-core tick → RefreshTitles (.title_scan_last) → RestoreScan (.restore_scan_last) → GC rows (.gc_last) + extras (.gc_extras_last)
auto_title_scan / registry_gc / sessions_log_scan / sessions_log_gc / sessions_log_restorable / _sessions_log_detect_id_for_session / _sessions_log_jsonl_exists / *_first_user_message → am_core <sub> → bin/am-core (env: AM_DIR, AM_SESSIONS_LOG, AM_STATE_DIR, AM_IDENTITY_DIR, socket, prefix)
am list-internal → am-list-internal (Go binary) → stdout
agent_launch() → am-core review-init → launch checkpoint (refs/am/<session>/{checkpoints,baseline} in the repo; silent outside one)
tool hook (PostToolUse family) → detached tail: touch /tmp/am-state/<session>.dirty; HEAD ≠ .head sidecar → am-core review-sync (branch checkpoint moves the baseline, head checkpoint does not) → rm .title_scan_last
am-core tick → RefreshTitles → refreshedReview (only when .dirty is newer than review_at, or the branch changed) → ReviewMeasure → registry review_files/added/deleted/at → tab "Δ<files> +<add> −<del>"
am diff [s] → review_diff_main → am-core review-stat --record → git -C dir diff <base_tree> <cur_tree>; --ack → review-ack (worktree tree becomes the baseline, count zeroed); --reset → review-baseline --reset
am restore → cmd_restore_internal → am-core review-adopt <old> <new> (refs follow the resumed conversation); sessions_log_gc → ReviewDrop when the entry is dropped
am new -p name → _cmd_new_apply_preset(name, fill=true) → preset fields where flags left gaps, preset args first → agent_launch()
form Preset field → --preset=name in the flags field → _cmd_new_apply_preset(name, fill=false) (args + shell only)
am send s "..." → agent_get_state → refuse running/starting/waiting_user (exit 4) or idle/dead (exit 2) unless --wait/--queue/--force
am wait --all|--any s1 s2 → _wait_many() → one agent_wait_state per session in the background → '<session> <state>' lines
am done "..." (in a worker) → $AM_DIR/results/<session>.txt → am result <session> (dispatcher); removed by agent_kill
hook state transition → waiting_user (or notify_states) → _notify_maybe() in the detached tail → notify_cmd | osascript | notify-send, skipped when a client shows the session
bare `am` → _install_refresh_if_stale() → fingerprint of install inputs vs $AM_DIR/.install_stamp → _install_refresh() (skills, Go build if sources newer, tmux.conf)
Ctrl-N in browser → am_new_session_form() → _form_run()
prefix+` / am shell → bin/toggle-shell → agent_shell_pane_toggle() → agent_shell_pane_add() (first use) | tmux_shell_pane_hide/show() (park in / rejoin from hidden _amshell window; pane state and shell.log streaming survive)
prefix+v / am review [s] → bin/toggle-review → agent_review_pane_toggle() → agent_review_pane_add() (split-window -h at the agent's right, @am_role=review, runs bin/am-review) | tmux_review_pane_hide/show() (park in / rejoin from hidden _amreview window)
am-review tick (1s) → .dirty mtime moved? → ReviewMeasure(record) + ReviewFileStats → ReviewFileDiff(selected) ; 'a' → am diff <s> --ack → re-measure
am-review 'c' → note line → Enter → noteMessage(file, L<range>, hunk, note) | am send <s> → exit 4 → am send --queue <s> (delivered when ready) ; exit 2 → "no running agent"
agent_kill() → sessions_log_snapshot() + sessions_log_update(closed_at) → tmux_kill_session() → registry_remove()
am restore → fzf_restore_picker() → sessions_log_restorable() → agent_launch(dir, agent_type, agent_resume_args...) → tmux_attach() (claude/cursor → --resume, pi → --session, codex → resume)
bare `am` → recovery_start_for_browser() → migrate live intent → prior-boot candidates queued → am-browse shows restoring rows while recovery_run() recreates sessions detached
```

## State Detection (hooks + title paint)

Claude sessions are resolved from documented-behavior signals — no
pane-content scraping:

1. **Hook state file** (primary). Claude Code lifecycle hooks (`Stop`,
   `Notification`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
   `PermissionRequest`) call `lib/hooks/state-hook.sh`, which maps the event
   to an am state and writes it to `/tmp/am-state/<session_name>`. The state
   is read **ungated**: `Stop`/`UserPromptSubmit` are reliable turn-boundary
   events (like pi's in-process extension and Cursor's stop hooks), a dead
   process drops the pane to a shell (caught by the shell-pane check), and a
   ctrl-b backgrounded turn fires its own `Stop` on Claude Code ≥2.1.237
   (live lab s6) — so `running` no longer goes silently stale. No staleness
   gate: hooks skip same-state rewrites (mtime pins turn start) and tmux
   `session_activity` is empirically unreliable (live lab s7 on 2.1.237:
   activity age grew unbounded while the pane visibly repainted), so any
   mtime/activity gate flaps long live turns to `unknown`.
2. **Pane title paint** (fresh-session detection + legacy busy glyph).
   Claude Code ≤2.1.233 animated a busy glyph in the terminal title — a
   braille spinner frame (`⠂` …, U+2800–U+28FF) up to 2.1.221, a
   circle-phase glyph (`◐◓◑◒`, U+25D0–U+25D3) from 2.1.232 — and painted
   `✳` when it needed the user. **Since 2.1.234 the title is written only
   when its text changes** (the 960ms spinner animation was removed to stop
   tab-bar jitter — see that version's changelog): the busy glyph is gone
   and `✳ <task>` stays painted from boot through running turns (verified on
   2.1.237, live lab: the title never left `✳ …` across all seven
   scenarios). So `✳` now proves only that Claude is alive and has painted;
   the one case it still decides is a **fresh session idle at its first
   prompt** (`✳` + no hook file → `ready`, since the very first
   `UserPromptSubmit` would have created the file). A busy glyph, where an
   old version still emits one, remains authoritative for `running`.

State detection priority: **shell pane check → busy glyph (legacy) / fresh
`✳`+no-hook-file → ungated hook state → unknown**.

Glyph × hook decision table (`_state_resolve`, Claude sessions):

| Glyph | Hook state | Result |
|---|---|---|
| busy (braille / circle-phase; ≤2.1.233 only) | `waiting_user` | pass through — a pending dialog needs the user; answering it fires `PreToolUse` which moves the file forward |
| busy | anything else | `running` — trust the legacy indicator |
| `✳` | missing, no identity sidecar | `ready` — fresh session idle at its first prompt (no hook has ever fired) |
| `✳` | missing, `.sid` sidecar exists (ephemeral or durable) | `unknown` — the hooks did fire, so the state file was removed under a live session (see `gc.log`); the next hook event restores it |
| `✳` | any state | hook state, ungated — `✳` carries no busy/waiting information on ≥2.1.234; resurrecting the old attention rows flips every running turn to `ready` within one status-bar tick |
| none (hostname / booting / titles unavailable) | any state | hook state, ungated; `unknown` when no file |
| — (non-Claude, non-pi, non-Cursor agents) | — | hook state with the 180s running-staleness gate, else `unknown` |

Known display wart (accepted): a wrap-up turn that starts when background
work completes fires no `UserPromptSubmit`, and its tool hooks are blocked
by the unconditional `background` race guard, so the session shows
`background` until the wrap-up turn's own `Stop`. Self-healing and
not user-blocking (it never fakes "waiting for you").

Hooks are installed via `am install` into `~/.claude/settings.json`. State
files are cleaned up on session kill and during registry GC.

The state file's mtime doubles as the state-entry timestamp: the hook only
writes on state *transitions*, skipping same-state rewrites (repeated
`idle_prompt` notifications, Stop re-fires while background work drains,
per-tool `running` rewrites), so the mtime pins the moment the state was
entered. The status bar renders tab ages from it — "waiting for you since"
for waiting_* tabs, "running for" on running tabs.

**Working-directory sidecar.** Every hook event also records the payload
`cwd` in `$AM_STATE_DIR/<session>.cwd` (rewritten only on change; a change
also drops the title-scan throttle so the tab relabels on the next status-bar
tick). On Claude Code this is the Bash tool's *tracked* cwd — verified live:
it flips with `cd` while the process cwd stays put — so an agent that moves
into another checkout is relabelled without pane scraping. The scan
(`auto_title_scan` / `RefreshTitles`) turns the
sidecar into the registry `workdir` and re-reads the branch from the
effective directory's `.git/HEAD` (fork-free `git_head_branch` /
`GitHeadBranch`), so a checkout in place also updates the label. Agents
without hooks, and shell tools that hand out a checkout (`wp allocate`), call
`am cd <dir>` instead.

| Hook Event | Matcher | am State |
|---|---|---|
| `Stop` | — | `ready`, or `background` when the payload's `background_tasks` lists running work |
| `Notification` | `idle_prompt` | `ready` (same `background_tasks` refinement; without the field it cannot downgrade `background` unless a prior Stop snapshot's leftover shells are all unowned) |
| `Notification` | `permission_prompt` | `waiting_user` |
| `Notification` | `elicitation_dialog` | `waiting_user` |
| `UserPromptSubmit` | — | `running` |
| `PostToolUse` | — | `running` |

States not covered by hooks (`starting`, `idle`, `dead`) use existing
process/tmux checks which are already reliable.

Hook writes require a **positive pane signal**: the hook identifies its
session from `AM_SESSION_NAME` (seeded into every am pane at creation) or,
failing that, `TMUX_PANE` mapped to its tmux session. There is no
directory-based fallback. A directory is a shared resource — other am
sessions, wp copies, and agents started outside am all run in it — and a
process that carries neither variable is not in an am pane, so its events
are dropped (one line under `AM_HOOK_DEBUG=1`). Observed live before this
rule: an interactive Claude started from Obsidian's terminal plugin in
`~/obsidian` (no `AM_SESSION_NAME`, no `TMUX_PANE`) was matched by directory
to the am session launched there, drove its tab through
running/background/waiting_user from a conversation the pane never ran,
overwrote its `.sid`/`.transcript` sidecars, and left it stuck at
`waiting_user`. The same rule governs identity and titles: a session's
conversation id comes only from the sidecar its own hook wrote
(Go `DetectID`; the bash `_sessions_log_detect_id_for_session` is a wrapper
over it), and the first-message title fallback opens exactly that
transcript (Go `FirstMessage`; `claude_first_user_message(dir, sid)` and its
pi/Cursor wrappers) — never the newest file in the directory's transcript
store. A
session whose hooks have not fired yet has no identity, no
transcript-derived title, and nothing to restore; the next hook event fills
all three in.

Hook writes are further gated by **agent family**: the event name proves the
source (CamelCase → Claude Code / Codex; camelCase → Cursor; pi never calls
the script — its states come from the in-process extension), and the
resolved session's registered `agent_type` must belong to that family. A
positively identified session of the wrong family means a foreign agent is
nested inside an am pane (observed live: a cursor-agent run by hand in a pi
session's shell pane); the hook exits rather than write another agent's
state. Cursor nested agents are a same-family exception: they inherit
`AM_SESSION_NAME` and do not reliably set `is_background_agent`, so reboot
identity is pinned to the physical session's first complete
conversation-id/transcript pair.

`background` (Claude's main turn ended but a background agent/task/
workflow/shell is still running) is written directly by the hook: the `Stop`
payload carries a `background_tasks` array (documented; Claude Code ≥2.1) —
one entry per still-running background item (`{id, type (subagent|shell),
status, description, …}`), pruned to `[]` once everything finishes — and the
hook writes `background` when any *owned* entry has `status ==
"running"`. A running `shell` / `local_bash` task whose matching OS process
is not owned by this Claude (PPID=1 after `--fork-session` or a parent
Claude exit) is ignored — otherwise leftover wait-loops keep every later
Stop at `background` while the pane already shows recap / "new
task?". `monitor` entries (the Artifact tool's live-updates watch, armed on
publish and re-armed on resume; Monitor waits) are passive wake triggers
with no completion of their own and are never counted — one artifact watch
otherwise pins `background` for the life of the session (observed live).
`Stop` re-fires when owned background work completes (the
completion re-invokes Claude for a wrap-up turn). The last Stop's array is
snapshotted to `$AM_STATE_DIR/<session>.bg` so a field-less `idle_prompt`
can re-check leftovers after wrap-up. No pane scraping.

The race guard in `state-hook.sh` protects `background`
unconditionally: a background subagent's own tool calls fire
`PreToolUse`/`PostToolUse` in the session for as long as it runs, and must
not flip the state to `running`; only `UserPromptSubmit` or the next `Stop`
moves it forward. `ready` gets a *bounded* guard instead (grace
window, `AM_STATE_GUARD_SECS`, default 10s): the trailing-hook race it
absorbs is milliseconds-scale, and a turn can resume without
`UserPromptSubmit` (answering an in-turn question dialog continues the same
turn), so tool hooks arriving after the window are genuine activity and flip
the state back to `running`.

History note: earlier revisions scraped pane content for a fourth signal
layer (background-wait banner, "N shell(s)" mode-line counters, hollow-bullet
agent panels, end-of-turn status classification with box-chrome/todo-widget
anchoring). That machinery misread live turns whose hook file and tmux
activity had both gone stale (>180s quiet tool calls are routine) and flapped
sessions through running/unknown/background hundreds of times a day.
The title glyph replaced all of it; do not reintroduce broad pane-content
classifiers for state. The sole narrow exception is Cursor's own structural
footer task counter, consulted only after its authoritative `✅ Ready` title
has established that the main turn is idle. Empirical ground truth lives in
`tests/live_lab/`.

**Pi sessions:** State comes from the in-process extension
`lib/hooks/am-state.ts` (`session_start` / `agent_settled` → `ready`,
`agent_start` → `running`), read ungated by `_state_resolve` (in-process
writes can't go silently stale; a dead pi drops the pane to a shell, which
the shell-pane check catches). Pi never reports `waiting_user` or `background`.

**Cursor sessions:** `~/.cursor/hooks.json` calls `state-hook.sh` for
`sessionStart`/`stop` (waiting) and prompt/tool/response activity (running).
The hook also writes `.sid` and `.transcript` identity sidecars from
`conversation_id` and `transcript_path`. Cursor hook state is read ungated:
turn-boundary events remain authoritative during long quiet tools, and the
shell-pane check catches process exit. Cursor 2026.08 added empirically stable
terminal-title suffixes: `✅ Ready`, `⏳ Working`, and `❓ Waiting for you`.
They self-heal missed/stale hook transitions and expose `waiting_user`
without broad pane scraping. The permission dialog still shows `⏳ Working`,
so it remains `running`. Cursor exposes no background-wait lifecycle event,
but while a Ready session owns background work its footer renders a nonzero
`<N> tasks` row after the exact `→ Add a follow-up` input placeholder (some
terminal captures also include the input border). `_state_resolve` matches only
that Cursor-owned structure to refine `ready` to `background`;
disappearance of the row returns it to `ready`. It cannot override a
Working title, and task-like text in
the conversation does not match.

### Verifying against real agents

`tests/live_lab/run.sh` drives a real `claude --model haiku` session in an
isolated tmux/state sandbox through every state (fresh idle, running,
permission dialog, background shell via `background_tasks`, AskUserQuestion
dialog, ctrl-b backgrounded turn, >180s quiet tool call) and records hook
payloads, state-file transitions, pane titles, and pane snapshots. Not part
of `test_all.sh` (spends real tokens, ~8 min). `tests/live_lab/run_pi.sh`
verifies pi state detection (session_start, agent_start, agent_settled). Run
the Claude lab when Claude Code updates or when changing `lib/state.sh` /
`lib/hooks/state-hook.sh`, and check `results/<ts>/report.txt` +
`timeline.tsv` for glyph/hook/state agreement.
`tests/live_lab/run_cursor.sh` records Cursor's fresh, running, permission,
question, subagent, stop, resume, and background-task footer behavior.
`tests/live_lab/run_pi.sh` covers pi.

**Version-drift canary.** Everything above is empirical, so an agent upgrade
can move the ground without any test failing. Two signals make that visible
in `am doctor` (sections "version drift" and "hook payload schema"):

- `tests/live_lab/VERIFIED` pins, per agent binary, the version the lab last
  confirmed (whitespace-separated: agent, version, date, lab script, note).
  Doctor warns when the installed version is newer than the pin (dotted
  numeric compare, suffixes ignored) and names the lab to re-run; each lab
  prints the installed version at the end of its run and appends an
  `agent_version` line to `report.txt`. Update the pin only after the report
  agrees. Codex has no lab and is reported as unverified.
- The state hook records the sorted top-level keys of every payload it sees
  in `$AM_DIR/hook-schema/<agent>.<event>.keys` (subagent-originated tool
  events, which carry `agent_id`, in a separate `.sub` file), rewritten only
  when the set changes with the previous set kept in `.keys.prev`. Doctor
  lists them, shows the diff against the previous set, and warns when a
  field the hook reads is missing (`hook_event_name`, `session_id`,
  `transcript_path`, `cwd` on every Claude event; `stop_hook_active` +
  `background_tasks` on `Stop`; `notification_type` on `Notification`;
  `conversation_id` on Cursor events). Written from the hook's detached tail,
  so it costs Claude's turn nothing.

### Debug instrumentation

- `AM_STATE_DEBUG=1` — `_state_resolve` appends one line per call to
  `$AM_DIR/.state-debug.log` (`<iso8601>\t<session>\t<agent>\t<source>\t<state>`)
  recording which layer (`shell` / `title` / `pane` / `hook` / `fallback` /
  `classify_exit`) produced the answer. Use for empirical data on which
  fallbacks are still load-bearing before cutting them.
- `$AM_DIR/gc.log` — always on: every registry row or hook state file GC
  removes, with the removing process's subcommand, AM_DIR, tmux socket,
  session prefix, and live-set size. A state file that vanishes under a live
  session is a GC problem until this log says otherwise.
- `AM_HOOK_DEBUG=1` — `state-hook.sh` appends to `$AM_DIR/.hook-debug.log`
  every time a hook fires but exits without writing state (registry miss,
  missing `AM_SESSION_NAME`, cwd mismatch). Surfaces vanished-session bugs
  that otherwise look like ghosts.

Both are opt-in. Logs are append-only; rotate externally if they grow.

## Agent-to-Agent CLI Guide

Use these commands when one CLI process or agent needs to launch, monitor, or message another `am` session without attaching to it.

### Launch a background session

Use `am new --detach` when the caller should keep control of its own terminal:

```bash
am new --detach ~/project
am new --detach --print-session ~/project
printf 'Investigate the test failure\n' | am new --detach --print-session ~/project
```

- `--detach` creates the tmux session and does not attach.
- `--print-session` writes the new session id to stdout, which makes scripting easier.
- Stdin becomes the initial prompt. `am` waits for the agent pane to be ready, then injects that prompt.

### Send a follow-up prompt

Use `am send` to talk to an already-running session:

```bash
am send am-abc123 "Review the latest diff"
printf 'Run the test suite and summarize failures\n' | am send am-abc123
```

- Session resolution supports exact names, stripped prefixes, and single fuzzy matches.
- Prompt text may come from argv or stdin.
- The prompt is pasted literally into the top agent pane, then Enter is sent.

### Peek at another session

Use `am peek` when you need visibility without attaching:

```bash
am peek am-abc123
am peek --pane shell am-abc123
am peek --follow am-abc123
am peek --pane shell --follow am-abc123
am peek --pane shell --history --lines 200 am-abc123
am peek --pane shell --history --grep "ERROR|FAIL" --lines 50 am-abc123
```

- Default pane is `agent` (top pane). `--pane shell` targets the shell panel — it follows the panel into the hidden `_amshell` window when toggled away, and errors with guidance (`am shell <session>`) when the panel was never opened (sessions start agent-only).
- Plain `am peek` returns a snapshot using tmux pane capture.
- `am peek --follow` prefers streamed pane logs when available and falls back to polling tmux output.
- `am peek --pane shell --history` reads the full streamed scrollback from `/tmp/am-logs/<session>/shell.log` instead of the viewport. Supports `--lines N` (default 200) and `--grep PAT` (filtered via `grep -E` then `tail`). Output is already ANSI-stripped. Mutually exclusive with `--follow`. See `skills/am-peek/SKILL.md` for context-conserving usage patterns.
- This follow contract is the right primitive for a future web wrapper: CLI and web can share the same snapshot/stream model.

### Recommended automation pattern

For agent orchestration, prefer this sequence:

1. Start worker: `session=$(am new --detach --print-session ~/repo)`
2. Give task: `printf 'Implement X\n' | am send "$session"`
3. Monitor progress: `am peek --follow "$session"`
4. Hand control to a human later: `am attach "$session"`

### Operational caveats

- `am peek --follow` is near-real-time, not a structured event stream.
- Log streaming is on by default (`stream_logs=true`). Follow mode tails `/tmp/am-logs/<session>/{agent,shell}.log`.
- If logs are disabled (`am config set logs false`), follow mode polls tmux pane text once per second.
- Every session exports `$AM_LOG_DIR` into both panes, pointing to `/tmp/am-logs/<session>/`.
- `am send` and `am peek` are transport primitives. They do not confirm task completion or parse agent state.

### Relabel a session that moved

The tab label (`dir/branch`) follows where the agent works, not where it was
launched. Claude Code sessions need nothing: the state hooks carry the Bash
tool's tracked cwd, and the branch is re-read from `.git/HEAD` on the 60s
title scan. For agents without hooks, or to fix a label by hand:

```bash
am cd ~/code/pink-wekapp     # from inside the session (agent pane or shell panel)
am cd                        # default: the caller's cwd
```

`wp allocate` / `wp checkout` call it themselves when run inside an am
session. The launch directory is kept for restore.

### Restore a closed session

Use `am restore` to browse recently closed Claude sessions and resume one:

```bash
am restore
```

- Opens an fzf picker showing closed sessions with pane snapshot previews.
- Sessions are available as long as their harness conversation identity remains resumable.
- Enter uses the harness-native adapter (Claude/Cursor `--resume`, pi `--session`, Codex `resume`).
- Also available as `Ctrl-H` in the main session browser (`am` with no args).

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, agent_args...)` - Creates session, registers, starts agent. `--shell`/`--no-shell` are consumed here; every other arg reaches the agent verbatim
- `agent_kill(name)` - Kills tmux + removes from registry
- `agent_kill_all()` - Kill all agent sessions
- `agent_info(name)` - Show session info
- `auto_title_scan([force])` - Wrapper over `am-core titles` (Go `RefreshTitles`, then `RestoreScan`): for every registry row, refresh the workdir field (from the .cwd sidecar) and the branch field (from the effective directory's .git/HEAD), then the task field from the agent pane title; when the title is empty or invalid and the row has no task, fall back to the first user message of the transcript bound by the session's own hook sidecar (`DetectID` + `FirstMessage`); an invalid title never replaces an existing task (hysteresis). Throttled 60s on `$AM_DIR/.title_scan_last`, shared with the am-browse / am-list-internal path (which calls `RefreshTitles` in-process). Always chains into `sessions_log_scan` (even when title-throttled), which runs on its own `$AM_DIR/.restore_scan_last` marker so the browser stamping first can't starve it.
- `agent_resume_args(agent_type, session_id)` - The manifest resume template with `{id}` expanded, one arg per line (claude/cursor → --resume, pi → --session, codex → resume); empty for unknown types
- `agent_restorable(agent_type)` - True when the manifest gives the type a resume form: gates the sessions-log append at launch and the snapshot/close at kill (Go twin `AgentSpec.Restorable`)

**Pane environment / workspaces:**
- `agent_pane_env(session_name, agent_type)` - Print the `VAR=VALUE` lines every am pane starts with (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, `AM_LOG_DIR` when streaming); consumed by `tmux_create_session` and the shell-panel `split-window -e`
- `agent_dir_resolve(@spec)` - Run the configured dir_provider's resolve verb (via `_agent_dir_provider_run`, which blanks AM_SESSION_NAME so a dispatcher is not relabelled by the worker's provider call) and return the directory it prints; errors with setup guidance when no provider is configured, when it fails, or when the output is not an existing directory
- `agent_dir_suggest(partial)` - The provider's suggest verb, run in its own process group under a perl alarm (`am_dir_suggest_timeout`) that kills the whole group on timeout (killing only the top process leaves its children holding the pipe open); prints spec-TAB-label lines, empty on no provider / no match / timeout (never an error)
- `agent_set_workdir(session_name, dir)` - Record where the agent works now: write the .cwd sidecar and apply the registry workdir (empty when equal to the launch directory) + branch refresh immediately, then redraw. Backs the cd command; never touches the directory field
- `current_session()` (in the am entry point) - Name of the am session the caller runs inside; backs the id command (aliases current, whoami) and the no-arg defaults of the shell and info commands

**Shell panel (collapsible; sessions launch agent-only by default):**
- `agent_shell_pane_add(session_name)` - Create the shell panel below the agent: split in the session directory, wire `AM_SESSION_NAME`/`AM_AGENT_TYPE`/`AM_IDENTITY_DIR`/`AM_LOG_DIR` exports + shell.log pipe-pane. Registry-driven, so it serves both `--shell` at launch and on-demand opening
- `agent_shell_pane_toggle(session_name)` - absent → add, open → hide, hidden → show; backs `am shell` and prefix+\` (via bin/toggle-shell)
- `tmux_shell_pane_state(session)` - Print absent/open/hidden from live tmux (no persisted layout state)
- `tmux_shell_pane_hide(session)` / `tmux_shell_pane_show(session)` - Park the panel in the hidden _amshell window / rejoin it below the agent (tmux break-pane/join-pane; the pane keeps running, so cwd, history, jobs, and pipe-pane streaming survive). Hide/show also toggle the window's pane-border-status so a lone agent pane wastes no row
- `tmux_main_window_id(session)` - @id of the session's non-_amshell/_amreview window; unambiguous even when the current window is a hidden one

**Review pane (collapsible, at the agent's right):**
- `agent_review_pane_add(session_name)` - Split the main window horizontally (`AM_REVIEW_WIDTH`, default 45%) in the session's effective directory, tag the pane `@am_role=review`, run `bin/am-review --session --dir --am [--am-dir --state-dir]`, give it focus. Errors outside a repository (exit 3) or when the binary is not built
- `agent_review_pane_toggle(session_name)` - absent → add, open → hide, hidden → show; backs `am review` and prefix+v (via bin/toggle-review)
- `tmux_pane_role_set(pane_id, role)` / `tmux_session_pane_by_role(session, role)` - Write / find the @am_role pane option across the session's windows (hidden ones included); the shell helpers (`tmux_shell_pane_id`) and `tmux_session_pane_target` (role agent → the top-left pane, roles shell / review → the tagged pane) resolve through it
- `tmux_review_pane_state(session)` / `tmux_review_pane_hide(session)` / `tmux_review_pane_show(session)` - absent/open/hidden from live tmux; park in / rejoin from the hidden _amreview window (break-pane / join-pane -h at the agent's right). `_tmux_border_status_sync(session)` turns pane-border-status on only while an auxiliary pane is visible

**Reboot recovery (`lib/recovery.sh`):**
- `recovery_desired_upsert/remove/identity()` - Maintain `desired_sessions.json`, the durable set of sessions the user still considers open
- `recovery_migrate_live_registry()` - One-time/idempotent capture of already-live sessions after upgrade
- `recovery_desired_candidates()` - Return exact-identity, prior-boot sessions missing from tmux
- `recovery_start_for_browser()` - Queue recovery only for the interactive browser and launch the detached worker
- `recovery_run()` / `recovery_restore_one()` - Locked, bounded-concurrency coordinator and per-session preflight/native resume. Resume runs in the record's project_directory (the launch cwd that keys the transcript store), never the effective workdir; the record also carries the branch, and preflight refuses a reused checkout whose branch changed (`branch changed: expected X, found Y`)
- `recovery_apply_workdir()` - After a successful resume, re-apply the recorded workdir (`.cwd` sidecar + registry) so the tab label survives the reboot
- `recovery_revoke_identity_rebind()` - Drop the `.rebind` marker when a launch fails, so the next hook event cannot re-pin a stale identity
- `recovery_sync_live_sidecars()` / `_recovery_mirror_sidecar()` / `recovery_desired_set_workspace()` - On browser open, mirror each live session's `.cwd`/`.bg` sidecars into the durable identity dir and refresh the desired record's workspace fields

**Title helpers (Go only, `internal/sessions/titles.go`):**
- `titleValid` - <=60 chars, no newlines, not the bare `Claude Code` placeholder
- `normalizeTitle` - Strip Claude's transient decorations (a trailing ` - 🔄 Reconnecting…` segment, a trailing ` - <dirname>`); `piTitleExtract` / `cursorTitleExtract` handle pi's `pi - <name> - <dir>` shape and Cursor's status suffixes. The scan applies hysteresis: an invalid pane title never replaces an existing task (the first-message fallback only fills an empty one)

**Presets (lib/presets.sh):**
- `am_preset_names()` / `am_preset_get(name)` / `am_preset_field(name, field)` - Read presets from config.json (the args field prints one per line; shell prints true/false; directory may be a `@spec`, and a pre-0.24 workspace+branch pair reads back as `@branch`)
- `am_preset_save(name, json)` / `am_preset_rm(name)` - Write / delete under the presets key of config.json; the key is dropped when empty
- `_preset_from_flags(flags...)` - Build the JSON object from `am new`-style flags (`-t -d -n --shell -- args`; the positional directory may be a `@spec`)
- `_preset_render(name)` - Equivalent `am new` command line, shell-quoted
- `preset_main(sub, ...)` - Entry for `am preset save|list|show|rm|help`
- `_cmd_new_apply_preset(name, fill)` (in the am entry point) - Merge a preset into cmd_new's locals; fill=true also supplies directory (path or `@spec`)/agent/task where the flags left gaps

**Dispatch (in the am entry point):**
- `_wait_many(mode, states, timeout, json, sessions...)` - Multi-session wait behind `am wait --all|--any`; one background `agent_wait_state` per session, results in a private tmpdir, exit 3 when any timed out
- `cmd_done` / `cmd_result` - Worker-recorded summary in `$AM_DIR/results/<session>.txt` (mode 700 dir); `result --wait` polls until the file exists or the session ends (exit 2)
- `_fzf_state_selected(state)` (lib/fzf.sh) - `am list --state` filter, driven by `AM_LIST_STATE_FILTER`

**Review checkpoints (lib/review.sh, Go `internal/sessions/review.go`):**
- `review_diff_main(args...)` - `am diff` entry: flags (`--ack`, `--reset`, `--list`/`-l`, `--checkpoint`/`-c id`, pass-through `--stat`/`--name-only`/`--numstat`/`-w`/`-U`, `--` for raw git diff args), session from the argument or `current_session`, directory from `review_session_dir` (workdir, else directory). Exit 2 unknown session, 3 not a repository
- `review_session_dir(session)` / `review_init(session, dir)` / `review_adopt(old, new, dir)` - Registry lookup and the two lifecycle wrappers over `am_core review-init` / `review-adopt`
- `_review_show(session, dir, from, git_args...)` - `am-core review-stat` (`--record` updates the registry count unless `--checkpoint` was given), header line on stderr (`<session>: 7 files +212 −48 since the ack checkpoint 3f2a1c0 (5m ago); HEAD moved: …`), then `git -C dir diff base_tree cur_tree`
- Go: `ReviewInit` (launch checkpoint of the worktree, idempotent), `ReviewAck` (worktree → new baseline), `ReviewSync` (HEAD vs newest checkpoint: branch name changed → a branch-kind checkpoint of `HEAD^{tree}` and baseline move; same branch, new sha → a head-kind checkpoint, baseline stays), `ReviewSetBaseline` / `ReviewResetBaseline` (to launch), `ReviewDiffStat(dir, base_tree)` (`git diff --numstat base_tree <worktree tree>`), `HeadMoved`, `ReviewAdopt` (rename refs), `ReviewDrop`. Chain writes are CAS `update-ref` on the checkpoints ref, so concurrent writers (hook tail, tick, `am diff`) cannot lose a checkpoint. `Env.ReviewMeasure(session, dir, from, record)` syncs first and creates the launch checkpoint on demand for pre-0.25 sessions; `Env.ReviewRecord` writes the registry fields review_files / review_added / review_deleted / review_at under the registry lock
- Sidecars: `$AM_STATE_DIR/<session>.dirty` (touched by the hook on every tool event; the scan re-measures when it is newer than the row's review_at), `<session>.head` (the hook's fork-free HEAD snapshot: `ref: refs/heads/x <sha>` or a bare sha). Both removed by `agent_kill` and GC

**Doctor (lib/doctor.sh):**
- `doctor_main([--capture] [session])` - Global report (versions, dirs, markers, hooks installed, version drift, hook payload schema, per-session summary) or one session in depth; `--capture` writes a tarball under `$AM_DIR/doctor/` (includes `hook-schema/`)
- `_doc_resolve_state(session, state_var, layer_var)` - Runs `agent_get_state` with `AM_STATE_DEBUG=1 AM_STATE_DEBUG_SINK=<tmp>` to learn which resolver layer answered
- `_doc_hooks_installed()` / `_doc_hooks_check(label, file, optional, helper|-, events...)` - Per-family check that the events scripts/install.sh registers name the am hook: Claude (settings.json, nested command shape), Codex and Cursor (optional hooks.json; Cursor's flat shape runs a byte copy of the hook, compared with cmp - a stale copy points at `am install --refresh`)
- `_doc_drift()` - Version-drift canary: installed agent versions vs `tests/live_lab/VERIFIED` pins (`AM_VERIFIED_FILE` overrides the path), then every `$AM_DIR/hook-schema/*.keys` file against the fields the hook reads (`_doc_required_keys`), with `_doc_keys_diff` against `.keys.prev`
- `_doc_ver_newer(a, b)` / `_doc_ver_core(v)` / `_doc_agent_version(agent)` - Dotted-numeric version compare (missing components are 0, non-numeric never compares newer), version-string core extraction, first line of `<agent> --version`

**Notifications (lib/hooks/state-hook.sh, lib/config.sh):**
- `_notify_maybe(session, state)` - Fired from the hook's detached tail only on a state transition into one of the configured notify states; skipped when an attached client displays the session; `AM_NOTIFY_CMD` env > notify_cmd config > osascript / notify-send
- `am_notify_enabled()` / `am_notify_states()` - Config readers (notify: bool, default true; notify_states: default waiting_user; notify_cmd: string)

**Install fingerprint (in the am entry point):**
- `_install_inputs()` / `_install_fingerprint()` - Version + cksum over the mtimes of everything `am install` derives artifacts from (am, lib/tmux.sh, hooks, scripts/install.sh, skills, Go sources)
- `_install_is_stale()` / `_install_stamp_write()` / `_install_refresh([quiet])` / `_install_refresh_if_stale()` - Stamp compare, quiet idempotent refresh (skills, Go build when sources newer, tmux.conf), browser hook (`AM_NO_INSTALL_REFRESH=1` disables); `am install --refresh` runs it by hand

**Registry (JSON metadata):**
- `registry_add/get_field/get_fields/update/remove` - CRUD for sessions.json. All writes are read-jq-rename cycles serialized under an exclusive lock on `$AM_REGISTRY.lock` (`_registry_lock`/`_registry_unlock`: the flock CLI on Linux, a perl flock syscall on an inherited fd on macOS — no flock CLI there; **not reentrant**, don't nest). The Go twin (`internal/sessions/lock.go:lockRegistry`) takes the same lock via `syscall.Flock`, so bash and Go writers can't lost-update each other; `RefreshTitles` computes titles unlocked, then re-reads and applies under the lock. The bash writers lock first and mktemp inside the lock (a writer blocked on the lock owns no temp file; the temp is removed when jq or the rename fails)
- `am_tick([force])` - One maintenance tick, `am-core tick`: `RefreshTitles`, `RestoreScan`, and both GC halves, each on its own marker. The status-bar tick and `am list` call this and nothing else
- `registry_gc([force])` - Wrapper over `am-core gc` (Go `GC`); prints the number of registry rows removed. Two independently throttled halves: registry rows + hook state files (incl. `.sid`/`.transcript`/`.cwd`/`.bg` sidecars) on `$AM_DIR/.gc_last` — `ReapOrphans`, also run by the am-browse / am-list-internal path: one lock, tmux snapshot taken inside it, one rewrite, rows younger than `AM_GC_GRACE_SECS` (default 5) spared; extras on `$AM_DIR/.gc_extras_last`: orphan state files and sidecars under the session prefix (skipped entirely when tmux lists no session — the state dir is shared, see Gotchas), `SessionsLogGC`, `SnapshotGC` (unreferenced snapshots older than 10 min), leaked temp sweep (`.sessions-log.*` >60s, `.dir_repo_cache.tmp.*` and `*.log.??????` >1h)
- `_registry_tmp_guard(tmp)` / `_registry_tmp_release()` - Signal-safe temp files for the bash sessions-log rewrites (`sessions_log_update`): lock first, then mktemp, then trap HUP/INT/TERM/PIPE to remove the temp, release the lock, restore the caller's traps and re-raise
- Titler trace: `AM_TITLER_DEBUG=1` makes the Go scan append to `$AM_DIR/titler.log` (off by default; an ungated version once grew it to 84MB). Each unthrottled title scan caps `titler.log`, `.state-debug.log`, `.hook-debug.log`, `gc.log` at 20MB, keeping the newest half (Go `capLog`)
- GC audit: `$AM_DIR/gc.log` (Go `gcLog`, always on, one line per removed registry row or state file: timestamp, `am-core <sub>`, AM_DIR, socket, prefix, live-set size, cwd, what was removed). `AM_GC_LOG=<path>` redirects it, e.g. to catch a test run's removals in one file

**Sessions log (for restore):**
- `sessions_log_append(session_name, directory, branch, agent_type, [task])` - Append session to `~/.agent-manager/sessions_log.jsonl`
- `sessions_log_update(session_name, field, value)` - Update field in most recent log entry for a session
- `sessions_log_snapshot(session_name, [snapshot_key])` - Capture pane text to `~/.agent-manager/snapshots/`
- `sessions_log_scan([force])` - Wrapper over `am-core restore-scan` (Go `RestoreScan`): rolling pane snapshots + session_id binding + task/branch sync into the log for live Claude, Codex, Cursor, and pi sessions that have a log entry (throttled 60s via `.restore_scan_last`); chained from `auto_title_scan`. Ephemeral and durable hook sidecars are authoritative for session_id: a logged sid that disagrees with the sidecar is corrected (heals wrong guesses, tracks forked resumes) and the snapshot is re-keyed; with no sidecar nothing is guessed. All log updates of one scan are a single locked rewrite
- `sessions_log_gc()` - Wrapper over `am-core slog-gc` (Go `SessionsLogGC`): drop entries whose transcript is gone (and their snapshot) and id-less entries older than 24h; lines this version cannot parse are kept verbatim
- `sessions_log_restorable()` - Wrapper over `am-core restorable` (Go `Restorable`): raw JSONL lines of sessions that can be restored (resumable agent, id bound, not alive, transcript present), newest first, one per conversation id
- `_sessions_log_detect_id_for_session(session_name, directory, [agent])` - Wrapper over `am-core detect-id` (Go `DetectID`): the conversation id bound to a session — the sidecar its own hook wrote (durable identity first, then the ephemeral `.sid`), verified against the agent's transcript store (codex ids are taken as-is). No directory-based guess — the store is shared with other sessions and with agents outside am
- `_sessions_log_field(session_name, field)` - Read a field from the most recent sessions-log entry for a session
- `_sessions_log_jsonl_exists(directory, session_id, [agent], [transcript_path])` - Wrapper over `am-core jsonl-exists` (Go `JSONLExists`): whether the transcript still exists (agent defaults to claude; cursor checks the hook-reported transcript path first)
- `_sessions_log_sidecar_id(session_name)` / `_sessions_log_sidecar_transcript(session_name)` - First line of the ephemeral or durable `.sid` / `.transcript` sidecar (bash readers for `agent_kill`)
- `_slog_encode_pi_dir(directory)` - Encode directory path for pi session storage (strip leading slash, replace [/\:] with -, wrap with --)
- `_pi_sessions_root()` - Return pi sessions root (~/.pi/agent/sessions)

**State detection (lib/state.sh):**
- `agent_get_state(session_name)` - Public entry: checks existence, looks up registry fields, delegates to `_state_resolve`, and returns one canonical lifecycle state. State-file reads and `am wait --state` accept the pre-0.12 `waiting_*` aliases, but all public output is canonical.
- `_state_resolve(session, agent_type, dir [, top_pid_map, comm_map, children_map, now_epoch [, activity_epoch [, title_map [, created_epoch [, cursor_tasks_map]]]]])` - **Single source of truth** for state derivation. Without bulk fixtures (last args), forks per-session for tmux/ps (fetching pane_pid + session_activity + pane_title in one call); with bulk fixtures passed by nameref (bash 4.3+), reads pre-built maps in place, plus optional per-session activity epoch, title map, created epoch, and pre-probed Cursor task signal. Used by `agent_get_state` / `lib/fzf.sh` (non-bulk) and `lib/status-bar` (bulk; passes tmux `#{session_created}` as created_epoch). Canonical order: shell pane check → title glyph/status × hook state → Cursor Ready-footer refinement → hook state when the title carries no signal → unknown. Bulk and non-bulk shell-pane semantics agree: shell pane + session <5s → starting (bulk needs created_epoch, else idle), otherwise idle; dead from `agent_classify_exit` is a non-bulk race-window branch only — missing sessions are reported dead by `agent_get_state`'s existence check
- `_state_title_signal(title, out_var)` - Classify Claude's self-maintained pane title into busy (braille spinner frame U+2800–U+28FF, or circle-phase glyph ◐◓◑◒ U+25D0–U+25D3 on Claude Code ≥2.1.232) / attention (✳) / none. Byte-oriented (LC_ALL=C) so it is locale-independent; fork-free
- `_state_cursor_tasks_signal(pane_text, out_var)` - Detect Cursor's nonzero footer task count only after the current `→ Add a follow-up` placeholder or captured input border; later footers supersede stale rows still visible in scrollback
- `agent_wait_state(session, [states], [timeout])` - Block until target state reached
- `agent_classify_exit(session)` - Classify shell exit as idle or dead
- `_state_hook_raw(session, out_var)` - Read the hook file ungated and canonicalize pre-0.12 aliases; used by title/status layers even when the file is stale
- `_state_has_identity(session)` - True when an identity sidecar exists (`$AM_STATE_DIR/<s>.sid` or `$AM_IDENTITY_DIR/<s>.sid`): proof that the session's hooks have fired. Fork-free; gates the fresh-session `✳`+no-file → ready branch, so a state file removed under a live session reads as unknown rather than ready
- `_state_hook_read(session, out_var [, now_epoch [, activity_epoch]])` - Gated hook-file read for agents without reliable turn-boundary events. Ready, waiting_user, and background persist; running gets a 180s staleness gate measured against max(file mtime, tmux session_activity), so a wedged agent falls to unknown. Claude, Cursor, and pi bypass this gate because long live turns routinely outlast it.
- `_state_pane_is_shell_bulk(session, top_pid_map, comm_map, children_map)` - Detect whether top pane is a plain shell (vs an agent process) from nameref bulk maps

**Utils:**
- `am_agent_manifest_load()` - Parse `$AM_AGENT_MANIFEST` (default `lib/agents.manifest`) once per process into the field table and `AM_AGENT_TYPES` (file order); runs when utils.sh is sourced
- `am_agent_field(type, field, [out_var])` - One manifest fact for a type or alias; empty for unknown types/fields and `-` values. Fork-free with out_var (status-bar hot path)
- `am_agent_normalize(name, [out_var])` / `am_agent_known(name)` - Alias → canonical type (unknown names pass through) / membership test
- `_format_seconds(seconds, [ago])` - Shared duration formatter (used by `format_time_ago`/`format_duration`)
- `am_file_mtime(file, [out_var])` / `am_files_mtime(assoc, files...)` - Portable mtime, flavor picked once from `$OSTYPE` (no probe fork); the batched form is one stat call for all files (status-bar tick, install fingerprint)
- `am_file_mode(path)` / `am_file_size(path)` - Octal permission bits / byte size through the same flavor logic (`_am_stat_field`, regex-validated with a one-time flavor flip). Use these instead of `stat -f X || stat -c Y`: on GNU coreutils `stat -f` is filesystem status and succeeds with a blob, so the fallback never runs (the CI-only doctor crash and eight 0700 test failures on 2026-09-07)
- `am_core(subcommand, args...)` - Run `$AM_ROOT_DIR/bin/am-core` with the caller's effective paths passed explicitly (`AM_DIR`, `AM_SESSIONS_LOG`, `AM_TMUX_SOCKET`, `AM_SESSION_PREFIX`, and `AM_STATE_DIR` / `AM_IDENTITY_DIR` when set) — bash derives them after sourcing and tests re-point them, so exports cannot be trusted. Missing binary: one stderr line, return 127; the periodic wrappers turn that into 0, the query wrappers into a failed lookup
- `am_mkdir_private(dir)` - `mkdir -p` with mode 700 (state, log, results, queue dirs)
- `git_head_branch(dir, [out_var])` - Fork-free branch lookup: walk up to the nearest `.git` (dir or worktree/submodule pointer file), read HEAD → branch name, 8-char sha when detached, empty outside a repo. `detect_git_branch` delegates to it; Go twin `GitHeadBranch`
- `claude_first_user_message(dir, session_id)` - Wrapper over `am-core first-message claude` (Go `FirstMessage`): first user message of exactly the Claude transcript bound to a session; the directory only locates the per-project store. No id → empty (never the newest file in the store). Used by the preview and doctor scripts
- `pi_first_user_message(dir, session_id)` - Pi twin, same contract (`AM_PI_SESSIONS_DIR` overrides the store root)
- `cursor_first_user_message(dir, [session_id], [transcript_path])` - Cursor twin: the hook-reported transcript path, else the standard layout addressed by id (`AM_CURSOR_PROJECTS_DIR` overrides the root); neither → empty

**tmux:**
- `tmux_create_session(name, dir, [VAR=VALUE...])` - New detached session; env args are passed as new-session -e and stored in the session environment so later splits inherit them
- `tmux_get_activity(name)` - Last activity timestamp
- `tmux_get_created(name)` - Session creation timestamp
- `tmux_enable_pipe_pane(session, pane, file)` - Stream pane output to log file
- `tmux_pipe_pane(target, file)` - Same, for a raw pane target (e.g. a `%id`)
- `tmux_cleanup_logs(name)` - Remove log directory for a session
- `tmux_list_am_sessions()` - List all am-* session names
- `tmux_send_keys(session, keys)` - Send keys to a tmux pane
- `tmux_pane_title(target)` - Read pane title set by the application
- `tmux_count_am_sessions()` - Count active sessions
- `am_session_order()` - Canonical sidebar order: tmux session creation time ascending (oldest first, newest appended). Stable — only changes on create/kill
- `am_refresh_sidebar_cache()` - Regenerate each session's `@am_sidebar` tmux option and force a client-wide redraw. Called from `agent_launch` / `agent_kill` so pane-border updates are instant instead of waiting for the 5s `status-interval`

**Form (lib/form.sh):**
- `am_new_session_form(...)` - Entry point: parses prefill values, then runs the tput form
- `_form_init(directory, agent, task)` - Initialize form state and fields: Directory (a path or `@spec`), Agent, Task, plus Preset first when any preset exists
- `_form_run()` - Main loop: draw → read key → dispatch (navigate/edit) → repeat. Returns tab-delimited output on stdout
- `_form_process_key(key, [extra_seq])` - Route to `_form_process_key_navigate` or `_form_process_key_edit` based on `_FORM_MODE`
- `_form_draw()` - Buffer all fields + directory suggestions into `_FORM_BUF`, single write to `/dev/tty`
- `_form_filter_dir_suggestions(query, max)` - Filter cached zoxide/frecent list into `_FORM_DIR_FILTERED` array (no subshell); a `@` query instead fills it from `agent_dir_suggest` (one provider call per distinct partial, memoized in `_FORM_PROVIDER_CACHE`), as `@spec<TAB>label` rows, or the typed spec alone when the provider returns nothing
- `_form_size_to_terminal()` - Grow `_FORM_DIR_SUGGESTION_LINES` (default 7) to fill the terminal height; called once by `_form_run`
- `_form_output()` - Format form values as `directory<US>agent<US>task<US>flags` (US = \x1f); flags carries only `--preset=<name>`; a `@spec` directory skips path validation (rejected only when no dir_provider is configured)

**Session browser (Go TUI — `cmd/am-browse`):**
- Compiled bubbletea binary; primary UI for the interactive session browser
- Output protocol: session name (attach), `__NEW__`, `__RESTORE__`, or empty (cancel)
- Flags: `--preview-cmd`, `--kill-cmd`, `--client-name`, `--benchmark`

**fzf helpers (lib/fzf.sh):**
- `fzf_main()` - Launches am-browse; errors if the binary is not built (run make)
- `fzf_list_json()` - JSON output of sessions for `am list --json`
- `fzf_list_simple()` - Plain text session list for `am list`
- `fzf_pick_directory()` - Directory picker with git-branch annotations and path completion
- `_annotate_directory(path)` - Annotate path with its current git branch
- `_dir_repo_scan_cached()` - Git-repo suggestions for `_list_directories`, served from `$AM_DIR/.dir_repo_cache` and refreshed in the background when older than `AM_DIR_REPO_CACHE_TTL` (default 1h); the raw `_dir_repo_scan` find is ~1s+ on large trees and never runs on the interactive path
- `fzf_restore_picker()` - Browse closed sessions, select to resume via `claude --resume`

**Config:**
- `am_config_init()` - Initialize config file
- `am_config_get(key)` / `am_config_set(key, value)` - Read/write config
- `am_default_agent()` - Get default agent type
- `am_stream_logs_enabled()` - Check if log streaming is enabled
- `am_shell_pane_enabled()` - Whether new sessions open with the shell panel visible (shell_pane key, default false)
- `am_dir_provider()` / `am_dir_is_spec(dir)` / `am_dir_suggest_timeout()` - The command behind `@spec` directories (dir_provider key, env override AM_DIR_PROVIDER; empty disables specs), the `@` test, and the suggest cut-off in seconds (AM_DIR_SUGGEST_TIMEOUT, default 0.3). Stored case-preserving — the config set path skips its lowercase normalization for this key
- `am_config_key_alias()` / `am_config_key_type()` / `am_config_value_is_valid()` - Normalize and validate config keys and values

## Session Naming

Format: `am-XXXXXX` where XXXXXX = md5(directory + timestamp)[:6]

Display: `dirname/branch [agent] task Δ<files> +<add> −<del> (Xm ago)` — dirname comes from `workdir` when the agent moved, else `directory`; the Δ segment appears only when the session has unreviewed change (registry `review_files` > 0). The status bar fits it after the title and before the age, dropping the line delta first (`Δ7`) and the whole segment together with the ages

## Extension Points

| Task | Where |
|------|-------|
| Add agent type | `lib/agents.manifest` → one block of `<type>.<field>` lines (fields documented in the file header); a new transcript layout or title parser also needs its code in `internal/sessions/` (`storeJSONLExists`, `FirstMessage`, `refreshedTitle`) and `lib/doctor.sh` `_doc_transcript`; add a live lab and a `tests/live_lab/VERIFIED` pin |
| Add CLI command | `am` → `case "$cmd"` in `main()` |
| Change browser keybindings | `cmd/am-browse/main.go` |
| Change review pane keybindings or layout | `cmd/am-review/main.go` → `handleKey` / `layout`; diff parsing and rendering in `view.go` |
| Modify session display | `internal/sessions/sessions.go` → `FormatDisplayBase()` |
| Add metadata field | `lib/registry.sh` → `registry_add()` |
| Change preview content | `lib/preview` (session), `lib/dir-preview` (directory picker) |
| Change title source | `internal/sessions/titles.go` → `refreshedTitle` (the bash `auto_title_scan` only execs `am-core titles`) |
| Add periodic maintenance or a store query | `internal/sessions/maintenance.go` (+ `identity.go` / `slog.go`), a subcommand in `cmd/am-core/main.go`, a bash wrapper via `am_core` in `lib/registry.sh` or `lib/utils.sh`; Go parity test in `maintenance_test.go` (fake tmux: `fakeTmux`; bash: `setup_fake_tmux`) |
| Add tmux helper | `bin/` directory (sourced by tmux keybindings) |
| Add form field | `lib/form.sh` → `_form_init()`, add `_form_add_field` call + handle in render/dispatch (Preset is conditional on saved presets, so field indices only shift when any exist) |
| Write a directory provider | Any command answering `suggest <partial>` (lines `spec<TAB>label`, local state only, well under 0.3s) and `resolve <spec>` (prints an existing directory; stderr passes through). The form shows the first suggest row highlighted and Enter accepts it, so for an empty partial the provider should lead with the row it wants bare `@` + Enter to mean — an empty spec (`<TAB>label`) renders as `@` and resolves as `resolve ""`. Register with `am config set dir_provider <cmd>`. Reference implementation: `wp suggest` / `wp resolve` in `~/code/tools/wp`; test double: `tests/fake_dir_provider` |
| Change form keybindings | `lib/form.sh` → `_form_process_key_navigate()` / `_form_process_key_edit()` |
| Add config option | `lib/config.sh` → `am_config_init()` defaults, `am_config_key_alias/type/value_is_valid`, `am_config_print`; `am` → `cmd_config` get case + help |
| Add a preset field | `lib/presets.sh` → `_preset_from_flags` + `_preset_render`; `am` → `_cmd_new_apply_preset`; `lib/form.sh` → `_form_apply_preset` |
| Add a doctor section | `lib/doctor.sh` → new `_doc_*` function, called from `_doc_session` / `_doc_global` |
| Add a review checkpoint kind or `am diff` flag | `internal/sessions/review.go` → `ReviewSync` (when to record) + `reviewAdd` (whether the baseline moves); `lib/review.sh` → `review_diff_main` flag parsing; `lib/hooks/state-hook.sh` → `_review_head_check` if a new HEAD signal is needed |
| Change notification text/targets | `lib/hooks/state-hook.sh` → `_notify_maybe` |
| Add an install-derived artifact | `am` → `_install_inputs` (fingerprint) + `_install_refresh` (quiet rebuild) |
| Add state detection signal | `lib/state.sh` → extend `_state_resolve()` ordering |
| Add hook state event | `lib/hooks/state-hook.sh` → event-to-state mapping |
| Add/edit dispatch skill | `skills/agent-manager-dispatch/SKILL.md` |
| Add/edit peek skill | `skills/am-peek/SKILL.md` |
| Add new skill (auto-installed) | drop `skills/<name>/SKILL.md`; `am install` loops `skills/*/` |
| Add restore agent support | `lib/agents.manifest` → `resume` template, `store`, `preflight` (the bash `agent_resume_args` / `agent_restorable` and Go `AgentSpec.ResumeArgs` / `Restorable` read them); a new store layout needs its Go existence check and first-message reader |
| Change pi state mapping | `lib/hooks/am-state.ts` → event-to-state mapping |
