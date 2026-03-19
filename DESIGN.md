# Agent Manager - Design Document

## Overview

A CLI tool for managing multiple AI coding agent sessions (Claude Code, Gemini CLI, etc.) using **tmux** for session persistence and **fzf** for an interactive browsing interface.

## Requirements

| Requirement | Value |
|-------------|-------|
| Use case | Both cross-project and same-project agents |
| Launch mode | Both from manager AND attach to existing |
| Agent types | Claude Code, Codex, Gemini CLI (extensible via `AGENT_COMMANDS`) |
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
│  │  Registry   │     │  Renderer   │     │  (claude, gemini)   │   │
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
      "task": "implement user auth flow",
      "worktree_path": "/home/user/code/myapp/.claude/worktrees/am-abc123",
      "yolo_mode": "false",
      "sandbox_mode": "false",
      "container_name": ""
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
- Plugin ecosystem (tmux-resurrect for reboot persistence)

**Session structure:**
```
tmux session: am-abc123
  └── window 0: agent
        ├── pane 0 (top): agent (claude, gemini, codex)  ← preview captures this
        └── pane 1 (bottom, 15 lines): shell             ← same working directory
```

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

### 5. Sandbox state volume (`am-state`)

Each sandbox mounts a single persistent Docker volume at `~/.am-state` inside the container.

```text
~/.am-state/
├── mappings.json
├── data/
│   └── <mapping-name>
└── meta.json
```

`mappings.json` is the manifest that drives runtime hydration:

```json
{
  "version": 1,
  "mappings": [
    {
      "name": "ssh",
      "source": "ssh",
      "target": "~/.ssh",
      "host_source": "~/.ssh",
      "mode": "0700"
    }
  ]
}
```

At container startup, the entrypoint expands `~`, then creates symlinks from each `target` to `~/.am-state/data/<source>`. Extra live `--share` bind mounts land on the same target paths and naturally override those symlinks.

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
am new -t gemini        # Start gemini instead of claude
am new --name "my-task" # Custom display name
am new --yolo           # Enable yolo mode (agent permissive flags)
am new --sandbox        # Run in Docker sandbox container
am new --share ~/.ssh:~/.ssh:ro  # Extra live bind mount for a sandbox session
am new -w               # Git worktree isolation
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
am events <session>               # Stream state-change events as JSONL
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

# Sandbox management
am sb map ~/.ssh --to ~/.ssh --mode 0700   # Copy host data into sandbox state volume
am sb maps                                 # List manifest-driven mappings
am sb sync ssh                             # Refresh one mapping from host_source
am sb ps                                   # List sandbox containers
am sb prune                                # Remove stopped containers
am sb build                                # Build sandbox Docker image
am sb reset --confirm                      # Reset sandbox state volume
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
│   ├── title-upgrade       # Standalone script: fire-and-forget Haiku title upgrade
│   ├── registry.sh         # Session registry, persistent history (JSONL), auto-titling
│   ├── sandbox.sh          # Docker sandbox lifecycle, mapping commands, and fleet ops
│   ├── sb_volume.sh        # Docker-volume helpers for sandbox state
│   ├── state.sh            # Session state detection: JSONL + pane pattern matching
│   ├── tmux.sh             # tmux wrapper functions
│   └── utils.sh            # Common utilities
├── bin/
│   ├── kill-and-switch     # tmux helper: kill session + switch to next
│   └── switch-last         # tmux helper: switch to most recent am-* session
├── sandbox/
│   ├── Dockerfile          # Docker image for sandbox containers
│   └── entrypoint.sh       # Container init: user alignment, Tailscale, SSH
├── skills/
│   └── am-orchestration/
│       └── SKILL.md        # Claude Code skill for multi-session orchestration
├── scripts/
│   └── install.sh          # Installer (symlinks, shell rc, tmux config)
├── tests/
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
2. Iterates registry entries that have no `task` field yet
3. Extracts first user message from Claude's session JSONL (truncated to 200 chars)
4. Writes a fallback title immediately (`_title_fallback`: first sentence extraction)
5. Spawns a fire-and-forget background subshell to upgrade via Claude Haiku (2-5 word title)
6. Updates registry `task` field and appends to session history

Key implementation details:
- Haiku subshell unsets `CLAUDECODE` env var to avoid "nested session" rejection
- Haiku subshell disables `errexit`/`pipefail` inherited from parent shell
- Rejects titles over 60 chars or multiline (`_title_valid`)
- Logs to `~/.agent-manager/titler.log` for debugging

### Session History

Persistent JSONL log at `~/.agent-manager/history.jsonl`:

```json
{"directory":"/path","task":"Fix auth bug","agent_type":"claude","branch":"main","created_at":"2024-01-15T10:30:00Z"}
```

- Written at launch (if task known) and after auto-titling
- Auto-pruned to 7 days
- Survives session GC (unlike registry entries)
- Used by directory picker to annotate directories with recent tasks

### Worktree Isolation

The `-w` flag creates a git worktree for Claude sessions:

```bash
am new -w ~/project              # worktree at .claude/worktrees/am-XXXXXX
am new -w my-feature ~/project   # worktree at .claude/worktrees/my-feature
```

- Only applies to Claude agent type in git repositories
- Shell pane auto-`cd`s into worktree once created
- Worktree path stored in registry as `worktree_path`
- Claude is launched with `-w <name>` flag

## Dependencies

- **Required:**
  - tmux >= 3.0
  - fzf >= 0.40
  - bash >= 4.0
  - jq (for JSON handling)
  - git (for branch detection)

- **Optional:**
  - tmux-resurrect (for reboot persistence)
  - bat (for syntax highlighting in preview)

## Future Enhancements

1. ~~**Multi-agent types:** Gemini CLI, Cursor, Aider, etc.~~ *(Done: claude, codex, gemini + extensible)*
2. **Session groups:** Group related sessions
3. **Task tracking:** Integration with todo systems
4. **Remote sessions:** SSH tunnel support
5. **Web UI:** Optional browser-based view
6. ~~**Notifications:** Alert when agent needs input~~ *(Done: `am wait`, `am events`, state detection)*
7. **Reboot persistence:** tmux-resurrect integration or custom solution
