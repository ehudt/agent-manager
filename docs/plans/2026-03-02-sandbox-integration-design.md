# Sandbox Integration Design

Merge agent-sandbox (`sb`) into agent-manager (`am`). Sandbox becomes an internal module — no standalone `sb` command.

## Goals

- Single repo, single install
- Sandbox lifecycle tied to session lifecycle (auto-remove on kill)
- Per-session sandbox containers (not per-directory)

## Repo Layout

```
agent-manager/
├── am                          # Add sandbox subcommand routing
├── lib/
│   ├── sandbox.sh              # Sandbox functions (extracted from sb)
│   ├── agents.sh               # agent_launch/kill integrate sandbox
│   ├── registry.sh             # Stores container_name per session
│   └── ...
├── sandbox/
│   ├── Dockerfile              # From agent-sandbox (unchanged)
│   ├── entrypoint.sh           # From agent-sandbox (unchanged)
│   └── config_context/         # .zshrc, .vimrc, .tmux.conf
└── ...
```

- `lib/sandbox.sh` — bash functions, sourced by `am`
- `sandbox/` — Docker build context only, no bash logic
- `lib/sandbox.sh` uses `SANDBOX_DIR` to locate the Docker build context

## Functions (`lib/sandbox.sh`)

| Function | Purpose |
|----------|---------|
| `sandbox_build_image()` | Build `agent-sandbox:persistent` from `sandbox/` |
| `sandbox_start(session_name, directory)` | Create & start container named `am-<session_name>` |
| `sandbox_attach(session_name)` | `docker exec` into the container |
| `sandbox_stop(session_name)` | Stop container |
| `sandbox_remove(session_name)` | Remove container (`docker rm -f`) |
| `sandbox_status(session_name)` | Show status, Tailscale IP |
| `sandbox_list()` | List all `agent-sandbox=true` containers |
| `sandbox_prune()` | Remove stopped sandbox containers |
| `sandbox_identity_init()` | Create `~/.sb/` with identity files |
| `sandbox_container_name(session_name)` | Return container name for a session |
| `sandbox_needs_refresh(container)` | Check if container mounts/caps are stale |

### Container Naming

Old: `sb-<dirname>-<random>` → New: `am-<session_name>` (e.g., `am-a1b2c3`).

1:1 mapping between am sessions and sandbox containers.

### Container Discovery

Labels:
- `agent-sandbox=true` — fleet operations
- `agent-sandbox.session=<session_name>` — direct lookup
- `agent-sandbox.dir=<path>` — kept for compatibility

### Config

Secrets in `~/.agent-manager/sandbox.env` (TS_AUTHKEY, ANTHROPIC_API_KEY, etc.). Environment variable overrides still work.

## Session Lifecycle Integration

### Launch (`agent_launch()`)

When `--yolo` and sandbox is enabled:

1. `sandbox_start(session_name, directory)`
2. `registry_update(session_name, container_name=am-<session_name>)`
3. Both tmux panes attach to sandbox
4. Agent command runs inside sandbox

### Kill (`agent_kill()`)

1. Read `container_name` from registry
2. If set, `sandbox_remove(session_name)` — `docker rm -f`
3. Existing kill logic (tmux session, registry removal)

### GC (`registry_gc()`)

When cleaning up dead sessions, also remove orphaned sandbox containers.

### Registry Change

Add `container_name` field to `sessions.json` entries.

## CLI Surface

```
am sandbox ls                  # List all sandbox containers
am sandbox prune               # Remove stopped containers
am sandbox rebuild             # Rebuild Docker image
am sandbox rebuild --restart   # Rebuild + recreate running sandboxes
am sandbox identity init       # Initialize ~/.sb/ identity
am sandbox status [session]    # Show sandbox status
```

## Migration

- `sb` command no longer installed. Remove from PATH.
- `install.sh` updated — no `sb` binary.
- Old containers (labeled `agent-sandbox.dir=...`) visible via `am sandbox ls`, removable via `am sandbox prune`.
- Old agent-sandbox repo can be archived after merge.
- On first `am sandbox` usage, if `~/.agent-manager/sandbox.env` missing, print message to copy secrets from old `.env`.
- Dockerfile, entrypoint.sh, container runtime behavior unchanged.
