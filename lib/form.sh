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

# Process a single keystroke. Sets FORM_KEY_RESULT to "continue", "submit", "cancel", or "tab".
# Must be called in current shell (not a subshell) so mutations take effect.
# Usage: _form_process_key <key> [extra_seq]
FORM_KEY_RESULT=""
_form_process_key() {
    local key="$1"
    local extra="${2:-__unset__}"

    case "$key" in
        $'\n'|"")
            FORM_KEY_RESULT="submit"
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                FORM_KEY_RESULT="cancel"
            else
                case "$extra" in
                    "[A") _form_handle_up; FORM_KEY_RESULT="continue" ;;
                    "[B") _form_handle_down; FORM_KEY_RESULT="continue" ;;
                    *) FORM_KEY_RESULT="continue" ;;
                esac
            fi
            ;;
        " ")
            _form_handle_space
            FORM_KEY_RESULT="continue"
            ;;
        $'\x7f'|$'\b')
            _form_handle_backspace
            FORM_KEY_RESULT="continue"
            ;;
        $'\t')
            FORM_KEY_RESULT="tab"
            ;;
        *)
            if [[ "$key" =~ [[:print:]] ]]; then
                _form_handle_char "$key"
            fi
            FORM_KEY_RESULT="continue"
            ;;
    esac
}

# Draw the full form to /dev/tty (not stdout, which may be captured by $())
_form_draw() {
    {
        tput cup 0 0 2>/dev/null || true
        tput ed 2>/dev/null || true

        printf '\033[1m  New Session\033[0m\n'
        printf '  Enter: create  Space: toggle/cycle  Tab: dir picker  Esc: cancel\n'
        printf '\n'

        local i name
        for ((i=0; i<${#FORM_FIELDS[@]}; i++)); do
            name="${FORM_FIELDS[$i]}"
            local focused="false"
            [[ $i -eq $FORM_CURSOR ]] && focused="true"
            _form_render_field "$name" "$focused"
            tput el 2>/dev/null || true
            printf '\n'
        done
    } > /dev/tty
}

# Main form loop
# Returns form values on stdout (same format as fzf_new_session_form).
# All rendering and input go through /dev/tty so this works inside $() capture.
_form_run() {
    {
        tput civis 2>/dev/null || true
        tput smcup 2>/dev/null || true
    } > /dev/tty
    trap '_form_cleanup' EXIT INT TERM

    while true; do
        _form_draw

        local key=""
        IFS= read -rsn1 key < /dev/tty

        if [[ "$key" == $'\x1b' ]]; then
            local seq=""
            IFS= read -rsn1 -t 0.05 seq < /dev/tty || true
            if [[ -n "$seq" ]]; then
                local seq2=""
                IFS= read -rsn1 -t 0.05 seq2 < /dev/tty || true
                seq+="$seq2"
            fi
            _form_process_key "$key" "$seq"
        else
            _form_process_key "$key"
        fi

        case "$FORM_KEY_RESULT" in
            submit) break ;;
            cancel)
                _form_cleanup
                return 1
                ;;
            tab)
                local name="${FORM_FIELDS[$FORM_CURSOR]}"
                if [[ "${FORM_TYPES[$name]}" == "directory" ]]; then
                    _form_cleanup_screen
                    local picked
                    if picked=$(_form_directory_popup "${FORM_VALUES[$name]}"); then
                        [[ -n "$picked" ]] && FORM_VALUES[$name]="$picked"
                    fi
                    { tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true; } > /dev/tty
                fi
                ;;
        esac
    done

    _form_cleanup
    _form_output
}

_form_cleanup_screen() {
    { tput rmcup 2>/dev/null || true; tput cnorm 2>/dev/null || true; } > /dev/tty
}

_form_cleanup() {
    _form_cleanup_screen
    trap - EXIT INT TERM
}

# Directory picker popup — delegates to fzf
_form_directory_popup() {
    local current="$1"

    export -f _list_directories _annotate_directory _strip_annotation detect_git_branch 2>/dev/null || true

    local initial_list
    initial_list=$(_list_directories 2>/dev/null | grep -v '^$' || true)

    local selected
    selected=$(echo "$initial_list" | fzf \
        --ansi \
        --height=12 \
        --layout=reverse \
        --print-query \
        --query="$current" \
        --header="Directory  Tab:complete  Type to filter  Esc:back" \
        --bind="tab:reload(bash -c '_list_directories {q}' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | grep -v '^$')+transform-query(dirname {q})" \
    ) || true

    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)
    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    [[ -z "$selection" && -n "$query" ]] && selection="$query"
    selection="${selection/#\~/$HOME}"

    if [[ -n "$selection" ]]; then
        echo "$selection"
    else
        echo "$current"
    fi
}

# Format output matching fzf_new_session_form contract:
# directory<TAB>agent<TAB>task<TAB>worktree_name<TAB>flags
_form_output() {
    local directory="${FORM_VALUES[directory]}"
    local agent="${FORM_VALUES[agent]}"
    local task="${FORM_VALUES[task]}"
    local mode="${FORM_VALUES[mode]}"
    local yolo="${FORM_VALUES[yolo]}"
    local sandbox="${FORM_VALUES[sandbox]}"
    local worktree_enabled="${FORM_VALUES[worktree_enabled]:-false}"
    local worktree_name="${FORM_VALUES[worktree_name]:-}"

    directory="${directory/#\~/$HOME}"

    if [[ -z "$directory" || ! -d "$directory" ]]; then
        log_error "Directory does not exist: ${directory:-<empty>}"
        return 1
    fi

    if [[ -z "$agent" || -z "${AGENT_COMMANDS[$agent]:-}" ]]; then
        log_error "Invalid agent type: ${agent:-<empty>}"
        return 1
    fi

    local flags=""
    [[ "$mode" == "resume" ]] && flags+=" --resume"
    [[ "$mode" == "continue" ]] && flags+=" --continue"
    [[ "$yolo" == "true" ]] && flags+=" --yolo"
    [[ "$sandbox" == "true" ]] && flags+=" --sandbox"

    local worktree=""
    if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
        if [[ -n "$worktree_name" ]]; then
            worktree="$worktree_name"
        else
            worktree="__auto__"
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$directory" "$agent" "$task" "$worktree" "$flags"
}

# Dispatch function: picks form implementation based on feature flag.
# Same signature and output as fzf_new_session_form().
am_new_session_form() {
    if am_new_form_enabled; then
        local prefill_directory="${1:-.}"
        local prefill_agent="${2:-$(am_default_agent)}"
        local prefill_task="${3:-}"
        local prefill_worktree="${4:-}"
        local prefill_mode_flags="${5:-}"

        local directory="${prefill_directory/#\~/$HOME}"
        local agent="$prefill_agent"
        local task="$prefill_task"
        local mode="new"
        local yolo="false"
        local sandbox="false"
        local worktree_enabled="false"
        local worktree_name=""
        local docker_available="true"
        am_docker_available || docker_available="false"

        # Parse prefill flags
        [[ "$prefill_mode_flags" == *"--resume"* ]] && mode="resume"
        [[ "$prefill_mode_flags" == *"--continue"* ]] && mode="continue"
        if [[ "$prefill_mode_flags" == *"--yolo"* ]]; then
            yolo="true"
        elif am_default_yolo_enabled; then
            yolo="true"
        fi
        if [[ "$prefill_mode_flags" == *"--sandbox"* ]]; then
            sandbox="true"
        elif am_default_sandbox_enabled && [[ "$docker_available" == "true" ]]; then
            sandbox="true"
        fi

        case "$prefill_worktree" in
            ""|false) worktree_enabled="false"; worktree_name="" ;;
            true|__auto__) worktree_enabled="true"; worktree_name="" ;;
            *) worktree_enabled="true"; worktree_name="$prefill_worktree" ;;
        esac

        _form_init "$directory" "$agent" "$task" "$mode" "$yolo" "$sandbox" \
            "$worktree_enabled" "$worktree_name" "$docker_available"
        _form_run
    else
        fzf_new_session_form "$@"
    fi
}
