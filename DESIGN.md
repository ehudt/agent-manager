# Agent Manager - Design Document

## Overview

A CLI tool for managing multiple AI coding agent sessions (Claude Code, Codex CLI, etc.) using **tmux** for session persistence and **fzf** for an interactive browsing interface.

## Requirements

| Requirement | Value |
|-------------|-------|
| Use case | Both cross-project and same-project agents |
| Launch mode | Both from manager AND attach to existing |
| Agent types | Claude Code, Codex (extensible via `AGENT_COMMANDS`) |
| Persistence | Sessions must survive logout/reboot |
| Metadata | Rich: directory, branch, agent type, running time, last command |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         agent-manager (am)                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐   │
│  │   am list   │────▶│     fzf     │────▶│   tmux attach/new   │   │
│  │  (default)  │     │  + preview  │     │                     │   │
│  └─────────────┘     └─────────────┘     └─────────────────────┘   │
│         │                   │                      │                │
│         ▼                   ▼                      ▼                │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐   │
│  │  Session    │     │  Preview    │     │  Agent Runner       │   │
│  │  Registry   │     │  Renderer   │     │  (claude, codex)    │   │
│  │  (JSON)     │     │  (capture)  │     │                     │   │
│  └─────────────┘     └─────────────┘     └─────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Session Registry (`~/.agent-manager/sessions.json`)

Stores metadata that tmux doesn't track natively:

```json
{
  "sessions": {
    "am-abc123": {
      "name": "am-abc123",
      "directory": "/home/user/code/myapp",
      "branch": "feature/auth",
      "agent_type": "claude",
      "created_at": "2024-01-15T10:30:00Z",
      "task": "implement user auth flow"
    }
  }
}
```

### 2. Session Naming Convention

```
am-<short-hash>
```

Where `<short-hash>` is derived from `directory + timestamp` for uniqueness.

The **display name** shown in fzf is composed from metadata:
```
myapp/feature/auth [claude] implement user auth flow (2h ago)
│       │             │        │                        └── activity indicator
│       │             │        └── task (auto-titled or manual)
│       │             └── agent type
│       └── git branch
└── directory basename
```

### 3. tmux Integration

**Why tmux over screen:**
- `capture-pane -p` outputs directly to stdout (no temp files)
- `session_activity` timestamp for detecting recent activity
- Rich format strings (`-F`) for scripting
- Native conversation resume can rebuild sessions without serializing tmux processes

**Session structure:**
```
tmux session: am-abc123
  ├── window 0: agent
  │     ├── pane (top): agent (claude, codex)        ← preview captures this
  │     └── pane (bottom, 15 lines): shell panel     ← optional, same working
  │                                                     directory; opened via
  │                                                     prefix+` / am shell
  └── window "_amshell": parked shell panel          ← only while hidden
```

The shell panel is collapsible (VS Code-style): sessions launch agent-only
by default, the panel is created on first toggle, and hiding it breaks the
pane into the hidden `_amshell` window (cwd, history, jobs, and shell.log
streaming survive) instead of killing it.

### 4. Preview System

fzf preview will show:

```
┌─ Preview ────────────────────────────────────────────┐
│ 📁 /home/user/code/myapp                           │
│ 🌿 feature/auth                                      │
│ 🤖 claude | Started: 2h 15m ago | Last active: 30s   │
│ ─────────────────────────────────────────────────────│
│ [Terminal output from tmux capture-pane]             │
│                                                      │
│ > Reading src/auth/handler.ts...                     │
│ > I'll implement the OAuth flow...                   │
│ > [tool calls shown here]                            │
│                                                      │
└──────────────────────────────────────────────────────┘
```

## CLI Interface

### Commands

```bash
# List/browse sessions (default action)
am                      # Opens fzf browser
am list                 # Same as above
am list --json          # Output JSON for scripting (includes state field)

# Create new session
am new                  # Interactive: pick directory, starts claude
am new /path/to/project # Start claude in specific directory
am new -t codex         # Start codex instead of claude
am new --name "my-task" # Custom display name
am new -W [branch]      # Allocate the directory via the configured workspace_cmd
am new --detach         # Create without attaching
am new --print-session  # Print session name to stdout

# Interact with sessions
am send <session> "prompt"        # Send prompt to running session
am send --wait <session> "prompt" # Wait for ready, then send
am peek <session>                 # Snapshot of agent pane
am peek --follow <session>        # Stream agent output
am peek --json <session>          # Structured snapshot with state

# Session state and orchestration
am status <session>               # Show session state
am status --json <session>        # Machine-readable state
am wait <session>                 # Block until agent finishes
am interrupt <session>            # Send Ctrl-C to agent pane

# Attach to session
am attach <session>     # Attach by name or fuzzy match

# Kill session
am kill <session>       # Kill specific session
am kill --all           # Kill all agent-manager sessions

# Session info
am info <session>       # Show detailed session info

# Configuration
am config               # Show current config
am config set <key> <value>  # Set config value
am config get <key>          # Get config value
```

### fzf Keybindings

| Key | Action |
|-----|--------|
| `Enter` | Attach to selected session |
| `Ctrl-N` | Create new session (prompts for directory) |
| `Ctrl-X` | Kill selected session |
| `Ctrl-R` | Refresh session list |
| `Ctrl-P` | Toggle preview panel |
| `Ctrl-J/K` | Scroll preview down/up |
| `Ctrl-D/U` | Scroll preview half-page down/up |
| `?` | Show help |
| `Esc` | Exit |

## File Structure

```
agent-manager/
├── am                      # Main executable (bash)
├── lib/
│   ├── agents.sh           # Agent lifecycle, launch, display formatting, kill
│   ├── config.sh           # User config: defaults, feature flags, persistent settings
│   ├── form.sh             # tput-based new session form (Navigate/Edit modes)
│   ├── fzf.sh              # fzf UI, directory picker with history annotations
│   ├── preview             # Standalone preview script for fzf panel
│   ├── dir-preview         # Standalone preview script for directory picker
│   ├── status-bar          # Standalone script: renders bottom bar as an adaptive clickable session-tab strip + writes @am_sidebar
│   ├── strip-ansi          # Standalone script: strips ANSI escape codes
│   ├── registry.sh         # Session registry, persistent history (JSONL), auto-titling
│   ├── state.sh            # Session state detection: JSONL + pane pattern matching
│   ├── tmux.sh             # tmux wrapper functions
│   └── utils.sh            # Common utilities
├── bin/
│   ├── kill-and-switch     # tmux helper: kill session + switch to next
│   ├── switch-cycle        # tmux helper: cycle next/prev in sidebar order
│   ├── switch-index        # tmux helper: jump to Nth sidebar slot
│   └── switch-last         # tmux helper: switch to most recent am-* session
├── skills/
│   └── agent-manager-dispatch/
│       └── SKILL.md        # Claude Code skill for multi-session dispatch/orchestration
├── scripts/
│   ├── check-docs.sh       # Documentation check script
│   ├── clean-history.sh    # History cleanup script
│   ├── install.sh          # Installer (symlinks, shell rc, tmux config)
│   ├── precommit-checks.sh # Pre-commit checks
│   ├── scan-secrets.sh     # Secret scanning
│   └── setup-git-hooks.sh  # Git hooks setup
├── docs/
│   ├── backlog.md          # Feature backlog and ideas
│   ├── perf-techniques.md  # Performance optimization techniques
│   └── test-speed-plan.md  # Test suite performance plan
├── tests/
│   ├── perf_test.sh        # Standalone latency benchmark for am list-internal
│   └── test_all.sh         # Test suite
```

## Technical Details

### Capturing Preview Content

```bash
# Get last 50 lines of pane content with ANSI colors
tmux capture-pane -t "$session" -p -S -50 -e
```

### Activity Detection

```bash
# Get session activity timestamp (seconds since epoch)
tmux list-sessions -F '#{session_name} #{session_activity}' \
  | grep "^$session " | cut -d' ' -f2

# Compare with current time for "X ago" display
now=$(date +%s)
age=$((now - activity))
```

### Git Branch Detection

```bash
# Get current branch for a directory
git -C "$directory" branch --show-current 2>/dev/null || echo "no branch"
```

### Session Creation Flow

```bash
# 1. Generate session name
name="am-$(echo "$directory$timestamp" | md5sum | head -c6)"

# 2. Create tmux session
tmux new-session -d -s "$name" -c "$directory"

# 3. Register metadata
registry_add "$name" "$directory" "$branch" "$agent_type"

# 4. Launch agent in the session
tmux send-keys -t "$name" "claude" Enter
```

### Auto-Titling (Claude Sessions)

Sessions are titled via `auto_title_scan()`, a piggyback scanner that runs during fzf touchpoints (list generation, reload):

1. Throttled to once per 60s (unless `force=1`) via timestamp marker
2. Iterates all registry entries
3. Reads `#{pane_title}` from the agent (top) pane via `tmux_pane_title()`
4. Trims leading non-alphanumeric characters and validates (≤60 chars, no newlines)
5. Updates registry `task` field if changed

Key implementation details:
- Agents set the terminal title via escape sequences; tmux exposes it as `#{pane_title}`
- Rejects titles over 60 chars or multiline (`_title_valid`)
- Logs to `~/.agent-manager/titler.log` for debugging

## Dependencies

- **Required:**
  - tmux >= 3.0
  - fzf >= 0.40
  - bash >= 4.0
  - jq (for JSON handling)
  - git (for branch detection)

- **Optional:**
  - bat (for syntax highlighting in preview)

## Future Enhancements

1. ~~**Multi-agent types:** Codex, Cursor, Aider, etc.~~ *(Done: claude, codex + extensible)*
2. **Session groups:** Group related sessions
3. **Task tracking:** Integration with todo systems
4. **Remote sessions:** SSH tunnel support
5. **Web UI:** Optional browser-based view
6. ~~**Notifications:** Alert when agent needs input~~ *(Done: `am wait`, state detection)*
7. ~~**Reboot persistence:** rebuild desired sessions with native harness resume~~ *(Done)*
