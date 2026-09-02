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
  "shell_pane": false
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

    case "$value" in
        cursor-agent) echo "cursor" ;;
        *) echo "$value" ;;
    esac
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

# Shell command that allocates an isolated workspace for `am new -W`. It runs
# via bash -c with AM_BRANCH exported (empty when no branch was requested) and
# prints the directory on stdout. Empty (the default) disables -W and hides
# the form's Workspace fields.
# Example: am config set workspace_cmd 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}'
am_workspace_cmd() {
    if [[ -n "${AM_WORKSPACE_CMD:-}" ]]; then
        echo "$AM_WORKSPACE_CMD"
        return
    fi
    am_config_get "workspace_cmd"
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

am_config_key_alias() {
    case "$1" in
        agent|default-agent|default_agent) echo "default_agent" ;;
        auto-restore|auto_restore|restore-on-startup) echo "auto_restore" ;;
        logs|stream-logs|stream_logs) echo "stream_logs" ;;
        shell|shell-pane|shell_pane) echo "shell_pane" ;;
        workspace|workspace-cmd|workspace_cmd) echo "workspace_cmd" ;;
        *) return 1 ;;
    esac
}

am_config_key_type() {
    case "$1" in
        default_agent|workspace_cmd) echo "string" ;;
        auto_restore|stream_logs|shell_pane) echo "boolean" ;;
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
        auto_restore|stream_logs|shell_pane)
            [[ "$value" =~ ^(1|0|true|false|yes|no|on|off)$ ]]
            ;;
        workspace_cmd)
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
    local workspace_cmd_value
    workspace_cmd_value=$(am_workspace_cmd)

    cat <<EOF
default_agent=$default_agent_value
auto_restore=$auto_restore_value
stream_logs=$stream_logs_value
shell_pane=$shell_pane_value
workspace_cmd=$workspace_cmd_value
config_file=$AM_CONFIG
EOF
}
