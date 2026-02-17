# Agent Manager (`am`)

Manage multiple AI coding agents from one terminal. Tmux + fzf powered.

- **Interactive browser** — browse, switch, and manage agent sessions with fzf
- **Multiple agents** — Claude Code, Codex CLI, Gemini CLI (extensible)
- **Rich preview** — see terminal output, git branch, and activity at a glance
- **Persistent sessions** — tmux-based, survive terminal close

## Installation

### Prerequisites

```bash
# macOS
brew install tmux fzf jq

# Ubuntu/Debian
sudo apt install tmux fzf jq

# Arch
sudo pacman -S tmux fzf jq
```

Requires: tmux >= 3.0, fzf >= 0.40, jq >= 1.6, bash >= 4.0

### Install

```bash
git clone https://github.com/ehudt/agent-manager.git
cd agent-manager
./scripts/install.sh
```

This installs `am` into `~/.local/bin`. See [Configuration](#configuration) for tmux keybindings and install options.

### Verify

```bash
am help
am version
```

## Quick Start

```bash
am new ~/code/myproject              # Create a Claude session
am                                    # Browse all sessions
am new -t gemini ~/code/other        # Use a different agent
am new -n "fix auth bug" .           # Add a task description
am attach am-abc123                  # Attach to a session by name
```

## Browsing Sessions

Run `am` to open the interactive browser:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Agent Sessions | Enter:attach  Ctrl-N:new  Ctrl-X:kill  Ctrl-R:refresh  │
├─────────────────────────────────────────────────────────────────────────┤
│ > myapp/feature/auth [claude] (5m ago) "implement user auth"           │
│   myproject/main [claude] (2h ago)                                      │
│   tools/dev [gemini] (1d ago) "refactor build system"                   │
├─────────────────────────────────────────────────────────────────────────┤
│ Preview:                                                                │
│ Directory: /home/user/code/myapp                                       │
│ Branch: feature/auth                                                    │
│ Agent: claude | Running: 2h 15m | Last active: 5m ago                   │
│ ───────────────────────────────────────                                 │
│ > Reading src/auth/handler.ts...                                        │
│ > I'll implement the OAuth flow using...                                │
└─────────────────────────────────────────────────────────────────────────┘
```

### Keybindings

| Key | Action |
|-----|--------|
| `Enter` | Attach to selected session |
| `Ctrl-N` | Create new session (interactive flow) |
| `Ctrl-X` | Kill selected session |
| `Ctrl-R` | Refresh session list |
| `Ctrl-P` | Toggle preview panel |
| `Ctrl-J` / `Ctrl-K` | Scroll preview down / up |
| `Ctrl-D` / `Ctrl-U` | Scroll preview half-page down / up |
| `?` | Show help |
| `Esc` | Exit |

## Creating Sessions

### Interactive Flow

Pressing `Ctrl-N` in the browser (or running `am new` with no directory) launches a 3-step interactive flow:

1. **Directory picker** — type to filter, `Tab` to complete, `Ctrl-U` to go up. Uses [zoxide](https://github.com/ajeetdsouza/zoxide) frecent directories if installed.
2. **Mode picker** — choose from: New session, Resume (`--resume`), Continue (`--continue`), or any of those with `--yolo` (permissive mode).
3. **Agent picker** — select the agent type (claude, codex, gemini).

### CLI Usage

```bash
am new [dir]                    # New session (default: current dir, claude)
am new -t codex ~/project       # Specify agent type
am new -n "task description" .  # Add task description
am new --yolo ~/project         # Permissive mode (flag mapped per agent)
am new ~/project -- --resume    # Pass extra args to the agent
```

## Inside a Session

Each session has a split-pane layout:

```
┌─────────────────────────────────────┐
│  Agent (Claude/Codex/Gemini) - top  │  ← Preview shows this pane
│                                     │
├─────────────────────────────────────┤
│  Shell - bottom                     │  ← Same working directory
└─────────────────────────────────────┘
```

### tmux Keybindings

These work inside `am-*` sessions (requires [tmux configuration](#tmux-keybindings-1)):

| Key | Action |
|-----|--------|
| `Prefix + a` | Switch to last used am session |
| `Prefix + s` | Open am browser popup |
| `Prefix + d` | Detach from session |
| `Prefix ↑/↓` | Switch between agent and shell panes |
| `:am` | Open am browser (tmux command) |

## Agent Types

| Agent | Command | `--yolo` maps to |
|-------|---------|-------------------|
| claude | `claude` | `--dangerously-skip-permissions` |
| codex | `codex` | `--yolo` |
| gemini | `gemini` | `--yolo` |

Unknown agent types are passed through as the command name directly.

## Advanced Features

### Zoxide Integration

If [zoxide](https://github.com/ajeetdsouza/zoxide) is installed, the directory picker shows frecent (frequently + recently used) directories instead of a flat listing.

### Sandbox Integration

When `--yolo` is used and the `sb` command is on PATH, agent-manager automatically starts a sandbox (`sb <dir> --start`) and attaches both panes to it before launching the agent.

### Claude Session Titles

For Claude sessions, the preview panel extracts and displays the first user message from Claude's session logs, giving you a quick summary of what each session is working on.

### Resume and Continue

Pass `--resume` or `--continue` to the agent via the mode picker (interactive) or CLI:

```bash
am new ~/project -- --resume      # Resume last session
am new ~/project -- --continue    # Continue from where you left off
```

## Commands Reference

| Command | Aliases | Description |
|---------|---------|-------------|
| `am` | `am list`, `am ls` | Open interactive browser |
| `am list --json` | `-j` | Output sessions as JSON |
| `am new [dir]` | `create`, `n` | Create new agent session |
| `am attach <name>` | `a` | Attach to session (exact, prefix, or fuzzy match) |
| `am kill <name>` | `rm`, `k` | Kill a session |
| `am kill --all` | `-a` | Kill all sessions |
| `am info <name>` | `i` | Show session details |
| `am status` | `s` | Summary of all sessions |
| `am <path>` | | Shortcut for `am new <path>` |
| `am help` | `-h`, `--help` | Show help |
| `am version` | `-v`, `--version` | Show version |

## Configuration

### tmux Keybindings

The installer can append tmux bindings automatically (`./scripts/install.sh`). For manual setup, add to `~/.tmux.conf`:

```bash
# These keybindings only activate inside am-* sessions.

# Prefix + a: switch to last used am session
bind a if-shell -F '#{m:am-*,#{session_name}}' 'run-shell "switch-last"' 'display-message "am shortcuts are active only in am-* sessions"'

# Prefix + s: open agent manager popup
bind s if-shell -F '#{m:am-*,#{session_name}}' 'display-popup -E -w 90% -h 80% "am"' 'display-message "am shortcuts are active only in am-* sessions"'

# Command alias: ":am" opens agent manager
set -s command-alias[100] am='display-popup -E -w 90% -h 80% "am"'
```

### Install Options

```bash
./scripts/install.sh --yes             # Non-interactive (accept all)
./scripts/install.sh --no-shell        # Skip shell rc updates
./scripts/install.sh --no-tmux         # Skip tmux config updates
./scripts/install.sh --prefix /usr/local/bin  # Custom install path
./scripts/install.sh --copy            # Copy files instead of symlink
```

### Session Storage

```
~/.agent-manager/
└── sessions.json       # Session metadata registry
```

### Shell Support

- **zsh**: `~/.zshrc` auto-detected by installer
- **bash**: `~/.bashrc` auto-detected when zshrc is absent
- Other shells: command works via shebang, but rc-file automation is not built-in

## Troubleshooting

### "Required command not found: tmux"

Install tmux: `brew install tmux` (macOS) or `apt install tmux` (Ubuntu).

### Sessions not showing

Run `am status` to check. Stale registry entries are cleaned automatically.

### Preview not working

Ensure the session exists and tmux is running. Try `tmux list-sessions`.

## Development

Run tests:

```bash
./tests/test_all.sh
```

Tests require all prerequisites (`tmux`, `fzf`, `jq`) and fail fast if any are missing.

## License

MIT (see `LICENSE`)
