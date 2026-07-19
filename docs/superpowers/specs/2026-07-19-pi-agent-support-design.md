# Pi Agent Support — Design

Date: 2026-07-19
Status: approved

## Goal

Full support for the `pi` coding agent (`@earendil-works/pi-coding-agent`) in
agent-manager: launch, state detection, restore, auto-titling, install wiring,
sandbox, and test coverage (including a live-lab variant). Explicitly out of
scope: yolo-mode flag mapping (pi has no permission system; `--yolo` is a
silent no-op for pi sessions).

## Background facts

Verified against pi docs/source at
`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent`:

- Pi extensions are TypeScript modules auto-discovered from
  `~/.pi/agent/extensions/*.ts`. They subscribe to in-process lifecycle
  events; the relevant ones: `session_start` (startup, `/new`, `/resume`,
  `/fork`), `agent_start` (a run begins), `agent_settled` (pi will not
  continue on its own — no retry, auto-compaction, or queued messages left).
- `ctx.sessionManager.getSessionId()` / `getSessionFile()` expose the session
  UUID and JSONL path.
- Sessions live at `~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl`
  where `<encoded-cwd>` = `"--" + cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-") + "--"`.
- Resume: `pi --session <uuid>` (partial UUID accepted) in the original cwd.
- Message entries: `{"type":"message", ..., "message":{"role":"user","content":...}}`
  where content is a string or an array of typed blocks (`{"type":"text","text":...}`).
- Prompt: `pi [messages...]` starts interactive mode with the message
  submitted (same shape as codex's positional prompt).
- Pi maintains the terminal title itself: `pi - <session name> - <cwd basename>`
  when the session is named, `pi - <cwd basename>` otherwise. No
  busy/attention glyph convention.
- Pi core has no tool-permission system; permission/custom dialogs only come
  from third-party extensions and are not observable by our extension.

## 1. Launch (lib/agents.sh)

- `AGENT_COMMANDS[pi]="pi"`.
- `_agent_prompt_as_arg`: pi → true.
- `agent_get_yolo_flag`: pi → empty string. `agent_launch` appends the yolo
  flag only when non-empty, making `--yolo` a no-op for pi.
- `agent_supports_worktree`: add pi. `agent_cli_manages_worktree` stays
  claude-only; `agent_worktree_root`: pi → `$directory/.pi/worktrees`
  (am-managed worktree, codex pattern).
- The new-session form and `am new -a pi` need no changes (agent options
  derive from `AGENT_COMMANDS`).

## 2. State detection

### Extension: `lib/hooks/am-state.ts` (in the am repo, next to the Claude hook)

Symlinked by `am install` into `~/.pi/agent/extensions/am-state.ts` (always
version-fresh, mirroring the skills-symlink pattern). Behavior:

- **Guard**: no-op unless `process.env.AM_SESSION_NAME` is set. When
  `~/.agent-manager/sessions.json` (override: `AM_REGISTRY`) exists, the
  session name must appear in it; when the registry file is missing (sandbox
  container), trust `AM_SESSION_NAME`.
- **State writes** to `$AM_STATE_DIR/<session>` (`AM_STATE_DIR` default
  `/tmp/am-state`), transition-only (skip same-state rewrites so the file
  mtime pins state-entry time, feeding status-bar tab ages):
  - `session_start` → `waiting_input` — covers fresh-idle-at-first-prompt,
    the case Claude needed the title glyph for.
  - `agent_start` → `running`.
  - `agent_settled` → `waiting_input`.
- **Sid sidecar**: on `session_start`, write the session UUID to
  `$AM_STATE_DIR/<session>.sid`. Re-fires on `/new`/`/resume`/`/fork`,
  keeping the sidecar authoritative (matches the Claude hook doctrine).
- **Side effects** (mirroring `lib/hooks/state-hook.sh`): remove
  `$AM_DIR/.list_cache`; remove `$AM_DIR/.title_scan_last` on prompt
  boundaries (`agent_start`, `agent_settled`); run
  `tmux -L ${AM_TMUX_SOCKET:-agent-manager} refresh-client -S`
  (fire-and-forget; harmless no-op inside the sandbox).
- All writes are best-effort: failures must never break the pi session.

### Resolver (lib/state.sh)

For `agent_type == pi`, `_state_resolve` reads the hook state **ungated**
(raw read, no 180s running-staleness gate). Rationale: the extension is
in-process — if pi dies, the top pane becomes a shell and the shell-pane
check already yields `idle`/`dead`. Long quiet tool calls therefore cannot
flap to `unknown`. No title-glyph layer for pi (pi's title carries no
busy/attention signal) and no pane-content heuristics (per project history).

State vocabulary for pi: `starting`, `running`, `waiting_input`, `idle`,
`dead`, `unknown`. `waiting_permission` / `waiting_custom` /
`waiting_background` never occur (not observable / not applicable).

`state-hook.sh` is untouched.

## 3. Restore

- `agent_launch`: `sessions_log_append` gate widens from `claude` to
  `claude|pi`.
- `agent_kill`: the snapshot/close block widens to `claude|pi`; sid binding
  order (sidecar → logged sid → guarded directory detection) is shared, with
  agent-aware JSONL existence/detection helpers.
- New helpers (bash `lib/registry.sh` + Go `internal/sessions`):
  - pi cwd encoding (`--…--` scheme above);
  - `_sessions_log_jsonl_exists` / `claudeJSONLExists` equivalents for pi:
    `~/.pi/agent/sessions/<encoded>/*_<sid>.jsonl` glob;
  - detection of the newest pi session UUID for a directory (filename parse,
    newest mtime; same shared-directory guard as Claude).
- `sessions_log_scan` (rolling snapshots, sid backfill, task sync) widens its
  claude gates to `claude|pi`.
- `sessions_log_restorable` (bash) and the Go restorable filter
  (`internal/sessions/sessions.go`) accept `pi` rows using the pi JSONL
  check.
- Restore flow: the picker protocol (`__RESTORE__<US>dir<US>sid`) gains an
  agent field; `cmd_restore_internal` routes: claude →
  `claude --resume <sid>`, pi → `pi --session <sid>`. Pre-seeding of the
  resumed sid in the sessions log stays as-is.

## 4. Auto-titling

- `auto_title_scan` (bash) and `RefreshTitles` (Go, `internal/sessions/titles.go`)
  learn pi's title format: `pi - <name> - <base>` → candidate title `<name>`;
  `pi - <base>` (or any unparsable pi title) → invalid → JSONL fallback.
- New `pi_first_user_message(dir, [sid])` in `lib/utils.sh` + Go mirror:
  first `type=="message" && .message.role=="user"` entry from the session
  JSONL (sid-matched file when known, else newest by mtime), content string
  or first text block, truncated/validated like the Claude path.

## 5. Sandbox

- `sandbox/Dockerfile`: `npm install -g @earendil-works/pi-coding-agent`
  (node already present for codex).
- State channel out of the container:
  - `sandbox_exec_cmd` gains `-e AM_SESSION_NAME=<session>`;
  - `sandbox_start` bind-mounts `/tmp/am-state` into the container at the
    same path. Side benefit: Claude hook states from sandboxed sessions
    become host-visible too.
- Extension inside the container: `sandbox_start` copies `lib/hooks/am-state.ts`
  into `$SB_HOME_DIR/.pi/agent/extensions/am-state.ts` (idempotent, re-copied
  each start; a symlink cannot cross the mount).

## 6. Install, docs, version

- `am install` (scripts/install.sh step): symlink
  `<repo>/lib/hooks/am-state.ts` → `~/.pi/agent/extensions/am-state.ts` when the
  `pi` CLI is on PATH (warn and skip otherwise). Idempotent re-point logic
  like the skills symlinks.
- AGENTS.md: pi paragraph in State Detection; Key Files, Key Functions and
  Extension Points tables updated; Data Flow note for pi restore.
- `AM_VERSION`: MINOR bump (new user-facing agent type).

## 7. Tests

`tests/test_all.sh` additions (unit-style, no real pi runs):

- launch: prompt-as-arg for pi, empty yolo flag handling, pi worktree root;
- resolver: pi hook state trusted ungated; shell-pane check still wins;
  stale `running` file for pi stays `running` (no flap to unknown);
- registry/restore: pi cwd encoding, pi JSONL existence + newest-sid
  detection fixtures, restorable filter accepts pi, restore command routing;
- titling: pi title parsing (named/unnamed), `pi_first_user_message`
  fixtures (string content, block content, missing file);
- Go tests mirroring the bash fixtures (encoding, JSONL exists, first user
  message, restorable filter, RefreshTitles pi path);
- extension: node-level smoke test is out of scope for test_all.sh (no pi
  dependency in CI); covered by the live lab instead.

Live lab: `tests/live_lab/` gains a pi runner driving a real `pi` session
through fresh-idle → running → settled → long-quiet-tool-call, recording
state-file transitions, sid sidecar, and pane titles. Provider/model
parameterized (defaults to the user's pi default). Excluded from
`test_all.sh` (spends tokens), like the Claude lab.

## Error handling

- Extension: every fs/subprocess side effect wrapped; failures never
  propagate into pi.
- Missing `~/.pi/agent/sessions` dir / unreadable JSONL → titling and restore
  helpers return empty (existing Claude semantics).
- `am install` without pi on PATH → warn, skip extension symlink, count as
  warning not failure.
- Sandboxed pi without the extension copied (stale sandbox-home) → state
  shows `unknown`; `sb_reset`/next `sandbox_start` heals it.
