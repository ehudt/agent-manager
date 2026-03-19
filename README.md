<p align="center">
  <img src="assets/tagline.png" alt="AM" width="280" />
</p>

<h1 align="center">Agent Manager</h1>

<p align="center">
  Run multiple AI coding agents side by side. Switch between them instantly.<br>
  <code>tmux</code> + <code>fzf</code> powered. Works with Claude Code, Codex CLI, and Gemini CLI.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> · <a href="#interactive-session-browser">Browser</a> · <a href="#agent-to-agent-orchestration">Orchestration</a> · <a href="#commands-reference">Reference</a>
</p>

---

## Why

AI coding agents work best with focused context. Real work often needs several of them at once — one debugging tests, another implementing a feature, a third reviewing a diff. Switching between terminal tabs and losing track of what's running where slows you down.

`am` gives you a single interface to launch, browse, and manage agent sessions. Each session is a persistent tmux split — agent on top, shell on the bottom — so you can check on any agent, send it new instructions, or hand it off to a teammate without losing state.

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

That's it. You're in a tmux session with Claude running in the top pane and a shell in the bottom. Press `Prefix + d` to detach, or `Prefix + s` to browse all your sessions.

<!-- TODO: Video (15-20s) — terminal recording showing: `am new ~/project` → agent starts → user detaches → `am` opens browser → user selects session → reattaches. Keep it fast. -->

## Installation

### Dependencies

| Dependency | Minimum | Install |
|-----------|---------|---------|
| **bash** | 4.0+ | Ships with most Linux distros. macOS: `brew install bash` |
| **tmux** | 3.0+ | `brew install tmux` / `apt install tmux` / `pacman -S tmux` |
| **fzf** | 0.40+ | `brew install fzf` / `apt install fzf` / `pacman -S fzf` |
| **jq** | 1.6+ | `brew install jq` / `apt install jq` / `pacman -S jq` |
| **git** | any | Required for worktree isolation and branch display |
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
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `npm install -g @anthropic-ai/gemini-cli` |

### Install

```bash
git clone https://github.com/ehudt/agent-manager.git
cd agent-manager
./scripts/install.sh
```

This symlinks `am` into `~/.local/bin` and sets up the dedicated tmux configuration. The installer will:
- Add `~/.local/bin` to your PATH in `.zshrc` or `.bashrc` if needed
- Generate a dedicated tmux config at `~/.agent-manager/tmux.conf` with am-specific keybindings (your personal `~/.tmux.conf` is unaffected)

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
am new -t gemini ~/code/project      # Use Gemini instead
am new -n "fix auth bug" .           # Session with a task description
am new --yolo ~/code/myproject       # Permissive mode (agent-specific flags)
am new -w ~/code/myproject           # Isolate changes in a git worktree
```

Running `am new` with no arguments opens an interactive form where you pick a directory, agent type, and mode:

<!-- TODO: Screenshot — the one-page new session form showing directory picker with zoxide suggestions, agent type selector, and mode options. -->

### Interactive session browser

Run `am` (or `am list`) to open the fzf-powered session browser:

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Agent Sessions | Enter:attach  Ctrl-N:new  Ctrl-X:kill  Ctrl-R:refresh   │
├───────────────────────────────────────────────────────────────────────────┤
│ > myapp/feature/auth [claude] Fix user auth  (5m ago)                    │
│   myproject/main [claude] (2h ago)                                       │
│   tools/dev [gemini] Refactor build system  (1d ago)                     │
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
| `Enter` | Attach to selected session |
| `Ctrl-N` | Create new session |
| `Ctrl-X` | Kill selected session |
| `Ctrl-R` | Refresh session list |
| `Ctrl-P` | Toggle preview panel |
| `Esc` | Exit |

### Inside a session

Each session is a tmux split pane — agent on top, shell on the bottom, both in the same working directory:

```
┌─────────────────────────────────────┐
│  Agent (Claude/Codex/Gemini)        │  ← top pane
│                                     │
├─────────────────────────────────────┤
│  Shell                              │  ← bottom pane, same directory
└─────────────────────────────────────┘
```

Sessions run on a dedicated tmux socket (`agent-manager`), so am keybindings don't interfere with your regular tmux setup.

| Key | Action |
|-----|--------|
| `Prefix + a` | Switch to last used am session |
| `Prefix + n` | Open new-session popup |
| `Prefix + s` | Open am browser popup |
| `Prefix + x` | Kill current session and switch to next |
| `Prefix + d` | Detach from session |
| `Prefix ↑/↓` | Switch between agent and shell panes |

### Peeking and monitoring

Check on a session without attaching to it:

```bash
am peek am-abc123                        # Snapshot of agent pane
am peek --pane shell am-abc123           # Snapshot of shell pane
am peek --follow am-abc123               # Stream agent output in real time
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
am peek --json "$session" | jq -r '.lines[-10:][]'

# 4. Send a follow-up (waits until agent is ready)
am send --wait "$session" "Now update the changelog"

# 5. Clean up or hand off
am kill "$session"              # or: am attach "$session"
```

### Parallel workers

```bash
s1=$(printf 'Run backend tests\n' | am new --detach --print-session ~/repo)
s2=$(printf 'Run frontend tests\n' | am new --detach --print-session ~/repo)

am wait --state idle,dead "$s1"
am wait --state idle,dead "$s2"

am peek --json "$s1" | jq -r '.lines[-5:][]'
am peek --json "$s2" | jq -r '.lines[-5:][]'
```

### Event-driven monitoring

```bash
am events "$session" | while IFS= read -r line; do
    state=$(printf '%s' "$line" | jq -r '.to // .state')
    printf 'State: %s\n' "$state"
done
```

### Session states

| State | Meaning |
|-------|---------|
| `starting` | Session created, agent not yet running |
| `running` | Agent is actively executing |
| `waiting_input` | Agent finished its turn, ready for next prompt |
| `waiting_permission` | Agent is blocked on a permission prompt |
| `idle` | Agent process exited cleanly |
| `dead` | Agent process crashed or session gone |

### Claude Code skill

`am` ships with an orchestration skill for Claude Code at `skills/am-orchestration/SKILL.md`. When installed, Claude Code agents can automatically use `am` to dispatch and manage worker sessions.

<!-- TODO: Video (30-40s) — terminal recording showing an orchestrator agent launching two parallel workers with `am new --detach`, waiting for them with `am wait`, peeking at results with `am peek --json`, and then killing the sessions. Show the session IDs being captured and reused. -->

## Sandbox Mode (Experimental)

> **Experimental feature — not a security boundary.** The sandbox reduces the blast radius of permissive (`--yolo`) agent runs by placing them inside a Docker container. It is **not** designed to contain a determined adversary. The project directory is still bind-mounted read-write, and Docker itself requires root-equivalent access on the host. Treat the sandbox as a safety net for accidental damage, not as isolation from malicious code. The sandbox API and defaults may change in future releases.

### Container model

Each sandbox now gets only two default mounts:

| Mount | Mode | Purpose |
|------|------|---------|
| `am-state` Docker volume → `~/.am-state` | rw | Persistent sandbox-owned state and mapping manifest |
| Project directory → same absolute path | rw | Working tree for the session |

Everything else is opt-in.

### Mapping host data into the state volume

Use `am sb map` to copy files or directories into the persistent `am-state` volume and expose them inside future containers via `mappings.json`:

```bash
am sb map ~/.ssh --to ~/.ssh --mode 0700
am sb map ~/.claude.json --to ~/.claude.json --name claude-auth
am sb maps
am sb sync ssh
am sb edit claude-auth
am sb unmap claude-auth
```

The volume layout is:

```text
~/.am-state/
├── mappings.json
├── data/
│   └── <mapping-name>
└── meta.json
```

`mappings.json` drives entrypoint hydration. On container startup, each mapping becomes a symlink from its configured `target` path to `~/.am-state/data/<source>`.

### Presets

`am` ships with preset bundles in `config/presets.json` and merges optional user overrides from `~/.agent-manager/presets.json`.

```bash
am sb map --list-presets
am sb map --preset ssh
am sb map --preset claude
am sb map --preset dotfiles
```

Missing host paths inside a preset are skipped with a note instead of aborting the whole preset.

### One-off live bind mounts with `--share`

Use `--share` when you want a temporary bind mount without copying it into the state volume:

```bash
am new --sandbox --share ~/.ssh:~/.ssh:ro ~/project
am new --sandbox --share ~/.env:~/.env:rw ~/project
```

Share syntax is:

```text
<host-path>[:container-path][:ro|rw]
```

- Omitted container path defaults to the host path.
- Omitted mode defaults to `ro`.
- Multiple `--share` flags are allowed.
- `--share` only applies when sandbox mode is active.

You can also configure sticky shares:

```bash
am config set sandbox-shares "~/.zshrc:ro,~/.vimrc:ro"
```

Those shares are merged with any per-command `--share` flags.

### Sandbox management commands

```bash
am sb maps
am sb ps
am sb prune
am sb build --no-cache
am sb reset --confirm
am sb export ~/sandbox-state.tgz
am sb import ~/sandbox-state.tgz --confirm
am sb shell
```

`am sandbox` and `am sb` are equivalent prefixes.

### Resource limits

| Resource | Default | Environment variable |
|----------|---------|---------------------|
| Memory | 4 GB | `SB_MEMORY_LIMIT` |
| CPUs | 2.0 | `SB_CPUS_LIMIT` |
| PIDs | 512 | `SB_PIDS_LIMIT` |

### Security hardening

By default, the container runs with:

- **`--cap-drop=ALL`** — all Linux capabilities dropped, then only `CHOWN`, `DAC_OVERRIDE`, and `FOWNER` are added back (required by the entrypoint for user alignment)
- **`--security-opt no-new-privileges:true`** — prevents privilege escalation inside the container
- **No passwordless sudo** — `sudo` is blocked unless you explicitly set `SB_UNSAFE_ROOT=1`

Optional hardening flags (set in `~/.agent-manager/sandbox.env`):

| Variable | Default | Effect |
|----------|---------|--------|
| `SB_UNSAFE_ROOT` | `0` | `1` = enable passwordless sudo (for `apt install`, etc.) |
| `SB_READ_ONLY_ROOTFS` | `0` | `1` = mount root filesystem read-only (`/tmp`, `/run` remain writable) |
| `SB_ENABLE_TAILSCALE` | `1` | `0` = disable Tailscale networking |
| `ENABLE_SSH` | `0` | `1` = start sshd inside the container |
| `TS_AUTHKEY` | (unset) | Tailscale auth key for automatic VPN join |

### Remote access via Tailscale

When `SB_ENABLE_TAILSCALE=1` and `TS_AUTHKEY` is set, each container joins your Tailscale network with its session name as the hostname. With `TS_ENABLE_SSH=1` (default), you can SSH directly into any sandbox:

```bash
ssh youruser@am-abc123
```

This is useful for accessing sandbox sessions from a phone, tablet, or another machine.

### Worktree isolation

Run agents in a git worktree to isolate changes from your main working tree:

```bash
am new -w ~/project                    # Auto-named worktree
am new -w my-feature ~/project         # Named worktree
```

### Auto-titling

Claude sessions are automatically titled from the first user message. A background process extracts the message and sends it to Claude Haiku to generate a short title (e.g., "Fix auth login bug") that appears in the session browser.

### Session history

Sessions are logged to `~/.agent-manager/history.jsonl`. The directory picker annotates paths with recent session history — agent type, task, and age — so you can see what you were working on last.

### Configuration

```bash
am config                          # Show current defaults
am config set agent codex          # Default to Codex
am config set yolo true            # Default to permissive mode
am config set logs true            # Enable pane log streaming
am config get agent                # Read a single value
```

Precedence: CLI flag > environment variable > saved config > built-in default.

## Agent Types

| Agent | Command | `--yolo` maps to |
|-------|---------|-------------------|
| `claude` | `claude` | `--dangerously-skip-permissions` |
| `codex` | `codex` | `--yolo` |
| `gemini` | `gemini` | `--yolo` |

Unknown agent types are passed through as the command name, so `am new -t aider .` will try to run `aider`.

## Commands Reference

| Command | Aliases | Description |
|---------|---------|-------------|
| `am` | `am list`, `am ls` | Open interactive session browser |
| `am new [dir]` | `create`, `n` | Create new agent session |
| `am send <session> [prompt]` | | Send a prompt to a running session |
| `am peek <session>` | | Snapshot or follow a session's pane output |
| `am wait <session>` | | Block until agent reaches a target state |
| `am events <session>` | | Stream state-change events as JSONL |
| `am interrupt <session>` | | Send Ctrl-C to the agent pane |
| `am attach <session>` | `a` | Attach to a session |
| `am kill <session>` | `rm`, `k` | Kill a session |
| `am kill --all` | | Kill all sessions |
| `am info <session>` | `i` | Show session details |
| `am status` | `s` | Summary of all sessions |
| `am status --json` | | Machine-readable session data |
| `am list --json` | | All sessions as JSON |
| `am config` | | Show or change saved defaults |
| `am sandbox <cmd>` | `sb` | Manage sandbox state, mappings, and containers |
| `am <path>` | | Shortcut for `am new <path>` |
| `am help` | `-h` | Show help |
| `am version` | `-v` | Show version |

## Storage

```
~/.agent-manager/
├── config.json         # Saved defaults (agent, yolo, log streaming)
├── sessions.json       # Live session metadata registry
├── history.jsonl       # Persistent session history (survives cleanup)
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
