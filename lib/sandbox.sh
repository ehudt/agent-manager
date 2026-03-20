# shellcheck shell=bash
# sandbox.sh - Container lifecycle functions for agent sandboxes

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_config_get)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t tmux_session_exists)" != "function" ]] && source "$SCRIPT_DIR/tmux.sh"
[[ "$(type -t sb_vol_ensure)" != "function" ]] && source "$SCRIPT_DIR/sb_volume.sh"

SANDBOX_DIR="${AM_SCRIPT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}/sandbox"
SANDBOX_IMAGE="agent-sandbox:persistent"
SANDBOX_ENV_FILE="$AM_DIR/sandbox.env"
SANDBOX_HOST_EXIT_CODE="${SANDBOX_HOST_EXIT_CODE:-42}"
SB_PRESETS_DEFAULT="${AM_SCRIPT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}/config/presets.json"
SB_PRESETS_USER="$AM_DIR/presets.json"

_SB_HOST_UID=""
_SB_HOST_GID=""

# shellcheck source=/dev/null
[[ -f "$SANDBOX_ENV_FILE" ]] && source "$SANDBOX_ENV_FILE"

_sandbox_ensure_host_identity() {
    [[ -n "$_SB_HOST_UID" ]] && return
    _SB_HOST_UID=$(id -u)
    _SB_HOST_GID=$(id -g)
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

_sandbox_wait_ready() {
    local session_name="$1"
    local timeout="${2:-30}"
    local waited=0

    while (( waited < timeout )); do
        if ! docker inspect "$session_name" >/dev/null 2>&1; then
            return 1
        fi
        if docker exec "$session_name" test -f /tmp/am-entrypoint-ready >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_warn "Sandbox '$session_name' did not signal readiness within ${timeout}s."
    return 1
}

# Build a docker exec command that runs a command inside the container directly.
# Unlike sandbox_enter_cmd (interactive shell + reconnect loop), this runs the
# given command via zsh -lc, avoiding race conditions with tty buffering.
# Usage: sandbox_exec_cmd <session-name> <directory> <command>
sandbox_exec_cmd() {
    local session_name="$1"
    local directory="$2"
    local cmd="$3"
    _sandbox_ensure_host_identity
    local target_dir="${directory:-$HOME}"
    local quoted_cmd
    printf -v quoted_cmd '%q' "$cmd"
    printf "%s" "docker exec -it -u ubuntu -w '$target_dir' -e 'HOST_UID=$_SB_HOST_UID' -e 'HOST_GID=$_SB_HOST_GID' -e 'TERM=\${TERM:-xterm-256color}' '$session_name' zsh -lc $quoted_cmd"
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
    local proxy_name net_name filter_file extra_hosts host
    proxy_name="$(_sandbox_proxy_name "$session_name")"
    net_name="$(_sandbox_net_name "$session_name")"

    docker network inspect "$net_name" >/dev/null 2>&1 || docker network create "$net_name" >/dev/null

    filter_file=$(mktemp)
    cat "$SANDBOX_DIR/tinyproxy-filter.txt" > "$filter_file"
    extra_hosts=$(am_config_get "sb_allowed_hosts")
    if [[ -n "$extra_hosts" && "$extra_hosts" != "null" ]]; then
        IFS=',' read -ra _hosts <<< "$extra_hosts"
        for host in "${_hosts[@]}"; do
            host=$(printf '%s' "$host" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [[ -n "$host" ]] && printf '^%s$\n' "$(printf '%s' "$host" | sed -E 's/\./\\./g')" >> "$filter_file"
        done
    fi

    docker rm -f "$proxy_name" >/dev/null 2>&1 || true
    docker run -d --name "$proxy_name" \
        --network "$net_name" \
        -v "$SANDBOX_DIR/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
        -v "$filter_file:/etc/tinyproxy/filter:ro" \
        --label "agent-sandbox-proxy=true" \
        --label "agent-sandbox.session=$session_name" \
        alpine:latest sh -c "apk add --no-cache tinyproxy >/dev/null 2>&1 && exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf" >/dev/null
    docker network connect bridge "$proxy_name" >/dev/null 2>&1 || true
    _sandbox_log_event "$session_name" "proxy_started" "proxy=$proxy_name network=$net_name"
}

_sandbox_stop_proxy() {
    local session_name="$1"
    docker rm -f "$(_sandbox_proxy_name "$session_name")" >/dev/null 2>&1 || true
    docker network rm "$(_sandbox_net_name "$session_name")" >/dev/null 2>&1 || true
    _sandbox_log_event "$session_name" "proxy_stopped"
}

SB_CONTAINER_HOME="/home/ubuntu"

_sb_expand_container_path() {
    local path="$1"
    # shellcheck disable=SC2088
    case "$path" in
        "~") printf '%s\n' "$SB_CONTAINER_HOME" ;;
        "~/"*) printf '%s/%s\n' "$SB_CONTAINER_HOME" "${path#"~/"}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

sb_expand_path() {
    local path="$1"
    # shellcheck disable=SC2088
    case "$path" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${path#"~/"}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

_sb_name_from_target() {
    local target="$1"
    target="${target##*/}"
    target="${target##.}"
    target=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
    target=$(printf '%s' "$target" | sed -E 's#[/[:space:]]+#-#g; s/^-+//; s/-+$//')
    printf '%s\n' "$target"
}

_sb_manifest_json() {
    sb_vol_read mappings.json
}

_sb_manifest_write() {
    local json="$1"
    printf '%s\n' "$json" | sb_vol_write mappings.json
}

_sb_mapping_get() {
    local name="$1"
    _sb_manifest_json | jq -c --arg name "$name" '.mappings[] | select(.name == $name)'
}

_sb_mapping_exists() {
    local name="$1"
    _sb_manifest_json | jq -e --arg name "$name" '.mappings[] | select(.name == $name)' >/dev/null
}

_sb_mapping_remove_data() {
    local mapping_json="$1"
    local source
    source=$(jq -r '.source' <<< "$mapping_json")
    [[ -n "$source" && "$source" != "null" ]] && sb_vol_rm "data/$source"
}

_sb_presets_json() {
    local sources=()
    [[ -f "$SB_PRESETS_DEFAULT" ]] && sources+=("$SB_PRESETS_DEFAULT")
    [[ -f "$SB_PRESETS_USER" ]] && sources+=("$SB_PRESETS_USER")
    if [[ ${#sources[@]} -eq 0 ]]; then
        echo '{}'
        return 0
    fi
    jq -s 'reduce .[] as $item ({}; . * $item)' "${sources[@]}"
}

_sb_share_spec_parse() {
    local spec="$1"
    local host="$spec" target="" mode="ro"

    if [[ "$spec" == *:* ]]; then
        local tail="${spec##*:}"
        local prefix="${spec%:*}"
        if [[ "$tail" == "ro" || "$tail" == "rw" ]]; then
            mode="$tail"
            if [[ "$prefix" == *:* ]]; then
                host="${prefix%%:*}"
                target="${prefix#*:}"
            else
                host="$prefix"
            fi
        else
            host="${spec%%:*}"
            target="${spec#*:}"
        fi
    fi

    host=$(sb_expand_path "$host")
    if [[ -z "$target" ]]; then
        target="$host"
    else
        target=$(_sb_expand_container_path "$target")
    fi
    printf '%s|%s|%s\n' "$host" "$target" "$mode"
}

_sb_collect_share_specs() {
    local cli_specs=("$@")
    local cfg raw parsed
    cfg=$(am_config_get "sandbox.shares")
    if [[ -n "$cfg" && "$cfg" != "null" ]]; then
        IFS=',' read -ra _cfg_specs <<< "$cfg"
        for raw in "${_cfg_specs[@]}"; do
            raw=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [[ -n "$raw" ]] && cli_specs=("$raw" "${cli_specs[@]}")
        done
    fi

    for raw in "${cli_specs[@]}"; do
        [[ -z "$raw" ]] && continue
        parsed=$(_sb_share_spec_parse "$raw")
        printf '%s\n' "$parsed"
    done
}

sb_build() {
    local no_cache="${1:-0}"
    if [[ "$no_cache" == "1" ]]; then
        docker build --no-cache -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    else
        docker build -t "$SANDBOX_IMAGE" "$SANDBOX_DIR"
    fi
}

sandbox_start() {
    local session_name="$1"
    local directory="$2"
    shift 2 || true
    local share_specs=("$@")
    _sandbox_ensure_host_identity
    _sandbox_log_event "$session_name" "start_requested" "directory=$directory"

    if [[ ! -d "$directory" ]]; then
        log_error "Sandbox directory does not exist: $directory"
        _sandbox_log_event "$session_name" "start_failed" "reason=missing_directory directory=$directory"
        return 1
    fi

    if ! docker image inspect "$SANDBOX_IMAGE" >/dev/null 2>&1; then
        log_info "Building sandbox image..."
        sb_build 0 || return 1
    fi

    sb_vol_ensure

    local state
    state=$(docker inspect -f '{{.State.Running}}' "$session_name" 2>/dev/null) || state=""
    if [[ "$state" == "true" ]]; then
        log_info "Sandbox '$session_name' already running."
        return 0
    elif [[ -n "$state" ]]; then
        docker rm -f "$session_name" >/dev/null 2>&1 || true
    fi

    local sb_unsafe_root
    local sb_pids_limit sb_memory_limit sb_cpus_limit sb_network_restrict
    sb_unsafe_root="${SB_UNSAFE_ROOT:-0}"
    sb_pids_limit="${SB_PIDS_LIMIT:-512}"
    sb_memory_limit="${SB_MEMORY_LIMIT:-4g}"
    sb_cpus_limit="${SB_CPUS_LIMIT:-2.0}"
    if am_sb_network_restrict_enabled; then sb_network_restrict=1; else sb_network_restrict=0; fi

    if [[ "$sb_network_restrict" == "1" ]]; then
        _sandbox_start_proxy "$session_name"
    fi

    local -a mounts
    mounts=(-v "$SB_STATE_VOLUME:/home/ubuntu/.am-state" -v "$directory:$directory")

    local parsed share_host share_target share_mode
    while IFS= read -r parsed; do
        [[ -z "$parsed" ]] && continue
        IFS='|' read -r share_host share_target share_mode <<< "$parsed"
        [[ -e "$share_host" ]] || { log_warn "Skipping missing share: $share_host"; continue; }
        mounts+=(-v "$share_host:$share_target:$share_mode")
    done < <(_sb_collect_share_specs "${share_specs[@]}")

    local -a env_vars=(
        -e "TERM=${TERM:-xterm-256color}"
        -e "SANDBOX_NAME=$session_name"
        -e "HOST_UID=$_SB_HOST_UID"
        -e "HOST_GID=$_SB_HOST_GID"
        -e "SB_UNSAFE_ROOT=$sb_unsafe_root"
    )
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_vars+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")

    local -a run_opts=(
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
        run_opts+=(--security-opt no-new-privileges:true)
    fi
    if [[ "$sb_network_restrict" == "1" ]]; then
        local proxy_name
        proxy_name="$(_sandbox_proxy_name "$session_name")"
        run_opts+=(--network "$(_sandbox_net_name "$session_name")")
        env_vars+=(
            -e "HTTP_PROXY=http://${proxy_name}:8888"
            -e "HTTPS_PROXY=http://${proxy_name}:8888"
            -e "http_proxy=http://${proxy_name}:8888"
            -e "https_proxy=http://${proxy_name}:8888"
            -e "NO_PROXY=localhost,127.0.0.1"
            -e "no_proxy=localhost,127.0.0.1"
        )
    fi

    if docker run -d \
        --name "$session_name" \
        --hostname "$session_name" \
        --label "agent-sandbox=true" \
        --label "agent-sandbox.session=$session_name" \
        --label "agent-sandbox.dir=$directory" \
        "${run_opts[@]}" \
        "${env_vars[@]}" \
        "${mounts[@]}" \
        "$SANDBOX_IMAGE" >/dev/null; then
        _sandbox_wait_ready "$session_name" || {
            _sandbox_log_event "$session_name" "start_failed" "reason=not_ready image=$SANDBOX_IMAGE directory=$directory"
            return 1
        }
        _sandbox_log_event "$session_name" "started" "image=$SANDBOX_IMAGE directory=$directory"
        return 0
    fi

    _sandbox_log_event "$session_name" "start_failed" "image=$SANDBOX_IMAGE directory=$directory"
    [[ "$sb_network_restrict" == "1" ]] && _sandbox_stop_proxy "$session_name"
    return 1
}

sandbox_enter_cmd() {
    local session_name="$1"
    local directory="${2:-$HOME}"
    local host_exit_code="${SANDBOX_HOST_EXIT_CODE:-42}"
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/sandbox-shell"
    printf '%q %q %q %q' "$script_path" "$session_name" "$directory" "$host_exit_code"
}

sandbox_remove() {
    local session_name="$1"
    docker rm -f "$session_name" >/dev/null 2>&1 || true
    _sandbox_stop_proxy "$session_name"
    _sandbox_log_event "$session_name" "remove" "reason=explicit_remove"
}

sandbox_gc_orphans() {
    local container_name removed=()
    while IFS= read -r container_name; do
        [[ -z "$container_name" ]] && continue
        if ! tmux_session_exists "$container_name"; then
            removed+=("$container_name")
            sandbox_remove "$container_name"
        fi
    done < <(_sandbox_list_containers)
    echo "${#removed[@]}"
}

sandbox_status() {
    local session_name="$1"
    local state dir event_log
    event_log="$(_sandbox_event_log_path "$session_name")"
    if ! state=$(docker inspect -f '{{.State.Status}}' "$session_name" 2>/dev/null); then
        log_error "Sandbox not found: $session_name"
        return 1
    fi
    dir=$(docker inspect -f '{{index .Config.Labels "agent-sandbox.dir"}}' "$session_name" 2>/dev/null || echo "n/a")
    cat <<EOF2
Sandbox: $session_name
State: $state
Directory: $dir
State volume: $SB_STATE_VOLUME
Event log: $event_log
EOF2
}

sandbox_enter() {
    local session_name="$1"
    local directory="${2:-$(docker inspect -f '{{index .Config.Labels "agent-sandbox.dir"}}' "$session_name" 2>/dev/null)}"
    if [[ -z "$directory" ]]; then
        log_error "Sandbox not found: $session_name"
        return 1
    fi
    local enter_cmd
    enter_cmd=$(sandbox_enter_cmd "$session_name" "$directory")
    exec bash -lc "$enter_cmd"
}

sb_ps() {
    docker ps -a --filter "label=agent-sandbox" --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Label "agent-sandbox.dir"}}'
}

sb_prune() {
    local container_name count=0
    while IFS= read -r container_name; do
        [[ -z "$container_name" ]] && continue
        _sandbox_log_event "$container_name" "prune" "reason=sb_prune"
        docker rm -f "$container_name" >/dev/null 2>&1 || true
        _sandbox_stop_proxy "$container_name"
        count=$((count + 1))
    done < <(_sandbox_list_containers)
    if (( count > 0 )); then
        log_info "Removed $count sandbox container(s)"
    else
        log_info "No sandbox containers to remove"
    fi
}

sb_reset() {
    local confirm="${1:-0}"
    if [[ "$confirm" != "1" ]]; then
        log_error "Refusing to reset state volume without confirmation. Use: am sb reset --confirm"
        return 1
    fi
    docker volume rm -f "$SB_STATE_VOLUME" >/dev/null 2>&1 || true
    sb_vol_ensure
    log_success "Reset sandbox state volume '$SB_STATE_VOLUME'."
}

sb_export() {
    local output_path="$1"
    local out_dir out_name
    out_dir=$(dirname "$output_path")
    out_name=$(basename "$output_path")
    mkdir -p "$out_dir"
    sb_vol_ensure
    docker run --rm -v "${SB_STATE_VOLUME}:/state" -v "$out_dir:/out" alpine sh -lc "tar czf /out/$out_name -C /state ."
}

sb_import() {
    local input_path="$1"
    local confirm="${2:-0}"
    local in_dir in_name
    [[ -f "$input_path" ]] || { log_error "Import archive not found: $input_path"; return 1; }
    if [[ "$confirm" != "1" ]]; then
        log_error "Refusing to import without confirmation. Use: am sb import <path> --confirm"
        return 1
    fi
    in_dir=$(dirname "$input_path")
    in_name=$(basename "$input_path")
    docker volume rm -f "$SB_STATE_VOLUME" >/dev/null 2>&1 || true
    sb_vol_ensure
    docker run --rm -v "${SB_STATE_VOLUME}:/state" -v "$in_dir:/in" alpine sh -lc "rm -rf /state/* /state/.[!.]* /state/..?* 2>/dev/null || true; tar xzf /in/$in_name -C /state"
}

sb_shell() {
    local mount_args=(-v "${SB_STATE_VOLUME}:/state")
    local repo_root
    if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
        mount_args+=(-v "$repo_root:$repo_root" -w "$repo_root")
    fi
    exec docker run --rm -it "${mount_args[@]}" alpine sh
}

sb_unmap() {
    local name="$1"
    local keep_data="${2:-0}"
    sb_vol_ensure
    local mapping_json
    mapping_json=$(_sb_mapping_get "$name")
    if [[ -z "$mapping_json" ]]; then
        log_error "Mapping not found: $name"
        return 1
    fi

    local manifest
    manifest=$(_sb_manifest_json | jq --arg name "$name" 'del(.mappings[] | select(.name == $name))')
    _sb_manifest_write "$manifest"
    if [[ "$keep_data" != "1" ]]; then
        _sb_mapping_remove_data "$mapping_json"
    fi
    log_success "Unmapped '$name'."
}

_sb_map_single() {
    local host_path="$1"
    local target_path="$2"
    local name="$3"
    local mode="$4"
    local description="$5"
    local expanded_host manifest entry src_path

    # Normalize target to ~/... so the entrypoint resolves it to the container home.
    # shellcheck disable=SC2088
    if [[ "$target_path" == "$HOME/"* ]]; then
        target_path="~/${target_path#"$HOME/"}"
    elif [[ "$target_path" == "$HOME" ]]; then
        target_path="~"
    fi

    expanded_host=$(sb_expand_path "$host_path")
    [[ -e "$expanded_host" ]] || { log_error "Host path not found: $expanded_host"; return 1; }

    sb_vol_ensure
    if _sb_mapping_exists "$name"; then
        log_error "Mapping '$name' already exists. Use 'am sb sync $name' or 'am sb unmap $name' first."
        return 1
    fi

    src_path="$name"
    sb_vol_copy_in "$expanded_host" "data/$src_path"

    entry=$(jq -n \
        --arg name "$name" \
        --arg source "$src_path" \
        --arg target "$target_path" \
        --arg host_source "$host_path" \
        --arg mode "$mode" \
        --arg description "$description" \
        '{name: $name, source: $source, target: $target, host_source: $host_source}
         + (if $mode != "" then {mode: $mode} else {} end)
         + (if $description != "" then {description: $description} else {} end)')
    manifest=$(_sb_manifest_json | jq --argjson entry "$entry" '.mappings += [$entry]')
    _sb_manifest_write "$manifest"
    printf 'Mapped %s → %s (as '\''%s'\'')\n' "$host_path" "$target_path" "$name"
}

sb_map() {
    local host_path=""
    local target_path=""
    local name=""
    local mode=""
    local preset=""
    local list_presets=0
    local description=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)
                target_path="$2"
                shift 2
                ;;
            --name)
                name="$2"
                shift 2
                ;;
            --mode)
                mode="$2"
                shift 2
                ;;
            --description)
                description="$2"
                shift 2
                ;;
            --preset)
                preset="$2"
                shift 2
                ;;
            --list-presets)
                list_presets=1
                shift
                ;;
            -h|--help)
                echo "Usage: am sb map <host-path> --to <container-path> [--name <id>] [--mode 0700]"
                echo "       am sb map --preset <preset-name>"
                echo "       am sb map --list-presets"
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$host_path" ]]; then
                    host_path="$1"
                    shift
                else
                    log_error "Unexpected argument: $1"
                    return 1
                fi
                ;;
        esac
    done

    if [[ "$list_presets" == "1" ]]; then
        _sb_presets_json | jq -r 'to_entries[] | .key as $name | "PRESET\t\($name)", (.value[] | "  - \(.host) -> \(.target) [\(.name)]")'
        return 0
    fi

    if [[ -n "$preset" ]]; then
        local preset_json
        preset_json=$(_sb_presets_json | jq -c --arg preset "$preset" '.[$preset] // empty')
        if [[ -z "$preset_json" ]]; then
            log_error "Unknown preset: $preset"
            return 1
        fi
        local item item_host item_target item_name item_mode item_description
        while IFS= read -r item; do
            item_host=$(jq -r '.host' <<< "$item")
            item_target=$(jq -r '.target' <<< "$item")
            item_name=$(jq -r '.name // empty' <<< "$item")
            item_mode=$(jq -r '.mode // empty' <<< "$item")
            item_description=$(jq -r '.description // empty' <<< "$item")
            [[ -n "$item_name" ]] || item_name=$(_sb_name_from_target "$item_target")
            if [[ ! -e "$(sb_expand_path "$item_host")" ]]; then
                log_info "Skipping missing preset mapping: $item_host"
                continue
            fi
            _sb_map_single "$item_host" "$item_target" "$item_name" "$item_mode" "$item_description"
        done < <(jq -c '.[]' <<< "$preset_json")
        return 0
    fi

    [[ -n "$host_path" ]] || { log_error "Host path required"; return 1; }
    [[ -n "$target_path" ]] || { log_error "Container target required (use --to)"; return 1; }
    [[ -n "$name" ]] || name=$(_sb_name_from_target "$target_path")
    _sb_map_single "$host_path" "$target_path" "$name" "$mode" "$description"
}

sb_maps() {
    sb_vol_ensure
    local rows
    rows=$(_sb_manifest_json | jq -r '.mappings[]? | [(.name // ""), (.target // ""), (.host_source // ""), (.description // "")] | @tsv')
    if [[ -z "$rows" ]]; then
        echo "No mappings configured. Use 'am sb map <path> --to <target>' to add one."
        return 0
    fi
    printf '%-15s %-22s %-22s %s\n' "NAME" "TARGET" "HOST SOURCE" "DESCRIPTION"
    while IFS=$'\t' read -r name target host_source description; do
        printf '%-15s %-22s %-22s %s\n' "$name" "$target" "$host_source" "$description"
    done <<< "$rows"
}

sb_sync() {
    local name=""
    local sync_all=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                sync_all=1
                shift
                ;;
            -h|--help)
                echo "Usage: am sb sync <name> | am sb sync --all"
                return 0
                ;;
            *)
                name="$1"
                shift
                ;;
        esac
    done

    sb_vol_ensure
    local item host_source source entry_name count=0
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        entry_name=$(jq -r '.name' <<< "$item")
        if [[ "$sync_all" != "1" && "$entry_name" != "$name" ]]; then
            continue
        fi
        host_source=$(jq -r '.host_source // empty' <<< "$item")
        source=$(jq -r '.source' <<< "$item")
        if [[ -z "$host_source" ]]; then
            log_error "Mapping '$entry_name' has no host_source; cannot sync."
            [[ "$sync_all" == "1" ]] && continue || return 1
        fi
        host_source=$(sb_expand_path "$host_source")
        [[ -e "$host_source" ]] || { log_error "Host source missing for '$entry_name': $host_source"; [[ "$sync_all" == "1" ]] && continue || return 1; }
        sb_vol_copy_in "$host_source" "data/$source"
        printf 'Synced %s from %s\n' "$entry_name" "$host_source"
        count=$((count + 1))
    done < <(_sb_manifest_json | jq -c '.mappings[]?')

    if [[ "$sync_all" != "1" && $count -eq 0 ]]; then
        log_error "Mapping not found: $name"
        return 1
    fi
}

sb_edit() {
    local name="$1"
    local editor="${EDITOR:-vi}"
    sb_vol_ensure
    local mapping_json source tmp_path
    mapping_json=$(_sb_mapping_get "$name")
    if [[ -z "$mapping_json" ]]; then
        log_error "Mapping not found: $name"
        return 1
    fi
    source=$(jq -r '.source' <<< "$mapping_json")
    tmp_path=$(mktemp -d)
    docker run --rm -v "${SB_STATE_VOLUME}:/state" -v "$tmp_path:/tmp-edit" alpine sh -lc "cp -a /state/data/$source /tmp-edit/item"
    "$editor" "$tmp_path/item"
    docker run --rm -v "${SB_STATE_VOLUME}:/state" -v "$tmp_path:/tmp-edit" alpine sh -lc "rm -rf /state/data/$source && cp -a /tmp-edit/item /state/data/$source"
    rm -rf "$tmp_path"
}
