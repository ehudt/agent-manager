# Security

`am` runs locally. It launches agent processes in tmux sessions on your
machine, edits your shell rc and your agents' hook configuration when you
run `am install` (preview with `am install --dry-run`, reverse with
`am uninstall`), and never sends anything off the machine itself; desktop
notifications go through `osascript` / `notify-send`.

The state hooks it installs run on every Claude Code / Codex / Cursor
event. They read the hook payload and write small state files under
`/tmp/am-state`; the source is `lib/hooks/state-hook.sh`.

## Reporting

Report a vulnerability by opening a GitHub security advisory on the
repository (Security > Report a vulnerability) rather than a public issue.
Include the `am version` output and the steps to reproduce.

CI runs `scripts/scan-secrets.sh` over tracked files and the git history
on every push.
