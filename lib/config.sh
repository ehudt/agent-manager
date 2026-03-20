# shellcheck shell=bash
# config.sh - Persistent user defaults and effective config resolution

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

AM_CONFIG="${AM_CONFIG:-$AM_DIR/config.json}"

am_config_init() {
    mkdir -p "$(dirname "$AM_CONFIG")"
    if [[ ! -f "$AM_CONFIG" ]]; then
        cat > "$AM_CONFIG" <<'EOF'
{
  "default_agent": "claude",
  "default_yolo": false,
  "default_sandbox": false,
  "stream_logs": true,
  "sb_network_restrict": true,
  "sb_allowed_hosts": "",
  "sandbox.shares": ""
}
EOF
    fi
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
    if [[ -n "${AM_DEFAULT_AGENT:-}" ]]; then
        echo "$AM_DEFAULT_AGENT"
        return 0
    fi

    local configured
    configured=$(am_config_get "default_agent")
    if [[ -n "$configured" && "$configured" != "null" ]]; then
        echo "$configured"
    else
        echo "claude"
    fi
}

am_default_yolo_enabled() {
    if [[ -n "${AM_DEFAULT_YOLO:-}" ]]; then
        am_bool_is_true "${AM_DEFAULT_YOLO,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "default_yolo")
    am_bool_is_true "${configured,,}"
}

am_default_sandbox_enabled() {
    if [[ -n "${AM_DEFAULT_SANDBOX:-}" ]]; then
        am_bool_is_true "${AM_DEFAULT_SANDBOX,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "default_sandbox")
    am_bool_is_true "${configured,,}"
}

am_docker_available() {
    if [[ -n "${AM_DOCKER_AVAILABLE:-}" ]]; then
        [[ "$AM_DOCKER_AVAILABLE" == "true" ]]
        return $?
    fi
    command -v docker &>/dev/null
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

am_new_form_enabled() {
    if [[ -n "${AM_NEW_FORM:-}" ]]; then
        am_bool_is_true "${AM_NEW_FORM,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "new_form")
    am_bool_is_true "${configured,,}"
}

am_sb_network_restrict_enabled() {
    if [[ -n "${AM_SB_NETWORK_RESTRICT:-}" ]]; then
        am_bool_is_true "${AM_SB_NETWORK_RESTRICT,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "sb_network_restrict")
    if [[ -z "$configured" ]]; then
        return 0  # default true
    fi
    am_bool_is_true "${configured,,}"
}

am_args_contain_yolo_flag() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yolo|--dangerously-skip-permissions)
                return 0
                ;;
        esac
    done
    return 1
}

am_maybe_apply_default_yolo() {
    if ! am_default_yolo_enabled; then
        return 1
    fi
    if am_args_contain_yolo_flag "$@"; then
        return 1
    fi
    return 0
}

am_maybe_apply_default_sandbox() {
    if ! am_default_sandbox_enabled; then
        return 1
    fi
    local arg
    for arg in "$@"; do
        case "$arg" in
            --sandbox) return 1 ;;
        esac
    done
    return 0
}

am_config_key_alias() {
    case "$1" in
        agent|default-agent|default_agent) echo "default_agent" ;;
        yolo|default-yolo|default_yolo) echo "default_yolo" ;;
        sandbox|default-sandbox|default_sandbox) echo "default_sandbox" ;;
        logs|stream-logs|stream_logs) echo "stream_logs" ;;
        new-form|new_form) echo "new_form" ;;
        sb-network-restrict|sb_network_restrict) echo "sb_network_restrict" ;;
        sb-allowed-hosts|sb_allowed_hosts) echo "sb_allowed_hosts" ;;
        sandbox-shares|sandbox_shares|sandbox.shares) echo "sandbox.shares" ;;
        *) return 1 ;;
    esac
}

am_config_key_type() {
    case "$1" in
        default_agent) echo "string" ;;
        default_yolo|default_sandbox|stream_logs|new_form|sb_network_restrict) echo "boolean" ;;
        sb_allowed_hosts|sandbox.shares) echo "string" ;;
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
        default_yolo|default_sandbox|stream_logs|new_form|sb_network_restrict)
            [[ "$value" =~ ^(1|0|true|false|yes|no|on|off)$ ]]
            ;;
        sb_allowed_hosts|sandbox.shares)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

am_config_print() {
    local default_agent_value default_yolo_value default_sandbox_value stream_logs_value
    default_agent_value=$(am_default_agent)
    if am_default_yolo_enabled; then
        default_yolo_value=true
    else
        default_yolo_value=false
    fi
    if am_default_sandbox_enabled; then
        default_sandbox_value=true
    else
        default_sandbox_value=false
    fi
    if am_stream_logs_enabled; then
        stream_logs_value=true
    else
        stream_logs_value=false
    fi
    local new_form_value
    if am_new_form_enabled; then
        new_form_value=true
    else
        new_form_value=false
    fi
    local sb_network_restrict_value
    if am_sb_network_restrict_enabled; then
        sb_network_restrict_value=true
    else
        sb_network_restrict_value=false
    fi
    local sb_allowed_hosts_value sandbox_shares_value
    sb_allowed_hosts_value=$(am_config_get "sb_allowed_hosts")
    sandbox_shares_value=$(am_config_get "sandbox.shares")

    cat <<EOF
default_agent=$default_agent_value
default_yolo=$default_yolo_value
default_sandbox=$default_sandbox_value
stream_logs=$stream_logs_value
new_form=$new_form_value
sb_network_restrict=$sb_network_restrict_value
sb_allowed_hosts=$sb_allowed_hosts_value
sandbox.shares=$sandbox_shares_value
config_file=$AM_CONFIG
EOF
}
