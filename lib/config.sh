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
  "stream_logs": false
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

am_stream_logs_enabled() {
    if [[ -n "${AM_STREAM_LOGS:-}" ]]; then
        am_bool_is_true "${AM_STREAM_LOGS,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "stream_logs")
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

am_config_key_alias() {
    case "$1" in
        agent|default-agent|default_agent) echo "default_agent" ;;
        yolo|default-yolo|default_yolo) echo "default_yolo" ;;
        logs|stream-logs|stream_logs) echo "stream_logs" ;;
        *) return 1 ;;
    esac
}

am_config_key_type() {
    case "$1" in
        default_agent) echo "string" ;;
        default_yolo|stream_logs) echo "boolean" ;;
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
        default_yolo|stream_logs)
            [[ "$value" =~ ^(1|0|true|false|yes|no|on|off)$ ]]
            ;;
        *)
            return 1
            ;;
    esac
}

am_config_print() {
    local default_agent_value default_yolo_value stream_logs_value
    default_agent_value=$(am_default_agent)
    if am_default_yolo_enabled; then
        default_yolo_value=true
    else
        default_yolo_value=false
    fi
    if am_stream_logs_enabled; then
        stream_logs_value=true
    else
        stream_logs_value=false
    fi

    cat <<EOF
default_agent=$default_agent_value
default_yolo=$default_yolo_value
stream_logs=$stream_logs_value
config_file=$AM_CONFIG
EOF
}
