# form.sh - tput-based new session form
# Alternative to fzf_new_session_form(), gated by new_form config flag.

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t agent_supports_worktree)" != "function" ]] && source "$SCRIPT_DIR/agents.sh"

# Field type display formatter
# Usage: _form_field_display <type> <value> <options> <disabled> <label> <focused>
_form_field_display() {
    local type="$1"
    local value="$2"
    local options="${3:-}"
    local disabled="${4:-}"
    local label="${5:-}"
    local focused="${6:-false}"

    case "$type" in
        text|directory)
            if [[ "$focused" == "true" ]]; then
                # Show blinking cursor when focused
                printf '%s\033[7m \033[0m' "$value"
            else
                echo "$value"
            fi
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

# Directory suggestions cache
declare -a _FORM_DIR_SUGGESTIONS=()
_FORM_DIR_SUGGESTIONS_LOADED=false

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
    _FORM_DIR_SUGGESTIONS=()
    _FORM_DIR_SUGGESTIONS_LOADED=false

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
    display=$(_form_field_display "$type" "$value" "$options" "$disabled" "$label" "$focused")

    local prefix="  "
    [[ "$focused" == "true" ]] && prefix="> "

    printf '%s%-14s %s' "$prefix" "$label:" "$display"
}

# Load directory suggestions (once, lazily)
_form_load_dir_suggestions() {
    [[ "$_FORM_DIR_SUGGESTIONS_LOADED" == "true" ]] && return 0
    _FORM_DIR_SUGGESTIONS=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _FORM_DIR_SUGGESTIONS+=("$line")
    done < <(_list_directories 2>/dev/null || true)
    _FORM_DIR_SUGGESTIONS_LOADED=true
}

# Filter directory suggestions by current value, return top N
# Usage: _form_filtered_dir_suggestions <query> <max>
_form_filtered_dir_suggestions() {
    local query="$1"
    local max="${2:-5}"
    local count=0
    local entry path

    _form_load_dir_suggestions

    for entry in "${_FORM_DIR_SUGGESTIONS[@]}"; do
        # Extract path (before tab if annotated)
        path="${entry%%$'\t'*}"
        if [[ -z "$query" || "$path" == *"$query"* ]]; then
            echo "$entry"
            ((count++))
            [[ $count -ge $max ]] && break
        fi
    done
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

# Handle Tab: accept top directory suggestion
_form_handle_tab() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    if [[ "$type" == "directory" ]]; then
        local query="${FORM_VALUES[$name]}"
        local top
        top=$(_form_filtered_dir_suggestions "$query" 1 | head -1)
        if [[ -n "$top" ]]; then
            # Extract just the path (strip annotation after tab)
            FORM_VALUES[$name]="${top%%$'\t'*}"
        fi
    fi
}

# Process a single keystroke. Sets FORM_KEY_RESULT to "continue", "submit", or "cancel".
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
            _form_handle_tab
            FORM_KEY_RESULT="continue"
            ;;
        *)
            if [[ "$key" =~ [[:print:]] ]]; then
                _form_handle_char "$key"
            fi
            FORM_KEY_RESULT="continue"
            ;;
    esac
}

# Number of inline directory suggestion lines
_FORM_DIR_SUGGESTION_LINES=5

# Draw the static header (called once at form start)
_form_draw_header() {
    {
        tput cup 0 0 2>/dev/null || true
        printf '\033[1m  New Session\033[0m'
        tput el 2>/dev/null || true
        printf '\n'
        printf '  Enter: create  Space: toggle/cycle  Tab: complete  Esc: cancel'
        tput el 2>/dev/null || true
        printf '\n'
        tput el 2>/dev/null || true
        printf '\n'
    } > /dev/tty
}

# Row where dynamic content starts (after header)
_FORM_CONTENT_ROW=3

# Draw the form fields to /dev/tty (not stdout, which may be captured by $()).
# Header is static (drawn once). Only fields + suggestions are redrawn per keystroke.
# Directory suggestions always occupy their fixed space to prevent layout shifts.
_form_draw() {
    local row=$_FORM_CONTENT_ROW

    {
        tput cup $row 0 2>/dev/null || true

        # Render each field
        local i name
        for ((i=0; i<${#FORM_FIELDS[@]}; i++)); do
            name="${FORM_FIELDS[$i]}"
            local focused="false"
            [[ $i -eq $FORM_CURSOR ]] && focused="true"
            _form_render_field "$name" "$focused"
            tput el 2>/dev/null || true
            printf '\n'
            ((row++))

            # Directory suggestions always shown (stable layout)
            if [[ "$name" == "directory" ]]; then
                local suggestions query dir_focused="false"
                [[ "$focused" == "true" ]] && dir_focused="true"
                query="${FORM_VALUES[directory]}"
                suggestions=$(_form_filtered_dir_suggestions "$query" "$_FORM_DIR_SUGGESTION_LINES")
                local sline scount=0
                while IFS= read -r sline; do
                    [[ -z "$sline" ]] && continue
                    local spath="${sline%%$'\t'*}"
                    local sannotation=""
                    [[ "$sline" == *$'\t'* ]] && sannotation="${sline#*$'\t'}"
                    if [[ "$dir_focused" == "true" && $scount -eq 0 ]]; then
                        # Highlight top suggestion when directory is focused
                        printf '    \033[36m%s\033[0m' "$spath"
                        [[ -n "$sannotation" ]] && printf '  \033[2m%s\033[0m' "$sannotation"
                    else
                        printf '    \033[2m%s\033[0m' "$spath"
                        [[ -n "$sannotation" ]] && printf '  \033[2m%s\033[0m' "$sannotation"
                    fi
                    tput el 2>/dev/null || true
                    printf '\n'
                    ((row++))
                    ((scount++))
                done <<< "$suggestions"
                # Pad to fixed height (prevents layout shift)
                while [[ $scount -lt $_FORM_DIR_SUGGESTION_LINES ]]; do
                    tput el 2>/dev/null || true
                    printf '\n'
                    ((row++))
                    ((scount++))
                done
            fi
        done

        # Clear a few extra lines to handle field count changes (e.g. worktree toggle)
        local extra
        for extra in 1 2 3; do
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

    _form_draw_header

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
