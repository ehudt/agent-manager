# Review follow-ups (2026-09-07)

Tracking file for the improvements agreed after the product/implementation/
architecture review. Status: `[ ]` open, `[~]` in progress, `[x]` committed.
Each item names the commit that closed it.

## A. Defects (hygiene batch)

- [x] A1 `sessions_log_gc` never ran: the status-bar tick now calls `registry_gc` after `auto_title_scan`; extras half also prunes unreferenced snapshots and leaked temps. Live: sessions_log 1413 → 336 entries, snapshots 1125 → 264.
- [x] A2 Leaked `.sessions-log.XXXXXX` temps: lock → mktemp → signal trap (`_registry_tmp_guard`) in `sessions_log_update` / `sessions_log_gc`; gc sweeps leftovers.
- [x] A3 Unbounded logs: `_titler_log` gated on `AM_TITLER_DEBUG=1`; `am_log_cap` keeps `titler.log`, `.state-debug.log`, `.hook-debug.log` under 20MB.
- [x] A4 `git_head_branch` infinite loop on a relative path outside a repo.
- [x] A5 `/tmp/am-logs`, `/tmp/am-state` mode 700; umask 077 for pipe-pane files and prompt temp files.
- [x] A6 `am send`: bracketed paste (`paste-buffer -p`), C0 controls stripped except newline/tab, multi-line = one submission.
- [x] A7 `am config get auto-restore` prints; `am interrupt --confirm` → `-i/--interactive` (hidden alias kept).
- [x] A8 Bash gate 4.4 in `am`, `lib/status-bar`, `lib/preview` (hook deliberately ungated: must run on /bin/bash 3.2).
- [x] A9 Title length: Go counts runes (`titleWorthy`), bash test pins characters; `go test ./...` runs in `test_all.sh` (worker 8, `make check`).
- [x] A10 Hook off the critical path: debug-gated jq, backgrounded refresh-client / marker removal, `trap 'exit 0' EXIT`, PostToolUse jq calls 8 → 2.
- [x] A11 Recovery: resume in `project_directory`; branch preflight; `.rebind` revoked on failed launch; `.cwd`/`.bg` mirrored into identities; `recovery_apply_workdir`.
- [x] A12 `registry_gc` rows half: one lock, snapshot inside it, one rewrite, grace window; `basename` fork gone; batched `stat` (`am_files_mtime`) in status-bar.

## B. Features

- [x] B1 Notifications: `notify` (default on), `notify_states` (default `waiting_user`), `notify_cmd`; fired by the hook on transitions, skipped when a client shows the session; osascript / notify-send fallbacks.
- [x] B2 Title stability: ` - 🔄 Reconnecting…` and ` - <dirname>` stripped (`_title_normalize` / `normalizeTitle`); hysteresis — an invalid pane title never replaces an existing task. No manual pin (the user does not set titles).
- [x] B3 `am doctor [session] [--capture]` (`lib/doctor.sh`, `AM_STATE_DEBUG_SINK`).
- [x] B4 `am wait --any|--all s1 s2 ...`; `am done "<summary>"` + `am result [--wait] [--clear] <session>`; dispatch skill updated.
- [x] B5 `am send` guard: exit 4 on running/starting/waiting_user, exit 2 on idle/dead; `--wait`, `--queue`, `--force`.
- [x] B6 `am list --state`, `am kill --state <list> [-y]`. Browser `state:` filter deferred: am-browse entries carry no state today (it belongs with the Go ticker, C1/C2).
- [x] B7 Presets: `am preset save|list|show|rm`, `am new -p`, `--preset=` from the form's Preset field.
- [x] B8 Docs/help drift: `am help` (peek --history/--grep, wait/send/doctor options, browser Ctrl-P/Ctrl-H/filter, tmux arrows/h/mouse/[ ]), README (keys, peek, notifications, dispatch, presets, config, commands, storage), dispatch skill. Screenshots: user.
- [x] B9 Stale-install detection: `_install_fingerprint` over install inputs → `$AM_DIR/.install_stamp`; bare `am` runs `_install_refresh` when it differs; `am install --refresh`.

## C. Structural

- [x] C1 One ticker: `bin/am-core tick` (Go, `internal/sessions/maintenance.go`) owns the title/workdir/branch refresh, the restore scan, and both gc halves; the status-bar tick and `am list` call `am_tick` and nothing else. Markers kept (`.title_scan_last` / `.restore_scan_last` / `.gc_last` / `.gc_extras_last`) because am-browse / am-list-internal still stamp the first of each pair in-process; the sidebar cache and hook request-file signalling stay as they were. Folded in: Go `ReapOrphans` now lists tmux inside the lock and honours `AM_GC_GRACE_SECS` (default 5).
- [x] C2 Go owns the stores: the bash bodies of `auto_title_scan`, `registry_gc`, `sessions_log_scan`, `sessions_log_gc`, `sessions_log_restorable`, `_sessions_log_detect_id_for_session`, `_sessions_log_jsonl_exists`, and the three `*_first_user_message` readers are wrappers over `am-core` (`am_core` in utils.sh passes the effective paths). Deleted outright: `_title_valid`, `_title_normalize`, `_pi_title_extract`, `_cursor_title_extract`, `_title_scan_refresh_workdir`, `_titler_log`, `_am_debug_logs_cap`, `am_log_cap`, `sessions_log_snapshot_gc`. Kept in bash on purpose: `git_head_branch`, `format_time_ago` / `_format_seconds` (fork-free status-bar hot path), the `_slog_encode_*` / store-root helpers and sidecar readers (doctor, agent_kill), `sessions_log_append/update/snapshot` (launch/kill path). Parity first: `internal/sessions/maintenance_test.go` (restore scan binding/correction/no-guess, marker independence, cursor transcript binding, gc halves/grace/temp sweeps, restorable, capLog, titler gating) plus the existing title tests; bash tests keep their assertions through the wrappers with a fake tmux on PATH (`setup_fake_tmux`). Also folded in: `registry_add/update/remove` lock before mktemp and remove the temp on failure. Go bugfix on the way: the browser title path now honours the durable identity sidecar (it read only the ephemeral `.sid`).
- [x] C3 Agent adapter table: `internal/sessions/agents.manifest` (Go embeds it; `lib/agents.manifest` is a symlink for bash) — per type: command, aliases, prompt (stdin/argv), resume template, store layout, title parser, title_state signal, turn_boundary, hook_family, preflight, version_bin, lab. Bash: `am_agent_field` / `am_agent_normalize` / `am_agent_known` (utils.sh), `AGENT_COMMANDS` derived, `agent_restorable`, `agent_resume_args` from the template; consumers rewired: agents.sh log/kill gates, config.sh alias, state.sh (title_state, turn_boundary), recovery.sh preflight, doctor.sh (version bins, lab mapping, transcript path by store), state-hook.sh family gate (manifest when in-repo, inline fallback for Cursor's copy, parity-tested). Go: `AgentSpec` / `Agent()` / `NormalizeAgent` / `AgentTypes`; identity.go, titles.go, sessions.go restorable filter, maintenance.go, slog.go branch on `Store` / `HasStore()` / `Restorable()`. Layout-specific code (encoders, readers, parsers) stays as code, selected by the `store` / `title` fields.
- [x] C4 Version-drift canary: `tests/live_lab/VERIFIED` pins the agent versions the labs last confirmed (labs print the installed version at the end); the hook records observed payload keys per `<agent>.<event>` (`$AM_DIR/hook-schema/`, `.sub` for subagent tool events, `.prev` on change); `am doctor` warns on newer-than-verified agents and on missing load-bearing fields, and checks hook installs per family (Claude/Codex/Cursor event lists mirror install.sh; Cursor's hook copy compared byte-for-byte). Version probing stays in doctor, not the hook (nothing on the turn path). First live run: Claude 2.1.263 and cursor-agent 2026.09.02 newer than pins; pi has no pin yet (run `tests/live_lab/run_pi.sh`).
- [x] C5 `lib/form.sh`: keep (actively used via prefix-n / Ctrl-N; recently improved). No action.

## Deferred / noted

- Browser `state:` filter token (see B6).
- Bash tests that drive the wrappers cannot stub tmux with shell functions any more (the work runs in `bin/am-core`); use `setup_fake_tmux` / `fake_tmux_title` / `fake_tmux_pane` from `tests/test_helpers.sh`.
