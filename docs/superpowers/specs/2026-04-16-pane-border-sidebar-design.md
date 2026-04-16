# Pane Border Session Sidebar

**Date**: 2026-04-16
**Status**: Approved

## Problem

Active sessions shown in tmux `status-right` (bottom-right corner) are too far
from the user's focus area. Eyes must travel to the far corner to see session
state.

## Solution

Use tmux `pane-border-status top` + `pane-border-format` to render the session
sidebar on the horizontal divider between agent pane and shell pane — center of
screen, high visibility.

## Layout

```
┌─────────────────────────────────────────────────┐
│ ── agent-manager/main ──────────────────────────│  ← pane 0 top border (task/title)
│                                                 │
│  Agent pane (Claude / other agent)              │
│                                                 │
│ ── 1:repo/main  2:! other/feat  3:> lib/fix ── │  ← pane 1 top border (session sidebar)
│  Shell pane (15 lines)                          │
│                                                 │
└─────────────────────────────────────────────────┘
  status-left: session metadata    status-right: session sidebar (kept as redundant display)
```

## Performance

Write-through cache — zero new script invocations:

| Component | Cost |
|-----------|------|
| `status-right` (status bar, already runs) | +1 `printf > file` to write cache |
| Border pane 0 (agent header) | Zero — tmux variable expansion (`#{pane_title}`) |
| Border pane 1 (session sidebar) | `cat` of ~200 byte file |

Cache location: `/tmp/am-sidebar/<session_name>`

## Implementation

### 1. tmux config (`lib/tmux.sh` → `am_tmux_config_path`)

Add to generated config:
```
set -g pane-border-status top
set -g pane-border-format '#{?#{==:#{pane_index},0},#[align=centre]#{pane_title},#[align=centre]#(cat /tmp/am-sidebar/#{session_name} 2>/dev/null)}'
```

### 2. Cache write (`lib/status-right`)

After building `$result`, write to cache:
```bash
cache_dir="/tmp/am-sidebar"
mkdir -p "$cache_dir"
printf '%s' "$result" > "$cache_dir/$current"
```

### 3. Agent pane title (`lib/agents.sh` → `agent_launch`)

Set pane title after selecting top pane:
```bash
local title_label="${task:-$(dir_basename "$directory")}"
title_label=$(truncate "$title_label" 60)
am_tmux select-pane -t "$session_name:.{top}" -T "$title_label"
```

### 4. Cache cleanup (`lib/tmux.sh` → `tmux_cleanup_logs`)

Add removal of `/tmp/am-sidebar/$name` alongside existing log cleanup.

### 5. Border styling

Use `pane-border-lines single` and appropriate `pane-border-style` /
`pane-active-border-style` for clean visual separation.

## Files Changed

| File | Change |
|------|--------|
| `lib/tmux.sh` | Config: pane-border-status/format/style. Cleanup: sidebar cache |
| `lib/status-right` | Write output to cache file as side effect |
| `lib/agents.sh` | Set pane title on agent pane at launch |
| `tests/test_standalone_scripts.sh` | Verify cache file written |

## Kept Unchanged

- `status-right` output format and logic — identical
- `status-right` in status bar — stays as redundant display
- All existing tests remain valid
