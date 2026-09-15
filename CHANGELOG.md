# Changelog

User-facing changes per release. The version is `AM_VERSION` in `am`
(`am version`); every bump lands in the same commit as its entry here, and
`scripts/check-changelog.sh` (run by CI through `scripts/check-docs.sh`)
fails when the two disagree. Patch releases are folded into their minor
entry unless they changed behaviour a user would notice.

## [0.37.0] - 2026-09-15

- Inactive sessions (the browser's restore rows and `am restore`) are listed
  most recently *closed* first. They were in launch order, so a long-lived
  session closed a minute ago sat below every shorter session started after
  it and looked missing.
- The browser's Ctrl-N form now resolves a `@spec` directory through the
  configured `dir_provider` and honors the Preset field, like `am new`. It
  launched with the raw values before, so `@<PR>` failed with "Directory does
  not exist: @…" and the preset's flags went to the agent unparsed.

## [0.36.0] - 2026-09-14

- `am wait --state` and state-file reads no longer accept the pre-0.12
  `waiting_input` / `waiting_permission` / `waiting_custom` /
  `waiting_background` aliases; use the canonical `ready`, `waiting_user`,
  `background` names.
- Internal consolidation (no behavior change): the bash git-branch, transcript
  path, and sidecar helpers now call the Go binaries instead of reimplementing
  them; the state hook resolves agent families from the manifest; dead code
  removed across bash and Go.

## [0.35.0] - 2026-09-13

- `am install --dry-run` prints every file the setup would create, link, or
  edit (config, skill links, PATH links, shell rc block, the am entries in
  Claude / Codex / Cursor hook files, the pi and opencode plugin links, the
  Go build) and changes nothing.
- `am uninstall [--dry-run] [--purge]` reverses the install: PATH links,
  the shell rc block, the am hook entries (a user's own hooks stay), the
  Cursor helper copy, the pi/opencode links, the skill links; `--purge`
  also removes `~/.agent-manager`.
- `am completions bash|zsh`: subcommands, flags, agent types, config keys,
  preset names, and live session names at every `<TAB>`. `am install` adds
  the `eval` line to the shell rc block.
- `./am install` is the documented install path (the script alone skipped
  the skills and the Go build); the bash version error names the fix
  (macOS ships 3.2, am needs 4.4); the README dependency table says so.
- `am doctor` flags tmux / fzf / jq / bash below their minimum, and no
  longer exits 1 on macOS when Notification Center has no Script Editor
  entry. A missing dependency error points at `am install`.
- `CHANGELOG.md`, checked by CI against `AM_VERSION`; `CONTRIBUTING.md`,
  `SECURITY.md`, issue templates, the CI badge, a platform-support section
  and a config-key table in the README.

## [0.34.1] - 2026-09-13

- `docs/adding-an-agent.md`: the end-to-end guide for integrating a new agent.

## [0.34.0] - 2026-09-13

- opencode is a full agent: in-process state plugin (`am install` links it
  into opencode's global plugin dir), transcript identity via a first-message
  mirror (opencode's store is SQLite), pane title, `am restore`, and a live
  lab (`tests/live_lab/run_opencode.sh`).

## [0.33.0] - 2026-09-10

- Review: the baseline follows a rebase. The agent's commits are found again
  by patch-id in the rewritten history and the baseline re-anchors there, so
  the tab counts only the agent's work, not the upstream commits the rebase
  pulled in. (0.33.2 offers the re-anchored base in the picker for sessions
  whose chain never recorded the rebase.)
- Review pane: picker rows carry the delta they would show
  (`Δ<files> +<add> −<del>`), and `/` takes any commit-ish as a base.
- Review pane note (0.33.1): the queue fallback is for a dialog, not a busy
  agent, matching the 0.32 send guard.

## [0.32.0] - 2026-09-10

- `am send` delivers mid-turn by default: agent harnesses steer on or queue
  input while a turn runs. Refused only when a permission/question dialog is
  up or the agent is still starting (exit 4), or the agent exited and the
  text would run in a shell (exit 2). `--wait` / `--queue` still deliver at
  the turn boundary.

## [0.31.0] - 2026-09-10

- `am send --queue`: no default deadline, an outcome line per prompt in
  `$AM_DIR/queue.log`, and an undelivered prompt kept as
  `queue/<file>.failed` instead of silently dropped. `--wait` accepts the
  `background` state.

## [0.30.0] - 2026-09-08

- Review pane: `j`/`k` (files) and `]`/`[` (hunks) work from either pane; the
  arrows follow the focused pane. The footer names every key (0.30.1).

## [0.29.0] - 2026-09-08

- Review pane: `s` opens the base picker: view the change since any
  checkpoint, or `b` to make it the baseline.

## [0.28.0] - 2026-09-08

- `am doctor`: notifications section, including the macOS Notification
  Center style of Script Editor (osascript banners) with a warning when
  banners fade.
- Notifications pass title/body to osascript as arguments, fixing the
  mojibake in every banner (0.27.3).

## [0.27.0] - 2026-09-08

- Review pane: `c` sends the hunk under the cursor to the agent with a note.
- GC never sweeps the shared hook state dir with an empty live set; every
  removal is logged in `$AM_DIR/gc.log` (0.27.1). A missing hook file next
  to a known identity reads as `unknown`, not `ready` (0.27.2).

## [0.26.0] - 2026-09-08

- Review pane: `am review` / `prefix+v` opens a live diff TUI beside the
  agent (file list, parsed hunks, `a` to acknowledge).

## [0.25.0] - 2026-09-08

- Review checkpoints: `am diff [session] [--ack|--reset|--list|--checkpoint]`
  shows what the agent changed since you last reviewed; the tab shows the
  pending size as `Δ<files> +<add> −<del>`. Checkpoints live in the
  session's own repository under `refs/am/<session>/`.

## [0.24.0] - 2026-09-07

- Directory providers: `am new @spec` resolves a directory through the
  configured `dir_provider` (suggest/resolve verbs); the form completes
  `@` specs. Replaces `-W`/`workspace_cmd`. Bare `@` keeps the provider's
  default (0.24.1).

## [0.23.0] - 2026-09-07

- Agent adapter manifest: one table (`lib/agents.manifest`) of per-agent
  facts shared by bash and Go.

## [0.22.0] - 2026-09-07

- Desktop notifications on state transitions (`notify`, `notify_states`,
  `notify_cmd` config), skipped when a client already shows the session.
- `am doctor [session] [--capture]`: every input behind a session's state,
  plus the version-drift canary against the live-lab pins.
- Launch presets: `am preset save|list|show|rm`, `am new -p <name>`, and a
  Preset field in the form.
- Dispatch fan-in: `am wait --all|--any`, `am done` / `am result`,
  `am send --queue`, `am kill --state`, `am list --state`.

## [0.21.0] - 2026-09-07

- Sessions are bound to their own pane and transcript: identity comes only
  from the sidecar the session's own hook wrote; every directory-based guess
  is gone. Fixes a foreign Claude in the same directory driving another
  session's tab.

## [0.20.0] - 2026-09-02

- Tab labels follow where the agent works: the Claude hook records the Bash
  tool's tracked cwd, the branch is re-read from `.git/HEAD`; `am cd` for
  agents without hooks.

## [0.19.0] - 2026-09-02

- Adaptive status-bar tabs: one fit shared by every tab, fields truncate
  with `…`, default branches hidden; the attention counter is gone.

## [0.18.0] - 2026-09-02

- Removed the sandbox, yolo, worktree, and form-mode features.

## [0.17.0] - 2026-09-02

- Pane environment (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, ...) is seeded at
  pane creation via tmux `-e`; `am id` prints the current session name.

## [0.16.0] - 2026-08-30

- The shell pane is a collapsible on-demand panel (`prefix+\``, `am shell`);
  sessions launch agent-only by default (`--shell`, `shell_pane` config).

## [0.15.0] - 2026-08-30

- The new-session form is faster and fills the terminal height.

## [0.14.0] - 2026-08-28

- Reboot recovery: open sessions are restored after a reboot from a durable
  desired-session store (`auto_restore` config).

## [0.13.0] - 2026-08-27

- New-session launches are fast (no synchronous scans on the launch path);
  launched directories are recorded in zoxide (0.12.1).

## [0.12.0] - 2026-08-25

- Session lifecycle states clarified and canonicalised (`ready`, `running`,
  `waiting_user`, `background`, `starting`, `idle`, `dead`, `unknown`).

## [0.11.0] - 2026-08-25

- Cursor: `background` detected from the Ready footer's task counter.

## [0.10.0] - 2026-08-15

- Full Cursor Agent support: hooks, identity sidecars, title suffixes,
  restore. Claude's circle-phase busy glyph recognised (0.10.1); `✳` no
  longer read as needs-attention, hooks trusted ungated (0.10.2); hook
  writes gated on agent family (0.10.3).

## [0.9.0] - 2026-07-20

- The dispatch skill is `agent-manager-dispatch` (was `am-orchestration`).
  Status-bar option writes chunked under tmux's command cap (0.9.1).

## [0.8.0] - 2026-07-19

- pi agent support with an in-process state extension. Registry writes
  serialised under a shared flock across bash and Go (0.8.1).

## [0.7.0] - 2026-07-10

- State detection reads Claude's title glyph instead of pane-content
  heuristics. tmux extended keys for Shift+Enter (0.7.2).

## [0.6.0] - 2026-07-08

- Waiting tabs show time-in-state, not tmux activity.

## [0.5.0] - 2026-06-28

- Background work detection from Claude's `Stop` payload (`background_tasks`),
  refined through 0.5.7.

## [0.4.0] - 2026-06-28

- Session picker results ranked by match quality, then recency.

## [0.3.0] - 2026-06-22

- `waiting_background` state for sessions blocked on background work.

## [0.2.0] - 2026-06-16

- SemVer adopted (`AM_VERSION`); skill re-link fix.

## [0.1.0] - 2026-02-04

- First version: tmux-backed sessions, the fzf browser, `am new` / `am send`
  / `am peek`, Claude Code state hooks.
