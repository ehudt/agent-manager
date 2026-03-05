# form.sh - tput-based new session form
# Alternative to fzf_new_session_form(), gated by new_form config flag.

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t agent_supports_worktree)" != "function" ]] && source "$SCRIPT_DIR/agents.sh"

# Field type display formatter
# Usage: _form_field_display <type> <value> <options> <disabled> <label>
_form_field_display() {
    local type="$1"
    local value="$2"
    local options="${3:-}"
    local disabled="${4:-}"
    local label="${5:-}"

    case "$type" in
        text|directory)
            echo "$value"
            ;;
        select)
            echo "< $value >"
            ;;
        checkbox)
            if [[ "$disabled" == "true" ]]; then
                echo "[disabled]"
            elif [[ "$value" == "true" ]]; then
                echo "[x]"
            else
                echo "[ ]"
            fi
            ;;
    esac
}

# Form field definitions
declare -a FORM_FIELDS=()
declare -A FORM_VALUES=()
declare -A FORM_TYPES=()
declare -A FORM_LABELS=()
declare -A FORM_OPTIONS=()
declare -A FORM_DISABLED=()
FORM_CURSOR=0

# Initialize form state
# Usage: _form_init <directory> <agent> <task> <mode> <yolo> <sandbox> <worktree_enabled> <worktree_name> <docker_available>
_form_init() {
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local sandbox="$6"
    local worktree_enabled="$7"
    local worktree_name="$8"
    local docker_available="${9:-true}"

    FORM_FIELDS=()
    FORM_VALUES=()
    FORM_TYPES=()
    FORM_LABELS=()
    FORM_OPTIONS=()
    FORM_DISABLED=()
    FORM_CURSOR=0

    _form_add_field "directory"         "Directory"      "directory"  "$directory"
    _form_add_field "agent"             "Agent"          "select"     "$agent"
    _form_add_field "task"              "Task"           "text"       "$task"
    _form_add_field "mode"              "Mode"           "select"     "$mode"
    _form_add_field "yolo"              "Yolo"           "checkbox"   "$yolo"
    _form_add_field "sandbox"           "Sandbox"        "checkbox"   "$sandbox"

    FORM_OPTIONS[agent]=$(printf '%s\n' "${!AGENT_COMMANDS[@]}" | sort | tr '\n' ',')
    FORM_OPTIONS[mode]="new,resume,continue"

    if [[ "$docker_available" != "true" ]]; then
        FORM_DISABLED[sandbox]="true"
    fi

    if agent_supports_worktree "$agent" || [[ "$worktree_enabled" == "true" ]]; then
        _form_add_field "worktree_enabled" "Worktree" "checkbox" "$worktree_enabled"
        if agent_supports_worktree "$agent"; then
            _form_add_field "worktree_name" "Worktree Name" "text" "$worktree_name"
        fi
        if ! agent_supports_worktree "$agent"; then
            FORM_DISABLED[worktree_enabled]="true"
        fi
    fi
}

_form_add_field() {
    local name="$1" label="$2" type="$3" value="$4"
    FORM_FIELDS+=("$name")
    FORM_LABELS[$name]="$label"
    FORM_TYPES[$name]="$type"
    FORM_VALUES[$name]="$value"
}

# Get the currently selected field name
_form_current_field() {
    echo "${FORM_FIELDS[$FORM_CURSOR]}"
}

# Render a single field line to stdout (no cursor movement)
_form_render_field() {
    local name="$1"
    local focused="${2:-false}"
    local label="${FORM_LABELS[$name]}"
    local type="${FORM_TYPES[$name]}"
    local value="${FORM_VALUES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"
    local options="${FORM_OPTIONS[$name]:-}"

    local display
    display=$(_form_field_display "$type" "$value" "$options" "$disabled" "$label")

    local prefix="  "
    [[ "$focused" == "true" ]] && prefix="> "

    printf '%s%-14s %s' "$prefix" "$label:" "$display"
}

# Handle space: toggle checkbox or cycle select
_form_handle_space() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"

    [[ "$disabled" == "true" ]] && return 0

    case "$type" in
        checkbox)
            if [[ "${FORM_VALUES[$name]}" == "true" ]]; then
                FORM_VALUES[$name]="false"
            else
                FORM_VALUES[$name]="true"
            fi
            ;;
        select)
            local options_str="${FORM_OPTIONS[$name]}"
            local -a options
            IFS=',' read -ra options <<< "$options_str"
            local count=${#options[@]}
            local current="${FORM_VALUES[$name]}"
            local i next_idx
            for ((i=0; i<count; i++)); do
                if [[ "${options[$i]}" == "$current" ]]; then
                    next_idx=$(( (i + 1) % count ))
                    FORM_VALUES[$name]="${options[$next_idx]}"
                    return 0
                fi
            done
            FORM_VALUES[$name]="${options[0]}"
            ;;
    esac
}

# Handle cursor movement
_form_handle_down() {
    local max=$(( ${#FORM_FIELDS[@]} - 1 ))
    if [[ $FORM_CURSOR -lt $max ]]; then
        ((FORM_CURSOR++))
    fi
}

_form_handle_up() {
    if [[ $FORM_CURSOR -gt 0 ]]; then
        ((FORM_CURSOR--))
    fi
}

# Handle a printable character: append to text/directory fields
_form_handle_char() {
    local ch="$1"
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            FORM_VALUES[$name]+="$ch"
            ;;
    esac
}

# Handle backspace: remove last character
_form_handle_backspace() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            local val="${FORM_VALUES[$name]}"
            if [[ -n "$val" ]]; then
                FORM_VALUES[$name]="${val%?}"
            fi
            ;;
    esac
}
