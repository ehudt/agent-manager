<p align="center">
  <img src="assets/tagline.png" alt="AM" width="280" />
</p>

<h1 align="center">Agent Manager</h1>

<p align="center">
  Run multiple AI coding agents side by side. Switch between them instantly.<br>
  <code>tmux</code> + <code>fzf</code> powered. Works with Claude Code, Cursor Agent, Codex, and pi.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> · <a href="#interactive-session-browser">Browser</a> · <a href="#agent-to-agent-orchestration">Orchestration</a> · <a href="#commands-reference">Reference</a>
</p>

---

## Why

AI coding agents work best with focused context. Real work often needs several of them at once — one debugging tests, another implementing a feature, a third reviewing a diff. Switching between terminal tabs and losing track of what's running where slows you down.

`am` gives you a single interface to launch, browse, and manage agent sessions. Each session is a persistent tmux session running the agent full-screen, with a collapsible shell panel one keystroke away — so you can check on any agent, send it new instructions, or hand it off to a teammate without losing state.

It works equally well whether **you** are driving from the keyboard or whether **another agent** is dispatching workers programmatically.

<!-- TODO: Screenshot — the fzf session browser with 3-4 sessions visible, preview panel showing an active Claude session mid-task. Capture with a real project to look authentic. -->

## Quick Start

```bash
# Install dependencies (see full list below)
brew install tmux fzf jq          # macOS
# sudo apt install tmux fzf jq    # Debian/Ubuntu

# Install am
git clone https://github.com/ehudt/agent-manager.git
cd agent-manager
./scripts/install.sh

# Launch your first session
am new ~/my-project
```

That's it. You're in a tmux session with Claude running full-screen. Press ``Prefix + ` `` to pop open a shell panel below the agent (VS Code-style — toggling it again hides it without losing its state), `Prefix + d` to detach, or `Prefix + s` to browse all your sessions.

<!-- TODO: Video (15-20s) — terminal recording showing: `am new ~/project` → agent starts → user detaches → `am` opens browser → user selects session → reattaches. Keep it fast. -->

## Installation

### Dependencies

| Dependency | Minimum | Install |
|-----------|---------|---------|
| **bash** | 4.0+ | Ships with most Linux distros. macOS: `brew install bash` |
| **tmux** | 3.2+ | `brew install tmux` / `apt install tmux` / `pacman -S tmux` |
| **fzf** | 0.40+ | `brew install fzf` / `apt install fzf` / `pacman -S fzf` |
| **jq** | 1.6+ | `brew install jq` / `apt install jq` / `pacman -S jq` |
| **git** | any | Required for branch display |
| **[zoxide](https://github.com/ajeetdsouza/zoxide)** | any | Frecent directory ranking in the session creation form |

**One-liner install for all dependencies:**

```bash
# macOS (Homebrew)
brew install bash tmux fzf jq zoxide

# Debian / Ubuntu
sudo apt install tmux fzf jq zoxide

# Fedora
sudo dnf install tmux fzf jq zoxide

# Arch Linux
sudo pacman -S tmux fzf jq zoxide
```

**At least one AI coding agent must be installed:**

| Agent | Install |
|-------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` |
| [Codex CLI](https://github.com/openai/codex) | `npm install -g @openai/codex` |
| [Cursor Agent](https://cursor.com/docs/cli/installation) | `curl https://cursor.com/install -fsS \| bash` |
| [pi](https://github.com/badlogic/pi-mono) | `npm install -g @earendil-works/pi-coding-agent` |

### Install

```bash
git clone https://github.com/ehudt/agent-manager.git
cd agent-manager
./scripts/install.sh
```

This symlinks `am` into `~/.local/bin` and sets up the dedicated tmux configuration. The installer will:
- Add `~/.local/bin` to your PATH in `.zshrc` or `.bashrc` if needed
- Generate a dedicated tmux config at `~/.agent-manager/tmux.conf` with am-specific keybindings (your personal `~/.tmux.conf` is unaffected)
- Register state-detection hooks for push-based session monitoring in Claude, Codex, and Cursor configuration (existing hooks are preserved)

```bash
# Install options
./scripts/install.sh --yes              # Non-interactive (accept all)
./scripts/install.sh --no-shell         # Skip shell rc updates
./scripts/install.sh --prefix /usr/local/bin  # Custom install path
./scripts/install.sh --copy             # Copy files instead of symlink
```

### Verify

```bash
am version
am help
```

## Human-Driven Workflow

### Creating sessions

```bash
am new ~/code/myproject              # New Claude session in a directory
am new -t codex ~/code/project       # Use Codex instead
am new -t cursor ~/code/project      # Use Cursor Agent
am new -n "fix auth bug" .           # Session with a task description
am new ~/code/proj -- --resume       # Anything after -- goes to the agent verbatim
am new -W review-48351               # Fresh workspace on a branch via workspace_cmd (below)
```

`-W`/`--workspace` hands directory selection to a command you configure once,
for tools that manage a pool of checkouts (a clone-pool manager, `git worktree`
wrapper, `jj workspace`, ...). The command runs with `AM_BRANCH` set to the
optional branch (empty when none was given) and prints the directory to use:

```bash
am config set workspace_cmd 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}'
am new -W                            # workspace on the default branch
am new -W review-48351 -n "review"   # workspace on a branch, with a task
printf 'Review PR 48351\n' | am new --detach --print-session -W review-48351
```

Once configured, the interactive form also offers **Workspace** / **Branch**
fields right after Directory (toggling Workspace on takes Directory out of play).

Running `am new` with no arguments opens an interactive form where you pick a directory, agent type, and task:

<!-- TODO: Screenshot — the one-page new session form showing directory picker with zoxide suggestions, agent type selector, and task field. -->

### Interactive session browser

Run `am` to open the session browser:

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Agent Sessions | ?:help  Enter:open  ^N:new  ^X:kill  ^R:refresh         │
├───────────────────────────────────────────────────────────────────────────┤
│ > am-a1b2c3 myapp/feature/auth [claude] Fix user auth  (5m ago)          │
│   am-d4e5f6 tools/dev [codex] Refactor build system  (1d ago)            │
│   Inactive sessions ─────────────────────────────────────────────────     │
│   myproject/main [claude] Investigate deploy issue  (2d ago)             │
├───────────────────────────────────────────────────────────────────────────┤
│ Preview:                                                                  │
│ Directory: ~/code/myapp                                                   │
│ Branch: feature/auth                                                      │
│ Agent: claude | Running: 2h 15m | Last active: 5m ago                     │
│ ──────────────────────────────────                                        │
│ > Reading src/auth/handler.ts...                                          │
│ > I'll implement the OAuth flow using...                                  │
└───────────────────────────────────────────────────────────────────────────┘
```

| Key | Action |
|-----|--------|
| `Up/Down` | Move selection |
| `Enter` | Attach an active session or restore an inactive session |
| `Esc/q` | Exit without action |
| `Ctrl-N` | Create new session |
| `Ctrl-X` | Kill selected active session |
| `Ctrl-R` | Refresh session list |
| `?` | Show inline help |

### Inside a session

Each session runs the agent full-screen, with a collapsible shell panel (VS Code-style) that opens below it on demand in the same working directory:

```
┌─────────────────────────────────────┐
│  Agent (Claude/Cursor/Codex/pi)     │  ← agent pane
│                                     │
├─────────────────────────────────────┤
│  Shell (optional, Prefix + `)       │  ← collapsible panel
└─────────────────────────────────────┘
```

The panel is created on first toggle; hiding it parks the pane rather than
killing it, so its cwd, history, and any running jobs survive until the next
toggle. To launch with the panel already open, pass `--shell` to `am new` or
set `am config set shell true`.

Sessions run on a dedicated tmux socket (`agent-manager`), so am keybindings don't interfere with your regular tmux setup.

| Key | Action |
|-----|--------|
| `Prefix + 1-9` | Jump to sidebar slot N |
| `Prefix + a` | Switch to last used am session |
| `Prefix + n` | Open new-session popup |
| `Prefix + s` | Open am browser popup |
| `Prefix + x` | Kill current session and switch to next |
| `Prefix + d` | Detach from session |
| ``Prefix + ` `` | Toggle the shell panel (open on first use, then hide/show) |
| `Prefix ↑/↓` | Switch between agent and shell panes (panel open) |
| `:am` | Open am browser as a tmux command |

The status bar shows all sessions as numbered tabs with the current session
highlighted. State icons distinguish active work (`▸`), background work (`⧗`),
a turn blocked on the user (`⚠`), and a session ready for another prompt (`●`).
Each tab shows as much as fits: `dir/branch · title age` when there is room,
then the branch (or directory, on a default branch) with a shortened title,
then the title alone as sessions multiply or the terminal narrows.
The current session's id (`am-xxxxxx`) sits at the bottom right next to the
clock. From inside either pane, `am id` prints it (`am id | pbcopy`,
`am send "$(am id)" ...`), and `$AM_SESSION_NAME` carries it as well; the
panes get `AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, and
`AM_LOG_DIR` from tmux at creation, so nothing is typed into your shell and
your history stays clean.

### Peeking and monitoring

Check on a session without attaching to it:

```bash
am peek am-abc123                        # Snapshot of agent pane
am peek --pane shell am-abc123           # Snapshot of shell panel (if opened)
am peek --follow am-abc123               # Stream agent output in real time
am peek --lines 100 am-abc123            # Include the last 100 lines
```

`--pane shell` works while the panel is open *or* hidden (the parked pane
keeps running); on a session whose panel was never opened it explains how to
open one (`am shell <session>`).

### Restoring closed sessions

Closed a session and want to pick it back up? Recently closed Claude, Codex,
Cursor, and pi sessions appear below active sessions in the main `am` browser. Select
an inactive session and press Enter to resume it exactly where you left off.

You can also open the standalone restore picker directly:

```bash
am restore
```

The preview panel displays the last captured pane output — a text snapshot of what the agent was showing when the session ended — so you can remember what you were doing.

Select a session and press Enter to resume it with the agent's native resume
flag in the original directory, with full conversation history intact.

Sessions stay restorable as long as the agent's conversation file exists on
disk. Cursor restore is bound to the exact hook-reported transcript path, so
multiple conversations in one directory do not get mixed up.

### Restoring the open workspace after reboot

`am` treats sessions as open until they are explicitly closed with `am kill`.
When the default interactive browser first opens after a machine reboot, it
recreates missing open sessions in the background and shows them as
`restoring`. The browser remains usable while recovery progresses and never
auto-attaches a session.

Recovery requires an exact hook-reported conversation identity. A missing
directory, harness command, or conversation file leaves that row visible as
`blocked` instead of silently starting a different session.
Press Enter to retry a blocked row after fixing its prerequisite, or Ctrl-X to
forget it. Explicit commands and automation (`am list`, `am new`, `am wait`,
and similar) never start recovery.

Claude and Cursor resume by conversation ID, pi by session ID, and Codex via
its native `codex resume ID` command. Conversation history and filesystem state
survive; interrupted tool calls, shell processes, and background jobs do not.
Disable automatic recovery with:

```bash
am config set auto-restore false
```

## Agent-to-Agent Orchestration

`am` is designed to be driven by other agents. An orchestrator agent can spawn workers, send them tasks, wait for completion, and inspect results — all through the CLI.

### Core pattern

```bash
# 1. Launch a worker with a self-contained prompt
session=$(printf 'Run the test suite in tests/ and fix any failures.
The tests use pytest. Commit fixes individually with descriptive messages.
' | am new --detach --print-session ~/repo)

# 2. Wait until the agent finishes its turn
am wait "$session"

# 3. Check results
am peek --lines 10 "$session"

# 4. Send a follow-up
am send "$session" "Now update the changelog"

# 5. Clean up or hand off
am kill "$session"              # or: am attach "$session"
```

### Parallel workers

```bash
s1=$(printf 'Run backend tests\n' | am new --detach --print-session ~/repo)
s2=$(printf 'Run frontend tests\n' | am new --detach --print-session ~/repo)

am wait --state idle,dead "$s1"
am wait --state idle,dead "$s2"

am peek --lines 5 "$s1"
am peek --lines 5 "$s2"
```

### Session states

| State | Meaning |
|-------|---------|
| `starting` | Session created, agent not yet running |
| `running` | Agent is actively executing |
| `background` | Foreground turn ended, but background work is still running |
| `waiting_user` | Current turn cannot continue until the user answers a dialog |
| `ready` | Agent finished its turn and can accept another prompt |
| `unknown` | Agent is alive, but no trustworthy activity signal is available |
| `idle` | Agent process exited cleanly |
| `dead` | Agent process crashed or session gone |

Claude, Cursor, Codex, and pi use push-based lifecycle hooks/extensions
installed by `am install`. Cursor lifecycle hooks expose turn start/stop; on
Cursor 2026.08+, verified terminal-title suffixes also distinguish ready,
working, and in-turn question states. Cursor permission prompts still remain
`running`. Cursor exposes no background-work lifecycle event, so a Ready pane
is narrowly refined from its CLI-owned footer task count.

`am wait --state` continues to accept the pre-0.12 names (`waiting_input`,
`waiting_permission`, `waiting_custom`, `waiting_background`) as aliases for
`ready`, `waiting_user`, and `background`. Commands and JSON output emit only
the canonical names.

### Agent dispatch skill

`am` ships with a dispatch skill at `skills/agent-manager-dispatch/SKILL.md`.
`am install` links bundled skills into both `~/.claude/skills` and
`~/.cursor/skills`.

<!-- TODO: Video (30-40s) — terminal recording showing an orchestrator agent launching two parallel workers with `am new --detach`, waiting for them with `am wait`, peeking at results with `am peek --lines 10`, and then killing the sessions. Show the session IDs being captured and reused. -->

## Cursor authentication

Authenticate the host CLI with `agent login`, or export `CURSOR_API_KEY`.

## Auto-titling

Agent-maintained terminal titles are used when they represent a task. Claude,
Cursor, and pi can also fall back to the exact session transcript's first user
message; transient Cursor titles such as `Cursor Agent` and `Shell Command` are
ignored.

## Configuration

```bash
am config                          # Show current defaults
am config set agent codex          # Default to Codex
am config set logs true            # Enable pane log streaming
am config set shell true           # Open the shell panel at launch
am config set workspace_cmd 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}'  # Backs `am new -W`
am config get agent                # Read a single value
```

Precedence: CLI flag > environment variable > saved config > built-in default.

## Agent Types

| Agent | Command |
|-------|---------|
| `claude` | `claude` |
| `codex` | `codex` |
| `cursor` (`cursor-agent` alias) | `agent` |
| `pi` | `pi` |

Unknown agent types are passed through as the command name, so `am new -t aider .` will try to run `aider`.
Agent-specific flags go after `--`, e.g. `am new . -- --dangerously-skip-permissions`.

## Commands Reference

| Command | Description |
|---------|-------------|
| `am` | Open interactive browser for active and inactive sessions |
| `am list [--json]` | List all sessions |
| `am new [dir]` | Create new agent session |
| `am send <session> [prompt]` | Send a prompt to a running session |
| `am peek <session>` | Snapshot or follow a session's pane output |
| `am wait <session>` | Block until agent reaches a target state |
| `am interrupt <session>` | Send Ctrl-C to the agent pane |
| `am attach <session>` | Attach to a session |
| `am restore` | Browse and resume closed Claude, Codex, Cursor, and pi sessions |
| `am kill <session>` | Kill a session |
| `am status [--json]` | Show detailed session info |
| `am config` | Show or change saved defaults |
| `am install` | First-time setup for dependencies, config, skills, and PATH |
| `am help` | Show help |
| `am version` | Show version |

## Storage

```
~/.agent-manager/
├── config.json         # Saved defaults (agent, log streaming, shell panel, workspace_cmd)
├── sessions.json       # Live session metadata registry
├── sessions_log.jsonl  # Session restore log (Claude session IDs + metadata)
├── snapshots/          # Pane text snapshots for closed session preview
└── tmux.conf           # Generated tmux config for am sessions
```

## Development

```bash
./tests/test_all.sh                # Run the test suite
./tests/perf_test.sh               # Standalone latency benchmark for am list-internal
bash -n lib/*.sh am                # Syntax check
```

Tests require `tmux`, `fzf`, and `jq`.
`tests/perf_test.sh` is not part of `test_all.sh`; it is a manual benchmark and should not create persistent resources.

## License

MIT — see [LICENSE](LICENSE).
