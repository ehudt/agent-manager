# Multi-Session Switching Design

## Problem

With 3+ agent sessions, switching is limited to binary toggle (`Prefix+a` = last used) or opening the full browser popup (`Prefix+s`). No middle ground for quick directional navigation.

## Design

### Canonical Session Order

A shared ordering used by both the status bar and all navigation keybindings:

1. **Current session** — always slot 1
2. **Attention sessions** — `waiting_permission`, `waiting_custom`, `waiting_input` — sorted by most-recent activity
3. **Background sessions** — `running`, `idle` — sorted by most-recent activity

Implemented as `am_session_order(current_session)` in `lib/state.sh`, returning newline-separated session names.

### Status Bar

Current status-right excludes the current session. New layout:

```
1:project-x  2:! project-a  3:> project-b  4:~ project-c  5:- project-d
```

- Slot 1 (current): bold white, underline
- Slots 2+: existing state prefixes and colors, with index prepended
- `waiting_input` color changed from `colour114` to `colour34` (darker green, better contrast on light backgrounds)
- State icons unchanged: `!` = permission/custom, `>` = waiting_input, `~` = running, `-` = idle

### Keybindings

| Binding | Action | Implementation |
|---|---|---|
| `Prefix+]` | Next session in sidebar order | `bin/switch-cycle next` |
| `Prefix+[` | Previous session in sidebar order (wraps) | `bin/switch-cycle prev` |
| `Prefix+1` through `Prefix+9` | Jump to slot N | `bin/switch-index N` |
| `Prefix+a` | Last used session (unchanged) | `bin/switch-last` |

Cycling wraps around at both ends.

### New Files

- `bin/switch-cycle` — takes `next`/`prev` argument, computes canonical order, finds current position, switches to adjacent session
- `bin/switch-index` — takes index 1-9, computes canonical order, switches to Nth session

### Modified Files

- `lib/state.sh` — add `am_session_order(current_session)` function
- `lib/status-right` — use `am_session_order`, add current session at slot 1 (highlighted), prepend index numbers, change `colour114` → `colour34`
- `lib/tmux.sh` — add keybindings for `]`, `[`, `1-9`

### No Changes To

- am-browse, registry, agent lifecycle, form — purely additive navigation layer
