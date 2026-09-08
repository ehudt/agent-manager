# Backlog

## In Progress

- **Review follow-ups (2026-09-07)** — defects, daily-loop features, and the
  structural work (single ticker, Go-owned stores, agent adapter table,
  version canary). Tracked item by item in
  [plans/2026-09-07-review-followups.md](plans/2026-09-07-review-followups.md).

## Up Next

- **Desktop notifications: remaining rough edges (2026-09-08)** — The
  reported symptom ("most of the notifications look like gibberish or partial
  gibberish") was the macOS notifier reading its strings through
  AppleScript's `system attribute`, which decodes environment variables as
  MacRoman: every `·` in the title rendered as `¬∑` and curly quotes, dashes,
  and check marks in the task came out as mojibake. Fixed in 0.27.3 by
  passing title and body as osascript arguments (`tests/test_state_hooks.sh`
  guards the round trip). Notifications are fired from `_notify_maybe` in
  `lib/hooks/state-hook.sh`, in the hook's detached tail, only on a
  transition into a `notify_states` state (default `waiting_user`), and
  skipped when a tmux client is attached to that session. Still open, none
  confirmed as a problem yet: (1) the banner is attributed to Script Editor
  (its icon, its name; clicking opens Script Editor, not the session) — a
  `terminal-notifier`/`alerter` path with `-activate` on the terminal's
  bundle id would fix both, when installed; (2) the attached-client
  suppression matches `client_session` only, so the session on screen is
  never announced even when the terminal is behind another app, while a
  session in another tmux window of the same client is; (3) only permission
  and question dialogs notify by default — finished turns need
  `notify_states waiting_user,ready`, which may be the more useful default;
  (4) nothing records whether a notification was sent or why it was skipped:
  a `notify` line under `AM_HOOK_DEBUG=1` (session, state, sent/skipped +
  reason, command rc) would make the next report checkable — Notification
  Center's own database needs Full Disk Access and is not readable from the
  hook's user; (5) the body is the registry `task`, which can lag the title
  scan by up to 60s, so an early notification carries the session name.
  Ghostty is the terminal in use (`bell-features = system,...` posts a system
  notification on bell), tmux has `allow-passthrough off` and `bell-action
  any`; whether Claude Code's own notification channel produces a second
  banner through that path is unverified.

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc. State detection is the non-portable part (pane title + local process tree); see the architecture notes in the follow-ups plan.

- **Review panel: attribute hunks to turns** — follow-up to the review
  checkpoints feature (`am diff`, per-session `refs/am/<session>/reviewed`,
  change count on the tab). The transcript records which turn made each Edit /
  Write / Bash call, so the review panel could annotate a changed region with
  the prompt that caused it ("changed in turn 14, after 'fix the race'").
  Answers "why did it change this", which no git tool can. Needs the transcript
  readers in `internal/sessions/identity.go`; do not build before the panel
  itself exists.

## Known Issues

- **State detection edge transitions** — `_state_resolve` combines the shell
  process check, agent-maintained title status, canonical hook state, and
  Cursor's narrow Ready-footer refinement. Earlier pane classifiers flapped
  live sessions through `running`/`unknown`/`background`. Remaining edge:
  agents without reliable turn-boundary events still use the 180s running
  staleness gate. Use `am doctor <session>` first, `AM_STATE_DEBUG=1` for
  empirical data and `tests/live_lab/` for ground truth.

## Closed

- **Inactive sessions issues (session-id mismatch)** — closed in v0.21.0
  (5f7bd47): sessions are bound to their own pane and transcript; every
  directory-based guess was removed. History in
  [session-id-mismatch.md](session-id-mismatch.md).
- **Rename skill to agent-manager-dispatch** — done (`skills/agent-manager-dispatch/`).
