# sandbox.sh - Container lifecycle functions for agent sandboxes

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

SANDBOX_DIR="$AM_SCRIPT_DIR/sandbox"
SANDBOX_IMAGE="agent-sandbox:persistent"
SANDBOX_ENV_FILE="$AM_DIR/sandbox.env"
SANDBOX_HOST_EXIT_CODE="${SANDBOX_HOST_EXIT_CODE:-42}"
SB_HOME="${SB_HOME:-$HOME/.sb}"
# Lazy-init host identity (avoid 3 subprocess spawns at source time)
_SB_HOST_USER="" _SB_HOST_UID="" _SB_HOST_GID=""
_sandbox_ensure_host_identity() {
    [[ -n "$_SB_HOST_USER" ]] && return
    _SB_HOST_USER=$(id -un)
    _SB_HOST_UID=$(id -u)
    _SB_HOST_GID=$(id -g)
}

[[ -f "$SANDBOX_ENV_FILE" ]] && source "$SANDBOX_ENV_FILE"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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

_sandbox_proxy_name() {
    echo "${1}-proxy"
}

_sandbox_net_name() {
    echo "${1}-net"
}

_sandbox_start_proxy() {
    local session_name="$1"
    local proxy_name net_name filter_file
    proxy_name="$(_sandbox_proxy_name "$session_name")"
    net_name="$(_sandbox_net_name "$session_name")"

    log_info "Creating isolated network '$net_name'..." >&2
    docker network create "$net_name" >/dev/null

    # Build filter file: default list + any extra hosts from config
    filter_file=$(mktemp)
    cat "$SANDBOX_DIR/tinyproxy-filter.txt" > "$filter_file"
    local extra_hosts
    extra_hosts=$(am_config_get "sb_allowed_hosts")
    if [[ -n "$extra_hosts" ]]; then
        local host
        while IFS=',' read -ra _hosts; do
            for host in "${_hosts[@]}"; do
                host=$(echo "$host" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
                [[ -n "$host" ]] && printf '^%s$\n' "$(sed -E 's/\./\\./g' <<<"$host")" >> "$filter_file"
            done
        done <<<"$extra_hosts"
    fi

    log_info "Starting proxy '$proxy_name'..." >&2
    docker run -d --name "$proxy_name" \
        --network "$net_name" \
        -v "$SANDBOX_DIR/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
        -v "$filter_file:/etc/tinyproxy/filter:ro" \
        --label "agent-sandbox-proxy=true" \
        --label "agent-sandbox.session=$session_name" \
        alpine:latest sh -c "apk add --no-cache tinyproxy >/dev/null 2>&1 && exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf" >/dev/null

    # Connect proxy to bridge so it can reach the internet
    docker network connect bridge "$proxy_name"

    _sandbox_log_event "$session_name" "proxy_started" "proxy=$proxy_name network=$net_name"
}

_sandbox_stop_proxy() {
    local session_name="$1"
    local proxy_name net_name
    proxy_name="$(_sandbox_proxy_name "$session_name")"
    net_name="$(_sandbox_net_name "$session_name")"

    docker rm -f "$proxy_name" >/dev/null 2>&1 || true
    docker network rm "$net_name" >/dev/null 2>&1 || true
    _sandbox_log_event "$session_name" "proxy_stopped" "proxy=$proxy_name network=$net_name"
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

_sandbox_needs_refresh() {
    local container_name="$1"

    # Check required capabilities
    for capability in CHOWN DAC_OVERRIDE FOWNER; do
        if ! _sandbox_container_has_cap "$container_name" "$capability"; then
            log_info "Refreshing sandbox '$container_name': missing CAP_$capability required by the entrypoint."
            return 0
        fi
    done

    # Check the two expected mounts are present
    if ! _sandbox_container_has_mount "$container_name" "$HOME"; then
        log_info "Refreshing sandbox '$container_name': missing home mount at $HOME."
        return 0
    fi

    if ! _sandbox_container_has_mount "$container_name" "$HOME/workspace"; then
        log_info "Refreshing sandbox '$container_name': missing workspace mount at $HOME/workspace."
        return 0
    fi

    return 1
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
    _sandbox_ensure_host_identity
    _sandbox_log_event "$session_name" "start_requested" "directory=$directory"

    if [[ ! -d "$directory" ]]; then
        log_error "Sandbox directory does not exist: $directory"
        _sandbox_log_event "$session_name" "start_failed" "reason=missing_directory directory=$directory"
        return 1
    fi

    if ! docker image inspect "$SANDBOX_IMAGE" &>/dev/null; then
        log_info "Building sandbox image..."
        _sandbox_log_event "$session_name" "image_build" "image=$SANDBOX_IMAGE"
        docker build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR" || return 1
    fi

    # Auto-create .sb if missing — first sandbox generates credentials here
    if [[ ! -d "$SB_HOME" ]]; then
        log_info "Sandbox home not found. Initializing $SB_HOME/..."
        sandbox_identity_init
    fi

    local state
    state=$(docker inspect -f '{{.State.Running}}' "$session_name" 2>/dev/null) || state=""

    if [[ "$state" == "true" ]]; then
        if _sandbox_needs_refresh "$session_name"; then
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

    local sb_enable_tailscale enable_ssh ts_enable_ssh sb_unsafe_root
    local sb_pids_limit sb_memory_limit sb_cpus_limit sb_network_restrict
    sb_enable_tailscale="${SB_ENABLE_TAILSCALE:-1}"
    enable_ssh="${ENABLE_SSH:-0}"
    ts_enable_ssh="${TS_ENABLE_SSH:-1}"
    sb_unsafe_root="${SB_UNSAFE_ROOT:-0}"
    sb_pids_limit="${SB_PIDS_LIMIT:-512}"
    sb_memory_limit="${SB_MEMORY_LIMIT:-4g}"
    sb_cpus_limit="${SB_CPUS_LIMIT:-2.0}"
    if am_sb_network_restrict_enabled; then
        sb_network_restrict=1
    else
        sb_network_restrict=0
    fi

    # Network restriction conflicts with Tailscale — prefer restriction
    if [[ "$sb_network_restrict" == "1" && "$sb_enable_tailscale" == "1" ]]; then
        log_warn "sb_network_restrict=true disables Tailscale (container has no direct network). Set 'am config set sb_network_restrict false' to use Tailscale."
        sb_enable_tailscale=0
    fi

    # Start proxy sidecar if network restriction is enabled
    if [[ "$sb_network_restrict" == "1" ]]; then
        _sandbox_start_proxy "$session_name"
    fi

    # Two mounts: workspace at ~/workspace, and .sb as home (shared credentials/config)
    local MOUNTS=(
        -v "$directory:$HOME/workspace"
        -v "$SB_HOME:$HOME"
    )

    local ENV_VARS=(
        -e "TERM=${TERM:-xterm-256color}"
        -e "SANDBOX_NAME=$session_name"
        -e "HOST_USER=$_SB_HOST_USER"
        -e "HOST_UID=$_SB_HOST_UID"
        -e "HOST_GID=$_SB_HOST_GID"
        -e "HOST_HOME=$HOME"
        -e "SB_ENABLE_TAILSCALE=$sb_enable_tailscale"
        -e "ENABLE_SSH=$enable_ssh"
        -e "TS_ENABLE_SSH=$ts_enable_ssh"
        -e "SB_UNSAFE_ROOT=$sb_unsafe_root"
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

    log_info "Mounts: workspace=$directory -> ~/workspace, home=$SB_HOME -> ~"

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
    if [[ "$sb_enable_tailscale" == "1" && -z "${TS_AUTHKEY:-}" ]]; then
        log_warn "SB_ENABLE_TAILSCALE=1 but TS_AUTHKEY is unset; tailscale will not connect."
    fi
    if [[ "$sb_enable_tailscale" != "1" && "$ts_enable_ssh" == "1" ]]; then
        log_warn "TS_ENABLE_SSH=1 ignored because SB_ENABLE_TAILSCALE=0."
    fi
    if [[ "$sb_network_restrict" == "1" ]]; then
        local proxy_name
        proxy_name="$(_sandbox_proxy_name "$session_name")"
        RUN_OPTS+=(--network "$(_sandbox_net_name "$session_name")")
        ENV_VARS+=(
            -e "HTTP_PROXY=http://${proxy_name}:8888"
            -e "HTTPS_PROXY=http://${proxy_name}:8888"
            -e "http_proxy=http://${proxy_name}:8888"
            -e "https_proxy=http://${proxy_name}:8888"
            -e "NO_PROXY=localhost,127.0.0.1"
            -e "no_proxy=localhost,127.0.0.1"
        )
    fi
    log_info "Runtime modes: tailscale=$sb_enable_tailscale tailscale_ssh=$ts_enable_ssh sshd=$enable_ssh unsafe_root=$sb_unsafe_root network_restrict=$sb_network_restrict"

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
        log_info "SSH: ssh $_SB_HOST_USER@$session_name"
    fi
}

sandbox_attach_cmd() {
    local session_name="$1"
    local directory="$2"
    sandbox_enter_cmd "$session_name" "$directory"
}

sandbox_enter_cmd() {
    local session_name="$1"
    local directory="${2:-}"
    _sandbox_ensure_host_identity
    local event_log enter_cmd target_dir host_exit_code
    event_log="$(_sandbox_event_log_path "$session_name")"
    # Workspace is always at ~/workspace in the container; fall back to $PWD for custom enters
    target_dir="${directory:-$HOME/workspace}"
    host_exit_code="${SANDBOX_HOST_EXIT_CODE}"
    enter_cmd="docker exec -it -u '$_SB_HOST_USER' -w '$target_dir' -e 'HOST_UID=$_SB_HOST_UID' -e 'HOST_GID=$_SB_HOST_GID' -e 'TERM=\${TERM:-xterm-256color}' '$session_name' zsh"
    printf "%s" "_am_sandbox_enter() { $enter_cmd; }; while true; do _am_sandbox_enter; _am_rc=\$?; if ! docker inspect '$session_name' >/dev/null 2>&1; then printf '\\n[am] sandbox %s is gone; you are now on the host shell.\\n[am] inspect: ./am sandbox status %s\\n[am] events: %s\\n' '$session_name' '$session_name' '$event_log'; break; fi; if [[ \$_am_rc -eq $host_exit_code ]]; then printf '\\n[am] leaving sandbox %s and staying on the host shell.\\n' '$session_name'; printf '[am] re-enter later: ./am sandbox enter $session_name\\n'; break; fi; if [[ \$_am_rc -eq 0 ]]; then printf '\\n[am] sandbox shell exited for %s; reconnecting...\\n' '$session_name'; else printf '\\n[am] sandbox shell exited (status %s) for %s; reconnecting...\\n' \"\$_am_rc\" '$session_name'; fi; printf '[am] to stay on the host shell, run: exit $host_exit_code\\n'; printf '[am] re-enter manually: ./am sandbox enter $session_name\\n'; sleep 1; done"
}

sandbox_remove() {
    local session_name="$1"
    if docker rm -f "$session_name" >/dev/null 2>&1; then
        _sandbox_log_event "$session_name" "remove" "reason=explicit_remove"
        log_info "Removed sandbox '$session_name'."
    fi
    _sandbox_stop_proxy "$session_name"
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
    if docker stop "$session_name" >/dev/null 2>&1; then
        _sandbox_log_event "$session_name" "stop" "reason=explicit_stop"
        log_info "Stopped sandbox '$session_name'."
    fi
}

sandbox_status() {
    local session_name="$1"
    _sandbox_ensure_host_identity
    local state ts_ip
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
        echo "Tailscale: $ts_ip" >&2
        if [[ "$ts_ip" != "n/a" ]]; then
            echo "SSH:       ssh $_SB_HOST_USER@$session_name" >&2
        fi
    fi
}

sandbox_enter() {
    local session_name="$1"
    local directory="${2:-}"
    local state
    if ! state=$(docker inspect -f '{{.State.Status}}' "$session_name" 2>/dev/null); then
        log_error "Sandbox not found: $session_name"
        return 1
    fi
    if [[ "$state" != "running" ]]; then
        log_error "Sandbox '$session_name' is not running (status: $state)"
        return 1
    fi

    local enter_cmd
    enter_cmd=$(sandbox_enter_cmd "$session_name" "$directory")
    eval "$enter_cmd"
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
    log_info "Initializing sandbox home in '$SB_HOME'..."

    mkdir -p "$SB_HOME"
    chmod 700 "$SB_HOME"

    local ssh_dir="$SB_HOME/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ ! -f "$ssh_dir/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -C "sb@$(hostname)" >&2
    fi
    chmod 600 "$ssh_dir/id_ed25519"
    chmod 644 "$ssh_dir/id_ed25519.pub"

    # Copy known_hosts from host if present
    [[ -f "$HOME/.ssh/known_hosts" && ! -f "$ssh_dir/known_hosts" ]] && \
        cp "$HOME/.ssh/known_hosts" "$ssh_dir/known_hosts"
    [[ -f "$ssh_dir/known_hosts" ]] && chmod 644 "$ssh_dir/known_hosts"

    if [[ ! -f "$ssh_dir/config" ]]; then
        cat > "$ssh_dir/config" <<EOF
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
        chmod 600 "$ssh_dir/config"
    fi

    log_success "Sandbox home ready at $SB_HOME"
    log_info "Public key: $ssh_dir/id_ed25519.pub"
    log_info "Next steps:"
    log_info "  1) Add this key where needed (GitHub/GitLab as deploy or user key)."
    log_info "  2) Run am as usual; sandboxes share this identity and any credentials in $SB_HOME."
}
