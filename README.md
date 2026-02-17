# Agent Manager (`am`)

A CLI tool for managing multiple AI coding agent sessions using tmux and fzf.

## Features

- **Interactive browser** - Browse and switch between agent sessions with fzf
- **Rich metadata** - See directory, git branch, agent type, and activity status
- **Live preview** - View terminal output from any session without attaching
- **Persistent sessions** - Sessions survive terminal close (tmux-based)
- **Multiple agent types** - Claude Code, Codex CLI, Gemini CLI, Aider (extensible)

## Installation

### Prerequisites

Install required dependencies:

```bash
# macOS
brew install tmux fzf jq

# Ubuntu/Debian
sudo apt install tmux fzf jq

# Arch
sudo pacman -S tmux fzf jq
```

Version requirements:
- tmux >= 3.0
- fzf >= 0.40
- jq >= 1.6
- bash >= 4.0

Shell support:
- zsh: supported (`~/.zshrc` auto-detected by installer)
- bash: supported (`~/.bashrc` auto-detected when zshrc is absent)
- other shells: command still works via shebang, but rc-file automation is not built-in

### Install agent-manager

```bash
# Clone or download
git clone https://github.com/ehudt/agent-manager.git
cd agent-manager

# Recommended: install command links + optional shell/tmux config
./scripts/install.sh
```

This installs `am` (plus helper commands used by tmux bindings) into `~/.local/bin` by default.

Common install options:

```bash
# Non-interactive install (accept shell + tmux updates)
./scripts/install.sh --yes

# Only install command links (no shell/tmux edits)
./scripts/install.sh --no-shell --no-tmux

# Use a custom install location
./scripts/install.sh --prefix /usr/local/bin
```

### Configure tmux (recommended)

The installer can append tmux bindings automatically. If you prefer manual setup, append the example snippet to your existing `~/.tmux.conf`:

```bash
cat config/tmux.conf.example >> ~/.tmux.conf
```

Or add to your existing `~/.tmux.conf`:

```bash
# Mouse/trackpad scrolling
set -g mouse on # optional, for easier pane switching

# These keybindings only activate inside am-* sessions.
# Use your existing tmux prefix key.

# Prefix + a: switch to last used am session
bind a if-shell -F '#{m:am-*,#{session_name}}' 'run-shell "switch-last"' 'display-message "am shortcuts are active only in am-* sessions"'

# Prefix + s: open agent manager popup
bind s if-shell -F '#{m:am-*,#{session_name}}' 'display-popup -E -w 90% -h 80% "am"' 'display-message "am shortcuts are active only in am-* sessions"'

# Command alias: ":am" opens agent manager
set -s command-alias[100] am='display-popup -E -w 90% -h 80% "am"'
```

### Verify installation

```bash
am help
am version
```

## Quick Start

```bash
# Open interactive session browser
am

# Create new Claude session in current directory
am new

# Create session in specific directory
am new ~/code/myproject

# Create session with task description
am new ~/code/myproject -n "implement auth flow"

# Use different agent (codex, claude, gemini)
am new -t claude ~/code/myproject
am new -t codex ~/code/myproject

# Enable permissive mode (mapped to each agent's flag)
am new -t codex --yolo ~/code/myproject

# Attach to a session
am attach am-abc123

# Kill a session
am kill am-abc123

# See all sessions status
am status
```

## Usage

### Interactive Mode (default)

Just run `am` to open the fzf browser:

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

### Keybindings (fzf browser)

| Key | Action |
|-----|--------|
| `Enter` | Attach to selected session |
| `Ctrl-N` | Create new session |
| `Ctrl-X` | Kill selected session |
| `Ctrl-R` | Refresh session list |
| `Ctrl-P` | Toggle preview panel |
| `?` | Show help |
| `↑/↓` | Navigate sessions |
| `Esc` | Exit |

### Keybindings (inside tmux session)

| Key | Action |
|-----|--------|
| `Prefix a` | Switch to last used am session (active only in `am-*` sessions) |
| `Prefix s` | Open am browser popup (active only in `am-*` sessions) |
| `Prefix d` | Detach from session |
| `Prefix :am` | Open am browser (popup) |
| `Prefix ↑/↓` | Switch panes (agent/shell) |

### Commands

```bash
am                      # Interactive browser (default)
am list                 # Same as above
am list --json          # Output JSON for scripting

am new [dir]            # Create new session
am new -t TYPE          # Specify agent type
am new -n "task"        # Add task description
am new --yolo [dir]     # Permissive mode (mapped per agent)

am attach NAME          # Attach to session
am kill NAME            # Kill session
am kill --all           # Kill all sessions

am info NAME            # Show session details
am status               # Summary of all sessions
am help                 # Show help
```

## Configuration

Sessions and metadata are stored in `~/.agent-manager/`:

```
~/.agent-manager/
├── sessions.json       # Session metadata registry
└── config.yaml         # (future) User configuration
```

## Session Layout

Each session has a split layout:

```
┌─────────────────────────────────────┐
│  Agent (Claude/Codex/Gemini) - 65%  │  ← Preview shows this pane
│                                     │
├─────────────────────────────────────┤
│  Shell - 35%                        │  ← Same working directory
└─────────────────────────────────────┘
```

Use `Prefix ↑/↓` to switch between panes.

## Session Naming

Sessions are named with prefix `am-` followed by a 6-character hash:
- `am-abc123` - internal session name
- Display shows: `dirname/branch [agent] (time) "task"`

## Architecture

```
agent-manager/
├── am                  # Main executable
├── scripts/
│   └── install.sh      # Installer for shell + tmux integration
├── lib/
│   ├── utils.sh        # Common utilities
│   ├── registry.sh     # JSON metadata storage
│   ├── tmux.sh         # tmux wrapper functions
│   ├── agents.sh       # Agent launcher
│   └── fzf.sh          # fzf interface
├── tests/
│   └── test_all.sh     # Test suite
└── README.md
```

## Troubleshooting

### "Required command not found: tmux"

Install tmux: `brew install tmux` (macOS) or `apt install tmux` (Ubuntu)

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

## Security Checks

Run these before publishing to catch accidentally committed credentials in current files and git history:

Run secret scans:

```bash
./scripts/scan-secrets.sh
./scripts/scan-secrets.sh --history
```

Optional local pre-commit hook:

```bash
./scripts/setup-git-hooks.sh
```

This enables `.githooks/pre-commit`, which runs:
- `bash -n` syntax checks
- `./scripts/scan-secrets.sh` on tracked files

Release checklist: see `RELEASE.md`.

## License
MIT (see `LICENSE`)
