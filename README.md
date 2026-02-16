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

### Install agent-manager

```bash
# Clone or download
git clone https://github.com/youruser/agent-manager.git
cd agent-manager

# Add to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$PATH:$(pwd)"

# Or create symlink
ln -s "$(pwd)/am" /usr/local/bin/am
```

### Configure tmux (recommended)

Copy the example tmux config for optimal experience:

```bash
cp config/tmux.conf.example ~/.tmux.conf
```

Or add to your existing `~/.tmux.conf`:

```bash
# Prefix: Ctrl-z (Ctrl-z Ctrl-z sends actual Ctrl-z to shell)
unbind C-b
set -g prefix C-z
bind C-z send-keys C-z

# Mouse/trackpad scrolling
set -g mouse on

# Agent manager popup: Ctrl-z a
bind a display-popup -E -w 90% -h 80% "am"

# Command alias: ":am" opens agent manager
set -s command-alias[100] am='display-popup -E -w 90% -h 80% "am"'
```

Add a reload alias to your shell config (`~/.zshrc` or `~/.bashrc`):

```bash
alias tmux-reload='tmux source-file ~/.tmux.conf && echo "tmux config reloaded"'
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

# Use different agent (codex, gemini, aider)
am new -t gemini ~/code/myproject
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
| `Ctrl-z a` | Open am browser (popup) |
| `Ctrl-z d` | Detach from session |
| `Ctrl-z Ctrl-z` | Send Ctrl-z to shell (suspend) |
| `Ctrl-z :am` | Open am browser (popup) |
| `Ctrl-z ↑/↓` | Switch panes (agent/shell) |

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

Use `Ctrl-z ↑/↓` to switch between panes.

## Session Naming

Sessions are named with prefix `am-` followed by a 6-character hash:
- `am-abc123` - internal session name
- Display shows: `dirname/branch [agent] (time) "task"`

## Architecture

```
agent-manager/
├── am                  # Main executable
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

Tests skip tmux-dependent tests if tmux isn't installed.

## License

MIT
