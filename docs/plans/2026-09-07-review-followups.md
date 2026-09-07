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

- [ ] C1 One ticker: `am ticker` (Go) owns title scan, restore scan, gc, sidebar cache; markers removed; hook signals via request file.
- [ ] C2 Go owns the stores: remove bash twins (title scan, gc, sessions-log scan/gc/restorable, detect-id, first-message readers, git_head_branch, format_time_ago, encoders); bash calls the Go binary. Carefully, with parity tests first.
- [ ] C3 Agent adapter table: one manifest (bash + Go) with command, aliases, prompt mode, resume args, transcript root/encoding, title parser, turn-boundary reliability, hook namespace, preflight.
- [ ] C4 Version-drift canary: hook records agent version + observed payload fields; verified-against pin; `am doctor`/`am status` warn.
- [x] C5 `lib/form.sh`: keep (actively used via prefix-n / Ctrl-N; recently improved). No action.

## Deferred / noted

- Go `ReapOrphans` still snapshots tmux before taking the lock and has no grace window (bash A12 closed that); fold into C1/C2.
- `registry_add/update/remove` mktemp before locking (same latent leak class as A2, never observed); fold into C2.
- Browser `state:` filter token (see B6).
