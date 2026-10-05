# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Commands

- Run tests: `./tests/test_all.sh`
- Run tests (summary): `./tests/test_all.sh --summary` — suppresses PASS lines, shows only failures with details and a counts summary
- Run perf benchmark: `./tests/perf_test.sh` — standalone latency check for `am list-internal`; not part of `test_all.sh` and should not leave resources behind
- Run live state-detection labs: `tests/live_lab/run.sh` (Claude), `run_cursor.sh` (Cursor), `run_pi.sh` (pi), and `run_opencode.sh` (opencode). They record hook payloads, pane titles, and transitions; they are opt-in and spend tokens.
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)
- Doc sync: `./scripts/check-docs.sh` — Key Files / Key Functions in this file exist, and `CHANGELOG.md` has an entry for `AM_VERSION` (`scripts/check-changelog.sh`); CI runs it
- Build the Go binaries: `make -s build` → `bin/am-list-internal`, `bin/am-browse`, `bin/am-core`, `bin/am-review`; `go vet ./... && go test ./...` for the Go side. `tests/test_all.sh` builds them first, because the bash maintenance wrappers exec `bin/am-core`

## Versioning

SemVer (`MAJOR.MINOR.PATCH`). Single source of truth: `AM_VERSION` in `am` (help text and `am --version` both read it — never hardcode a version string elsewhere).

When to bump (pre-1.0, so `MAJOR` stays `0`):

- **PATCH** (`0.2.0` → `0.2.1`) — bug fixes, doc/test/skill tweaks, internal refactors with no user-facing behavior change.
- **MINOR** (`0.2.0` → `0.3.0`) — new user-facing capability: a new `am` command/flag, a new pane/UI mode, restore/skill features, or a behavior change a user would notice.
- **MAJOR** — reserved; bump to `1.0.0` only on the first stability commitment.

How to bump: edit `AM_VERSION` in `am` in the same commit as the change that earns it, add the `## [x.y.z] - date` entry at the top of `CHANGELOG.md` in that commit (CI fails otherwise), and mention the bump in the commit body. Accumulate several small changes under one bump rather than bumping per-commit — bump when cutting a coherent batch. Patch releases are folded into the minor entry unless a user would notice.

## Code Style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- `events.log` is always on, so it is bounded by *where* it is written from, not by a flag: log failures and rare lifecycle events (launch, kill, restore, send, provider resolve), never the success of anything periodic or per-render — state resolution, the status-bar tick, `am list`, a hook's state write, the hook's no-pane exit (every non-am Claude takes it on every tool call). One stray `am_event` on the render path costs a fork-free append per tick per session and fills the 8MB cap with noise that buries the one line you needed
- Registry writes must go through `registry_add/update/remove` (or Go's `lockRegistry`-wrapped paths) — a bare jq-rewrite of `sessions.json` bypasses the write lock and reintroduces lost updates. Don't spawn background jobs while `_registry_lock` is held (children inherit the lock fd and keep the lock alive until they exit)
- Periodic maintenance and store queries run in `bin/am-core`; the bash names (`auto_title_scan`, `registry_gc`, `sessions_log_scan`, `sessions_log_gc`, `sessions_log_restorable`, `_sessions_log_detect_id_for_session`, `_sessions_log_jsonl_exists`, `*_first_user_message`) are one-line wrappers. Consequences: a bash function stub for `tmux_pane_title` / `tmux_capture_pane` no longer reaches the scan (tests put a fake `tmux` on PATH via `setup_fake_tmux`); `am_core` passes `AM_DIR`, `AM_SESSIONS_LOG`, the socket, the prefix, and `AM_STATE_DIR` / `AM_IDENTITY_DIR` explicitly, so anything else the Go side reads (`AM_GC_GRACE_SECS`, `AM_TITLER_DEBUG`, `AM_PI_SESSIONS_DIR`, `AM_CURSOR_PROJECTS_DIR`, `HOME`) must be exported; a missing binary is one stderr line, and the periodic wrappers return 0 so the status-bar tick never fails
- Sourced libs derive their own dir as `_<MODULE>_LIB_DIR` from `AM_LIB_DIR` (exported by the `am` entry point); standalone scripts like `lib/status-bar` set their own `SCRIPT_DIR`
- Tests source libs directly — test helpers like `registry_exists` live in `test_helpers.sh`, not in production code
- The shell panel is optional and collapsible: sessions launch agent-only (override: `--shell` / `am config set shell true`), and hiding the panel parks its pane in the hidden `_amshell` window. Session-keyed pane enumeration (e.g. status-bar's bulk `list-panes -a`) must skip that window or the parked shell's pid clobbers the agent pid and flips running sessions to idle. Non-bulk `.{top-left}` targets resolve against the session's *current* window — briefly wrong only if a user manually navigates into `_amshell` (self-heals on toggle)
- Auxiliary panes carry a tmux pane option `@am_role` (`shell` / `review`); the agent pane is the untagged one. The review pane (`am review`, prefix+v) splits to the agent's *right*, so "at top" no longer identifies the agent: address it as `.{top-left}` (never `.{top}`, which tmux resolves in the *active* pane's column — with the review pane focused it names the review pane), enumerate with `#{@am_role}` and take the first untagged top pane (status-bar bulk path), and resolve shell/review targets through `tmux_session_pane_by_role`. Its hidden window is `_amreview`; skip it wherever `_amshell` is skipped
- Never overwrite a live Go binary in place (`cp` onto `bin/am-core`, `: > bin/…`): macOS invalidates the code signature of the mapped file and every process running it dies with SIGKILL (rc=137, "Taskgated Invalid Signature" in `~/Library/Logs/DiagnosticReports`). `go build -o` is safe (it unlinks and recreates); a copy must go to a sibling temp file and `mv` into place. The install test's binary restore did this and intermittently killed other workers' `am-core review-init` / title scans
- Pane environment (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, `AM_LOG_DIR`) is seeded at pane creation via tmux `-e` (`agent_pane_env` → `tmux_create_session` env args / `split-window -e`) plus the session environment. Never `send-keys` an `export` into a pane: even a space-prefixed one lingers as zsh's most recent history entry, and the vars must exist before the agent command runs. Requires tmux ≥ 3.2 (`display-popup` already did)
- A directory argument starting with `@` is a provider spec, not a path: `cmd_new` hands it to `agent_dir_resolve`, which runs the configured `dir_provider` as `<provider> resolve <spec>` (bash -c, `AM_SESSION_NAME` blanked) and uses its stdout. The form passes `@spec` through unvalidated in the directory field; provider suggestions come from `<provider> suggest <partial>` under a timeout (`AM_DIR_SUGGEST_TIMEOUT`, 0.3s; Go `DirProviderSuggest` for the form, `agent_dir_suggest`'s perl alarm in bash) and are cached per typed partial for the life of the form. am never interprets a spec (PR number, branch, ...) — that is the provider's business
- lipgloss's default renderer probes stdout, and am-browse's stdout is captured by bash for the output protocol, so it reports no color support: any bubbles widget (textinput, cursor) left on its default styles loses its reverse video and colors there. Build every style from `ttyRenderer` (the `/dev/tty` renderer `initStyles` receives) — `newModel` and `newFormInput` do; `TestFilterCursorUsesTTYRenderer` guards the filter
- `scripts/check-docs.sh`'s Key Functions check validates only bash names (`^name()` in `lib/` and `am`): the camelCase Go names listed in this file are skipped by its regex, so a renamed Go function does not fail CI — keep those by hand
- osascript decodes environment variables as MacRoman: `system attribute "VAR"` turns a UTF-8 `·` into `¬∑` and curly quotes/dashes into mojibake (every notification banner read as gibberish until 0.27.3). Hand strings to AppleScript as script arguments (`on run argv` … `item 1 of argv`), which are decoded as UTF-8; `tests/test_state_hooks.sh` checks the hook never uses `system attribute`
- jq's `//` treats `false` as missing: `(.notify // true)` is `true` for `"notify": false`. Read boolean config keys with `if has("k") then .k else default end` (see `_notify_maybe`, `am_auto_restore_enabled`)
- The test stub agent is a bash script, so the shell-pane check resolves stub sessions as `idle`. Tests that send to a stub pass `am send --force`; the plain form is exercised once to prove the refusal
- Review checkpoints live in the session's repository (`refs/am/<session>/*`), not under `$AM_DIR`: `agent_kill` and `registry_gc` leave them alone (restore adopts them under the new session name), only `SessionsLogGC` drops them with the log entry. `WorktreeTree` copies the real index to a temp file and must preserve its mtime (`os.Chtimes`) — git only re-hashes entries whose file mtime is not older than the index, so a fresh copy hides a same-size edit made in the second after a commit. Never run `git add`/`stash` against the real index from am; the whole point is that review never touches the user's git state
- The hook state dir (`AM_STATE_DIR`, default `/tmp/am-state`) is shared by every AM_DIR, tmux socket, and session prefix on the machine, so the GC orphan sweep must never run against it from a mis-pointed environment. Two fences: Go `sweepOrphanStateFiles` does nothing when tmux lists no session (an empty live set almost always means the wrong server, not an empty machine), and every test gets its own `AM_STATE_DIR` (per worker in `tests/test_all.sh`, a temp dir when a test file runs directly). A test that points `AM_DIR` elsewhere must not undo that. `$AM_DIR/gc.log` (always on, capped with the debug logs, `AM_GC_LOG` overrides the path) records every row and state file GC removes with the caller's argv, AM_DIR, socket, prefix and live-set size — grep it first when a live session's state file vanishes. 2026-09-08: `tests/test_bin_helpers.sh` ticked with a stub tmux and wiped every real hook file on each suite run; waiting `background` sessions (no tool events) then showed `ready` until their next hook event
- Registry `directory` is the *launch* cwd and must never be rewritten: it keys the Claude/Cursor/pi transcript store (`~/.claude/projects/<encoded-dir>/`), the title fallback, session-id detection, and `am restore`. Where the agent works *now* lives in the separate `workdir` field (empty = same as `directory`), fed by the state hook's `/tmp/am-state/<session>.cwd` sidecar (Claude stamps hook payloads with the Bash tool's tracked cwd — the process cwd and tmux `pane_current_path` never move) or by `am cd`. Labels and the branch refresh read `workdir` first; state detection and restore read `directory`. The directory is a *hint* for the Claude transcript, not its key: `claudeTranscriptPath` (Go) tries the hook-reported path, then `<store of directory>/<sid>.jsonl`, then a search of every `~/.claude/projects/*/` (5s cache), because a session restored into another checkout keeps appending to the transcript under its *original* directory's store — a directory that may no longer exist

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. `install` / `uninstall` / `completions` are dispatched before the directory setup and dependency checks (`--dry-run` must create nothing; the rc block evals `completions` at every shell start) |
| `completions/am.bash`, `completions/am.zsh` | Shell completions printed by `am completions bash\|zsh` with `@AGENT_TYPES@` filled from the manifest; subcommands, per-command flags, config keys, preset names (`am preset list`), and live session names (`am list --json`) at completion time. `scripts/install.sh` adds `eval "$(am completions <shell>)"` to the rc managed block, shell chosen by the rc file's name |
| `scripts/install.sh` | PATH links, shell rc block (PATH + completions), legacy tmux block, and the agent hook installs; `--dry-run` prints every mutation, `--uninstall` reverses them (marker-tagged hook entries only; a user's own hooks stay). `am install` wraps it (`AM_INSTALL_NESTED=1`); run by hand it points at `am install` for skills and binaries |
| `scripts/check-changelog.sh` | CI guard: `CHANGELOG.md` must have a `## [<AM_VERSION>]` entry; called by `scripts/check-docs.sh` |
| `CHANGELOG.md` | User-facing changes per release, newest first |
| `lib/utils.sh` | Shared: colors, logging (`log_*` to stderr, `am_event` to the always-on `$AM_DIR/events.log`), time formatting, paths, agent JSONL extraction, the `am_core` wrapper |
| `internal/sessions/eventlog.go` | Go writer of `events.log` (`EventLog`), same TSV shape as `am_event`; `eventsLogCap` is the 8MB size cap the title scan applies |
| `lib/registry.sh` | JSON storage for session metadata (locked jq rewrites), sessions-log append/update/snapshot, and the thin bash wrappers (`am_tick`, `auto_title_scan`, `registry_gc`, `sessions_log_scan/gc/restorable`, detect-id, jsonl-exists) that exec `bin/am-core` |
| `lib/recovery.sh` | Durable desired-session store, boot/machine identity, reboot preflight, and progressive recovery worker |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/agents.manifest` | Agent adapter table (symlink to `internal/sessions/agents.manifest`, which Go embeds): per agent type, the launch command, aliases, prompt delivery (stdin/argv/argv:<flags>), resume-args template, transcript store layout, title parser, title→state signal, turn-boundary reliability, hook family, restore preflight, version binary, live lab. Bash reads it through `am_agent_field`; Go through `Agent()` / `AgentSpec`. Libs branch on these fields, not on agent names. The state hook resolves each type's `hook_family` from the manifest — the repo copy, or the copy `am install` materializes beside Cursor's out-of-repo hook byte copy (`<cursor hooks>/agents.manifest`) |
| `cmd/am-browse/newform.go` | The new-session form, a screen of the browser (Ctrl-N) and the whole program under `am-browse --new` (`am new` with no arguments). Two stages — directory-first launcher, then options (Preset first when any preset exists, Directory, Agent, Task) with navigate/edit modes — and one output line `__NEW_SESSION__␟dir␟agent␟flags␟task`. Text fields are bubbles `textinput` (line editing, bracketed paste) styled from `ttyRenderer` with a static cursor; replaced the bash `lib/form.sh` in 0.39 |
| `internal/sessions/config.go`, `dirs.go`, `provider.go` | The form's Go readers of what bash owns: `LoadConfig` (default agent, dir_provider, presets — a tolerant reader, `lib/config.sh` / `lib/presets.sh` do every write), `FrecentDirs` / `RepoScanCached` / `PathCompletions` (the Directory candidates; `.dir_repo_cache` is shared with `_dir_repo_scan_cached`), `DirProviderSuggest` (`<provider> suggest <partial>` under the 0.3s timeout, process group killed, `suggest.fail` event) |
| `lib/presets.sh` | Named launch presets for `am new -p` (stored under `presets` in config.json): `am preset save/list/show/rm` |
| `lib/review.sh` | `am diff [session] [--ack\|--reset\|--list\|--checkpoint id] [--stat] [-- git args]`: resolves the session (argument, else the caller's pane), asks `am-core review-*` for the baseline/worktree trees and the numstat, prints the header to stderr and runs `git diff <base_tree> <cur_tree>` so the user's pager and diff tools apply. The review lifecycle calls `am-core review-init` / `review-adopt` directly |
| `internal/sessions/review.go` | Review checkpoint store: per session a chain of commit objects under `refs/am/<session>/checkpoints` (kinds launch / ack / branch / head / rebase / pick; `anchor=` names the commit a rebase or pick tree sits on, `AnchorCommit()` is what `HeadMoved` and re-anchoring measure from) plus `refs/am/<session>/baseline`, in the session's own repository. `WorktreeTree` (temp index copied from the real one, mtime preserved, `add -A`, `write-tree`), `ReviewInit/Ack/Sync/SetBaseline/ResetBaseline/Adopt/Drop`, `ReviewDiffStat`, `Env.ReviewMeasure` (records the registry `review_*` fields) |
| `lib/doctor.sh` | `am doctor [session] [--capture]`: one report with every state input (registry row, tmux panes/titles, hook sidecars, identity, transcript, process tree, desired record, resolver layer via `AM_STATE_DEBUG_SINK`) plus the version-drift canary (installed agents vs `tests/live_lab/VERIFIED`, observed hook payload keys vs the fields the hook reads) |
| `cmd/am-browse/main.go` | Compiled Go TUI session browser (bubbletea); primary UI for `am` |
| `cmd/am-list-internal/main.go` | Compiled Go binary for fast session list generation |
| `cmd/am-core/main.go` | Compiled Go back end of the bash maintenance and query wrappers: `tick` (title/workdir/branch refresh + restore scan + gc, one status-bar tick), `titles`, `restore-scan`, `gc`, `slog-gc`, `restorable`, `first-message`, `detect-id`, `jsonl-exists`, `store-dir`, `transcript-path`, `sidecar`, `branch`, `branch-batch`, `head-signal`. Paths from the environment (`AM_DIR`, `AM_STATE_DIR`, `AM_IDENTITY_DIR`, `AM_SESSIONS_LOG`, `AM_TMUX_SOCKET`, `AM_SESSION_PREFIX`, `HOME`) with utils.sh's defaults |
| `internal/sessions/` | Shared Go package: tmux queries, registry parsing and locking, formatting, title/workdir/branch refresh (`titles.go`), session identity and transcript readers (`identity.go`), sessions-log rewrites (`slog.go`), the periodic maintenance entry points and GC (`maintenance.go`, `reap.go`), environment/paths (`env.go`) |
| `lib/fzf.sh` | Browser launcher (`fzf_main`), directory picker, restore picker, `am list` helpers |
| `lib/preview` | Standalone preview script (extracts first user message, captures pane) |
| `lib/status-bar` | Standalone script: renders whole bottom bar as a clickable session-tab strip (idx, state glyph, dir/branch label, title, age). Adaptive layout, one fit shared by every tab (`_fit_strip`): rungs are full `dir/branch · title` → branch-or-dir `· title` (water-filled, ≥12 chars/field) → title only (label for untitled sessions) → no ages; fields truncate with a 1-col `…` and default branches (main/master) are hidden. Tab age is time-in-state (state-file mtime) for waiting_* and running sessions, tmux activity otherwise. The dir half of the label is the registry `workdir` (where the agent moved) when set, else `directory`. Also writes `@am_sidebar` (label-only pane-border variant). `AM_STATUS_WIDTH` overrides the client-width probe for tests and ad-hoc inspection. |
| `lib/strip-ansi` | Standalone script: strips ANSI escape codes from pane output |
| `lib/dir-preview` | Standalone preview script for directory picker fzf panel |
| `lib/config.sh` | User config: defaults, feature flags, persistent settings |
| `lib/state.sh` | Session state detection: title glyph + hook file + process tree, wait/poll |
| `lib/hooks/am-state.ts` | Pi extension: lifecycle events → am state files (session_start/agent_settled → ready, agent_start → running) |
| `lib/hooks/opencode-state.js` | opencode plugin: server events → am state files (session.status busy/idle → running/ready, permission/question asked/replied → waiting_user/running), plus `.sid`/`.transcript`/`.cwd`/`.dirty` sidecars and the first-user-message mirror (`$AM_DIR/opencode/<sid>.jsonl`, since opencode's conversation store is SQLite) |
| `tests/live_lab/run.sh`, `run_cursor.sh`, `run_pi.sh`, `run_opencode.sh` | Empirical state labs for real agent sessions; each prints the installed agent version at the end so `tests/live_lab/VERIFIED` (the per-agent verified-version pins `am doctor` compares against) can be updated |
| `skills/agent-manager-dispatch/SKILL.md` | Claude/Cursor skill: teaches agents to use am for multi-session dispatch/orchestration |
| `skills/am-peek/SKILL.md` | Claude Code skill: teaches agents to read another session's full shell scrollback via `am peek --pane shell --history` |
| `bin/toggle-shell` | tmux helper (prefix+\`): toggle the collapsible shell panel — create on first use via `am shell`, then hide/show by parking the pane in the hidden `_amshell` window |
| `bin/toggle-review` | tmux helper (prefix+v): toggle the review pane via `am review` — create on first use, then park in / rejoin from the hidden `_amreview` window |
| `cmd/am-review/main.go`, `view.go`, `note.go` | Compiled Go TUI (bubbletea) for the review pane: `--session`, `--dir`, `--am` (for `a` → `am diff --ack` and `c` → `am send`), `--am-dir`, `--state-dir`, `--poll` (1s). Measures in-process (`ReviewMeasure` with record, `ReviewFileStats`, `ReviewFileDiff`), re-measures when the `.dirty` sidecar's mtime moves (and fully every few ticks), renders the file list (stacked above the diff on narrow panes, beside it when wide) and the selected file's parsed diff. Navigation is focus-independent for `j`/`k` (files) and `]`/`[` (hunks); the arrows act in the focused pane (files, or hunks in the diff), and `gotoHunk` never steals focus. The footer names every key, focus-aware (`↑↓ file` / `↑↓ hunk`, `tab diff` / `tab files`), laid out by `fitHints` (drops trailing hints whole on narrow panes, hunk position right-aligned); styled text is cut with `truncStyled` (`x/ansi`, column-aware), `truncRunes` only for plain diff lines. `c` opens a one-line note (bubbles textinput in the footer) pinned to the hunk under the cursor; Enter sends `noteMessage` (file, new-side line range, the hunk capped at 80 lines, the note) on stdin to `am send <session>`, falling back to `am send --queue` on exit 4 (agent busy) and reporting exit 2 (no agent) as an error. `s` opens the base picker (`ReviewRead`, newest first, `*` = baseline; every row carries the change it would show, `Δ<files> +<add> −<del>`, from one `WorktreeTree` snapshot and `ReviewStatTrees` per checkpoint, so a base can be chosen by delta when the chain jumps; `ReviewRebaseSuggestion` adds a virtual kind-rebase row, id = the anchor commit, when the chain holds a rewrite no rebase checkpoint re-anchored for — sessions from before 0.33 — and `am diff --list` prints the same row marked `~`): Enter measures since the highlighted checkpoint (`ReviewMeasure` with `fromID`, nothing recorded, header tagged "picked base"), `b` moves the baseline there (`ReviewSetBaseline`, then a recording measure), `/` prompts for any commit-ish (`CommitCheckpoint`, sized the same way) and adds it as a kind-commit row that Enter and `b` treat like a checkpoint (`b` records it as a pick checkpoint) |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/switch-cycle` | tmux helper: cycle next/prev in canonical sidebar order |
| `bin/switch-index` | tmux helper: jump to Nth slot in canonical sidebar order |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |
| `docs/` | Architecture docs, backlog, perf notes; `docs/adding-an-agent.md` is the end-to-end guide for a new agent integration |

## Data Flow

```
am → fzf_main() → am-browse (Go TUI) → stdout protocol → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session(name, dir, VAR=VAL...) → registry_add() → tmux_send_keys()
am new @spec → agent_dir_resolve(@spec) → $dir_provider resolve spec → agent_launch(dir, ...)
form Directory "@par" → newForm.refilter → DirProviderSuggest(par) off the UI thread (≤0.3s, one run per distinct text, cached for the form's life) → formProviderMsg → "@spec" rows with the label; the typed spec alone while it loads or when nothing matches
am id → current_session() → $AM_SESSION_NAME, else attached session on the am tmux server
am cd [dir] → current_session() → agent_set_workdir() → .cwd sidecar + registry workdir/branch → am_refresh_sidebar_cache()
agent cd's (Bash tool) → Claude hook payload cwd → state-hook.sh writes /tmp/am-state/<session>.cwd → am-core tick (RefreshTitles) → registry workdir + branch (from .git/HEAD) → tab label
status-bar tick / am list → am_tick() → am-core tick → RefreshTitles (.title_scan_last) → RestoreScan (.restore_scan_last) → GC rows (.gc_last) + extras (.gc_extras_last)
auto_title_scan / registry_gc / sessions_log_scan / sessions_log_gc / sessions_log_restorable / _sessions_log_detect_id_for_session / _sessions_log_jsonl_exists / *_first_user_message → am_core <sub> → bin/am-core (env: AM_DIR, AM_SESSIONS_LOG, AM_STATE_DIR, AM_IDENTITY_DIR, socket, prefix)
am list-internal → am-list-internal (Go binary) → stdout
agent_launch() → am-core review-init → launch checkpoint (refs/am/<session>/{checkpoints,baseline} in the repo; silent outside one)
tool hook (PostToolUse family) → detached tail: touch /tmp/am-state/<session>.dirty; HEAD ≠ .head sidecar → am-core review-sync (branch checkpoint moves the baseline, head checkpoint does not) → rm .title_scan_last
opencode plugin (in-process) → session.status busy/idle + permission/question events → $AM_STATE_DIR/<session> state file; .sid/.transcript (.cwd/.dirty) sidecars + $AM_DIR/opencode/<sid>.jsonl first-message mirror
am-core tick → RefreshTitles → refreshedReview (only when .dirty is newer than review_at, or the branch changed) → ReviewMeasure → registry review_files/added/deleted/at → tab "Δ<files> +<add> −<del>"
am diff [s] → review_diff_main → am-core review-stat --record → git -C dir diff <base_tree> <cur_tree>; --ack → review-ack (worktree tree becomes the baseline, count zeroed); --reset → review-baseline --reset
am restore → cmd_restore_internal → am-core review-adopt <old> <new> (refs follow the resumed conversation); sessions_log_gc → ReviewDrop when the entry is dropped
am new -p name → _cmd_new_apply_preset(name, fill=true) → preset fields where flags left gaps, preset args first → agent_launch()
form Preset field → --preset=name in the flags field → _cmd_new_apply_preset(name, fill=false) (args + shell only)
am send s "..." → agent_get_state → send now for ready/running/background/unknown (the harness steers on mid-turn input or queues it); refuse waiting_user/starting (exit 4: the text would answer a dialog or miss the TUI) and idle/dead (exit 2: it would run in a shell) unless --wait/--queue/--force
am send --queue s "..." → $AM_DIR/queue/<s>.XXXXXX (prompt) → detached _send_queue_helper → am send --wait --timeout 0 (ready|background|idle|dead, no deadline) → delivered: rm qfile | failed: mv qfile .failed ; both → one line in $AM_DIR/queue.log
am wait --all|--any s1 s2 → _wait_many() → one agent_wait_state per session in the background → '<session> <state>' lines
am done "..." (in a worker) → $AM_DIR/results/<session>.txt → am result <session> (dispatcher); removed by agent_kill
hook state transition → waiting_user (or notify_states) → _notify_maybe() in the detached tail → notify_cmd | osascript | notify-send, skipped when a client shows the session
any failure / launch / kill / restore / send / resolve → am_event | _hook_event | EventLog → $AM_DIR/events.log (TSV, 8MB cap) → am log [-n N] [--grep ERE] [-f] [session] | am doctor "events log" section (24h failure counts) + per-session tail
am completions bash|zsh → no-libs path → completions/am.<shell> with @AGENT_TYPES@ from the manifest → eval'd by the rc block at shell start; session names via `am list --json` at <TAB>
am install --dry-run → cmd_install plan (config, skill links, Go build, tmux.conf) + scripts/install.sh --dry-run (PATH links, rc block, hook entries) → nothing written
am uninstall → _uninstall_skills → scripts/install.sh --uninstall (PATH links, rc block, marker-tagged hook entries, Cursor helper copy, pi/opencode links) → --purge: rm -rf $AM_DIR
bare `am` → _install_refresh_if_stale() → fingerprint of install inputs vs $AM_DIR/.install_stamp → _install_refresh() (skills, Go build if sources newer, tmux.conf)
Ctrl-N in browser → model.openForm → newForm (Esc returns to the list) → submit → am-browse prints the __NEW_SESSION__ line → fzf_main passes it through → cmd_browse → cmd_new_internal (strips --preset=<name> → _cmd_new_apply_preset(name, fill=false), resolves a @spec directory via agent_dir_resolve — the same post-processing as cmd_new's form branch) → agent_launch() ; AM_BROWSE_CMD swaps the browser binary for a stand-in (tests)
am new (no args, tty) → fzf_browse_bin → am-browse --new --dir --agent --task (the form alone; Esc quits with no output → "Cancelled") → __NEW_SESSION__ line → cmd_new's form branch
prefix+` / am shell → bin/toggle-shell → agent_shell_pane_toggle() → agent_shell_pane_add() (first use) | tmux_shell_pane_hide/show() (park in / rejoin from hidden _amshell window; pane state and shell.log streaming survive)
prefix+v / am review [s] → bin/toggle-review → agent_review_pane_toggle() → agent_review_pane_add() (split-window -h at the agent's right, @am_role=review, runs bin/am-review) | tmux_review_pane_hide/show() (park in / rejoin from hidden _amreview window)
am-review tick (1s) → .dirty mtime moved? → ReviewMeasure(record) + ReviewFileStats → ReviewFileDiff(selected) ; 'a' → am diff <s> --ack → re-measure
am-review 'c' → note line → Enter → noteMessage(file, L<range>, hunk, note) | am send <s> → exit 4 (dialog up / starting) → am send --queue <s> (delivered when ready) ; exit 2 → "no running agent"
am-review 's' → ReviewSync + ReviewRead + WorktreeTree + ReviewStatTrees per checkpoint → picker (newest first, * baseline, Δ per row) → Enter → ReviewMeasure(from=id, record=false) (one-off view; tab count unchanged) | 'b' → ReviewSetBaseline(id) → ReviewMeasure(from="", record=true) → registry review_* follow | '/' <rev> → CommitCheckpoint(rev) → kind-commit row → Enter (view since the commit) | 'b' (pick checkpoint of its tree, baseline moves)
tool hook → review-sync: HEAD not descended from the newest checkpoint's HEAD (rebase/reset) → rebase checkpoint (anchor = parent of the agent's earliest rewritten commit, found by patch-id; baseline moves there, uncommitted launch delta re-applied) → the tab counts only the agent's work, not the upstream commits the rebase pulled in
agent_kill() → sessions_log_snapshot() + sessions_log_update(closed_at) → tmux_kill_session() → registry_remove()
am restore → fzf_restore_picker() → sessions_log_restorable() → cmd_restore_internal → am_checkout_check(dir, branch) → ok: agent_launch(dir, agent_type, agent_resume_args...) → tmux_attach() (claude/cursor → --resume, pi → --session, codex → resume)
am restore, checkout moved (missing | branch <found>) → _restore_relocation_choice (AM_RESTORE_ON_MISMATCH, else [f]/[h]/[q] on the tty) → fresh: agent_dir_resolve(@branch) → agent_dir_live_session(dir) empty → _AM_LAUNCH_PROMPT=_restore_move_note, _AM_LAUNCH_FENCE=<log row's fence lines minus the resume dir> + "<old>TAB<new>" → agent_launch(new_dir, ..., resume args) writes $AM_STATE_DIR/<s>.fence before the agent command → sessions_log_update(session_id, transcript_path via am-core transcript-path) ; here: launch in dir as is (carried fence only) ; q: exit 3 (browser: no hold)
Claude PreToolUse + <s>.fence present → state-hook scans tool_input (as JSON text, path-boundary match, ~/ spelling too) for a fenced <old> → stdout {"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"am: this conversation was moved from <old> to <new> …"}} + hook.fence_deny event ; state still → running
cmd_restore_internal (relocated) → sessions_log_update(fence) on the new row right after launch ; agent_kill → .fence contents → sessions_log_update(fence) → rm .fence ; recovery_restore_one → _AM_LAUNCH_FENCE from _sessions_log_field(fence) → the sidecar survives a reboot
am owner [dir] → agent_dir_live_session(dir) (exact or subdirectory match) → name + exit 0 | exit 1 (free) | exit 2 (not a directory) ; wp clear / wp allocate's candidate probe call it to refuse / skip a copy another live session works in (the caller's own session is exempt)
am install → _install_claude_hooks → PreToolUse command `[ -s ${AM_STATE_DIR:-/tmp/am-state}/${AM_SESSION_NAME:-}.fence ] || exit 0; bash state-hook.sh` → the script starts only in a fenced pane
am new @spec (cli | form | preset) → agent_dir_resolve → _dir_free_of_live_session → agent_dir_live_session(dir) non-empty → launch.fail reason=dir_busy, exit 1 (a path argument is never checked)
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
effective directory's `.git/HEAD` (`GitHeadBranch`), so a checkout in place
also updates the label. Agents
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
| `PreToolUse` | — | `running`; with a `<session>.fence` sidecar (relocated restore), a tool_input reaching under a fenced old directory is denied (`permissionDecision: deny` on stdout, `hook.fence_deny` event) |

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

**opencode sessions:** State comes from the in-process plugin
`lib/hooks/opencode-state.js`, installed by `am install` as a symlink at
`~/.config/opencode/plugins/am-state.js` (opencode auto-discovers the global
plugin dir and loads it with Bun). The plugin maps `session.status`
(`busy`/`retry` → `running`, `idle` → `ready`), `session.idle` → `ready`, and
`permission(.v2).asked` / `question(.v2).asked` → `waiting_user` (replied /
rejected → `running`). State is read ungated (`turn_boundary=reliable`): a
dead opencode drops the pane to a shell, which the shell-pane check catches.
Plugin init writes `ready` because a fresh TUI creates no session until the
first prompt; `message.updated` user messages are **not** turn starts —
opencode emits a synthetic user message for post-turn title generation after
`session.idle`, which would otherwise pin the tab at `running`. The plugin
writes `.sid`/`.transcript` (identity), `.cwd` (tab label), `.dirty` (review
re-measure), and a first-user-message mirror at `$AM_DIR/opencode/<sid>.jsonl`
(opencode's real conversation store is SQLite, which am cannot address; the
mirror backs the title fallback and restore preflight). The TUI's
`OC | <title>` pane title is parsed by `opencodeTitleExtract`
(`title_state=none`, so no state comes from the title).

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
`tests/live_lab/run_pi.sh` covers pi. `tests/live_lab/run_opencode.sh` covers
opencode (o1 fresh ready, o2 prompt round-trip + mirror/identity, o3 200s
quiet turn stays running, o4 death → idle).

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

- `$AM_DIR/events.log` — always on, the after-the-fact record (`am log`,
  `am doctor` "events log" section). One TSV line per lifecycle event or
  swallowed failure: `<utc> TAB <component>:<pid> TAB <event> TAB <session|->
  TAB k=v ...`, `from=<AM_SESSION_NAME>` added when a session issued the
  command. Writers: bash `am_event` (utils.sh; `log_warn`/`log_error` tee
  into it as `warn`/`error` with the calling function), the state hook's
  inlined `_hook_event` (component `hook`), Go `sessions.EventLog`
  (component `core` / binary name), the status bar (`AM_EVENT_COMPONENT=bar`).
  Events: `launch.ok/fail/step` (source=cli|form|restore|recovery, reason),
  `resolve`/`resolve.fail`/`suggest.fail` (provider secs, rc, stderr tail),
  `kill`/`kill.step`/`kill.sid_unverified`, `restore`/`restore.fail`,
  `recovery.ok/blocked/abandoned/failed`, `send.ok/fail/refused`, `queue.*`,
  `tmux.fail`, `registry.write_fail`/`slog.write_fail`/`config.write_fail`,
  `core.fail` (am-core rc≠0, from the bash wrapper) / `core.error` (from
  am-core itself), `review.measure_fail`/`review.sync_fail`,
  `install.build_fail`, `bar.flush_fail`, `hook.drop` (registry_miss /
  no_registry), `hook.bad_payload`, `hook.no_jq`, `hook.write_fail`,
  `notify.sent`/`notify.fail`. Rules: **nothing on a hot path** — state
  resolution, the status-bar render, `am list`, a successful tick, the
  hook's success path and its every-tool-call no-pane exit log nothing;
  only failures and rare lifecycle events do. Writers are fork-free (bash
  `printf %(…)T`; the hook falls back to `date` under /bin/bash 3.2), values
  are sanitized (tabs/newlines → space) and capped at 400 chars, the file at
  8MB (newest half, Go `capLog` on the 60s title scan). `AM_EVENTS_LOG`
  overrides the path (empty disables); `am_core` forwards it
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

`events.log` and `gc.log` are always on and capped by the title scan; the
`AM_*_DEBUG` traces are opt-in and capped the same way once enabled.

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
- The prompt is pasted literally into the top agent pane, then Enter is sent — now, mid-turn included. Agent harnesses take input while a turn runs and steer on it or queue it for the next turn (their own setting), so `running` is sendable. Refused only when a permission/question dialog is up or the agent is still starting (exit 4: Enter would answer the dialog / the text would miss the TUI), or when the agent exited and the pane is a shell (exit 2).
- `--wait` / `--queue` deliver at the turn boundary instead (ready or background), for text that must arrive as its own turn. `--queue` is detached with no deadline by default; its outcome is one line in `$AM_DIR/queue.log` and an undelivered prompt is kept as `$AM_DIR/queue/<file>.failed`.

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
- A row marked `⚠ dir gone` / `⚠ on <branch>` ran in a checkout that was released or re-allocated (pooled `wp` copies). Enter asks: `[f]` fresh checkout of the recorded branch via the `dir_provider` (`<provider> resolve <branch>`; refused when a live session already works in the copy it returns), `[h]` resume in place, `[q]` cancel. `AM_RESTORE_ON_MISMATCH=fresh|here|fail` answers for scripts (no tty + `ask` → exit 1 with the options printed). A relocated session's first prompt names the new and old directories, forbids the old paths, and flags a HEAD that differs from the one the session closed on. Claude resumes by id from any directory and keeps writing the original transcript (2.1.286, live lab s8), so only am's bookkeeping moves: the new log row is pre-seeded with the sid and the transcript path, and review checkpoints are not adopted (they live in the old repository).

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, agent_args...)` - Creates session, registers, starts agent. `--shell`/`--no-shell` are consumed here; every other arg reaches the agent verbatim
- `agent_kill(name)` - Kills tmux + removes from registry
- `agent_kill_all()` - Kill all agent sessions
- `agent_info(name)` - Show session info
- `auto_title_scan([force])` - Wrapper over `am-core titles` (Go `RefreshTitles`, then `RestoreScan`): for every registry row, refresh the workdir field (from the .cwd sidecar) and the branch field (from the effective directory's .git/HEAD), then the task field from the agent pane title; when the title is empty or invalid and the row has no task, fall back to the first user message of the transcript bound by the session's own hook sidecar (`DetectID` + `FirstMessage`); an invalid title never replaces an existing task (hysteresis). Throttled 60s on `$AM_DIR/.title_scan_last`, shared with the am-browse / am-list-internal path (which calls `RefreshTitles` in-process). Always chains into `sessions_log_scan` (even when title-throttled), which runs on its own `$AM_DIR/.restore_scan_last` marker so the browser stamping first can't starve it.
- `agent_resume_args(agent_type, session_id)` - The manifest resume template with `{id}` expanded, one arg per line (claude/cursor → --resume, pi → --session, codex → resume); empty for unknown types
- `agent_restorable(agent_type)` - True when the manifest gives the type a resume form: gates the sessions-log append at launch and the snapshot/close at kill (Go twin `AgentSpec.Restorable`)
- `agent_dir_live_session(dir)` - Name of the live am session whose registry directory or workdir is the given directory (tmux session present), empty when free. Guards `am new @spec` (`_dir_free_of_live_session()` in the entry point) and the fresh-checkout restore against two agents in one pooled copy
- `cmd_restore_internal(dir, sid, [agent])` (entry point) - Looks up the branch / head_sha / transcript_path / fence lines the session closed with (by sid in the sessions log), runs `am_checkout_check()`, and on a missing directory or another branch asks `_restore_relocation_choice()` (prints fresh / here; exit 1 when impossible or `AM_RESTORE_ON_MISMATCH=fail`, exit 3 when declined) — fresh resolves `@branch` through the provider, refuses a busy copy, and launches with `_restore_move_note()` as the first prompt and the relocation fence in `_AM_LAUNCH_FENCE` (the row's carried lines, minus any for the directory it resumes in, plus `<old>TAB<new>` when the path changed; `agent_launch` writes `$AM_STATE_DIR/<s>.fence` before the agent command, `agent_kill` copies it back to the log row's "fence" field); after launch the new log row gets the sid and (relocated only) the transcript path, and review-adopt is skipped for a relocated session
- `cmd_owner([dir])` (entry point) - `am owner`: the live session working in or under a directory (`agent_dir_live_session`, which matches the registry directory / workdir exactly or as a subdirectory), name + exit 0, exit 1 when free, exit 2 for a non-directory. The hook for tools that reclaim checkouts: `wp clear` refuses (explicit colors) or skips (`--stale`) a copy another session owns — the caller's own session is exempt and no flag overrides it — and `wp allocate` never re-uses one

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
- `_send_queue_helper(session, qfile, timeout_s)` / `_send_queue_log(session, event, detail)` - The detached half of `am send --queue`: `am send --wait` on the prompt file (timeout 0 = no deadline, the default for --queue; the wait set is ready/background/idle/dead, the same states the direct path sends into), then the prompt file is removed on delivery or renamed to `<qfile>.failed` on failure, and one line (event queued / delivered / failed with exit code and reason) goes to `$AM_DIR/queue.log` (capped with the debug logs). Before 0.31 the helper had a 600s deadline, stderr to /dev/null, and the inherited errexit skipped its cleanup: a worker turn longer than 10 min dropped the prompt with no trace but the orphan queue file (2026-09-10, two HOLD/ADDITION prompts to backport workers)
- `cmd_done` / `cmd_result` - Worker-recorded summary in `$AM_DIR/results/<session>.txt` (mode 700 dir); `result --wait` polls until the file exists or the session ends (exit 2)
- `_fzf_state_selected(state)` (lib/fzf.sh) - `am list --state` filter, driven by `AM_LIST_STATE_FILTER`

**Review checkpoints (lib/review.sh, Go `internal/sessions/review.go`):**
- `review_diff_main(args...)` - `am diff` entry: flags (`--ack`, `--reset`, `--list`/`-l`, `--checkpoint`/`-c id`, pass-through `--stat`/`--name-only`/`--numstat`/`-w`/`-U`, `--` for raw git diff args), session from the argument or `current_session`, directory from `review_session_dir` (workdir, else directory). Exit 2 unknown session, 3 not a repository
- `review_session_dir(session)` - Registry lookup of the effective directory (workdir when set, else the launch directory) for `am diff`
- `_review_show(session, dir, from, git_args...)` - `am-core review-stat` (`--record` updates the registry count unless `--checkpoint` was given), header line on stderr (`<session>: 7 files +212 −48 since the ack checkpoint 3f2a1c0 (5m ago); HEAD moved: …`), then `git -C dir diff base_tree cur_tree`
- Go: `ReviewInit` (launch checkpoint of the worktree, idempotent), `ReviewAck` (worktree → new baseline), `ReviewSync` (HEAD vs newest checkpoint: branch name changed → a branch-kind checkpoint of `HEAD^{tree}` and baseline move; the newest checkpoint's HEAD no longer an ancestor of HEAD (rebase / reset) → a rebase-kind checkpoint that re-anchors the baseline via `rebasedBaseline`: the agent's commits since the baseline's anchor are found again by `git patch-id --stable` in the rewritten history, the anchor is the parent of the earliest match (HEAD itself when the agent had no commits; `HEAD~N` then the merge base when patch-ids no longer match), and the baseline's uncommitted delta is re-applied on the anchor's tree with `treeWithDelta` (temp index, `apply --cached`); a re-anchor that reproduces the current baseline tree is recorded as a plain head checkpoint instead; same branch, HEAD moved forward → a head-kind checkpoint, baseline stays), `ReviewSetBaseline` (a chain id, or any commit-ish → a pick-kind checkpoint of that commit's tree, anchored on it) / `ReviewResetBaseline` (to launch), `CommitCheckpoint` / `ReviewState.Resolve` (any commit as a virtual kind-commit checkpoint, for `am diff --checkpoint <rev>` and the pane's `/`), `ReviewDiffStat(dir, base_tree)` (`git diff --numstat base_tree <worktree tree>`) / `ReviewStatTrees`, `HeadMoved` ("N commits" / "rebased or reset" / "moved"), `ReviewAdopt` (rename refs), `ReviewDrop`. Chain writes are CAS `update-ref` on the checkpoints ref, so concurrent writers (hook tail, tick, `am diff`) cannot lose a checkpoint. `Env.ReviewMeasure(session, dir, from, record)` syncs first and creates the launch checkpoint on demand for pre-0.25 sessions; `Env.ReviewRecord` writes the registry fields review_files / review_added / review_deleted / review_at under the registry lock
- Sidecars: `$AM_STATE_DIR/<session>.dirty` (touched by the hook on every tool event; the scan re-measures when it is newer than the row's review_at), `<session>.head` (the hook's fork-free HEAD snapshot: `ref: refs/heads/x <sha>` or a bare sha). Both removed by `agent_kill` and GC

**Relocation fence (lib/hooks/state-hook.sh, `am restore`):**
- `$AM_STATE_DIR/<session>.fence` - One `<old>TAB<new>` line per directory the conversation used to work in and no longer owns (a released / re-allocated pooled copy). Written by `agent_launch` from `_AM_LAUNCH_FENCE` (set by `cmd_restore_internal`, and by `recovery_restore_one` from the log row) before the agent command runs; recorded on the sessions-log row's "fence" field by the relocating restore right after launch and again by `agent_kill` (the sidecar is under /tmp, so a crash or reboot must not lose it), and the next restore or reboot recovery re-seeds the sidecar from the row (minus a line for the directory it resumes in, or a parent of it — fencing a parent would deny every call); removed by `agent_kill` and GC; shown by `am doctor`. The provider's directory is abspath'd before any same-path comparison, and no line is written whose new directory is under its old one
- Hook side, Claude `PreToolUse` only (`session_agent == claude`: Codex fires the same event name but does not speak the deny JSON): the hook's inner _fence_hit (haystack, needle) is one bash regex match of the quoted (literal) needle followed by a path boundary — any char outside `[A-Za-z0-9._-]` or the end — against the compact tool_input JSON, for `<old>` and its `~/` spelling, so `<old>-bak` / `<old>2` pass; one match is linear in the input (a `${rest#*needle}` loop went quadratic on near-miss-heavy inputs). A hit prints the deny JSON (the only stdout the hook ever produces) with a reason naming `<new>`, logs `hook.fence_deny tool= old= new=`, and still writes state running. Install side: scripts/install.sh's Claude hook installer registers `PreToolUse` with a command that tests `${AM_STATE_DIR:-/tmp/am-state}/${AM_SESSION_NAME:-}.fence` and exits 0 before starting the script, so unfenced sessions pay one file test per tool call; `_doc_hooks_check` expects the event and the lab registers the same gated command. Verified on Claude Code 2.1.286 (live lab s8: the agent sees the denial, not the file). Known limits (accepted): a relative path or a `$HOME/…` spelling of the old directory is not matched; a fence has no lift other than deleting the sidecar

**Doctor (lib/doctor.sh):**
- `doctor_main([--capture] [session])` - Global report (versions, dirs, markers, hooks installed, version drift, hook payload schema, per-session summary) or one session in depth; `--capture` writes a tarball under `$AM_DIR/doctor/` (includes `hook-schema/`)
- `_doc_resolve_state(session, state_var, layer_var)` - Runs `agent_get_state` with `AM_STATE_DEBUG=1 AM_STATE_DEBUG_SINK=<tmp>` to learn which resolver layer answered
- `_doc_hooks_installed()` / `_doc_hooks_check(label, file, optional, helper|-, events...)` - Per-family check that the events scripts/install.sh registers name the am hook: Claude (settings.json, nested command shape), Codex and Cursor (optional hooks.json; Cursor's flat shape runs a byte copy of the hook, compared with cmp - a stale copy points at `am install --refresh`)
- `_doc_drift()` - Version-drift canary: installed agent versions vs `tests/live_lab/VERIFIED` pins (`AM_VERIFIED_FILE` overrides the path), then every `$AM_DIR/hook-schema/*.keys` file against the fields the hook reads (`_doc_required_keys`), with `_doc_keys_diff` against `.keys.prev`
- `_doc_notify()` - "notifications" section: the notify / notify_states / notify_cmd config, and on macOS the Notification Center style of Script Editor (the app osascript banners are attributed to) with a warning when it is Banners (fade after seconds) or None; `_doc_nc_style(flags)` decodes the ncprefs flags (bit 3 Banners, bit 4 Alerts), `_doc_nc_flags(bundle)` / `_doc_nc_flags_parse(bundle)` read the app-level flags from `defaults read com.apple.ncprefs apps` (the nested per-source flags are skipped; empty when the app never posted)
- `_doc_dep_row(tool, version)` - One row of the versions section with a warning when the tool is below `am_dep_min`
- `_doc_ver_newer(a, b)` / `_doc_ver_core(v)` / `_doc_agent_version(agent)` - Dotted-numeric version compare (missing components are 0, non-numeric never compares newer), version-string core extraction, first line of `<agent> --version`

**Notifications (lib/hooks/state-hook.sh, lib/config.sh):**
- `_notify_maybe(session, state)` - Fired from the hook's detached tail only on a state transition into one of the configured notify states; skipped when an attached client displays the session; `AM_NOTIFY_CMD` env > notify_cmd config > osascript / notify-send
- `am_notify_enabled()` / `am_notify_states()` - Config readers (notify: bool, default true; notify_states: default waiting_user; notify_cmd: string)

**Install / uninstall (in the am entry point):**
- `cmd_install(args...)` - Deps check (`am_dep_min` minimums), config, skill links, `scripts/install.sh` (PATH, rc block, hooks), Go build, tmux.conf, stamp. `--dry-run` prints each step's plan (`_install_plan_skills` for the links) and forwards the flag to the script; nothing is created, including `$AM_DIR`
- `cmd_uninstall([--dry-run] [--purge] [-y] [--prefix d] [--shell-rc f])` - `_uninstall_skills` (only links that point into this checkout's skills directory) → `scripts/install.sh --uninstall` → `--purge` removes `$AM_DIR`; asks once unless `-y`; running sessions are left alone with a warning
- `am_dep_min(tool)` / `am_version_core(str)` / `am_version_ge(required, actual)` (utils.sh) - The one table of minimums (bash 4.4, tmux 3.2, fzf 0.40, jq 1.6, go 1.19), the dotted core of a version string (tmux's letter suffix kept), and the compare; used by install, `require_cmd`'s error (which points at `am install`, since doctor needs the same tools), and doctor's `_doc_dep_row`

**Install fingerprint (in the am entry point):**
- `_install_inputs()` / `_install_fingerprint()` - Version + cksum over the mtimes of everything `am install` derives artifacts from (am, lib/tmux.sh, hooks, scripts/install.sh, skills, Go sources)
- `_install_is_stale()` / `_install_stamp_write()` / `_install_refresh([quiet])` / `_install_refresh_if_stale()` - Stamp compare, quiet idempotent refresh (skills, Go build when sources newer, tmux.conf), browser hook (`AM_NO_INSTALL_REFRESH=1` disables); `am install --refresh` runs it by hand

**Registry (JSON metadata):**
- `registry_add/get_field/get_fields/update/remove` - CRUD for sessions.json. All writes are read-jq-rename cycles serialized under an exclusive lock on `$AM_REGISTRY.lock` (`_registry_lock`/`_registry_unlock`: the flock CLI on Linux, a perl flock syscall on an inherited fd on macOS — no flock CLI there; **not reentrant**, don't nest). The Go twin (`internal/sessions/lock.go:lockRegistry`) takes the same lock via `syscall.Flock`, so bash and Go writers can't lost-update each other; `RefreshTitles` computes titles unlocked, then re-reads and applies under the lock. The bash writers lock first and mktemp inside the lock (a writer blocked on the lock owns no temp file; the temp is removed when jq or the rename fails)
- `am_tick([force])` - One maintenance tick, `am-core tick`: `RefreshTitles`, `RestoreScan`, and both GC halves, each on its own marker. The status-bar tick and `am list` call this and nothing else
- `registry_gc([force])` - Wrapper over `am-core gc` (Go `GC`); prints the number of registry rows removed. Two independently throttled halves: registry rows + hook state files (incl. `.sid`/`.transcript`/`.cwd`/`.bg`/`.dirty`/`.head`/`.fence` sidecars) on `$AM_DIR/.gc_last` — `ReapOrphans`, also run by the am-browse / am-list-internal path: one lock, tmux snapshot taken inside it, one rewrite, rows younger than `AM_GC_GRACE_SECS` (default 5) spared; extras on `$AM_DIR/.gc_extras_last`: orphan state files and sidecars under the session prefix (skipped entirely when tmux lists no session — the state dir is shared, see Gotchas), `SessionsLogGC`, `SnapshotGC` (unreferenced snapshots older than 10 min), leaked temp sweep (`.sessions-log.*` >60s, `.dir_repo_cache.tmp.*` and `*.log.??????` >1h)
- `_registry_tmp_guard(tmp)` / `_registry_tmp_release()` - Signal-safe temp files for the bash sessions-log rewrites (`sessions_log_update`): lock first, then mktemp, then trap HUP/INT/TERM/PIPE to remove the temp, release the lock, restore the caller's traps and re-raise
- Titler trace: `AM_TITLER_DEBUG=1` makes the Go scan append to `$AM_DIR/titler.log` (off by default; an ungated version once grew it to 84MB). Each unthrottled title scan caps `titler.log`, `.state-debug.log`, `.hook-debug.log`, `gc.log` at 20MB, keeping the newest half (Go `capLog`)
- GC audit: `$AM_DIR/gc.log` (Go `gcLog`, always on, one line per removed registry row or state file: timestamp, `am-core <sub>`, AM_DIR, socket, prefix, live-set size, cwd, what was removed). `AM_GC_LOG=<path>` redirects it, e.g. to catch a test run's removals in one file

**Sessions log (for restore):**
- `sessions_log_append(session_name, directory, branch, agent_type, [task])` - Append session to `~/.agent-manager/sessions_log.jsonl`
- `sessions_log_update(session_name, field, value)` - Update field in most recent log entry for a session. The log's branch is always the *launch* directory's (the one restore resumes in and judges): `RestoreScan` syncs it from `GitHeadBranchName(directory)`, not from the registry branch (which follows the workdir after `am cd`), and `agent_kill` writes it as of the close together with head_sha — a detached HEAD records only head_sha (`git_head_branch_name` / `GitHeadBranchName` blank the sha; a pre-0.38 sha-as-branch is ignored by `am_checkout_check` / `RestoreNote`). For Claude/Cursor/opencode `agent_kill` also writes the hook-reported transcript_path; a relocated restore writes session_id and transcript_path on the new row before any hook fires
- `sessions_log_snapshot(session_name, [snapshot_key])` - Capture pane text to `~/.agent-manager/snapshots/`
- `sessions_log_scan([force])` - Wrapper over `am-core restore-scan` (Go `RestoreScan`): rolling pane snapshots + session_id binding + task/branch sync into the log for live Claude, Codex, Cursor, and pi sessions that have a log entry (throttled 60s via `.restore_scan_last`); chained from `auto_title_scan`. Ephemeral and durable hook sidecars are authoritative for session_id: a logged sid that disagrees with the sidecar is corrected (heals wrong guesses, tracks forked resumes) and the snapshot is re-keyed; with no sidecar nothing is guessed. All log updates of one scan are a single locked rewrite
- `sessions_log_gc()` - Wrapper over `am-core slog-gc` (Go `SessionsLogGC`): drop entries whose transcript is gone (and their snapshot) and id-less entries older than 24h; lines this version cannot parse are kept verbatim
- `sessions_log_restorable()` - Wrapper over `am-core restorable` (Go `Restorable`): raw JSONL lines of sessions that can be restored (resumable agent, id bound, not alive, transcript present), most recently *closed* first (by closed_at, else created_at; undated lines keep log order), one per conversation id (the newest log entry for it). `restorableEntriesFromLog` (the browser's inactive rows) orders the same way — the log itself is in launch order, which buried a long-lived session closed a minute ago under every shorter session launched after it
- `_sessions_log_detect_id_for_session(session_name, directory, [agent])` - Wrapper over `am-core detect-id` (Go `DetectID`): the conversation id bound to a session — the sidecar its own hook wrote (durable identity first, then the ephemeral `.sid`), verified against the agent's transcript store (codex ids are taken as-is). No directory-based guess — the store is shared with other sessions and with agents outside am
- `_sessions_log_field(session_name, field)` - Read a field from the most recent sessions-log entry for a session
- `_sessions_log_jsonl_exists(directory, session_id, [agent], [transcript_path])` - Wrapper over `am-core jsonl-exists` (Go `JSONLExists`): whether the transcript still exists (agent defaults to claude; cursor checks the hook-reported transcript path first)
- `agent_kill` reads the bound conversation through `am-core sidecar <session> id|transcript` (Go `SidecarID` / `SidecarTranscript`, durable identity first); `am doctor` resolves a session's transcript path through `am-core transcript-path` (Go `Env.TranscriptPath`), the sole implementation of the per-agent store layout and path encoding (`Env.StoreDir`)

**State detection (lib/state.sh):**
- `agent_get_state(session_name)` - Public entry: checks existence, looks up registry fields, delegates to `_state_resolve`, and returns one canonical lifecycle state
- `_state_resolve(session, agent_type, dir [, top_pid_map, comm_map, children_map, now_epoch [, activity_epoch [, title_map [, created_epoch [, cursor_tasks_map]]]]])` - **Single source of truth** for state derivation. Without bulk fixtures (last args), forks per-session for tmux/ps (fetching pane_pid + session_activity + pane_title in one call); with bulk fixtures passed by nameref (bash 4.3+), reads pre-built maps in place, plus optional per-session activity epoch, title map, created epoch, and pre-probed Cursor task signal. Used by `agent_get_state` / `lib/fzf.sh` (non-bulk) and `lib/status-bar` (bulk; passes tmux `#{session_created}` as created_epoch). Canonical order: shell pane check → title glyph/status × hook state → Cursor Ready-footer refinement → hook state when the title carries no signal → unknown. Bulk and non-bulk shell-pane semantics agree: shell pane + session <5s → starting (bulk needs created_epoch, else idle), otherwise idle; dead from `agent_classify_exit` is a non-bulk race-window branch only — missing sessions are reported dead by `agent_get_state`'s existence check
- `_state_title_signal(title, out_var)` - Classify Claude's self-maintained pane title into busy (braille spinner frame U+2800–U+28FF, or circle-phase glyph ◐◓◑◒ U+25D0–U+25D3 on Claude Code ≥2.1.232) / attention (✳) / none. Byte-oriented (LC_ALL=C) so it is locale-independent; fork-free
- `_state_cursor_tasks_signal(pane_text, out_var)` - Detect Cursor's nonzero footer task count only after the current `→ Add a follow-up` placeholder or captured input border; later footers supersede stale rows still visible in scrollback
- `agent_wait_state(session, [states], [timeout])` - Block until target state reached
- `agent_classify_exit(session)` - Classify shell exit as idle or dead
- `_state_hook_raw(session, out_var)` - Read the hook file ungated; used by title/status layers even when the file is stale
- `_state_has_identity(session)` - True when an identity sidecar exists (`$AM_STATE_DIR/<s>.sid` or `$AM_IDENTITY_DIR/<s>.sid`): proof that the session's hooks have fired. Fork-free; gates the fresh-session `✳`+no-file → ready branch, so a state file removed under a live session reads as unknown rather than ready
- `_state_hook_read(session, out_var [, now_epoch [, activity_epoch]])` - Gated hook-file read for agents without reliable turn-boundary events. Ready, waiting_user, and background persist; running gets a 180s staleness gate measured against max(file mtime, tmux session_activity), so a wedged agent falls to unknown. Claude, Cursor, and pi bypass this gate because long live turns routinely outlast it.
- `_state_pane_is_shell_bulk(session, top_pid_map, comm_map, children_map)` - Detect whether top pane is a plain shell (vs an agent process) from nameref bulk maps

**Utils:**
- `am_agent_manifest_load()` - Parse `$AM_AGENT_MANIFEST` (default `lib/agents.manifest`) once per process into the field table and `AM_AGENT_TYPES` (file order); runs when utils.sh is sourced
- `am_agent_field(type, field, [out_var])` - One manifest fact for a type or alias; empty for unknown types/fields and `-` values. Fork-free with out_var (status-bar hot path)
- `am_agent_normalize(name, [out_var])` - Alias → canonical type (unknown names pass through)
- `_format_seconds(seconds, [ago])` - Shared duration formatter (used by `format_time_ago`/`format_duration`)
- `am_file_mtime(file, [out_var])` / `am_files_mtime(assoc, files...)` - Portable mtime, flavor picked once from `$OSTYPE` (no probe fork); the batched form is one stat call for all files (status-bar tick, install fingerprint)
- `am_file_mode(path)` / `am_file_size(path)` - Octal permission bits / byte size through the same flavor logic (`_am_stat_field`, regex-validated with a one-time flavor flip). Use these instead of `stat -f X || stat -c Y`: on GNU coreutils `stat -f` is filesystem status and succeeds with a blob, so the fallback never runs (the CI-only doctor crash and eight 0700 test failures on 2026-09-07)
- `am_core(subcommand, args...)` - Run `$AM_ROOT_DIR/bin/am-core` with the caller's effective paths passed explicitly (`AM_DIR`, `AM_SESSIONS_LOG`, `AM_TMUX_SOCKET`, `AM_SESSION_PREFIX`, and `AM_STATE_DIR` / `AM_IDENTITY_DIR` when set) — bash derives them after sourcing and tests re-point them, so exports cannot be trusted. Missing binary: one stderr line, return 127; the periodic wrappers turn that into 0, the query wrappers into a failed lookup
- `am_event(event, session|-, k=v...)` - Append one line to `$AM_DIR/events.log` (see Debug instrumentation): fork-free, sanitized, never fails the caller, `from=$AM_SESSION_NAME` added automatically, `AM_EVENT_COMPONENT` names writers other than the CLI (the status bar sets it to bar), `AM_EVENTS_LOG` overrides the sink (empty disables). Call it on failures and rare lifecycle events only — never from state resolution, the status-bar render, list, or a successful tick. Twins: the hook's `_hook_event` (state-hook.sh, no utils.sh) and Go `EventLog(amDir, event, session, kv...)` (`internal/sessions/eventlog.go`); `cmd_log` (in the am entry point) reads it back for `am log [-n N] [--grep ERE] [-f] [session]`
- `am_mkdir_private(dir)` - `mkdir -p` with mode 700 (state, log, results, queue dirs)
- `git_head_branch(dir, [out_var])` - Wrapper over `am-core branch` (Go `GitHeadBranch`, sole implementation): branch name, 8-char sha when detached, empty outside a repo. `detect_git_branch` delegates to it
- `git_head_branch_name(dir, [out_var])` - `git_head_branch` with a detached-HEAD sha blanked: for values a later checkout is judged against (sessions log at kill, desired-session record). Go twin `GitHeadBranchName`
- `am_checkout_check(dir, expected_branch)` - Is the directory still the checkout a session ran in: silent / 0 when it exists and HEAD is on the branch (or no branch recorded, a sha recorded as the branch, or no readable HEAD); prints "missing" or "branch <found>" and returns 1 otherwise. One judge for the manual restore (which then offers a fresh checkout), the reboot-recovery preflight (which blocks: `directory unavailable` / `branch changed: expected X, found Y`), and the picker markers (Go twin `RestoreNote`)
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

**New-session form (Go, `cmd/am-browse/newform.go`; tests in `newform_test.go`):**
- `newNewForm(cfg, amDir, home, dir, agent, task, standalone)` - Build the form with its prefill: fields Directory (a path or `@spec`), Agent, Task, plus Preset first when `cfg.PresetNames()` is non-empty; the agent falls back to `cfg.DefaultAgentType()`, an unknown one to the first manifest type; `f.standalone` (`--new`) makes Esc quit instead of returning to the list. `newForm.init()` loads `FrecentDirs` off the UI thread (`formDirsMsg`)
- `newForm.update(msg) (newForm, tea.Cmd, formResult)` - The one entry the browser model calls: `formContinue` / `formCancel` / `formSubmit` (then `f.output` holds the line). Routes keys by stage and mode: `keyLauncher` (Enter / Ctrl-S launch with the highlighted directory accepted, Ctrl-L/X/R/P/O launch with a named agent via `launchShortcuts`, Tab accepts + opens the options, Up/Down move the highlight, Esc cancels, anything else edits Directory), `keyOptionsNav` (Up/Down fields, Left/Right/Space cycle a select, Enter edits Task / launches from a select / returns to the launcher from Directory, Ctrl-S launches, Esc back), `keyOptionsEdit` (Task text; Enter/Esc back to navigation). `trimPaste` drops a paste's trailing line breaks (bubbles turns inner ones into spaces)
- `newForm.refilter()` - Rebuild the candidate rows for the Directory value: a `@` query shows the provider's suggestions (`DirProviderSuggest` as the returned Cmd, once per distinct text, `providerCache` / `providerPending`), else the typed spec alone; a path-like query (`/`, `~`, `.`) lists the directory it names first, then frecent substring matches, then `PathCompletions`, so Enter never picks a child. Capped at `formMaxCandidates` (50). `acceptHighlight` copies the highlighted row into the field (`CursorEnd`: `SetValue` keeps an in-range cursor, which made Backspace eat the old text's head)
- `newForm.submit()` - Validation and the output line: a `@spec` passes unvalidated once `cfg.DirProviderCmd()` is set (the error names the dir_provider config key otherwise), a path must exist (`~` expanded), the agent must be a manifest type; the flags field carries only `--preset=<name>`. Errors show under the fields (`errMsg`, cleared by the next edit) and the form stays open
- `applyPreset(name)` - Copy the preset's directory (path or `@spec`), agent, and task into the fields; its args and shell flag travel as `--preset=<name>` and are merged by `cmd_new` / `cmd_new_internal` (`_cmd_new_apply_preset(name, fill=false)`)
- `newForm.view()` / `renderField` / `renderSuggestions` - Header with the hint lines, the fields (`»` editing / `>` navigating, label blue in edit / gray in navigate), the suggestion window (`visibleRows`, `▲ N more` / `▼ N more` when scrolled, `ensureHighlightVisible` keeps the highlight inside it), the error line. Styles `formLabelEditStyle` / `formLabelNavStyle` / `formSelectedStyle` / `formErrorStyle` come from `initStyles`

**Session browser (Go TUI — `cmd/am-browse`):**
- Compiled bubbletea binary; primary UI for the interactive session browser and host of the new-session form (`model.form`, opened by `openForm`; while set it takes every message except the window size and a list reload)
- Output protocol: session name (attach), `__NEW_SESSION__␟dir␟agent␟flags␟task` (form submitted), `__RESTORE__␟…`, `__RETRY_RECOVERY__␟id`, `__FORGET_RECOVERY__␟id`, or empty (cancel)
- Flags: `--preview-cmd`, `--kill-cmd`, `--client-name`, `--benchmark`; `--new [--dir d] [--agent a] [--task t]` runs the form alone

**fzf helpers (lib/fzf.sh):**
- `fzf_browse_bin()` - Path of the am-browse binary (`AM_BROWSE_CMD` override for tests; errors when not built), exporting the socket/dir/prefix it reads; shared by `fzf_main` and `cmd_new`'s form branch
- `fzf_main()` - Launches am-browse; `__RESTORE__` goes to `fzf_restore_picker`, every other line (session name, `__NEW_SESSION__`, recovery tags) is echoed for `cmd_browse`
- `fzf_list_json()` - JSON output of sessions for `am list --json`
- `fzf_list_simple()` - Plain text session list for `am list`
- `fzf_pick_directory()` - Directory picker with git-branch annotations and path completion
- `_am_branch_batch()` - Read paths on stdin, print `path<TAB>branch` via one `am-core branch-batch` call (used by `_list_directories` to annotate a whole list without a fork per path)
- `_dir_repo_scan_cached()` - Git-repo suggestions for `_list_directories`, served from `$AM_DIR/.dir_repo_cache` and refreshed in the background when older than `AM_DIR_REPO_CACHE_TTL` (default 1h); the raw `_dir_repo_scan` find is ~1s+ on large trees and never runs on the interactive path
- `fzf_restore_picker()` - Browse closed sessions, select to resume via `claude --resume`; rows whose checkout moved on carry `⚠ dir gone` / `⚠ on <branch>` (`am_checkout_check`; the browser's inactive rows get the same from Go `RestoreNote`)

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
| Add agent type | `lib/agents.manifest` → one block of `<type>.<field>` lines (fields documented in the file header); a new transcript layout or title parser also needs its code in `internal/sessions/` (`storeJSONLExists`, `FirstMessage`, `refreshedTitle`) and `lib/doctor.sh` `_doc_transcript`; add a live lab and a `tests/live_lab/VERIFIED` pin. Full walkthrough: `docs/adding-an-agent.md` |
| Add CLI command | `am` → `case "$cmd"` in `main()` |
| Change browser keybindings | `cmd/am-browse/main.go` |
| Change review pane keybindings or layout | `cmd/am-review/main.go` → `handleKey` / `layout`; diff parsing and rendering in `view.go` |
| Modify session display | `internal/sessions/sessions.go` → `FormatDisplayBase()` |
| Add metadata field | `lib/registry.sh` → `registry_add()` |
| Change preview content | `lib/preview` (session), `lib/dir-preview` (directory picker) |
| Change title source | `internal/sessions/titles.go` → `refreshedTitle` (the bash `auto_title_scan` only execs `am-core titles`) |
| Add periodic maintenance or a store query | `internal/sessions/maintenance.go` (+ `identity.go` / `slog.go`), a subcommand in `cmd/am-core/main.go`, a bash wrapper via `am_core` in `lib/registry.sh` or `lib/utils.sh`; Go parity test in `maintenance_test.go` (fake tmux: `fakeTmux`; bash: `setup_fake_tmux`) |
| Add tmux helper | `bin/` directory (sourced by tmux keybindings) |
| Add form field | `cmd/am-browse/newform.go` → a `formField` constant + `label()`, append it in `newNewForm`'s `fields`, handle it in `renderField`, `keyOptionsNav` (text: Enter edits; select: `cycleSelect`), and `submit`'s output (Preset is conditional on saved presets, so field indices only shift when any exist) |
| Write a directory provider | Any command answering `suggest <partial>` (lines `spec<TAB>label`, local state only, well under 0.3s) and `resolve <spec>` (prints an existing directory; stderr passes through). The form shows the first suggest row highlighted and Enter accepts it, so for an empty partial the provider should lead with the row it wants bare `@` + Enter to mean — an empty spec (`<TAB>label`) renders as `@` and resolves as `resolve ""`. Register with `am config set dir_provider <cmd>`. Reference implementation: `wp suggest` / `wp resolve` in `~/code/tools/wp`; test double: `tests/fake_dir_provider` |
| Change form keybindings | `cmd/am-browse/newform.go` → `keyLauncher` / `keyOptionsNav` / `keyOptionsEdit` (+ the hint lines in `view`); one-key agent launches in `launchShortcuts`. Text editing inside a field is bubbles' `textinput` (its `KeyMap`), not am code |
| Add config option | `lib/config.sh` → `am_config_init()` defaults, `am_config_key_alias/type/value_is_valid`, `am_config_print`; `am` → `cmd_config` get case + help |
| Add a preset field | `lib/presets.sh` → `_preset_from_flags` + `_preset_render`; `am` → `_cmd_new_apply_preset`; `internal/sessions/config.go` → `Preset` + `LoadConfig`; `cmd/am-browse/newform.go` → `applyPreset` |
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
| Change opencode state mapping or identity/title sidecars | `lib/hooks/opencode-state.js` → event mapping, `bind`/`handlePart`; install/refresh wiring in `scripts/install.sh` + `am` `_install_refresh`; `lib/doctor.sh` `_doc_opencode_plugin` |
