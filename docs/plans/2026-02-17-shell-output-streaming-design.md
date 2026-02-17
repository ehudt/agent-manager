# Shell Output Streaming

## Summary

Stream tmux pane output to log files for easy reference and agent access.

## Activation

Env var `AM_STREAM_LOGS=1` (off by default). Checked at session creation.

## Log Structure

```
/tmp/am-logs/<session-name>/
├── agent.log
└── shell.log
```

## Mechanism

- `tmux pipe-pane -o` on each pane after creation
- `AM_LOG_DIR` env var exported into each pane
- Logs are raw terminal output (includes ANSI codes)

## Cleanup

- `/tmp` cleared on reboot
- `am kill` removes session log directory

## Code Changes

- `lib/tmux.sh`: `tmux_enable_pipe_pane()` wrapper, cleanup in kill path
- `lib/agents.sh`: `agent_launch()` calls pipe-pane + exports env var when enabled

## Not Included

- No config file, log rotation, ANSI stripping, or `am logs` subcommand
