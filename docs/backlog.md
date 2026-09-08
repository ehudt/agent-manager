# Backlog

## In Progress

- **Review follow-ups (2026-09-07)** — defects, daily-loop features, and the
  structural work (single ticker, Go-owned stores, agent adapter table,
  version canary). Tracked item by item in
  [plans/2026-09-07-review-followups.md](plans/2026-09-07-review-followups.md).

## Up Next

- **Desktop notifications: find out what is off (reported 2026-09-08)** —
  Ehud: "something's off about them", no specific symptom yet. They are fired
  from `_notify_maybe` in `lib/hooks/state-hook.sh`, in the hook's detached
  tail, only on a transition into a `notify_states` state (default
  `waiting_user`), and skipped when a tmux client is attached to that session.
  Nothing records whether a notification was sent or why it was skipped, so
  start there: add a `notify` line to the hook debug log (`AM_HOOK_DEBUG=1`) or
  a small `$AM_DIR/notify.log` (session, state, sent/skipped + reason, command
  rc). Then check the likely faults against it: (1) the attached-client
  suppression matches `client_session`, so a session shown in another
  client's *previous* window or in a zoomed/hidden pane still counts as "on
  screen", while a session visible in an iTerm tab that is not the tmux
  client's current session is *not* suppressed — the rule may be the wrong
  way round for how Ehud actually works; (2) the `.bg`-snapshot path turns a
  field-less `idle_prompt` into `ready` and the completion re-fires `Stop`,
  which could produce duplicate `ready` notifications when `notify_states`
  includes `ready`; (3) a state file deleted under a live session (see the GC
  audit log, `gc.log`, added 2026-09-08) makes the next hook event look like
  a transition and re-notify; (4) macOS: `osascript display notification`
  attributes the banner to Script Editor, is rate-limited by Notification
  Center, and silently drops when Focus is on — confirm with `AM_NOTIFY_CMD`
  set to a logging stub; (5) the title/body come from the registry `task`,
  which lags the title scan by up to 60s, so early notifications carry the
  session name instead of the task. Ask Ehud for the concrete symptom
  (missing, duplicate, late, wrong text, wrong session) before fixing.

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
