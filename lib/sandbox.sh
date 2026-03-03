# sandbox.sh - Container lifecycle functions for agent sandboxes

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

SANDBOX_DIR="$AM_SCRIPT_DIR/sandbox"
SANDBOX_IMAGE="agent-sandbox:persistent"
SANDBOX_ENV_FILE="$AM_DIR/sandbox.env"
SB_HOME="${SB_HOME:-$HOME/.sb}"
_SB_SSH_DIR="$SB_HOME/ssh"
_SB_CLAUDE_JSON="$SB_HOME/claude.json"
_SB_CLAUDE_DIR="$SB_HOME/claude"
_SB_CODEX_DIR="$SB_HOME/codex"

[[ -f "$SANDBOX_ENV_FILE" ]] && source "$SANDBOX_ENV_FILE"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_sandbox_copy_if_missing() {
    local src="$1"
    local dst="$2"
    [[ -e "$src" ]] || return 0
    [[ -e "$dst" ]] && return 0
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
}

_sandbox_container_mount_mode() {
    local container_name="$1"
    local destination="$2"
    docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{if .RW}}rw{{else}}ro{{end}}{{end}}{{end}}" "$container_name" 2>/dev/null
}

_sandbox_container_has_cap() {
    local container_name="$1"
    local capability="$2"
    docker inspect -f '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$container_name" 2>/dev/null | \
        sed 's/^CAP_//' | grep -Fxq "$capability"
}

_sandbox_container_has_mount() {
    local container_name="$1"
    local destination="$2"
    local mount_present
    mount_present=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}present{{end}}{{end}}" "$container_name" 2>/dev/null)
    [[ "$mount_present" == "present" ]]
}

_sandbox_list_containers() {
    docker ps -a --filter "label=agent-sandbox" --format '{{.Names}}'
}

_sandbox_log_dir() {
    local session_name="$1"
    echo "$AM_DIR/logs/$session_name"
}

_sandbox_event_log_path() {
    local session_name="$1"
    echo "$(_sandbox_log_dir "$session_name")/sandbox.log"
}

_sandbox_log_event() {
    local session_name="$1"
    local event="$2"
    shift 2

    local log_dir log_path timestamp details
    log_dir="$(_sandbox_log_dir "$session_name")"
    log_path="$(_sandbox_event_log_path "$session_name")"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$log_dir"

    details="$*"
    if [[ -n "$details" ]]; then
        printf '%s\t%s\t%s\n' "$timestamp" "$event" "$details" >> "$log_path"
    else
        printf '%s\t%s\n' "$timestamp" "$event" >> "$log_path"
    fi
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
    local claude_mount_mode
    local claude_json_mount_mode
    local stale=1

    claude_json_mount_mode=$(_sandbox_container_mount_mode "$container_name" "$HOME/.claude.json")
    if [[ "$claude_json_mount_mode" != "rw" ]]; then
        log_info "Refreshing sandbox '$container_name': ~/.claude.json is mounted '$claude_json_mount_mode' but Claude interactive startup needs write access."
        stale=0
    fi

    claude_mount_mode=$(_sandbox_container_mount_mode "$container_name" "$HOME/.claude")
    if [[ "$claude_mount_mode" != "rw" ]]; then
        log_info "Refreshing sandbox '$container_name': ~/.claude is mounted '$claude_mount_mode' but Claude requires read-write access."
        stale=0
    fi

    for capability in CHOWN DAC_OVERRIDE FOWNER; do
        if ! _sandbox_container_has_cap "$container_name" "$capability"; then
            log_info "Refreshing sandbox '$container_name': missing CAP_$capability required by the entrypoint."
            stale=0
        fi
    done

    if [[ -n "$claude_native_bin_src" ]] && ! _sandbox_container_has_mount "$container_name" "$HOME/.local/bin/claude"; then
        log_info "Refreshing sandbox '$container_name': missing native Claude binary mount at $HOME/.local/bin/claude."
        stale=0
    fi

    if [[ -n "$claude_native_versions_src" ]] && ! _sandbox_container_has_mount "$container_name" "$HOME/.local/share/claude/versions"; then
        log_info "Refreshing sandbox '$container_name': missing native Claude versions mount at $HOME/.local/share/claude/versions."
        stale=0
    fi

    return "$stale"
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

sandbox_build_image() {
    local no_cache="${1:-0}"
    if [[ "$no_cache" == "1" ]]; then
        log_info "Rebuilding sandbox image (no cache)..."
        docker build --no-cache -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    else
        log_info "Rebuilding sandbox image..."
        docker build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    fi
}

sandbox_start() {
    local session_name="$1"
    local directory="$2"
    _sandbox_log_event "$session_name" "start_requested" "directory=$directory"

    if [[ ! -d "$directory" ]]; then
        log_error "Sandbox directory does not exist: $directory"
        _sandbox_log_event "$session_name" "start_failed" "reason=missing_directory directory=$directory"
        return 1
    fi

    if ! docker image inspect "$SANDBOX_IMAGE" &>/dev/null; then
        log_info "Building sandbox image..."
        _sandbox_log_event "$session_name" "image_build" "image=$SANDBOX_IMAGE"
        docker build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    fi

    mkdir -p "$HOME/.claude"
    touch "$HOME/.claude.json"
    mkdir -p "$HOME/.codex"

    local claude_json_src claude_dir_src claude_install_method_name
    local claude_native_bin_src claude_native_versions_src

    claude_json_src="$HOME/.claude.json"
    [[ -f "$_SB_CLAUDE_JSON" ]] && claude_json_src="$_SB_CLAUDE_JSON"

    claude_dir_src="$HOME/.claude"
    [[ -d "$_SB_CLAUDE_DIR" ]] && claude_dir_src="$_SB_CLAUDE_DIR"

    claude_install_method_name="$(_sandbox_claude_install_method "$claude_json_src" || true)"
    claude_native_bin_src=""
    claude_native_versions_src=""
    if [[ "$claude_install_method_name" == "native" && -x "$HOME/.local/bin/claude" ]]; then
        claude_native_bin_src="$HOME/.local/bin/claude"
        [[ -d "$HOME/.local/share/claude/versions" ]] && claude_native_versions_src="$HOME/.local/share/claude/versions"
    fi

    local state
    state=$(docker inspect -f '{{.State.Running}}' "$session_name" 2>/dev/null) || state=""

    if [[ "$state" == "true" ]]; then
        if _sandbox_needs_refresh "$session_name" "$claude_native_bin_src" "$claude_native_versions_src"; then
            log_info "Recreating sandbox '$session_name' to apply updated runtime settings..."
            _sandbox_log_event "$session_name" "recreate_running" "reason=runtime_settings_changed"
            docker rm -f "$session_name" >/dev/null
        else
            log_info "Sandbox '$session_name' already running."
            _sandbox_log_event "$session_name" "start_skipped" "reason=already_running"
            return 0
        fi
    elif [[ -n "$state" ]]; then
        # Container exists but is stopped — remove it (per-session = fresh each time)
        log_info "Removing stopped sandbox '$session_name'..."
        _sandbox_log_event "$session_name" "remove_stopped" "reason=restart_after_stop"
        docker rm -f "$session_name" >/dev/null 2>&1 || true
    fi

    log_info "Starting persistent sandbox '$session_name'..."

    local host_user host_uid host_gid
    host_user=$(id -un)
    host_uid=$(id -u)
    host_gid=$(id -g)
    local sb_enable_tailscale enable_ssh ts_enable_ssh sb_unsafe_root sb_read_only_rootfs
    local sb_pids_limit sb_memory_limit sb_cpus_limit
    sb_enable_tailscale="${SB_ENABLE_TAILSCALE:-1}"
    enable_ssh="${ENABLE_SSH:-0}"
    ts_enable_ssh="${TS_ENABLE_SSH:-1}"
    sb_unsafe_root="${SB_UNSAFE_ROOT:-0}"
    sb_read_only_rootfs="${SB_READ_ONLY_ROOTFS:-0}"
    sb_pids_limit="${SB_PIDS_LIMIT:-512}"
    sb_memory_limit="${SB_MEMORY_LIMIT:-4g}"
    sb_cpus_limit="${SB_CPUS_LIMIT:-2.0}"

    local MOUNTS=(-v "$directory:$directory")
    local codex_config_src codex_auth_src ssh_dir_src
    MOUNTS+=(-v "$claude_json_src:$HOME/.claude.json")

    MOUNTS+=(-v "$claude_dir_src:$HOME/.claude")
    [[ -n "$claude_native_bin_src" ]] && MOUNTS+=(-v "$claude_native_bin_src:$HOME/.local/bin/claude:ro")
    [[ -n "$claude_native_versions_src" ]] && MOUNTS+=(-v "$claude_native_versions_src:$HOME/.local/share/claude/versions:ro")

    codex_config_src=""
    [[ -f "$_SB_CODEX_DIR/config.toml" ]] && codex_config_src="$_SB_CODEX_DIR/config.toml"
    [[ -z "$codex_config_src" && -f "$HOME/.codex/config.toml" ]] && codex_config_src="$HOME/.codex/config.toml"
    [[ -n "$codex_config_src" ]] && MOUNTS+=(-v "$codex_config_src:$HOME/.codex/config.toml")

    codex_auth_src=""
    [[ -f "$_SB_CODEX_DIR/auth.json" ]] && codex_auth_src="$_SB_CODEX_DIR/auth.json"
    [[ -z "$codex_auth_src" && -f "$HOME/.codex/auth.json" ]] && codex_auth_src="$HOME/.codex/auth.json"
    [[ -n "$codex_auth_src" ]] && MOUNTS+=(-v "$codex_auth_src:$HOME/.codex/auth.json:ro")

    ssh_dir_src=""
    [[ -d "$_SB_SSH_DIR" ]] && ssh_dir_src="$_SB_SSH_DIR"
    [[ -z "$ssh_dir_src" && -d "$HOME/.ssh" ]] && ssh_dir_src="$HOME/.ssh"
    [[ -n "$ssh_dir_src" ]] && MOUNTS+=(-v "$ssh_dir_src:$HOME/.ssh:ro")
    [[ -f "$HOME/.gitconfig" ]] && MOUNTS+=(-v "$HOME/.gitconfig:$HOME/.gitconfig:ro")
    [[ -f "$HOME/.zshrc" ]] && MOUNTS+=(-v "$HOME/.zshrc:$HOME/.zshrc:ro")
    [[ -f "$HOME/.vimrc" ]] && MOUNTS+=(-v "$HOME/.vimrc:$HOME/.vimrc:ro")
    [[ -f "$HOME/.tmux.conf" ]] && MOUNTS+=(-v "$HOME/.tmux.conf:$HOME/.tmux.conf:ro")
    [[ -d "$HOME/code/tools" ]] && MOUNTS+=(-v "$HOME/code/tools:$HOME/code/tools:ro")

    local ENV_VARS=(
        -e "TERM=${TERM:-xterm-256color}"
        -e "SANDBOX_NAME=$session_name"
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
            log_warn "SB_FORWARD_SSH_AGENT=1 but SSH_AUTH_SOCK is not available."
        fi
    fi

    if [[ "$claude_json_src" == "$_SB_CLAUDE_JSON" ]]; then
        log_info "Using sandbox Claude JSON: $_SB_CLAUDE_JSON"
    else
        log_info "Using host-global Claude JSON: $claude_json_src"
    fi

    if [[ "$claude_dir_src" == "$_SB_CLAUDE_DIR" ]]; then
        log_info "Using sandbox Claude directory: $_SB_CLAUDE_DIR"
    else
        log_info "Using host-global Claude directory: $claude_dir_src"
    fi

    if [[ -n "$claude_native_bin_src" ]]; then
        log_info "Mounting native Claude binary: $claude_native_bin_src"
    fi
    if [[ -n "$claude_native_versions_src" ]]; then
        log_info "Mounting native Claude versions directory: $claude_native_versions_src"
    fi

    if [[ -n "$codex_config_src" ]]; then
        if [[ "$codex_config_src" == "$_SB_CODEX_DIR/config.toml" ]]; then
            log_info "Using sandbox Codex config: $codex_config_src"
        else
            log_info "Using host-global Codex config: $codex_config_src"
        fi
    fi

    if [[ -n "$codex_auth_src" ]]; then
        if [[ "$codex_auth_src" == "$_SB_CODEX_DIR/auth.json" ]]; then
            log_info "Using sandbox Codex auth: $codex_auth_src"
        else
            log_info "Using host-global Codex auth: $codex_auth_src"
        fi
    fi

    if [[ "$ssh_dir_src" == "$_SB_SSH_DIR" ]]; then
        log_info "Using sandbox SSH identity: $_SB_SSH_DIR"
    elif [[ "$ssh_dir_src" == "$HOME/.ssh" ]]; then
        log_info "Using host-global SSH identity: $HOME/.ssh"
    fi

    local RUN_OPTS=(
        # Ensure orphaned docker exec descendants are reaped instead of
        # accumulating as zombies under the container's long-lived PID 1.
        --init
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
    else
        log_warn "SB_UNSAFE_ROOT=1 disables hardened sudo/privilege restrictions."
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
            -v "${session_name}-codex-home:/home/dev/.codex"
        )
        if [[ "$sb_enable_tailscale" == "1" ]]; then
            RUN_OPTS+=(-v "${session_name}-tailscale-state:/var/lib/tailscale")
        fi
    fi
    if [[ "$sb_enable_tailscale" == "1" && -z "${TS_AUTHKEY:-}" ]]; then
        log_warn "SB_ENABLE_TAILSCALE=1 but TS_AUTHKEY is unset; tailscale will not connect."
    fi
    if [[ "$sb_enable_tailscale" != "1" && "$ts_enable_ssh" == "1" ]]; then
        log_warn "TS_ENABLE_SSH=1 ignored because SB_ENABLE_TAILSCALE=0."
    fi
    log_info "Runtime modes: tailscale=$sb_enable_tailscale tailscale_ssh=$ts_enable_ssh sshd=$enable_ssh unsafe_root=$sb_unsafe_root read_only_rootfs=$sb_read_only_rootfs"

    if docker run -d \
        --name "$session_name" \
        --hostname "$session_name" \
        --label "agent-sandbox=true" \
        --label "agent-sandbox.session=$session_name" \
        --label "agent-sandbox.dir=$directory" \
        --restart unless-stopped \
        "${RUN_OPTS[@]}" \
        "${MOUNTS[@]}" \
        "${ENV_VARS[@]}" \
        "$SANDBOX_IMAGE" >/dev/null; then
        _sandbox_log_event "$session_name" "started" "image=$SANDBOX_IMAGE directory=$directory"
    else
        _sandbox_log_event "$session_name" "start_failed" "image=$SANDBOX_IMAGE directory=$directory"
        return 1
    fi

    log_success "Sandbox started in background."

    if [[ "$sb_enable_tailscale" == "1" && -n "${TS_AUTHKEY:-}" ]]; then
        sleep 3
        local ts_ip
        ts_ip=$(docker exec "$session_name" tailscale ip -4 2>/dev/null || echo "connecting...")
        log_info "Tailscale: $ts_ip"
        log_info "SSH: ssh $host_user@$session_name"
    fi
}

sandbox_attach_cmd() {
    local session_name="$1"
    local directory="$2"
    local host_user host_uid host_gid
    host_user=$(id -un)
    host_uid=$(id -u)
    host_gid=$(id -g)
    local event_log
    event_log="$(_sandbox_event_log_path "$session_name")"
    printf "%s" "docker exec -it -u '$host_user' -w '$directory' -e 'HOST_UID=$host_uid' -e 'HOST_GID=$host_gid' -e 'TERM=${TERM:-xterm-256color}' '$session_name' zsh; _am_rc=\$?; if docker inspect '$session_name' >/dev/null 2>&1; then if [[ \$_am_rc -eq 0 ]]; then clear; else printf '\\n[am] sandbox shell exited (status %s) for %s. Container is still present.\\n' \"\$_am_rc\" '$session_name'; fi; else printf '\\n[am] sandbox %s is gone; you are now on the host shell.\\n[am] inspect: ./am sandbox status %s\\n[am] events: %s\\n' '$session_name' '$session_name' '$event_log'; fi"
}

sandbox_remove() {
    local session_name="$1"
    if docker inspect "$session_name" &>/dev/null; then
        _sandbox_log_event "$session_name" "remove" "reason=explicit_remove"
        docker rm -f "$session_name" >/dev/null
        log_info "Removed sandbox '$session_name'."
    fi
}

sandbox_gc_orphans() {
    local container_name
    local removed=0

    while IFS= read -r container_name; do
        [[ -z "$container_name" ]] && continue
        if ! tmux_session_exists "$container_name"; then
            _sandbox_log_event "$container_name" "remove_orphan" "reason=missing_tmux_session"
            sandbox_remove "$container_name"
            ((removed++))
        fi
    done < <(_sandbox_list_containers)

    echo "$removed"
}

sandbox_stop() {
    local session_name="$1"
    if docker inspect "$session_name" &>/dev/null; then
        _sandbox_log_event "$session_name" "stop" "reason=explicit_stop"
        docker stop "$session_name" >/dev/null 2>&1 || true
        log_info "Stopped sandbox '$session_name'."
    fi
}

sandbox_status() {
    local session_name="$1"
    local state ts_ip host_user
    local event_log
    event_log="$(_sandbox_event_log_path "$session_name")"
    if ! state=$(docker inspect -f '{{.State.Status}}' "$session_name" 2>/dev/null); then
        state="not found"
    fi
    echo "Container: $session_name" >&2
    echo "Status:    $state" >&2
    echo "Events:    $event_log" >&2
    if [[ "$state" == "running" ]]; then
        local dir
        dir=$(docker inspect -f '{{index .Config.Labels "agent-sandbox.dir"}}' "$session_name" 2>/dev/null || echo "n/a")
        echo "Directory: $dir" >&2
        ts_ip=$(docker exec "$session_name" tailscale ip -4 2>/dev/null || echo "n/a")
        host_user=$(id -un)
        echo "Tailscale: $ts_ip" >&2
        if [[ "$ts_ip" != "n/a" ]]; then
            echo "SSH:       ssh $host_user@$session_name" >&2
        fi
    fi
}

sandbox_list() {
    log_info "Agent sandbox containers:"
    docker ps -a \
        --filter "label=agent-sandbox" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Label "agent-sandbox.dir"}}'
}

sandbox_prune() {
    log_info "Removing all stopped agent-sandbox containers..."
    while IFS= read -r container_name; do
        [[ -z "$container_name" ]] && continue
        _sandbox_log_event "$container_name" "prune_stopped" "reason=sandbox_prune"
    done < <(docker ps -a --filter "label=agent-sandbox" --filter "status=exited" --format '{{.Names}}')
    docker container prune -f --filter "label=agent-sandbox"
}

sandbox_rebuild_and_restart() {
    local no_cache="${1:-0}"
    local running_info
    running_info=$(docker ps --filter "label=agent-sandbox" --format '{{.Names}}	{{.Label "agent-sandbox.dir"}}')

    log_info "Removing all running agent-sandbox containers..."
    if [[ -z "$running_info" ]]; then
        log_info "No running agent-sandbox containers found."
    else
        while IFS=$'\t' read -r container_name _dir; do
            [[ -z "$container_name" ]] && continue
            log_info "Removing '$container_name'..."
            _sandbox_log_event "$container_name" "remove_rebuild" "reason=rebuild_and_restart"
            docker rm -f "$container_name" >/dev/null
        done <<< "$running_info"
    fi

    sandbox_build_image "$no_cache"

    if [[ -n "$running_info" ]]; then
        log_info "Starting previously running sandboxes..."
        while IFS=$'\t' read -r container_name dir; do
            [[ -z "$dir" ]] && continue
            log_info "Starting sandbox for '$dir'..."
            sandbox_start "$container_name" "$dir"
        done <<< "$(printf '%s\n' "$running_info" | awk -F '\t' '!seen[$2]++')"
    fi
}

sandbox_identity_init() {
    log_info "Initializing sandbox identity in '$SB_HOME'..."

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
        cat > "$_SB_SSH_DIR/config" <<EOF
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
        chmod 600 "$_SB_SSH_DIR/config"
    fi

    log_success "Sandbox identity ready."
    log_info "Public key: $_SB_SSH_DIR/id_ed25519.pub"
    log_info "Next steps:"
    log_info "  1) Add this key where needed (GitHub/GitLab as deploy or user key)."
    log_info "  2) Run am as usual; ~/.sb identity will be preferred over host-global secrets."
}
