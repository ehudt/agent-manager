# shellcheck shell=bash
# config.sh - Persistent user defaults and effective config resolution

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/utils.sh"

AM_CONFIG="${AM_CONFIG:-$AM_DIR/config.json}"

# Keys written by releases before 0.18 (yolo and Docker sandbox defaults).
# They are no longer read; am_config_init drops them so `am config` and the
# file agree.
_AM_CONFIG_OBSOLETE_KEYS='["default_yolo","default_sandbox","sb_network_restrict","sb_allowed_hosts","sandbox.shares"]'

am_config_init() {
    mkdir -p "$(dirname "$AM_CONFIG")"
    if [[ ! -f "$AM_CONFIG" ]]; then
        cat > "$AM_CONFIG" <<'EOF'
{
  "default_agent": "claude",
  "auto_restore": true,
  "stream_logs": true,
  "shell_pane": false,
  "notify": true,
  "notify_states": "waiting_user"
}
EOF
        return 0
    fi
    _am_config_prune_obsolete
}

_am_config_prune_obsolete() {
    jq -e --argjson keys "$_AM_CONFIG_OBSOLETE_KEYS" \
        'any(keys[]; IN($keys[]))' "$AM_CONFIG" >/dev/null 2>&1 || return 0
    local tmp
    tmp=$(mktemp)
    jq --argjson keys "$_AM_CONFIG_OBSOLETE_KEYS" 'with_entries(select(.key as $k | $keys | index($k) | not))' \
        "$AM_CONFIG" > "$tmp" && mv "$tmp" "$AM_CONFIG"
}

am_config_get() {
    local key="$1"
    jq -r --arg key "$key" '.[$key] // empty' "$AM_CONFIG" 2>/dev/null
}

am_config_set() {
    local key="$1"
    local value="$2"
    local type="${3:-string}"

    local jq_value='
        if $type == "boolean" then
            ($value | test("^(1|true|yes|on)$"; "i"))
        else
            $value
        end
    '

    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" --arg value "$value" --arg type "$type" \
        ". + {(\$key): ($jq_value)}" \
        "$AM_CONFIG" > "$tmp" && mv "$tmp" "$AM_CONFIG"
}

am_config_unset() {
    local key="$1"

    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" 'del(.[$key])' "$AM_CONFIG" > "$tmp" && mv "$tmp" "$AM_CONFIG"
}

am_bool_is_true() {
    local value="${1:-}"
    [[ "$value" =~ ^(1|true|yes|on)$ ]]
}

am_default_agent() {
    local value
    if [[ -n "${AM_DEFAULT_AGENT:-}" ]]; then
        value="$AM_DEFAULT_AGENT"
    else
        local configured
        configured=$(am_config_get "default_agent")
        if [[ -n "$configured" && "$configured" != "null" ]]; then
            value="$configured"
        else
            value="claude"
        fi
    fi

    am_agent_normalize "$value"
}

am_stream_logs_enabled() {
    if [[ -n "${AM_STREAM_LOGS:-}" ]]; then
        am_bool_is_true "${AM_STREAM_LOGS,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "stream_logs")
    am_bool_is_true "${configured,,}"
}

# Whether new sessions open with the shell panel already visible.
# Default false: sessions start agent-only; prefix+` / `am shell` opens the
# panel on demand.
am_shell_pane_enabled() {
    if [[ -n "${AM_SHELL_PANE:-}" ]]; then
        am_bool_is_true "${AM_SHELL_PANE,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "shell_pane")
    am_bool_is_true "${configured,,}"
}

# Directory provider: the command behind `@spec` directories (`am new @48351`,
# `@` in the form's Directory field). am runs it two ways, both via bash -c
# with the arguments appended:
#   <provider> suggest <partial>   one "<spec>\t<label>" line per candidate
#   <provider> resolve <spec>      prints an existing directory
# Empty (the default) disables `@` specs. Example: am config set dir_provider wp
am_dir_provider() {
    if [[ -n "${AM_DIR_PROVIDER:-}" ]]; then
        echo "$AM_DIR_PROVIDER"
        return
    fi
    am_config_get "dir_provider"
}

# Whether a directory argument is a provider spec rather than a path.
# Usage: am_dir_is_spec <directory>
am_dir_is_spec() {
    [[ "${1:-}" == @* ]]
}

# Suggest timeout for the provider, in seconds (fractional allowed). The form
# calls suggest on keystrokes, so a slow provider must be cut off rather than
# stall the picker.
am_dir_suggest_timeout() {
    printf '%s\n' "${AM_DIR_SUGGEST_TIMEOUT:-0.3}"
}

am_auto_restore_enabled() {
    if [[ -n "${AM_AUTO_RESTORE:-}" ]]; then
        am_bool_is_true "${AM_AUTO_RESTORE,,}"
        return $?
    fi

    local configured
    configured=$(jq -r 'if has("auto_restore") then (.auto_restore | tostring) else "missing" end' \
        "$AM_CONFIG" 2>/dev/null)
    [[ "$configured" == "missing" || -z "$configured" ]] && return 0
    am_bool_is_true "${configured,,}"
}

# Desktop notifications (fired by the state hook on transitions into
# notify_states). Missing key = enabled; AM_NOTIFY env overrides.
am_notify_enabled() {
    if [[ -n "${AM_NOTIFY:-}" ]]; then
        am_bool_is_true "${AM_NOTIFY,,}"
        return $?
    fi
    local configured
    configured=$(jq -r 'if has("notify") then (.notify | tostring) else "missing" end' \
        "$AM_CONFIG" 2>/dev/null)
    [[ "$configured" == "missing" || -z "$configured" ]] && return 0
    am_bool_is_true "${configured,,}"
}

am_notify_states() {
    local configured
    configured=$(am_config_get "notify_states")
    printf '%s\n' "${configured:-waiting_user}"
}

am_config_key_alias() {
    case "$1" in
        agent|default-agent|default_agent) echo "default_agent" ;;
        auto-restore|auto_restore|restore-on-startup) echo "auto_restore" ;;
        logs|stream-logs|stream_logs) echo "stream_logs" ;;
        shell|shell-pane|shell_pane) echo "shell_pane" ;;
        provider|dir-provider|dir_provider) echo "dir_provider" ;;
        notify|notifications) echo "notify" ;;
        notify-states|notify_states) echo "notify_states" ;;
        notify-cmd|notify_cmd) echo "notify_cmd" ;;
        *) return 1 ;;
    esac
}

am_config_key_type() {
    case "$1" in
        default_agent|dir_provider|notify_states|notify_cmd) echo "string" ;;
        auto_restore|stream_logs|shell_pane|notify) echo "boolean" ;;
        *) return 1 ;;
    esac
}

am_config_value_is_valid() {
    local key="$1"
    local value="$2"
    case "$key" in
        default_agent)
            [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
            ;;
        auto_restore|stream_logs|shell_pane|notify)
            [[ "$value" =~ ^(1|0|true|false|yes|no|on|off)$ ]]
            ;;
        notify_states)
            local s ok=true
            for s in ${value//,/ }; do
                case "$s" in
                    starting|running|ready|waiting_user|background|idle|unknown|dead) ;;
                    *) ok=false ;;
                esac
            done
            [[ -n "$value" ]] && $ok
            ;;
        dir_provider|notify_cmd)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

am_config_print() {
    local default_agent_value auto_restore_value stream_logs_value shell_pane_value
    default_agent_value=$(am_default_agent)
    if am_stream_logs_enabled; then
        stream_logs_value=true
    else
        stream_logs_value=false
    fi
    if am_shell_pane_enabled; then
        shell_pane_value=true
    else
        shell_pane_value=false
    fi
    if am_auto_restore_enabled; then
        auto_restore_value=true
    else
        auto_restore_value=false
    fi
    local dir_provider_value notify_value notify_states_value notify_cmd_value
    dir_provider_value=$(am_dir_provider)
    if am_notify_enabled; then notify_value=true; else notify_value=false; fi
    notify_states_value=$(am_notify_states)
    notify_cmd_value=$(am_config_get "notify_cmd")

    cat <<EOF
default_agent=$default_agent_value
auto_restore=$auto_restore_value
stream_logs=$stream_logs_value
shell_pane=$shell_pane_value
dir_provider=$dir_provider_value
notify=$notify_value
notify_states=$notify_states_value
notify_cmd=$notify_cmd_value
config_file=$AM_CONFIG
EOF
}
