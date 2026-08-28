# shellcheck shell=bash
# recovery.sh - Durable desired sessions and reboot recovery coordination

_RECOVERY_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "${AM_DIR:-}" ]] && source "$_RECOVERY_LIB_DIR/utils.sh"
[[ "$(type -t _registry_lock)" != "function" ]] && source "$_RECOVERY_LIB_DIR/registry.sh"

_recovery_store_path() {
    printf '%s\n' "${AM_DESIRED_SESSIONS:-$AM_DIR/desired_sessions.json}"
}

_recovery_identity_dir() {
    printf '%s\n' "${AM_IDENTITY_DIR:-$AM_DIR/identities}"
}

recovery_current_boot_id() {
    if [[ -n "${AM_BOOT_ID:-}" ]]; then
        printf '%s\n' "$AM_BOOT_ID"
        return
    fi

    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        command cat /proc/sys/kernel/random/boot_id
        return
    fi

    local boot
    boot=$(sysctl -n kern.boottime 2>/dev/null || true)
    if [[ "$boot" =~ sec[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
        printf 'darwin-%s\n' "${BASH_REMATCH[1]}"
        return
    fi

    return 1
}

recovery_current_machine_id() {
    if [[ -n "${AM_MACHINE_ID:-}" ]]; then
        printf '%s\n' "$AM_MACHINE_ID"
        return
    fi

    if [[ -r /etc/machine-id ]]; then
        command cat /etc/machine-id
        return
    fi

    local machine
    machine=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
        | awk -F'"' '/IOPlatformUUID/{print $(NF-1); exit}' || true)
    if [[ -n "$machine" ]]; then
        printf '%s\n' "$machine"
        return
    fi

    hostname
}

recovery_desired_init() {
    local store
    store=$(_recovery_store_path)
    if [[ "${_RECOVERY_DESIRED_INITIALIZED:-}" == "$store" && -f "$store" ]]; then
        return 0
    fi
    mkdir -p "$AM_DIR" "$(_recovery_identity_dir)"

    _registry_lock
    if [[ ! -f "$store" ]]; then
        printf '{"schema_version":1,"next_order":1,"sessions":{}}\n' > "$store"
    elif ! jq -e '.schema_version == 1 and (.sessions | type == "object")' "$store" >/dev/null 2>&1; then
        _registry_unlock
        log_error "Desired-session store is invalid: $store"
        return 1
    fi
    _registry_unlock
    _RECOVERY_DESIRED_INITIALIZED="$store"
}

# Record a successfully launched logical session as desired-open.
# Usage: recovery_desired_upsert <name> <project_dir> <agent> <task> <yolo>
#        <sandbox> <worktree_name> <effective_dir> <worktree_host_path> <shares_json>
recovery_desired_upsert() {
    local name="$1" directory="$2" agent="$3" task="$4"
    local yolo="$5" sandbox="$6" worktree_name="$7"
    local effective_dir="$8" worktree_host_path="$9" shares_json="${10:-[]}"
    recovery_desired_init || return 1

    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$shares_json" || shares_json='[]'

    local store tmp created boot machine
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    boot=$(recovery_current_boot_id 2>/dev/null || true)
    machine=$(recovery_current_machine_id 2>/dev/null || true)

    _registry_lock
    if jq --arg id "$name" \
          --arg dir "$directory" \
          --arg agent "$agent" \
          --arg task "$task" \
          --arg yolo "$yolo" \
          --arg sandbox "$sandbox" \
          --arg wt_name "$worktree_name" \
          --arg effective_dir "$effective_dir" \
          --arg wt_host "$worktree_host_path" \
          --arg created "$created" \
          --arg boot "$boot" \
          --arg machine "$machine" \
          --argjson shares "$shares_json" '
        (.sessions[$id] // null) as $old |
        (.next_order // 1) as $next |
        .schema_version = 1 |
        .sessions[$id] = {
            logical_id: $id,
            session_name: $id,
            desired_state: "open",
            agent_type: $agent,
            project_directory: $dir,
            effective_directory: $effective_dir,
            task: $task,
            yolo_mode: $yolo,
            sandbox_mode: $sandbox,
            worktree_name: $wt_name,
            worktree_host_path: $wt_host,
            sandbox_shares: $shares,
            created_at: ($old.created_at // $created),
            order_key: ($old.order_key // $next),
            session_id: ($old.session_id // ""),
            transcript_path: ($old.transcript_path // ""),
            identity_source: ($old.identity_source // ""),
            launch_boot_id: $boot,
            machine_id: $machine,
            recovery_state: "live",
            recovery_error: "",
            last_attempt_boot: ""
        } |
        if $old == null then .next_order = ($next + 1) else . end
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi

    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_identity() {
    local name="$1" sid="$2" transcript="${3:-}" source="${4:-hook}"
    [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    recovery_desired_init || return 1

    local store tmp
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    _registry_lock
    if jq --arg id "$name" --arg sid "$sid" --arg transcript "$transcript" --arg source "$source" '
        if .sessions[$id] then
            .sessions[$id].session_id = $sid |
            .sessions[$id].transcript_path = $transcript |
            .sessions[$id].identity_source = $source
        else . end
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_set_status() {
    local name="$1" state="$2" error="${3:-}" attempt_boot="${4:-}"
    recovery_desired_init || return 1

    local store tmp
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    _registry_lock
    if jq --arg id "$name" --arg state "$state" --arg error "$error" --arg attempt "$attempt_boot" '
        if .sessions[$id] then
            .sessions[$id].recovery_state = $state |
            .sessions[$id].recovery_error = $error |
            if $attempt != "" then .sessions[$id].last_attempt_boot = $attempt else . end
        else . end
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_mark_live() {
    local name="$1" session_name="${2:-$1}"
    recovery_desired_init || return 1

    local store tmp boot
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    boot=$(recovery_current_boot_id 2>/dev/null || true)
    _registry_lock
    if jq --arg id "$name" --arg session "$session_name" --arg boot "$boot" '
        if .sessions[$id] then
            .sessions[$id].session_name = $session |
            .sessions[$id].launch_boot_id = $boot |
            .sessions[$id].recovery_state = "live" |
            .sessions[$id].recovery_error = "" |
            .sessions[$id].last_attempt_boot = $boot
        else . end
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_retry() {
    local name="$1"
    recovery_desired_init || return 1

    local store tmp
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    _registry_lock
    if jq --arg id "$name" '
        if .sessions[$id] then
            .sessions[$id].last_attempt_boot = "" |
            .sessions[$id].launch_boot_id = "manual-retry" |
            .sessions[$id].recovery_state = "pending" |
            .sessions[$id].recovery_error = ""
        else . end
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        rm -f "$AM_DIR/.recovery_boot_id"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_remove() {
    local name="$1"
    recovery_desired_init || return 1

    local store tmp
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    _registry_lock
    if jq --arg id "$name" 'del(.sessions[$id])' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_desired_is_open() {
    local name="$1"
    recovery_desired_init || return 1
    jq -e --arg id "$name" '.sessions[$id].desired_state == "open"' \
        "$(_recovery_store_path)" >/dev/null 2>&1
}

recovery_sync_identities() {
    recovery_desired_init || return 1
    local identity_dir sid_file name sid transcript
    identity_dir=$(_recovery_identity_dir)
    [[ -d "$identity_dir" ]] || return 0

    local -A current_sid=() current_transcript=()
    local current_name
    while IFS=$'\x1f' read -r current_name sid transcript; do
        [[ -n "$current_name" ]] || continue
        current_sid[$current_name]="$sid"
        current_transcript[$current_name]="$transcript"
    done < <(jq -r --arg us $'\x1f' '
        .sessions | to_entries[] |
        [.key, (.value.session_id // ""), (.value.transcript_path // "")] | join($us)
    ' "$(_recovery_store_path)" 2>/dev/null)

    for sid_file in "$identity_dir"/"${AM_SESSION_PREFIX}"*.sid; do
        [[ -f "$sid_file" ]] || continue
        name=$(basename "$sid_file" .sid)
        sid=""
        IFS= read -r sid < "$sid_file" 2>/dev/null || true
        [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        transcript=""
        if [[ -f "$identity_dir/$name.transcript" ]]; then
            IFS= read -r transcript < "$identity_dir/$name.transcript" 2>/dev/null || true
            if [[ "$transcript" == /home/ubuntu/* && ! -f "$transcript" ]]; then
                transcript="${SB_HOME_DIR:-$HOME/.agent-manager/sandbox-home}/${transcript#/home/ubuntu/}"
            fi
        fi
        if [[ "${current_sid[$name]:-}" == "$sid" \
            && "${current_transcript[$name]:-}" == "$transcript" ]]; then
            continue
        fi
        recovery_desired_identity "$name" "$sid" "$transcript" "hook" || true
    done
}

recovery_migrate_live_registry() {
    recovery_desired_init || return 1

    local name fields directory agent task yolo sandbox worktree_path worktree_host
    local effective worktree_name sid transcript identity_dir state_dir
    identity_dir=$(_recovery_identity_dir)
    state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    mkdir -p "$identity_dir"

    local -A desired_names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && desired_names[$name]=1
    done < <(jq -r '.sessions | keys[]' "$(_recovery_store_path)" 2>/dev/null)

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -n "${desired_names[$name]:-}" ]]; then
            continue
        fi
        fields=$(registry_get_fields "$name" directory agent_type task yolo_mode \
            sandbox_mode worktree_path worktree_host_path)
        IFS='|' read -r directory agent task yolo sandbox worktree_path worktree_host <<< "$fields"
        [[ -n "$directory" && -n "$agent" ]] || continue
        effective="${worktree_host:-${worktree_path:-$directory}}"
        worktree_name=""
        [[ -n "$worktree_path" ]] && worktree_name="${worktree_path##*/}"
        recovery_desired_upsert "$name" "$directory" "$agent" "$task" \
            "${yolo:-false}" "${sandbox:-false}" "$worktree_name" \
            "$effective" "$worktree_host" '[]'

        # Upgrade already-running sessions before their ephemeral sidecars
        # disappear at reboot.
        if [[ -f "$state_dir/$name.sid" ]]; then
            sid=""
            IFS= read -r sid < "$state_dir/$name.sid" 2>/dev/null || true
            if [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]]; then
                printf '%s' "$sid" > "$identity_dir/$name.sid"
                transcript=""
                if [[ -f "$state_dir/$name.transcript" ]]; then
                    IFS= read -r transcript < "$state_dir/$name.transcript" 2>/dev/null || true
                    printf '%s' "$transcript" > "$identity_dir/$name.transcript"
                fi
                recovery_desired_identity "$name" "$sid" "$transcript" "hook"
            fi
        fi
    done < <(am_session_order 2>/dev/null || true)
}

recovery_preflight_record() {
    local record="$1"
    local id agent sid identity_source directory effective transcript sandbox worktree_name
    id=$(jq -r '.logical_id // empty' <<< "$record")
    agent=$(jq -r '.agent_type // empty' <<< "$record")
    sid=$(jq -r '.session_id // empty' <<< "$record")
    identity_source=$(jq -r '.identity_source // empty' <<< "$record")
    directory=$(jq -r '.project_directory // empty' <<< "$record")
    effective=$(jq -r '.effective_directory // .project_directory // empty' <<< "$record")
    transcript=$(jq -r '.transcript_path // empty' <<< "$record")
    sandbox=$(jq -r '.sandbox_mode // "false"' <<< "$record")
    worktree_name=$(jq -r '.worktree_name // empty' <<< "$record")

    if [[ -z "$id" || -z "$agent" \
        || ! "$id" =~ ^${AM_SESSION_PREFIX}[A-Za-z0-9._-]+$ ]]; then
        echo "invalid desired-session record"
        return 1
    fi
    if [[ -z "$sid" || ( "$identity_source" != "hook" && "$identity_source" != "resume" ) ]]; then
        echo "exact conversation identity is unavailable"
        return 1
    fi
    if [[ -z "$effective" || ! -d "$effective" ]]; then
        if [[ -n "$worktree_name" ]]; then
            echo "worktree directory unavailable: ${effective:-<empty>}"
        else
            echo "directory unavailable: ${effective:-$directory}"
        fi
        return 1
    fi
    if [[ -n "$worktree_name" ]]; then
        local worktree_root project_common worktree_common
        worktree_root=$(git -C "$effective" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -z "$worktree_root" ]]; then
            echo "worktree is no longer a valid git worktree: $effective"
            return 1
        fi
        local effective_real root_real
        effective_real=$(cd "$effective" 2>/dev/null && pwd -P || true)
        root_real=$(cd "$worktree_root" 2>/dev/null && pwd -P || true)
        if [[ -z "$effective_real" || "$effective_real" != "$root_real" ]]; then
            echo "worktree path no longer matches its git root: $effective"
            return 1
        fi
        project_common=$(git -C "$directory" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
        worktree_common=$(git -C "$effective" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
        if [[ -z "$project_common" || -z "$worktree_common" ]]; then
            echo "worktree cannot resolve recorded project metadata: $directory"
            return 1
        fi
        project_common=$(cd "$project_common" 2>/dev/null && pwd -P || true)
        worktree_common=$(cd "$worktree_common" 2>/dev/null && pwd -P || true)
        if [[ -z "$project_common" || "$project_common" != "$worktree_common" ]]; then
            echo "worktree does not belong to recorded project: $effective"
            return 1
        fi
    fi

    local agent_cmd
    agent_cmd=$(agent_get_command "$agent")
    if ! command -v "$agent_cmd" >/dev/null 2>&1; then
        echo "agent command not found: $agent_cmd"
        return 1
    fi

    if [[ "$sandbox" == "true" ]]; then
        if ! am_docker_available || ! docker info >/dev/null 2>&1; then
            echo "Docker unavailable for sandbox session"
            return 1
        fi
    fi

    local share_spec share_host
    while IFS= read -r share_spec; do
        [[ -n "$share_spec" ]] || continue
        share_host="${share_spec%%:*}"
        if [[ ! -e "$share_host" ]]; then
            echo "sandbox share unavailable: $share_host"
            return 1
        fi
    done < <(jq -r '.sandbox_shares[]? // empty' <<< "$record")

    case "$agent" in
        codex)
            # Codex validates its exact hook-reported id when `codex resume`
            # starts; its rollout files are not stored under one stable path.
            ;;
        claude|cursor|pi)
            local check_home="$HOME"
            [[ "$sandbox" == "true" ]] && check_home="${SB_HOME_DIR:-$HOME/.agent-manager/sandbox-home}"
            if ! HOME="$check_home" _sessions_log_jsonl_exists \
                "$effective" "$sid" "$agent" "$transcript"; then
                echo "conversation history unavailable for $sid"
                return 1
            fi
            ;;
        *)
            echo "automatic resume unsupported for agent: $agent"
            return 1
            ;;
    esac
}

recovery_allow_identity_rebind() {
    local name="$1" identity_dir
    identity_dir=$(_recovery_identity_dir)
    mkdir -p "$identity_dir"
    : > "$identity_dir/$name.rebind"
}

recovery_agent_started() {
    local session_name="$1" waited=0 stable=0 pane_info pane_pid pane_command active
    while (( waited < 30 )); do
        pane_info=$(am_tmux display-message -p -t "$session_name:.{top}" \
            '#{pane_pid}|#{pane_current_command}' 2>/dev/null || true)
        IFS='|' read -r pane_pid pane_command <<< "$pane_info"
        active=false
        case "$pane_command" in
            ""|bash|dash|fish|ksh|sh|zsh) ;;
            *) active=true ;;
        esac
        if [[ "$pane_pid" =~ ^[0-9]+$ ]] && pgrep -P "$pane_pid" >/dev/null 2>&1; then
            active=true
        fi
        if $active; then
            stable=$((stable + 1))
            (( stable >= 10 )) && return 0
        else
            stable=0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

recovery_cleanup_failed_runtime() {
    local session_name="$1" container_name
    container_name=$(registry_get_field "$session_name" container_name 2>/dev/null || true)
    if [[ -n "$container_name" ]]; then
        [[ "$(type -t sandbox_remove)" == "function" ]] || source "$_RECOVERY_LIB_DIR/sandbox.sh"
        sandbox_remove "$session_name" >/dev/null 2>&1 || true
    fi
    tmux_kill_session "$session_name" >/dev/null 2>&1 || true
    registry_remove "$session_name" >/dev/null 2>&1 || true
}

recovery_restore_one() {
    local record="$1"
    if [[ "$(type -t agent_launch)" != "function" ]]; then
        source "$_RECOVERY_LIB_DIR/agents.sh"
    fi

    local id boot error
    id=$(jq -r '.logical_id // empty' <<< "$record")
    boot=$(recovery_current_boot_id 2>/dev/null || true)
    if ! error=$(recovery_preflight_record "$record"); then
        recovery_desired_set_status "$id" "blocked" "$error" "$boot"
        return 1
    fi

    recovery_desired_set_status "$id" "restoring" "" "$boot"

    local agent task project effective sid yolo sandbox
    agent=$(jq -r '.agent_type' <<< "$record")
    task=$(jq -r '.task // empty' <<< "$record")
    project=$(jq -r '.project_directory' <<< "$record")
    effective=$(jq -r '.effective_directory // .project_directory' <<< "$record")
    sid=$(jq -r '.session_id' <<< "$record")
    yolo=$(jq -r '.yolo_mode // "false"' <<< "$record")
    sandbox=$(jq -r '.sandbox_mode // "false"' <<< "$record")

    local -a restore_args=()
    while IFS= read -r _arg; do
        [[ -n "$_arg" ]] && restore_args+=("$_arg")
    done < <(agent_resume_args "$agent" "$sid")
    [[ "$yolo" == "true" ]] && restore_args+=("--yolo")
    [[ "$sandbox" == "true" ]] && restore_args+=("--sandbox")

    AM_SANDBOX_SHARES=()
    while IFS= read -r _share; do
        [[ -n "$_share" ]] && AM_SANDBOX_SHARES+=("$_share")
    done < <(jq -r '.sandbox_shares[]? // empty' <<< "$record")
    if [[ "$sandbox" == "true" && "$effective" != "$project" ]]; then
        AM_SANDBOX_SHARES+=("$project:$project:rw")
    fi
    AM_SANDBOX_SHARES_EXACT=1

    _AM_SESSION_NAME_OVERRIDE="$id"
    _AM_RECOVERY_MODE=1
    _AM_DEFER_SIDEBAR_REFRESH=1
    recovery_desired_is_open "$id" || return 1
    recovery_allow_identity_rebind "$id"
    local restored
    if restored=$(agent_launch "$effective" "$agent" "$task" "" "${restore_args[@]}") \
        && [[ -n "$restored" ]]; then
        if ! recovery_desired_is_open "$id"; then
            agent_kill "$restored" >/dev/null 2>&1 || true
            return 1
        fi
        if ! recovery_agent_started "$restored"; then
            recovery_cleanup_failed_runtime "$restored"
            recovery_desired_set_status "$id" "failed" \
                "resume command exited before agent started" "$boot"
            return 1
        fi
        if ! recovery_desired_is_open "$id"; then
            recovery_cleanup_failed_runtime "$restored"
            return 1
        fi
        recovery_desired_mark_live "$id" "$restored"
        return 0
    fi

    recovery_desired_set_status "$id" "failed" "agent launch failed" "$boot"
    return 1
}

# Print compact JSON records that were desired-open on this machine during a
# prior boot but do not currently have a physical tmux session.
recovery_desired_candidates() {
    recovery_desired_init || return 1
    recovery_sync_identities

    local live_json boot machine store
    live_json=$(tmux_list_am_sessions 2>/dev/null \
        | jq -Rsc 'split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries')
    boot=$(recovery_current_boot_id 2>/dev/null || true)
    machine=$(recovery_current_machine_id 2>/dev/null || true)
    store=$(_recovery_store_path)

    [[ -n "$boot" && -n "$machine" ]] || return 0
    jq -c --arg boot "$boot" --arg machine "$machine" --argjson live "$live_json" '
        .sessions | to_entries | map(.value) | sort_by(.order_key // 0)[] |
        select(.desired_state == "open") |
        select(.machine_id == $machine) |
        select(.launch_boot_id != "" and .launch_boot_id != $boot) |
        select((.last_attempt_boot // "") != $boot) |
        select(($live[.session_name] // false) | not)
    ' "$store" 2>/dev/null
}

_recovery_worker_active() {
    local lock_dir="$AM_DIR/.recovery-worker.lock" owner="" started=0 now
    [[ -f "$lock_dir/pid" ]] && IFS= read -r owner < "$lock_dir/pid" 2>/dev/null || true
    [[ -f "$lock_dir/started_at" ]] && IFS= read -r started < "$lock_dir/started_at" 2>/dev/null || true
    [[ "$owner" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$owner" 2>/dev/null || return 1
    now=$(date +%s)
    (( now - started < 900 )) || return 1
    [[ "$owner" == "$$" ]] && return 0
    local command_line
    command_line=$(ps -p "$owner" -o command= 2>/dev/null || true)
    [[ "$command_line" == *"recover-open --worker"* ]]
}

_recovery_worker_lock() {
    local lock_dir="$AM_DIR/.recovery-worker.lock"
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        date +%s > "$lock_dir/started_at"
        _RECOVERY_WORKER_LOCK_DIR="$lock_dir"
        return 0
    fi

    if ! _recovery_worker_active; then
        rm -rf "$lock_dir"
        mkdir "$lock_dir" 2>/dev/null || return 1
        printf '%s\n' "$$" > "$lock_dir/pid"
        date +%s > "$lock_dir/started_at"
        _RECOVERY_WORKER_LOCK_DIR="$lock_dir"
        return 0
    fi
    return 1
}

_recovery_worker_unlock() {
    [[ -n "${_RECOVERY_WORKER_LOCK_DIR:-}" ]] || return 0
    rm -rf "$_RECOVERY_WORKER_LOCK_DIR"
    _RECOVERY_WORKER_LOCK_DIR=""
}

recovery_reclaim_stale_claims() {
    local lock_dir="$AM_DIR/.recovery-worker.lock"
    if _recovery_worker_active; then
        return 0
    fi
    [[ -d "$lock_dir" ]] && rm -rf "$lock_dir"

    recovery_desired_init || return 1
    local live_json store tmp
    live_json=$(tmux_list_am_sessions 2>/dev/null \
        | jq -Rsc 'split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries')
    store=$(_recovery_store_path)
    tmp=$(mktemp "$AM_DIR/.desired-sessions.XXXXXX")
    _registry_lock
    if jq --argjson live "$live_json" '
        .sessions |= with_entries(
            if ((.value.recovery_state == "queued" or .value.recovery_state == "restoring")
                and (($live[.value.session_name] // false) | not))
            then .value.recovery_state = "pending"
                | .value.recovery_error = ""
                | .value.last_attempt_boot = ""
            else . end
        )
    ' "$store" > "$tmp"; then
        command mv "$tmp" "$store"
        _registry_unlock
        return 0
    fi
    rm -f "$tmp"
    _registry_unlock
    return 1
}

recovery_run() {
    _recovery_worker_lock || return 0

    local records
    records=$(recovery_desired_candidates)
    if [[ -z "$records" ]]; then
        _recovery_worker_unlock
        return 0
    fi

    local -a pids=()
    local record pid
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        (recovery_restore_one "$record") &
        pid=$!
        pids+=("$pid")
        if (( ${#pids[@]} >= 2 )); then
            wait "${pids[0]}" || true
            pids=("${pids[@]:1}")
        fi
    done <<< "$records"

    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    am_refresh_sidebar_cache >/dev/null 2>&1 || true
    _recovery_worker_unlock
}

recovery_start_for_browser() {
    if [[ -z "${AM_MACHINE_ID:-}" ]]; then
        AM_MACHINE_ID=$(recovery_current_machine_id 2>/dev/null || true)
        export AM_MACHINE_ID
    fi
    if [[ -z "${AM_BOOT_ID:-}" ]]; then
        AM_BOOT_ID=$(recovery_current_boot_id 2>/dev/null || true)
        export AM_BOOT_ID
    fi
    am_auto_restore_enabled || return 0
    recovery_desired_init || return 0

    local migration_marker="$AM_DIR/.desired_sessions_v1_migrated"
    if [[ ! -f "$migration_marker" ]]; then
        recovery_migrate_live_registry
        : > "$migration_marker"
    fi

    local boot last_boot=""
    boot="${AM_BOOT_ID:-}"
    [[ -n "$boot" ]] || return 0
    if [[ -f "$AM_DIR/.recovery_boot_id" ]]; then
        IFS= read -r last_boot < "$AM_DIR/.recovery_boot_id" 2>/dev/null || true
    fi
    if [[ "$last_boot" == "$boot" ]]; then
        # Normal browser opens stay fast. Only revisit this boot when a worker
        # died while records were queued/restoring.
        if ! jq -e '.sessions[] | select(.recovery_state == "queued" or .recovery_state == "restoring")' \
            "$(_recovery_store_path)" >/dev/null 2>&1; then
            return 0
        fi
    fi

    recovery_reclaim_stale_claims

    local candidates
    candidates=$(recovery_desired_candidates)
    printf '%s\n' "$boot" > "$AM_DIR/.recovery_boot_id"
    [[ -n "$candidates" ]] || return 0
    local candidate id
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        id=$(jq -r '.logical_id' <<< "$candidate")
        recovery_desired_set_status "$id" "queued" ""
    done <<< "$candidates"

    nohup "$AM_ROOT_DIR/am" recover-open --worker \
        >> "$AM_DIR/recovery.log" 2>&1 </dev/null &
}
