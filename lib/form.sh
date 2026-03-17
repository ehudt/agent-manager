# form.sh - tput-based new session form
# Alternative to fzf_new_session_form(), gated by new_form config flag.

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t agent_supports_worktree)" != "function" ]] && source "$SCRIPT_DIR/agents.sh"

# Pre-cache tput sequences to avoid forking per frame
_FORM_CUP_PREFIX=$'\033['   # used as "${_FORM_CUP_PREFIX}${row};0H"
_FORM_EL=$'\033[K'          # clear to end of line
_FORM_BOLD=$'\033[1m'
_FORM_DIM=$'\033[2m'
_FORM_CYAN=$'\033[36m'
_FORM_INVERSE=$'\033[7m'
_FORM_RESET=$'\033[0m'
_FORM_HIDE_CURSOR=$'\033[?25l'
_FORM_SHOW_CURSOR=$'\033[?25h'
_FORM_BG_NAV=$'\033[48;5;236m'    # dark gray background in navigate mode
_FORM_BG_EDIT=$'\033[48;5;24m'   # dark blue background in edit mode

# Form field definitions
declare -a FORM_FIELDS=()
declare -A FORM_VALUES=()
declare -A FORM_TYPES=()
declare -A FORM_LABELS=()
declare -A FORM_OPTIONS=()
declare -A FORM_DISABLED=()
FORM_CURSOR=0

# Mode: "navigate" or "edit"
_FORM_MODE="navigate"

# Directory suggestion highlight index (used in edit mode)
_FORM_DIR_HIGHLIGHT=0
_FORM_DIR_SCROLL_OFFSET=0

# Directory suggestions cache
declare -a _FORM_DIR_SUGGESTIONS=()
_FORM_DIR_SUGGESTIONS_LOADED=false

# Filtered results cache (avoids subshell)
declare -a _FORM_DIR_FILTERED=()

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
    _FORM_DIR_FILTERED=()
    _FORM_MODE="edit"
    _FORM_DIR_HIGHLIGHT=0
    _FORM_DIR_SCROLL_OFFSET=0

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
            if [[ "$worktree_enabled" != "true" ]]; then
                FORM_DISABLED[worktree_name]="true"
            fi
        fi
        if ! agent_supports_worktree "$agent"; then
            FORM_DISABLED[worktree_enabled]="true"
        fi
    fi

    # Submit button (always last)
    _form_add_field "submit" "" "submit" ""
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

# Field type display formatter (used by tests and _form_render_field)
# Usage: _form_field_display <type> <value> <options> <disabled> <label> <focused>
_form_field_display() {
    local type="$1"
    local value="$2"
    local disabled="${4:-}"
    local focused="${6:-false}"

    case "$type" in
        text|directory)
            if [[ "$disabled" == "true" ]]; then
                echo "--"
            else
                echo "$value"
            fi
            ;;
        select)
            local options_str="$3"
            if [[ -n "$options_str" ]]; then
                local -a _ffd_opts
                IFS=',' read -ra _ffd_opts <<< "$options_str"
                local _ffd_parts=""
                local _ffd_opt
                for _ffd_opt in "${_ffd_opts[@]}"; do
                    if [[ "$_ffd_opt" == "$value" ]]; then
                        _ffd_parts+="[${_ffd_opt}]  "
                    else
                        _ffd_parts+="${_ffd_opt}  "
                    fi
                done
                echo "${_ffd_parts%  }"
            else
                echo "[$value]"
            fi
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
        submit)
            echo "[ Create ]"
            ;;
    esac
}

# Render a single field line directly to the output buffer (no subshell).
# Appends to the _FORM_BUF variable.
_form_render_field() {
    local name="$1"
    local focused="${2:-false}"
    local label="${FORM_LABELS[$name]}"
    local type="${FORM_TYPES[$name]}"
    local value="${FORM_VALUES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"

    local prefix="  "
    if [[ "$focused" == "true" ]]; then
        if [[ "$_FORM_MODE" == "edit" ]]; then
            prefix="» "
        else
            prefix="> "
        fi
    fi

    # Inline display formatting (no subshell)
    local display=""
    case "$type" in
        text|directory)
            if [[ "$disabled" == "true" ]]; then
                display="${_FORM_DIM}--${_FORM_RESET}"
            elif [[ "$focused" == "true" && "$_FORM_MODE" == "edit" ]]; then
                display="${value}${_FORM_INVERSE} ${_FORM_RESET}"
            elif [[ -z "$value" && "$name" == "worktree_name" ]]; then
                display="${_FORM_DIM}(auto)${_FORM_RESET}"
            else
                display="$value"
            fi
            ;;
        select)
            local options_str="${FORM_OPTIONS[$name]}"
            local -a _render_opts
            IFS=',' read -ra _render_opts <<< "$options_str"
            display=""
            local _render_opt
            for _render_opt in "${_render_opts[@]}"; do
                if [[ "$_render_opt" == "$value" ]]; then
                    display+="${_FORM_INVERSE}${_FORM_CYAN} ${_render_opt} ${_FORM_RESET} "
                else
                    display+="${_FORM_DIM}${_render_opt}${_FORM_RESET} "
                fi
            done
            ;;
        checkbox)
            if [[ "$disabled" == "true" ]]; then
                display="[disabled]"
            elif [[ "$value" == "true" ]]; then
                display="[x]"
            else
                display="[ ]"
            fi
            ;;
        submit)
            display="[ Create ]"
            ;;
    esac

    # Pick highlight color based on mode
    local bg=""
    if [[ "$focused" == "true" ]]; then
        if [[ "$_FORM_MODE" == "edit" ]]; then
            bg="$_FORM_BG_EDIT"
        else
            bg="$_FORM_BG_NAV"
        fi
    fi

    if [[ "$type" == "submit" ]]; then
        _FORM_BUF+="${_FORM_EL}"$'\n'
        if [[ "$focused" == "true" ]]; then
            _FORM_BUF+="${prefix}${bg}${display}${_FORM_RESET}${_FORM_EL}"$'\n'
        else
            _FORM_BUF+="${prefix}${display}${_FORM_EL}"$'\n'
        fi
    elif [[ "$focused" == "true" ]]; then
        _FORM_BUF+="${prefix}${bg}$(printf '%-14s' "$label:")${_FORM_RESET} ${display}${_FORM_EL}"$'\n'
    else
        _FORM_BUF+="${prefix}$(printf '%-14s' "$label:") ${display}${_FORM_EL}"$'\n'
    fi
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

# Filter directory suggestions into _FORM_DIR_FILTERED array (no subshell).
# Usage: _form_filter_dir_suggestions <query> <max>
_form_filter_dir_suggestions() {
    local query="$1"
    local max="${2:-5}"
    local count=0
    local entry path

    _form_load_dir_suggestions
    _FORM_DIR_FILTERED=()

    for entry in "${_FORM_DIR_SUGGESTIONS[@]}"; do
        path="${entry%%$'\t'*}"
        if [[ -z "$query" || "$path" == *"$query"* ]]; then
            _FORM_DIR_FILTERED+=("$entry")
            ((count++))
            [[ $count -ge $max ]] && break
        fi
    done
}

# Cycle a select field. direction: 1=forward, -1=backward
_form_cycle_select() {
    local name="$1"
    local direction="${2:-1}"
    local options_str="${FORM_OPTIONS[$name]}"
    local -a options
    IFS=',' read -ra options <<< "$options_str"
    local count=${#options[@]}
    local current="${FORM_VALUES[$name]}"
    local i next_idx
    for ((i=0; i<count; i++)); do
        if [[ "${options[$i]}" == "$current" ]]; then
            next_idx=$(( (i + direction + count) % count ))
            FORM_VALUES[$name]="${options[$next_idx]}"
            return 0
        fi
    done
    FORM_VALUES[$name]="${options[0]}"
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
            # Yolo ON implies sandbox + worktree
            if [[ "$name" == "yolo" && "${FORM_VALUES[$name]}" == "true" ]]; then
                if [[ "${FORM_DISABLED[sandbox]:-}" != "true" ]]; then
                    FORM_VALUES[sandbox]="true"
                fi
                if [[ -n "${FORM_TYPES[worktree_enabled]:-}" && "${FORM_DISABLED[worktree_enabled]:-}" != "true" ]]; then
                    FORM_VALUES[worktree_enabled]="true"
                    FORM_DISABLED[worktree_name]=""
                fi
            fi
            # Update worktree_name disabled state when worktree_enabled toggles
            if [[ "$name" == "worktree_enabled" ]]; then
                if [[ "${FORM_VALUES[$name]}" == "true" ]]; then
                    FORM_DISABLED[worktree_name]=""
                else
                    FORM_DISABLED[worktree_name]="true"
                fi
            fi
            ;;
        select)
            _form_cycle_select "$name" 1
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
    local disabled="${FORM_DISABLED[$name]:-}"

    [[ "$disabled" == "true" ]] && return 0

    case "$type" in
        text|directory)
            FORM_VALUES[$name]+="$ch"
            if [[ "$type" == "directory" ]]; then
                _FORM_DIR_HIGHLIGHT=0
                _FORM_DIR_SCROLL_OFFSET=0
            fi
            ;;
    esac
}

# Handle backspace: remove last character
_form_handle_backspace() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"

    [[ "$disabled" == "true" ]] && return 0

    case "$type" in
        text|directory)
            local val="${FORM_VALUES[$name]}"
            if [[ -n "$val" ]]; then
                FORM_VALUES[$name]="${val%?}"
                if [[ "$type" == "directory" ]]; then
                    _FORM_DIR_HIGHLIGHT=0
                    _FORM_DIR_SCROLL_OFFSET=0
                fi
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
        _form_filter_dir_suggestions "$query" "$_FORM_DIR_FILTER_MAX"
        if [[ ${#_FORM_DIR_FILTERED[@]} -gt 0 ]]; then
            local idx=$_FORM_DIR_HIGHLIGHT
            [[ $idx -ge ${#_FORM_DIR_FILTERED[@]} ]] && idx=0
            local entry="${_FORM_DIR_FILTERED[$idx]}"
            FORM_VALUES[$name]="${entry%%$'\t'*}"
            _FORM_DIR_HIGHLIGHT=0
            _FORM_DIR_SCROLL_OFFSET=0
        fi
    fi
}

# Ensure the directory highlight is within the visible scroll window
_form_ensure_dir_highlight_visible() {
    local total=${#_FORM_DIR_FILTERED[@]}
    local visible=$_FORM_DIR_SUGGESTION_LINES
    if [[ $total -le $visible ]]; then
        _FORM_DIR_SCROLL_OFFSET=0
        return
    fi

    local highlight=$_FORM_DIR_HIGHLIGHT
    # Scroll up if highlight is above window
    if [[ $highlight -lt $_FORM_DIR_SCROLL_OFFSET ]]; then
        _FORM_DIR_SCROLL_OFFSET=$highlight
        return
    fi

    # Scroll down if highlight is below visible entries
    while true; do
        local offset=$_FORM_DIR_SCROLL_OFFSET
        local entry_lines=$visible
        [[ $offset -gt 0 ]] && ((entry_lines--))
        [[ $((offset + entry_lines)) -lt $total ]] && ((entry_lines--))
        if [[ $highlight -lt $((offset + entry_lines)) ]]; then
            break
        fi
        ((_FORM_DIR_SCROLL_OFFSET++))
    done
}

# Process a single keystroke. Sets FORM_KEY_RESULT to "continue", "submit", or "cancel".
# Must be called in current shell (not a subshell) so mutations take effect.
# Dispatches to mode-specific handler based on _FORM_MODE.
FORM_KEY_RESULT=""
_form_process_key() {
    local key="$1"
    local extra="${2:-__unset__}"

    if [[ "$_FORM_MODE" == "edit" ]]; then
        _form_process_key_edit "$key" "$extra"
    else
        _form_process_key_navigate "$key" "$extra"
    fi
}

# Navigate mode: move between fields, toggle/cycle, enter edit mode
_form_process_key_navigate() {
    local key="$1"
    local extra="$2"

    case "$key" in
        $'\n'|"")
            local name="${FORM_FIELDS[$FORM_CURSOR]}"
            local type="${FORM_TYPES[$name]}"
            local disabled="${FORM_DISABLED[$name]:-}"
            case "$type" in
                text|directory)
                    if [[ "$disabled" == "true" ]]; then
                        FORM_KEY_RESULT="continue"
                    else
                        _FORM_MODE="edit"
                        FORM_KEY_RESULT="continue"
                    fi
                    ;;
                checkbox|select)
                    FORM_KEY_RESULT="submit"
                    ;;
                submit)
                    FORM_KEY_RESULT="submit"
                    ;;
            esac
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                FORM_KEY_RESULT="cancel"
            else
                case "$extra" in
                    "[A") _form_handle_up; FORM_KEY_RESULT="continue" ;;
                    "[B") _form_handle_down; FORM_KEY_RESULT="continue" ;;
                    "[C"|"[D")
                        local _nav_name="${FORM_FIELDS[$FORM_CURSOR]}"
                        local _nav_type="${FORM_TYPES[$_nav_name]}"
                        local _nav_disabled="${FORM_DISABLED[$_nav_name]:-}"
                        if [[ "$_nav_disabled" != "true" ]]; then
                            case "$_nav_type" in
                                select)
                                    if [[ "$extra" == "[C" ]]; then
                                        _form_cycle_select "$_nav_name" 1
                                    else
                                        _form_cycle_select "$_nav_name" -1
                                    fi
                                    ;;
                                checkbox) _form_handle_space ;;
                            esac
                        fi
                        FORM_KEY_RESULT="continue"
                        ;;
                    *) FORM_KEY_RESULT="continue" ;;
                esac
            fi
            ;;
        " ")
            _form_handle_space
            FORM_KEY_RESULT="continue"
            ;;
        $'\x13')
            # Ctrl-S: submit from anywhere
            FORM_KEY_RESULT="submit"
            ;;
        *)
            # Ignore all other keys in navigate mode
            FORM_KEY_RESULT="continue"
            ;;
    esac
}

# Edit mode: type into current field, scroll directory suggestions
_form_process_key_edit() {
    local key="$1"
    local extra="$2"

    case "$key" in
        $'\n'|"")
            # On directory field, Enter accepts highlighted suggestion
            local name="${FORM_FIELDS[$FORM_CURSOR]}"
            if [[ "${FORM_TYPES[$name]}" == "directory" && ${#_FORM_DIR_FILTERED[@]} -gt 0 ]]; then
                local idx=$_FORM_DIR_HIGHLIGHT
                [[ $idx -ge ${#_FORM_DIR_FILTERED[@]} ]] && idx=0
                local entry="${_FORM_DIR_FILTERED[$idx]}"
                FORM_VALUES[$name]="${entry%%$'\t'*}"
            fi
            _FORM_MODE="navigate"
            FORM_KEY_RESULT="continue"
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                # Esc: exit edit mode (not cancel)
                _FORM_MODE="navigate"
                FORM_KEY_RESULT="continue"
            else
                local name="${FORM_FIELDS[$FORM_CURSOR]}"
                local type="${FORM_TYPES[$name]}"
                case "$extra" in
                    "[A")
                        # Up: scroll directory suggestions
                        if [[ "$type" == "directory" && $_FORM_DIR_HIGHLIGHT -gt 0 ]]; then
                            ((_FORM_DIR_HIGHLIGHT--))
                            _form_ensure_dir_highlight_visible
                        fi
                        FORM_KEY_RESULT="continue"
                        ;;
                    "[B")
                        # Down: scroll directory suggestions
                        if [[ "$type" == "directory" ]]; then
                            local max=$(( ${#_FORM_DIR_FILTERED[@]} - 1 ))
                            [[ $max -lt 0 ]] && max=0
                            if [[ $_FORM_DIR_HIGHLIGHT -lt $max ]]; then
                                ((_FORM_DIR_HIGHLIGHT++))
                                _form_ensure_dir_highlight_visible
                            fi
                        fi
                        FORM_KEY_RESULT="continue"
                        ;;
                    *) FORM_KEY_RESULT="continue" ;;
                esac
            fi
            ;;
        " ")
            # Space types a literal space in edit mode
            _form_handle_char " "
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
_FORM_DIR_SUGGESTION_LINES=10
_FORM_DIR_FILTER_MAX=50

# Row where dynamic content starts (after header)
_FORM_CONTENT_ROW=3

# Draw the static header (called once at form start)
_form_draw_header() {
    printf '%s' "${_FORM_CUP_PREFIX}0;0H" > /dev/tty
    printf '%s  New Session%s\n' "${_FORM_BOLD}" "${_FORM_RESET}" > /dev/tty
    printf '  ↑↓: move  ←→/Space: toggle  Enter: edit  Ctrl-S: create  Esc: back/cancel%s\n' "${_FORM_EL}" > /dev/tty
    printf '%s\n' "${_FORM_EL}" > /dev/tty
}

# Draw the form fields to /dev/tty (not stdout, which may be captured by $()).
# Header is static (drawn once). Only fields + suggestions are redrawn per keystroke.
# Directory suggestions always occupy their fixed space to prevent layout shifts.
# All output is buffered into a single write to minimize flicker.
_form_draw() {
    local row=$_FORM_CONTENT_ROW
    _FORM_BUF="${_FORM_CUP_PREFIX}${row};0H"

    # Render each field
    local i name
    for ((i=0; i<${#FORM_FIELDS[@]}; i++)); do
        name="${FORM_FIELDS[$i]}"
        local focused="false"
        [[ $i -eq $FORM_CURSOR ]] && focused="true"
        _form_render_field "$name" "$focused"

        # Directory suggestions always shown (stable layout)
        if [[ "$name" == "directory" ]]; then
            local dir_focused="false"
            [[ "$focused" == "true" ]] && dir_focused="true"
            _form_filter_dir_suggestions "${FORM_VALUES[directory]}" "$_FORM_DIR_FILTER_MAX"
            local total=${#_FORM_DIR_FILTERED[@]}
            local visible=$_FORM_DIR_SUGGESTION_LINES
            local offset=$_FORM_DIR_SCROLL_OFFSET

            # Clamp offset
            if [[ $total -le $visible ]]; then
                offset=0
            else
                local max_offset=$((total - visible + 1))
                [[ $offset -gt $max_offset ]] && offset=$max_offset
            fi
            _FORM_DIR_SCROLL_OFFSET=$offset

            # Compute indicators and entry count
            local has_above=false has_below=false
            local entry_lines=$visible
            [[ $offset -gt 0 ]] && { has_above=true; ((entry_lines--)); }
            [[ $((offset + entry_lines)) -lt $total ]] && { has_below=true; ((entry_lines--)); }

            local scount=0 si

            # Scroll-up indicator
            if [[ "$has_above" == true ]]; then
                _FORM_BUF+="    ${_FORM_DIM}▲ $offset more${_FORM_RESET}${_FORM_EL}"$'\n'
                ((scount++))
            fi

            # Directory entries
            for ((si=offset; si < offset + entry_lines && si < total; si++)); do
                local sline="${_FORM_DIR_FILTERED[$si]}"
                local spath="${sline%%$'\t'*}"
                local sannotation=""
                [[ "$sline" == *$'\t'* ]] && sannotation="${sline#*$'\t'}"
                if [[ "$dir_focused" == "true" && $si -eq $_FORM_DIR_HIGHLIGHT ]]; then
                    _FORM_BUF+="    ${_FORM_CYAN}${spath}${_FORM_RESET}"
                    [[ -n "$sannotation" ]] && _FORM_BUF+="  ${_FORM_DIM}${sannotation}${_FORM_RESET}"
                else
                    _FORM_BUF+="    ${_FORM_DIM}${spath}${_FORM_RESET}"
                    [[ -n "$sannotation" ]] && _FORM_BUF+="  ${_FORM_DIM}${sannotation}${_FORM_RESET}"
                fi
                _FORM_BUF+="${_FORM_EL}"$'\n'
                ((scount++))
            done

            # Scroll-down indicator
            if [[ "$has_below" == true ]]; then
                local remaining=$((total - offset - entry_lines))
                _FORM_BUF+="    ${_FORM_DIM}▼ $remaining more${_FORM_RESET}${_FORM_EL}"$'\n'
                ((scount++))
            fi

            # Pad to fixed height
            while [[ $scount -lt $visible ]]; do
                _FORM_BUF+="${_FORM_EL}"$'\n'
                ((scount++))
            done
        fi
    done

    # Clear extra lines for field count changes
    _FORM_BUF+="${_FORM_EL}"$'\n'"${_FORM_EL}"$'\n'"${_FORM_EL}"$'\n'

    # Single write to terminal
    printf '%s' "$_FORM_BUF" > /dev/tty
}

# Main form loop
# Returns form values on stdout (same format as fzf_new_session_form).
# All rendering and input go through /dev/tty so this works inside $() capture.
_form_run() {
    printf '%s' "${_FORM_HIDE_CURSOR}" > /dev/tty
    # Use smcup via tput (only called once, not per-frame)
    tput smcup > /dev/tty 2>/dev/null || true
    trap '_form_cleanup' EXIT INT TERM

    # Disable XON/XOFF flow control so Ctrl-S reaches us
    local _form_old_stty
    _form_old_stty=$(stty -g < /dev/tty 2>/dev/null) || true
    stty -ixon < /dev/tty 2>/dev/null || true

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
    { tput rmcup 2>/dev/null || true; printf '%s' "${_FORM_SHOW_CURSOR}"; } > /dev/tty
    # Restore terminal settings (XON/XOFF)
    [[ -n "${_form_old_stty:-}" ]] && stty "$_form_old_stty" < /dev/tty 2>/dev/null || true
}

_form_cleanup() {
    _form_cleanup_screen
    trap - EXIT INT TERM
}

# Format output matching fzf_new_session_form contract:
# directory<US>agent<US>task<US>worktree_name<US>flags  (US = \x1f unit separator)
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

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$directory" "$agent" "$task" "$worktree" "$flags"
}

# Dispatch function: picks form implementation based on feature flag.
# Same signature and output as fzf_new_session_form().
am_new_session_form() {
    if am_new_form_enabled; then
        local prefill_directory="${1:-}"
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

        # --yolo implies sandbox + worktree
        if [[ "$yolo" == "true" ]]; then
            [[ "$docker_available" == "true" ]] && sandbox="true"
            worktree_enabled="true"
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
