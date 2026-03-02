# Sandbox Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Merge agent-sandbox (`sb`) into agent-manager as `lib/sandbox.sh` + `sandbox/` Docker assets, with per-session container lifecycle tied to `agent_kill()`.

**Architecture:** Extract sb's ~900 lines into a sourced lib module (`lib/sandbox.sh`) with `sandbox_*` prefixed functions. Docker build context (Dockerfile, entrypoint.sh, config_context/) goes into `sandbox/`. Container naming changes from `sb-<dirname>-<random>` to the am session name (already unique). The `am` CLI gains a `sandbox` subcommand for fleet/image/identity management.

**Tech Stack:** Bash, Docker, jq, tmux

**Design doc:** `docs/plans/2026-03-02-sandbox-integration-design.md`

---

### Task 1: Copy Docker assets into `sandbox/`

**Files:**
- Create: `sandbox/Dockerfile` (copy from `~/code/agent-sandbox/Dockerfile`)
- Create: `sandbox/entrypoint.sh` (copy from `~/code/agent-sandbox/entrypoint.sh`)
- Create: `sandbox/config_context/.zshrc` (copy from `~/code/agent-sandbox/config_context/.zshrc`)
- Create: `sandbox/config_context/.vimrc` (copy from `~/code/agent-sandbox/config_context/.vimrc`)
- Create: `sandbox/config_context/.tmux.conf` (copy from `~/code/agent-sandbox/config_context/.tmux.conf`)
- Create: `sandbox/.env.example` (copy from `~/code/agent-sandbox/.env.example`)

**Step 1: Copy files**

```bash
mkdir -p sandbox/config_context
cp ~/code/agent-sandbox/Dockerfile sandbox/
cp ~/code/agent-sandbox/entrypoint.sh sandbox/
cp ~/code/agent-sandbox/config_context/.zshrc sandbox/config_context/
cp ~/code/agent-sandbox/config_context/.vimrc sandbox/config_context/
cp ~/code/agent-sandbox/config_context/.tmux.conf sandbox/config_context/
cp ~/code/agent-sandbox/.env.example sandbox/
```

**Step 2: Add .env to .gitignore**

Add to `.gitignore`:
```
sandbox/.env
```

**Step 3: Commit**

```bash
git add sandbox/
git add .gitignore
git commit -m "Add sandbox Docker assets from agent-sandbox"
```

---

### Task 2: Create `lib/sandbox.sh` — core container functions

**Files:**
- Create: `lib/sandbox.sh`

This task extracts the core container lifecycle functions from `~/code/agent-sandbox/sb`. All functions are prefixed with `sandbox_`. The module uses `SANDBOX_DIR` (set relative to `AM_SCRIPT_DIR`) to find the Docker build context.

**Step 1: Write `lib/sandbox.sh` with globals and helpers**

Source reference: `~/code/agent-sandbox/sb` lines 7-15 (globals), 139-146 (copy_if_missing), 184-190 (resolve_target_dir), 192-197 (generate_container_name), 199-207 (find/inspect helpers), 209-230 (container inspection helpers), 232-270 (needs_refresh).

```bash
# lib/sandbox.sh — Docker sandbox lifecycle management
#
# Provides sandbox_* functions for creating, managing, and destroying
# per-session Docker containers. Sourced by `am`.

SANDBOX_DIR="$AM_SCRIPT_DIR/sandbox"
SANDBOX_IMAGE="agent-sandbox:persistent"
SANDBOX_ENV_FILE="$AM_DIR/sandbox.env"
SB_HOME="${SB_HOME:-$HOME/.sb}"
_SB_SSH_DIR="$SB_HOME/ssh"
_SB_CLAUDE_JSON="$SB_HOME/claude.json"
_SB_CLAUDE_DIR="$SB_HOME/claude"
_SB_CODEX_DIR="$SB_HOME/codex"

# Source sandbox env file if it exists
[[ -f "$SANDBOX_ENV_FILE" ]] && source "$SANDBOX_ENV_FILE"

# --- Internal helpers ---

_sandbox_copy_if_missing() {
    local src="$1" dst="$2"
    [[ -e "$src" ]] || return 0
    [[ -e "$dst" ]] && return 0
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
}

_sandbox_container_mount_mode() {
    local container_name="$1" destination="$2"
    docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{if .RW}}rw{{else}}ro{{end}}{{end}}{{end}}" "$container_name" 2>/dev/null
}

_sandbox_container_has_cap() {
    local container_name="$1" capability="$2"
    docker inspect -f '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -Fxq "$capability"
}

_sandbox_container_has_mount() {
    local container_name="$1" destination="$2"
    local present
    present=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}present{{end}}{{end}}" "$container_name" 2>/dev/null)
    [[ "$present" == "present" ]]
}

_sandbox_claude_install_method() {
    local config_path="$1"
    local line
    [[ -f "$config_path" ]] || return 1
    line=$(grep -m1 -E '"installMethod"[[:space:]]*:[[:space:]]*"[^"]+"' "$config_path" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1
    sed -E 's/.*"installMethod"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' <<<"$line"
}

_sandbox_needs_refresh() {
    local container_name="$1"
    local claude_native_bin_src="$2"
    local claude_native_versions_src="$3"
    local stale=1

    local claude_json_mount_mode
    claude_json_mount_mode=$(_sandbox_container_mount_mode "$container_name" "$HOME/.claude.json")
    if [[ "$claude_json_mount_mode" != "rw" ]]; then
        log_info "Refreshing sandbox: ~/.claude.json needs write access" >&2
        stale=0
    fi

    local claude_mount_mode
    claude_mount_mode=$(_sandbox_container_mount_mode "$container_name" "$HOME/.claude")
    if [[ "$claude_mount_mode" != "rw" ]]; then
        log_info "Refreshing sandbox: ~/.claude needs read-write access" >&2
        stale=0
    fi

    local capability
    for capability in CHOWN DAC_OVERRIDE FOWNER; do
        if ! _sandbox_container_has_cap "$container_name" "$capability"; then
            log_info "Refreshing sandbox: missing CAP_$capability" >&2
            stale=0
        fi
    done

    if [[ -n "$claude_native_bin_src" ]] && ! _sandbox_container_has_mount "$container_name" "$HOME/.local/bin/claude"; then
        log_info "Refreshing sandbox: missing native Claude binary mount" >&2
        stale=0
    fi

    if [[ -n "$claude_native_versions_src" ]] && ! _sandbox_container_has_mount "$container_name" "$HOME/.local/share/claude/versions"; then
        log_info "Refreshing sandbox: missing native Claude versions mount" >&2
        stale=0
    fi

    return "$stale"
}
```

**Step 2: Add `sandbox_build_image()`**

Source reference: `~/code/agent-sandbox/sb` lines 354-363 (rebuild_image).

```bash
sandbox_build_image() {
    local no_cache="${1:-0}"
    if [[ "$no_cache" == "1" ]]; then
        log_info "Building sandbox image (no cache)..." >&2
        docker build --no-cache -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    else
        log_info "Building sandbox image..." >&2
        docker build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    fi
}
```

**Step 3: Add `sandbox_start()`**

Source reference: `~/code/agent-sandbox/sb` lines 419-628 (ensure_running). Key change: takes `session_name` and `directory` as args; container is named after the session; adds `agent-sandbox.session` label.

```bash
sandbox_start() {
    local session_name="$1"
    local directory="$2"
    local container_name="$session_name"

    # Build image if missing
    if ! docker image inspect "$SANDBOX_IMAGE" &>/dev/null; then
        sandbox_build_image
    fi

    mkdir -p "$HOME/.claude"
    touch "$HOME/.claude.json"
    mkdir -p "$HOME/.codex"

    # Detect Claude source paths (prefer ~/.sb/ over ~/.)
    local claude_json_src="$HOME/.claude.json"
    [[ -f "$_SB_CLAUDE_JSON" ]] && claude_json_src="$_SB_CLAUDE_JSON"

    local claude_dir_src="$HOME/.claude"
    [[ -d "$_SB_CLAUDE_DIR" ]] && claude_dir_src="$_SB_CLAUDE_DIR"

    local claude_install_method_name
    claude_install_method_name="$(_sandbox_claude_install_method "$claude_json_src" || true)"
    local claude_native_bin_src="" claude_native_versions_src=""
    if [[ "$claude_install_method_name" == "native" && -x "$HOME/.local/bin/claude" ]]; then
        claude_native_bin_src="$HOME/.local/bin/claude"
        [[ -d "$HOME/.local/share/claude/versions" ]] && claude_native_versions_src="$HOME/.local/share/claude/versions"
    fi

    # Check if container already exists and is running
    local state
    state=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null) || state=""

    if [[ "$state" == "true" ]]; then
        if _sandbox_needs_refresh "$container_name" "$claude_native_bin_src" "$claude_native_versions_src"; then
            log_info "Recreating sandbox '$container_name' for updated runtime settings..." >&2
            docker rm -f "$container_name" >/dev/null
        else
            log_info "Sandbox '$container_name' already running." >&2
            return 0
        fi
    fi

    # If container exists but stopped, remove it (per-session = fresh each time)
    if docker inspect "$container_name" &>/dev/null; then
        docker rm -f "$container_name" >/dev/null
    fi

    # Collect environment
    local host_user host_uid host_gid
    host_user=$(id -un)
    host_uid=$(id -u)
    host_gid=$(id -g)

    local sb_enable_tailscale="${SB_ENABLE_TAILSCALE:-1}"
    local enable_ssh="${ENABLE_SSH:-0}"
    local ts_enable_ssh="${TS_ENABLE_SSH:-1}"
    local sb_unsafe_root="${SB_UNSAFE_ROOT:-0}"
    local sb_read_only_rootfs="${SB_READ_ONLY_ROOTFS:-0}"
    local sb_pids_limit="${SB_PIDS_LIMIT:-512}"
    local sb_memory_limit="${SB_MEMORY_LIMIT:-4g}"
    local sb_cpus_limit="${SB_CPUS_LIMIT:-2.0}"

    # Build mount list
    local MOUNTS=(-v "$directory:$directory")
    MOUNTS+=(-v "$claude_json_src:$HOME/.claude.json")
    MOUNTS+=(-v "$claude_dir_src:$HOME/.claude")
    [[ -n "$claude_native_bin_src" ]] && MOUNTS+=(-v "$claude_native_bin_src:$HOME/.local/bin/claude:ro")
    [[ -n "$claude_native_versions_src" ]] && MOUNTS+=(-v "$claude_native_versions_src:$HOME/.local/share/claude/versions:ro")

    local codex_config_src="" codex_auth_src="" ssh_dir_src=""
    [[ -f "$_SB_CODEX_DIR/config.toml" ]] && codex_config_src="$_SB_CODEX_DIR/config.toml"
    [[ -z "$codex_config_src" && -f "$HOME/.codex/config.toml" ]] && codex_config_src="$HOME/.codex/config.toml"
    [[ -n "$codex_config_src" ]] && MOUNTS+=(-v "$codex_config_src:$HOME/.codex/config.toml")

    [[ -f "$_SB_CODEX_DIR/auth.json" ]] && codex_auth_src="$_SB_CODEX_DIR/auth.json"
    [[ -z "$codex_auth_src" && -f "$HOME/.codex/auth.json" ]] && codex_auth_src="$HOME/.codex/auth.json"
    [[ -n "$codex_auth_src" ]] && MOUNTS+=(-v "$codex_auth_src:$HOME/.codex/auth.json:ro")

    [[ -d "$_SB_SSH_DIR" ]] && ssh_dir_src="$_SB_SSH_DIR"
    [[ -z "$ssh_dir_src" && -d "$HOME/.ssh" ]] && ssh_dir_src="$HOME/.ssh"
    [[ -n "$ssh_dir_src" ]] && MOUNTS+=(-v "$ssh_dir_src:$HOME/.ssh:ro")
    [[ -f "$HOME/.gitconfig" ]] && MOUNTS+=(-v "$HOME/.gitconfig:$HOME/.gitconfig:ro")
    [[ -f "$HOME/.zshrc" ]] && MOUNTS+=(-v "$HOME/.zshrc:$HOME/.zshrc:ro")
    [[ -f "$HOME/.vimrc" ]] && MOUNTS+=(-v "$HOME/.vimrc:$HOME/.vimrc:ro")
    [[ -f "$HOME/.tmux.conf" ]] && MOUNTS+=(-v "$HOME/.tmux.conf:$HOME/.tmux.conf:ro")
    [[ -d "$HOME/code/tools" ]] && MOUNTS+=(-v "$HOME/code/tools:$HOME/code/tools:ro")

    # Build env vars list
    local ENV_VARS=(
        -e "TERM=${TERM:-xterm-256color}"
        -e "SANDBOX_NAME=$container_name"
        -e "HOST_USER=$host_user"
        -e "HOST_UID=$host_uid"
        -e "HOST_GID=$host_gid"
        -e "HOST_HOME=$HOME"
        -e "TARGET_DIR=$directory"
        -e "SB_ENABLE_TAILSCALE=$sb_enable_tailscale"
        -e "ENABLE_SSH=$enable_ssh"
        -e "TS_ENABLE_SSH=$ts_enable_ssh"
        -e "SB_UNSAFE_ROOT=$sb_unsafe_root"
        -e "SB_READ_ONLY_ROOTFS=$sb_read_only_rootfs"
    )
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && ENV_VARS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [[ -n "${TS_AUTHKEY:-}" ]] && ENV_VARS+=(-e "TS_AUTHKEY=$TS_AUTHKEY")
    if [[ "${SB_FORWARD_SSH_AGENT:-0}" == "1" ]]; then
        if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
            MOUNTS+=(-v "$SSH_AUTH_SOCK:/ssh-agent")
            ENV_VARS+=(-e "SSH_AUTH_SOCK=/ssh-agent")
        else
            log_warn "SB_FORWARD_SSH_AGENT=1 but SSH_AUTH_SOCK is not available" >&2
        fi
    fi

    # Build runtime options
    local RUN_OPTS=(
        --pids-limit "$sb_pids_limit"
        --memory "$sb_memory_limit"
        --cpus "$sb_cpus_limit"
        --cap-drop=ALL
        --cap-add=CHOWN
        --cap-add=DAC_OVERRIDE
        --cap-add=FOWNER
    )
    if [[ "$sb_unsafe_root" != "1" ]]; then
        RUN_OPTS+=(--security-opt no-new-privileges:true)
    fi
    if [[ "$sb_enable_tailscale" == "1" ]]; then
        RUN_OPTS+=(--cap-add=NET_ADMIN --device /dev/net/tun)
    fi
    if [[ "$sb_read_only_rootfs" == "1" ]]; then
        RUN_OPTS+=(
            --read-only
            --tmpfs /tmp:rw,noexec,nosuid,nodev
            --tmpfs /run:rw,nosuid,nodev
            --tmpfs /var/run:rw,nosuid,nodev
            -v "${container_name}-codex-home:/home/dev/.codex"
        )
        if [[ "$sb_enable_tailscale" == "1" ]]; then
            RUN_OPTS+=(-v "${container_name}-tailscale-state:/var/lib/tailscale")
        fi
    fi

    # Run container
    docker run -d \
        --name "$container_name" \
        --hostname "$container_name" \
        --label "agent-sandbox=true" \
        --label "agent-sandbox.session=$session_name" \
        --label "agent-sandbox.dir=$directory" \
        --restart unless-stopped \
        "${RUN_OPTS[@]}" \
        "${MOUNTS[@]}" \
        "${ENV_VARS[@]}" \
        "$SANDBOX_IMAGE" >/dev/null

    log_success "Sandbox '$container_name' started." >&2
}
```

**Step 4: Add attach, stop, remove, status functions**

Source reference: `~/code/agent-sandbox/sb` lines 393-417 (attach_shell), 630-646 (status_sandbox), 648-660 (stop_sandbox), 662-674 (clean_sandbox).

```bash
sandbox_attach_cmd() {
    # Returns the shell command string for tmux_send_keys to attach to a sandbox
    local session_name="$1"
    local directory="$2"
    local host_user host_uid host_gid
    host_user=$(id -un)
    host_uid=$(id -u)
    host_gid=$(id -g)
    echo "docker exec -it -u '$host_user' -w '$directory' -e 'HOST_UID=$host_uid' -e 'HOST_GID=$host_gid' -e 'TERM=${TERM:-xterm-256color}' '$session_name' zsh"
}

sandbox_remove() {
    local session_name="$1"
    if docker inspect "$session_name" &>/dev/null; then
        docker rm -f "$session_name" >/dev/null
        log_info "Removed sandbox '$session_name'" >&2
    fi
}

sandbox_stop() {
    local session_name="$1"
    if docker inspect "$session_name" &>/dev/null; then
        docker stop "$session_name" >/dev/null 2>&1 || true
        log_info "Stopped sandbox '$session_name'" >&2
    fi
}

sandbox_status() {
    local session_name="$1"
    local state ts_ip host_user
    if ! state=$(docker inspect -f '{{.State.Status}}' "$session_name" 2>/dev/null); then
        state="not found"
    fi
    echo "Container: $session_name"
    echo "Status:    $state"
    if [[ "$state" == "running" ]]; then
        local dir
        dir=$(docker inspect -f '{{index .Config.Labels "agent-sandbox.dir"}}' "$session_name" 2>/dev/null || echo "n/a")
        echo "Directory: $dir"
        ts_ip=$(docker exec "$session_name" tailscale ip -4 2>/dev/null || echo "n/a")
        host_user=$(id -un)
        echo "Tailscale: $ts_ip"
        if [[ "$ts_ip" != "n/a" ]]; then
            echo "SSH:       ssh $host_user@$session_name"
        fi
    fi
}
```

**Step 5: Add fleet management functions**

Source reference: `~/code/agent-sandbox/sb` lines 284-294 (list/prune), 296-352 (remove_sandboxes), 365-391 (rebuild+restart).

```bash
sandbox_list() {
    echo "Agent sandbox containers:" >&2
    docker ps -a \
        --filter "label=agent-sandbox" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Label "agent-sandbox.dir"}}'
}

sandbox_prune() {
    log_info "Removing stopped sandbox containers..." >&2
    docker container prune -f --filter "label=agent-sandbox"
}

sandbox_rebuild_and_restart() {
    local no_cache="${1:-0}"
    local running_info
    running_info=$(docker ps --filter "label=agent-sandbox" --format '{{.Names}}	{{.Label "agent-sandbox.dir"}}')

    log_info "Removing all running sandbox containers..." >&2
    if [[ -z "$running_info" ]]; then
        log_info "No running sandbox containers found." >&2
    else
        while IFS=$'\t' read -r container_name _dir; do
            [[ -z "$container_name" ]] && continue
            log_info "Removing '$container_name'..." >&2
            docker rm -f "$container_name" >/dev/null
        done <<< "$running_info"
    fi

    sandbox_build_image "$no_cache"

    if [[ -n "$running_info" ]]; then
        log_info "Starting previously running sandboxes..." >&2
        while IFS=$'\t' read -r container_name dir; do
            [[ -z "$dir" ]] && continue
            log_info "Starting sandbox for '$dir'..." >&2
            sandbox_start "$container_name" "$dir"
        done <<< "$(printf '%s\n' "$running_info" | awk -F '\t' '!seen[$2]++')"
    fi
}
```

**Step 6: Add identity init function**

Source reference: `~/code/agent-sandbox/sb` lines 148-182 (init_sb_home).

```bash
sandbox_identity_init() {
    log_info "Initializing sandbox identity in '$SB_HOME'..." >&2

    mkdir -p "$SB_HOME" "$_SB_CODEX_DIR" "$_SB_SSH_DIR"
    chmod 700 "$SB_HOME" "$_SB_SSH_DIR"

    _sandbox_copy_if_missing "$HOME/.claude.json" "$_SB_CLAUDE_JSON"
    _sandbox_copy_if_missing "$HOME/.claude" "$_SB_CLAUDE_DIR"
    _sandbox_copy_if_missing "$HOME/.codex/config.toml" "$_SB_CODEX_DIR/config.toml"
    _sandbox_copy_if_missing "$HOME/.codex/auth.json" "$_SB_CODEX_DIR/auth.json"
    _sandbox_copy_if_missing "$HOME/.ssh/known_hosts" "$_SB_SSH_DIR/known_hosts"

    if [[ ! -f "$_SB_SSH_DIR/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$_SB_SSH_DIR/id_ed25519" -N "" -C "sb@$(hostname)"
    fi
    chmod 600 "$_SB_SSH_DIR/id_ed25519"
    chmod 644 "$_SB_SSH_DIR/id_ed25519.pub"
    [[ -f "$_SB_SSH_DIR/known_hosts" ]] && chmod 644 "$_SB_SSH_DIR/known_hosts"

    if [[ ! -f "$_SB_SSH_DIR/config" ]]; then
        cat > "$_SB_SSH_DIR/config" <<SSHEOF
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
SSHEOF
        chmod 600 "$_SB_SSH_DIR/config"
    fi

    echo >&2
    log_success "Sandbox identity ready." >&2
    echo "Public key: $_SB_SSH_DIR/id_ed25519.pub" >&2
    echo "Next steps:" >&2
    echo "  1) Add this key where needed (GitHub/GitLab)." >&2
    echo "  2) Run am as usual; ~/.sb identity will be preferred over host-global secrets." >&2
}
```

**Step 7: Commit**

```bash
git add lib/sandbox.sh
git commit -m "Add lib/sandbox.sh: sandbox lifecycle functions"
```

---

### Task 3: Integrate sandbox into session lifecycle

**Files:**
- Modify: `lib/agents.sh` (agent_launch sandbox block ~lines 183-191, agent_kill ~lines 307-321)
- Modify: `lib/registry.sh` (registry_gc ~lines 102-140)

**Step 1: Update `agent_launch()` sandbox block in `lib/agents.sh`**

Replace the existing sandbox block (lines 183-191):

```bash
    # OLD (lines 183-191):
    if $wants_yolo && command -v sb &>/dev/null; then
        sb "$directory" --start >&2
        tmux_send_keys "$session_name:.{bottom}" "sb . --attach && clear" Enter
        tmux_send_keys "$session_name:.{top}" "sb . --attach && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi
```

With:

```bash
    # NEW:
    if $wants_yolo && command -v docker &>/dev/null; then
        sandbox_start "$session_name" "$directory"
        registry_update "$session_name" "container_name" "$session_name"
        local attach_cmd
        attach_cmd=$(sandbox_attach_cmd "$session_name" "$directory")
        tmux_send_keys "$session_name:.{bottom}" "$attach_cmd && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$attach_cmd && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi
```

**Step 2: Update `agent_kill()` in `lib/agents.sh`**

Replace the existing function (lines 307-321):

```bash
    # OLD:
    agent_kill() {
        local session_name="$1"
        local rc=0
        tmux_kill_session "$session_name" || rc=$?
        registry_remove "$session_name"
        if [[ $rc -eq 0 ]]; then
            log_success "Killed session: $session_name"
        fi
        return $rc
    }
```

With:

```bash
    # NEW:
    agent_kill() {
        local session_name="$1"
        local rc=0

        # Remove sandbox container if session had one
        local container_name
        container_name=$(registry_get_field "$session_name" "container_name")
        if [[ -n "$container_name" ]]; then
            sandbox_remove "$session_name"
        fi

        tmux_kill_session "$session_name" || rc=$?
        registry_remove "$session_name"

        if [[ $rc -eq 0 ]]; then
            log_success "Killed session: $session_name"
        fi
        return $rc
    }
```

**Step 3: Update `registry_gc()` in `lib/registry.sh`**

Add sandbox cleanup inside the gc loop. After `registry_remove "$name"`, add:

```bash
        if ! tmux_session_exists "$name"; then
            # Clean up sandbox container if one exists
            local container
            container=$(registry_get_field "$name" "container_name")
            if [[ -n "$container" ]]; then
                sandbox_remove "$name"
            fi
            registry_remove "$name"
            ((removed++))
        fi
```

Note: `registry_get_field` must be called before `registry_remove` since remove deletes the entry.

**Step 4: Run tests**

```bash
./tests/test_all.sh
```

Expected: All existing tests pass (sandbox functions are only called when Docker is present and `--yolo` is active, which tests don't use).

**Step 5: Commit**

```bash
git add lib/agents.sh lib/registry.sh
git commit -m "Integrate sandbox lifecycle with session launch/kill/gc"
```

---

### Task 4: Add `am sandbox` CLI subcommand

**Files:**
- Modify: `am` (add `sandbox` case in main routing, add `cmd_sandbox()` function)

**Step 1: Add `cmd_sandbox()` function**

Add before `main()` in `am` (around line 525):

```bash
cmd_sandbox() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        ls|list|ps)
            sandbox_list
            ;;
        prune)
            sandbox_prune
            ;;
        rebuild)
            local no_cache=0
            local restart=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --no-cache) no_cache=1 ;;
                    --restart|--restart-running) restart=1 ;;
                    *) log_error "Unknown option: $1"; return 1 ;;
                esac
                shift
            done
            if [[ "$restart" == "1" ]]; then
                sandbox_rebuild_and_restart "$no_cache"
            else
                sandbox_build_image "$no_cache"
            fi
            ;;
        identity)
            local sub="${1:-}"
            case "$sub" in
                init|init-home) sandbox_identity_init ;;
                *) log_error "Usage: am sandbox identity init"; return 1 ;;
            esac
            ;;
        status)
            local session="${1:-}"
            if [[ -z "$session" ]]; then
                log_error "Usage: am sandbox status <session>"
                return 1
            fi
            sandbox_status "$session"
            ;;
        ""|help|--help|-h)
            cat <<'EOF'
Usage: am sandbox <subcommand>

Subcommands:
  ls                              List all sandbox containers
  prune                           Remove stopped sandbox containers
  rebuild [--no-cache] [--restart] Rebuild sandbox Docker image
  identity init                   Initialize ~/.sb/ sandbox identity
  status <session>                Show sandbox status for a session
EOF
            ;;
        *)
            log_error "Unknown sandbox subcommand: $action"
            return 1
            ;;
    esac
}
```

**Step 2: Add `sandbox` to the case statement in `main()`**

In the main case statement (around line 542), add before the `*` catch-all:

```bash
        sandbox|sb)
            cmd_sandbox "$@"
            ;;
```

**Step 3: Source `lib/sandbox.sh`**

Add to the library sourcing block (after line 110, after `source "$AM_LIB_DIR/agents.sh"`):

```bash
source "$AM_LIB_DIR/sandbox.sh"
```

**Step 4: Run tests**

```bash
./tests/test_all.sh
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add am
git commit -m "Add 'am sandbox' CLI subcommand for fleet/image/identity management"
```

---

### Task 5: Add sandbox tests

**Files:**
- Modify: `tests/test_all.sh`

**Step 1: Add unit tests for sandbox helper functions**

These test the pure functions that don't need Docker. Add a new `test_sandbox()` function:

```bash
test_sandbox() {
    header "Sandbox"

    # Test sandbox_attach_cmd output format
    run_test "sandbox_attach_cmd returns docker exec command" '
        local cmd
        cmd=$(sandbox_attach_cmd "am-abc123" "/home/user/project")
        assert_contains "$cmd" "docker exec"
        assert_contains "$cmd" "am-abc123"
        assert_contains "$cmd" "/home/user/project"
    '

    # Test _sandbox_copy_if_missing skips existing
    run_test "_sandbox_copy_if_missing skips when dest exists" '
        local tmpdir
        tmpdir=$(mktemp -d)
        echo "src" > "$tmpdir/src"
        echo "dst" > "$tmpdir/dst"
        _sandbox_copy_if_missing "$tmpdir/src" "$tmpdir/dst"
        assert_eq "$(cat "$tmpdir/dst")" "dst"
        rm -rf "$tmpdir"
    '

    # Test _sandbox_copy_if_missing copies when missing
    run_test "_sandbox_copy_if_missing copies when dest missing" '
        local tmpdir
        tmpdir=$(mktemp -d)
        echo "src" > "$tmpdir/src"
        _sandbox_copy_if_missing "$tmpdir/src" "$tmpdir/dst"
        assert_eq "$(cat "$tmpdir/dst")" "src"
        rm -rf "$tmpdir"
    '

    # Test _sandbox_copy_if_missing noop when src missing
    run_test "_sandbox_copy_if_missing noop when src missing" '
        local tmpdir
        tmpdir=$(mktemp -d)
        _sandbox_copy_if_missing "$tmpdir/nonexistent" "$tmpdir/dst"
        [[ ! -f "$tmpdir/dst" ]] || fail "dst should not exist"
        rm -rf "$tmpdir"
    '

    # Test _sandbox_claude_install_method
    run_test "_sandbox_claude_install_method extracts method" '
        local tmpdir
        tmpdir=$(mktemp -d)
        echo "{\"installMethod\": \"native\"}" > "$tmpdir/claude.json"
        local method
        method=$(_sandbox_claude_install_method "$tmpdir/claude.json")
        assert_eq "$method" "native"
        rm -rf "$tmpdir"
    '

    # Test _sandbox_claude_install_method returns 1 for missing file
    run_test "_sandbox_claude_install_method fails for missing file" '
        ! _sandbox_claude_install_method "/nonexistent/path"
    '

    # Test SANDBOX_DIR points to sandbox/ directory
    run_test "SANDBOX_DIR is set correctly" '
        assert_contains "$SANDBOX_DIR" "sandbox"
        [[ -d "$SANDBOX_DIR" ]] || fail "SANDBOX_DIR does not exist: $SANDBOX_DIR"
    '
}
```

**Step 2: Register the test**

Add `test_sandbox` to the test runner at the bottom of `test_all.sh`, alongside the other test function calls.

**Step 3: Run tests**

```bash
./tests/test_all.sh
```

Expected: All tests pass, including the new sandbox tests.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add sandbox unit tests"
```

---

### Task 6: Update documentation and cleanup

**Files:**
- Modify: `AGENTS.md` (add sandbox to key files, functions, extension points)
- Modify: `README.md` (update sandbox section to reflect `am sandbox` commands)
- Modify: `scripts/install.sh` (no changes needed — sb was never installed by this script)

**Step 1: Update AGENTS.md key files table**

Add rows:

```markdown
| `lib/sandbox.sh` | Docker sandbox lifecycle: start, attach, stop, remove, fleet ops |
| `sandbox/Dockerfile` | Docker image definition for sandbox containers |
| `sandbox/entrypoint.sh` | Container init: user alignment, Tailscale, SSH |
```

**Step 2: Update AGENTS.md key functions**

Add a **Sandbox** section:

```markdown
**Sandbox:**
- `sandbox_start(session_name, dir)` - Create and start per-session Docker container
- `sandbox_attach_cmd(session_name, dir)` - Return docker exec command string for tmux
- `sandbox_remove(session_name)` - Force-remove container
- `sandbox_list()` - List all agent-sandbox containers
- `sandbox_prune()` - Remove stopped containers
- `sandbox_build_image([no_cache])` - Build Docker image from `sandbox/`
- `sandbox_rebuild_and_restart([no_cache])` - Rebuild image, recreate running containers
- `sandbox_identity_init()` - Initialize `~/.sb/` with dedicated sandbox credentials
```

**Step 3: Update AGENTS.md extension points**

Add row:

```markdown
| Change sandbox config | `lib/sandbox.sh` → globals, `sandbox/Dockerfile` |
```

**Step 4: Update AGENTS.md data flow**

Add sandbox flow:

```markdown
am new --yolo ~/project → agent_launch() → sandbox_start() → tmux panes attach → agent runs in container
agent_kill() → sandbox_remove() → tmux_kill_session() → registry_remove()
```

**Step 5: Update README.md sandbox section**

Replace any reference to standalone `sb` with `am sandbox` commands. Update the sandbox integration section to show the new CLI surface.

**Step 6: Run the doc-sync pre-commit hook to verify**

```bash
bash -n lib/sandbox.sh && ./tests/test_all.sh
```

**Step 7: Commit**

```bash
git add AGENTS.md README.md
git commit -m "Update docs for integrated sandbox"
```

---

### Task 7: Final integration test

**Step 1: Manual smoke test (if Docker available)**

```bash
# Build sandbox image
am sandbox rebuild

# Create a sandboxed session
am new --yolo /tmp/test-sandbox-integration

# Verify container is running
am sandbox ls

# Kill session — container should be auto-removed
am kill <session-name>

# Verify container is gone
am sandbox ls
```

**Step 2: Verify identity init**

```bash
am sandbox identity init
ls -la ~/.sb/
```

**Step 3: Run full test suite**

```bash
./tests/test_all.sh
```

Expected: All tests pass.

**Step 4: Final commit (if any fixups needed)**

```bash
git add -A
git commit -m "Fix integration issues from smoke testing"
```
