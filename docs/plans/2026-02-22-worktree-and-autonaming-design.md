# Worktree Isolation & Auto-naming Design

## Feature 1: Worktree Isolation (`-w`)

### Overview

Opt-in flag that launches Claude in a git worktree via `claude -w <name>`, then cd's the shell pane into the worktree directory.

### CLI

```
am new -w ~/project              # worktree named am-XXXXXX (default)
am new -w my-feature ~/project   # worktree named "my-feature"
am new ~/project                 # no worktree (unchanged)
```

Flag: `-w` / `--worktree` with an optional name argument.

### How it works

1. `agent_launch()` receives worktree name (or generates default `am-${session_hash}`)
2. Appends `-w "<worktree_name>"` to the claude command
3. Claude creates the worktree eagerly at `<repo>/.claude/worktrees/<name>`
4. Background process polls for that directory (up to 10s), then cd's the shell pane into it
5. `worktree_path` stored in registry for display

### Constraints

- Only for Claude agent type (others don't support `-w`)
- Only for git repos (skip with warning if not a git repo)
- am does NOT clean up worktrees — that's Claude's responsibility on normal exit, or the user's on force-kill

### Changes

| File | Change |
|------|--------|
| `am` | `cmd_new()`: parse `-w [name]` flag, pass to `agent_launch()` |
| `am` | `usage()`: document new flag |
| `lib/agents.sh` | `agent_launch()`: accept worktree param, append `-w` to claude cmd, spawn background cd waiter |
| `lib/registry.sh` | No schema change — use existing `registry_update` to store `worktree_path` |
| `lib/agents.sh` | `agent_info()`: show worktree path if present |
| `lib/fzf.sh` | Ctrl-N flow: no change (worktree is a CLI flag, not interactive) |

### Background cd waiter

```bash
worktree_path="$directory/.claude/worktrees/$worktree_name"
(for i in $(seq 1 20); do
    [ -d "$worktree_path" ] && {
        tmux send-keys -t "${session_name}:0.1" "cd '$worktree_path'" Enter
        break
    }
    sleep 0.5
done) &
```

---

## Feature 2: Auto-naming with Haiku

### Overview

Background process that extracts the first user message from Claude's JSONL session file and asks Haiku to generate a short title, then writes it to the registry.

### How it works

1. Launched as background process at end of `agent_launch()`
2. Polls for JSONL content (every 2s, up to 60s)
3. Extracts first meaningful user message (reuses existing logic from `get_claude_session_title()`)
4. Calls `claude -p --model haiku` with a title-generation prompt
5. Writes result to `registry_update "$session_name" task "$title"`
6. Fallback: if `claude -p` fails, uses raw first-sentence extraction

### Changes

| File | Change |
|------|--------|
| `lib/agents.sh` | New function `auto_title_session()` — the background titler |
| `lib/agents.sh` | `agent_launch()`: spawn `auto_title_session` in background |

### Display

No display changes needed — `agent_display_name()` and `lib/preview` already read and show the `task` field from registry.
