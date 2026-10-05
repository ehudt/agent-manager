# shellcheck shell=bash
# form.sh - tput-based new session form

# Source dependencies if not already loaded
_FORM_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "$AM_DIR" ]] && source "$_FORM_LIB_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$_FORM_LIB_DIR/config.sh"
[[ "$(type -t agent_type_supported)" != "function" ]] && source "$_FORM_LIB_DIR/agents.sh"

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
_FORM_PASTE_ON=$'\033[?2004h'     # bracketed paste: a paste arrives as \e[200~ … \e[201~
_FORM_PASTE_OFF=$'\033[?2004l'

# Terminal width (set by _form_size_to_terminal); long values scroll inside it.
_FORM_COLS=80

# Input fd on /dev/tty, opened once by _form_run (0 until then).
_FORM_TTY_FD=0

# Line-editor cursor of the focused text/directory field. _FORM_POS_FIELD and
# _FORM_POS_VALUE record which field and value the position belongs to: any
# change made elsewhere (Tab accepting a suggestion, a preset, the prefill)
# no longer matches, and _form_pos_sync puts the cursor back at the end.
_FORM_POS=0
_FORM_POS_FIELD=""
_FORM_POS_VALUE=""
_FORM_HSCROLL=0

# Form field definitions (declare -g: stay global when sourced inside a function)
declare -ga FORM_FIELDS=()
declare -gA FORM_VALUES=()
declare -gA FORM_TYPES=()
declare -gA FORM_LABELS=()
declare -gA FORM_OPTIONS=()
FORM_CURSOR=0

# Mode: "navigate" or "edit"
_FORM_MODE="navigate"

# The initial screen is a directory-first launcher. Advanced options are hidden
# until requested with Tab.
_FORM_OPTIONS_OPEN=false

# Directory suggestion highlight index (used in edit mode)
_FORM_DIR_HIGHLIGHT=0
_FORM_DIR_SCROLL_OFFSET=0

# Directory suggestions cache
declare -ga _FORM_DIR_SUGGESTIONS=()
_FORM_DIR_SUGGESTIONS_LOADED=false

# Filtered results cache (avoids subshell)
declare -ga _FORM_DIR_FILTERED=()

# Provider suggestions per typed partial (`@...` queries): one provider call
# per distinct text, so redraws and cursor moves never re-run it.
declare -gA _FORM_PROVIDER_CACHE=()

# Initialize form state
# Usage: _form_init <directory> <agent> <task>
_form_init() {
    local directory="$1"
    local agent="$2"
    local task="$3"

    FORM_FIELDS=()
    FORM_VALUES=()
    FORM_TYPES=()
    FORM_LABELS=()
    FORM_OPTIONS=()
    FORM_CURSOR=0
    _FORM_DIR_SUGGESTIONS=()
    _FORM_DIR_SUGGESTIONS_LOADED=false
    _FORM_DIR_FILTERED=()
    _FORM_PROVIDER_CACHE=()
    _FORM_MODE="edit"
    _FORM_OPTIONS_OPEN=false
    _FORM_DIR_HIGHLIGHT=0
    _FORM_DIR_SCROLL_OFFSET=0
    _FORM_POS=0
    _FORM_POS_FIELD=""
    _FORM_POS_VALUE=""
    _FORM_HSCROLL=0

    # Preset picker: only when presets exist, and first so picking one fills
    # the fields below. Field indices for everyone else stay unchanged.
    _FORM_PRESET_NAMES=""
    if [[ "$(type -t am_preset_names)" == "function" ]]; then
        _FORM_PRESET_NAMES=$(am_preset_names | tr '\n' ',')
        _FORM_PRESET_NAMES="${_FORM_PRESET_NAMES%,}"
    fi
    if [[ -n "$_FORM_PRESET_NAMES" ]]; then
        _form_add_field "preset" "Preset" "select" "-"
        FORM_OPTIONS[preset]="-,${_FORM_PRESET_NAMES}"
    fi

    # The Directory field also takes `@spec` (resolved by the dir_provider);
    # see _form_filter_dir_suggestions for the provider-backed suggestions.
    _form_add_field "directory"         "Directory"      "directory"  "$directory"
    _form_add_field "agent"             "Agent"          "select"     "$agent"
    _form_add_field "task"              "Task"           "text"       "$task"

    FORM_OPTIONS[agent]=$(printf '%s\n' "${!AGENT_COMMANDS[@]}" | sort | tr '\n' ',')
}

_form_add_field() {
    local name="$1" label="$2" type="$3" value="$4"
    FORM_FIELDS+=("$name")
    FORM_LABELS[$name]="$label"
    FORM_TYPES[$name]="$type"
    FORM_VALUES[$name]="$value"
}

# Render a single field line directly to the output buffer (no subshell).
# Appends to the _FORM_BUF variable.
_form_render_field() {
    local name="$1"
    local focused="${2:-false}"
    local label="${FORM_LABELS[$name]}"
    local type="${FORM_TYPES[$name]}"
    local value="${FORM_VALUES[$name]}"

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
            if [[ "$focused" == "true" && "$_FORM_MODE" == "edit" ]]; then
                _form_pos_sync
                _form_value_view "$value" "$_FORM_POS" "$(( _FORM_COLS - 18 ))"
                display="$_FORM_VIEW"
            else
                _form_value_view "$value" -1 "$(( _FORM_COLS - 18 ))"
                display="$_FORM_VIEW"
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

    local padded
    printf -v padded '%-14s' "$label:"
    if [[ "$focused" == "true" ]]; then
        _FORM_BUF+="${prefix}${bg}${padded}${_FORM_RESET} ${display}${_FORM_EL}"$'\n'
    else
        _FORM_BUF+="${prefix}${padded} ${display}${_FORM_EL}"$'\n'
    fi
}

# Fit a field value into <width> columns, into _FORM_VIEW. With pos >= 0 the
# cell under the cursor is drawn inverse (one past the end when pos is the
# length) and a value wider than the field scrolls horizontally to keep the
# cursor in view, `…` marking the hidden side; with pos -1 a long value is
# cut with a trailing `…`. A field never wraps, which would shift every row
# below it.
# Usage: _form_value_view <value> <pos> <width>
_form_value_view() {
    local value="$1" pos="$2" width="$3"
    (( width < 4 )) && width=4
    local len=${#value}

    if (( pos < 0 )); then
        if (( len > width )); then
            _FORM_VIEW="${value:0:width-1}…"
        else
            _FORM_VIEW="$value"
        fi
        return 0
    fi

    local cells=$(( len + 1 )) start=0
    if (( cells > width )); then
        start=$_FORM_HSCROLL
        # One cell of margin each side, so a `…` never covers the cursor.
        (( pos < start + 1 )) && start=$(( pos - 1 ))
        (( pos > start + width - 2 )) && start=$(( pos - width + 2 ))
        (( start > cells - width )) && start=$(( cells - width ))
        (( start < 0 )) && start=0
    fi
    _FORM_HSCROLL=$start

    local vis="${value} "
    vis="${vis:start:width}"
    (( start > 0 )) && vis="…${vis:1}"
    (( start + width < cells )) && vis="${vis:0:width-1}…"
    local rel=$(( pos - start ))
    _FORM_VIEW="${vis:0:rel}${_FORM_INVERSE}${vis:rel:1}${_FORM_RESET}${vis:rel+1}"
}

# Load directory suggestions (once, lazily)
_form_load_dir_suggestions() {
    [[ "$_FORM_DIR_SUGGESTIONS_LOADED" == "true" ]] && return 0
    _FORM_DIR_SUGGESTIONS=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _FORM_DIR_SUGGESTIONS+=("$line")
    done < <(_list_directories "" false 2>/dev/null || true)
    _FORM_DIR_SUGGESTIONS_LOADED=true
}

# Filter directory suggestions into _FORM_DIR_FILTERED array (no subshell).
# A query starting with `@` is a provider spec: the candidates come from
# `<dir_provider> suggest <partial>` instead (cached per partial), each shown
# as `@spec` with the provider's label as annotation; with no candidates the
# typed spec itself is offered so Enter still resolves it.
# Usage: _form_filter_dir_suggestions <query> <max>
_form_filter_dir_suggestions() {
    local query="$1"
    local max="${2:-5}"
    local count=0
    local entry path

    _FORM_DIR_FILTERED=()

    if [[ "$query" == @* ]]; then
        # Cache key keeps the `@`: bash rejects an empty associative-array
        # subscript, and bare `@` (the provider's default) is the common case.
        local partial="${query#@}" lines
        if [[ -z "${_FORM_PROVIDER_CACHE[$query]+set}" ]]; then
            lines=$(agent_dir_suggest "$partial")
            _FORM_PROVIDER_CACHE[$query]="$lines"
        fi
        lines="${_FORM_PROVIDER_CACHE[$query]}"
        if [[ -z "$lines" ]]; then
            _FORM_DIR_FILTERED+=("@${partial}"$'\t'"resolve with dir_provider")
            return
        fi
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            _FORM_DIR_FILTERED+=("@${entry}")
            ((count++))
            [[ $count -ge $max ]] && break
        done <<< "$lines"
        return
    fi

    _form_load_dir_suggestions

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

# A select changed value: the Preset field fills the other fields.
# Usage: _form_after_select_change <field-name>
_form_after_select_change() {
    [[ "$1" == "preset" ]] || return 0
    _form_apply_preset "${FORM_VALUES[preset]}"
}

# Copy a preset's directory (path or @spec), agent, and task into the form
# fields. The preset's agent args and shell flag travel to cmd_new via
# --preset=<name> in the flags output (see _form_output), so they are applied
# there.
# Usage: _form_apply_preset <name>
_form_apply_preset() {
    local name="$1"
    [[ -n "$name" && "$name" != "-" ]] && am_preset_get "$name" >/dev/null 2>&1 || return 0
    local v
    v=$(am_preset_field "$name" directory); [[ -n "$v" ]] && FORM_VALUES[directory]="$v"
    v=$(am_preset_field "$name" agent);     [[ -n "$v" ]] && FORM_VALUES[agent]="$v"
    v=$(am_preset_field "$name" task);      [[ -n "$v" ]] && FORM_VALUES[task]="$v"
    return 0
}

# Handle space: cycle select
_form_handle_space() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    if [[ "$type" == "select" ]]; then
        _form_cycle_select "$name" 1
        _form_after_select_change "$name"
    fi
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

# Attach the line-editor cursor to the focused field: unless it still holds
# the value the cursor was last placed in, the cursor goes to its end.
_form_pos_sync() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local value="${FORM_VALUES[$name]}"
    if [[ "$name" != "$_FORM_POS_FIELD" || "$value" != "$_FORM_POS_VALUE" ]]; then
        _FORM_POS=${#value}
        _FORM_POS_FIELD="$name"
        _FORM_POS_VALUE="$value"
        _FORM_HSCROLL=0
    fi
    (( _FORM_POS > ${#value} )) && _FORM_POS=${#value}
    return 0
}

# Word boundaries for the line editor, into _FORM_WORD_AT. "alnum" words
# (Alt-B/F/D/Backspace, Ctrl/Alt-arrows) stop at any non-alphanumeric
# character, so they step through path components; "space" words (Ctrl-W)
# run to whitespace, as in readline.
# Usage: _form_word_left <value> <pos> alnum|space
_form_word_left() {
    local v="$1" p="$2" kind="$3"
    local word='[[:alnum:]]'
    [[ "$kind" == "space" ]] && word='[^[:space:]]'
    while (( p > 0 )) && [[ ! "${v:p-1:1}" =~ $word ]]; do p=$(( p - 1 )); done
    while (( p > 0 )) && [[ "${v:p-1:1}" =~ $word ]]; do p=$(( p - 1 )); done
    _FORM_WORD_AT=$p
}

# Usage: _form_word_right <value> <pos>
_form_word_right() {
    local v="$1" p="$2" len=${#1}
    while (( p < len )) && [[ ! "${v:p:1}" =~ [[:alnum:]] ]]; do p=$(( p + 1 )); done
    while (( p < len )) && [[ "${v:p:1}" =~ [[:alnum:]] ]]; do p=$(( p + 1 )); done
    _FORM_WORD_AT=$p
}

# Apply one line-editing operation to the focused text/directory field at
# the cursor. Returns 1 (nothing done) on a select field.
# Ops: insert <text>, backspace, delete, left, right, home, end, word_left,
# word_right, kill_word_left (Alt-Backspace), kill_word_right (Alt-D),
# kill_space_word_left (Ctrl-W), kill_to_start (Ctrl-U), kill_to_end (Ctrl-K).
# Usage: _form_edit <op> [text]
_form_edit() {
    local op="$1" text="${2:-}"
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"
    [[ "$type" == "text" || "$type" == "directory" ]] || return 1

    _form_pos_sync
    local v="${FORM_VALUES[$name]}" p=$_FORM_POS
    local len=${#v}

    case "$op" in
        insert)          v="${v:0:p}${text}${v:p}"; p=$(( p + ${#text} )) ;;
        backspace)       if (( p > 0 )); then v="${v:0:p-1}${v:p}"; p=$(( p - 1 )); fi ;;
        delete)          if (( p < len )); then v="${v:0:p}${v:p+1}"; fi ;;
        left)            if (( p > 0 )); then p=$(( p - 1 )); fi ;;
        right)           if (( p < len )); then p=$(( p + 1 )); fi ;;
        home)            p=0 ;;
        end)             p=$len ;;
        word_left)       _form_word_left "$v" "$p" alnum; p=$_FORM_WORD_AT ;;
        word_right)      _form_word_right "$v" "$p"; p=$_FORM_WORD_AT ;;
        kill_word_left)  _form_word_left "$v" "$p" alnum; v="${v:0:_FORM_WORD_AT}${v:p}"; p=$_FORM_WORD_AT ;;
        kill_space_word_left)
                         _form_word_left "$v" "$p" space; v="${v:0:_FORM_WORD_AT}${v:p}"; p=$_FORM_WORD_AT ;;
        kill_word_right) _form_word_right "$v" "$p"; v="${v:0:p}${v:_FORM_WORD_AT}" ;;
        kill_to_start)   v="${v:p}"; p=0 ;;
        kill_to_end)     v="${v:0:p}" ;;
        *)               return 0 ;;
    esac

    if [[ "$v" != "${FORM_VALUES[$name]}" ]]; then
        FORM_VALUES[$name]="$v"
        if [[ "$type" == "directory" ]]; then
            _FORM_DIR_HIGHLIGHT=0
            _FORM_DIR_SCROLL_OFFSET=0
        fi
    fi
    _FORM_POS=$p
    _FORM_POS_VALUE="$v"
    return 0
}

# Handle a printable character: insert at the cursor of text/directory fields
_form_handle_char() {
    _form_edit insert "$1" || true
}

# Handle backspace: remove the character before the cursor
_form_handle_backspace() {
    _form_edit backspace || true
}

# Insert pasted text at the cursor (edit mode only). The fields are single
# lines: trailing line breaks are dropped (a copied path usually ends in
# one), inner line breaks and tabs become spaces, other control characters
# are removed.
# Usage: _form_handle_paste <text>
_form_handle_paste() {
    local text="$1"
    FORM_KEY_RESULT="continue"
    [[ "$_FORM_MODE" == "edit" ]] || return 0
    while [[ "$text" == *$'\n' || "$text" == *$'\r' ]]; do text="${text%?}"; done
    text="${text//$'\r\n'/ }"
    text="${text//[$'\r\n\t']/ }"
    text="${text//[[:cntrl:]]/}"
    [[ -n "$text" ]] || return 0
    _form_edit insert "$text" || true
}

# Map the bytes after ESC to a line-editing op (into _FORM_EDIT_OP; empty
# when the sequence is not an editing key). Covers the xterm/VT encodings of
# the arrows, Home/End and Delete, their Ctrl/Alt/Cmd-modified forms
# (1;5 / 1;3 / 1;9), and readline's Alt-letter bindings.
# Usage: _form_escape_edit_op <seq>
_form_escape_edit_op() {
    case "$1" in
        "[D"|"OD")                          _FORM_EDIT_OP=left ;;
        "[C"|"OC")                          _FORM_EDIT_OP=right ;;
        "[H"|"OH"|"[1~"|"[7~")              _FORM_EDIT_OP=home ;;
        "[F"|"OF"|"[4~"|"[8~")              _FORM_EDIT_OP=end ;;
        "[3~")                              _FORM_EDIT_OP=delete ;;
        "[1;3D"|"[1;5D"|"[1;9D"|"Od"|b|B)   _FORM_EDIT_OP=word_left ;;
        "[1;3C"|"[1;5C"|"[1;9C"|"Oc"|f|F)   _FORM_EDIT_OP=word_right ;;
        $'\x7f'|$'\b')                      _FORM_EDIT_OP=kill_word_left ;;
        d|D|"[3;3~"|"[3;5~")                _FORM_EDIT_OP=kill_word_right ;;
        *)                                  _FORM_EDIT_OP="" ;;
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

# Accept the current directory candidate and reveal advanced options.
_form_open_options() {
    _form_handle_tab
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="navigate"
    FORM_CURSOR=1
}

# Accept the current directory candidate and optionally override the harness.
_form_launch_from_directory() {
    local agent="${1:-}"
    _form_handle_tab
    [[ -n "$agent" ]] && FORM_VALUES[agent]="$agent"
    FORM_KEY_RESULT="submit"
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
            case "$type" in
                directory)
                    _FORM_OPTIONS_OPEN=false
                    _FORM_MODE="edit"
                    FORM_KEY_RESULT="continue"
                    ;;
                text)
                    _FORM_MODE="edit"
                    FORM_KEY_RESULT="continue"
                    ;;
                select)
                    FORM_KEY_RESULT="submit"
                    ;;
            esac
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                if [[ "$_FORM_OPTIONS_OPEN" == "true" ]]; then
                    _FORM_OPTIONS_OPEN=false
                    _FORM_MODE="edit"
                    FORM_CURSOR=0
                    FORM_KEY_RESULT="continue"
                else
                    FORM_KEY_RESULT="cancel"
                fi
            else
                case "$extra" in
                    "[A") _form_handle_up; FORM_KEY_RESULT="continue" ;;
                    "[B") _form_handle_down; FORM_KEY_RESULT="continue" ;;
                    "[C"|"[D")
                        local _nav_name="${FORM_FIELDS[$FORM_CURSOR]}"
                        local _nav_type="${FORM_TYPES[$_nav_name]}"
                        if [[ "$_nav_type" == "select" ]]; then
                            if [[ "$extra" == "[C" ]]; then
                                _form_cycle_select "$_nav_name" 1
                            else
                                _form_cycle_select "$_nav_name" -1
                            fi
                            _form_after_select_change "$_nav_name"
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
            local name="${FORM_FIELDS[$FORM_CURSOR]}"
            if [[ "${FORM_TYPES[$name]}" == "directory" ]]; then
                _form_handle_tab
                if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                    FORM_KEY_RESULT="submit"
                else
                    _FORM_MODE="navigate"
                    FORM_KEY_RESULT="continue"
                fi
            else
                _FORM_MODE="navigate"
                FORM_KEY_RESULT="continue"
            fi
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                    FORM_KEY_RESULT="cancel"
                else
                    # In advanced options, Esc exits field editing.
                    _FORM_MODE="navigate"
                    FORM_KEY_RESULT="continue"
                fi
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
                    *)
                        # Cursor movement and word deletion
                        _form_escape_edit_op "$extra"
                        [[ -n "$_FORM_EDIT_OP" ]] && { _form_edit "$_FORM_EDIT_OP" || true; }
                        FORM_KEY_RESULT="continue"
                        ;;
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
        $'\x01'|$'\x05'|$'\x02'|$'\x06'|$'\x04'|$'\x0b'|$'\x15'|$'\x17')
            # readline/emacs line editing: Ctrl-A/E home/end, Ctrl-B/F
            # left/right, Ctrl-D delete, Ctrl-K/U kill to end/start, Ctrl-W
            # kill the previous word.
            local _edit_op
            case "$key" in
                $'\x01') _edit_op=home ;;
                $'\x05') _edit_op=end ;;
                $'\x02') _edit_op=left ;;
                $'\x06') _edit_op=right ;;
                $'\x04') _edit_op=delete ;;
                $'\x0b') _edit_op=kill_to_end ;;
                $'\x15') _edit_op=kill_to_start ;;
                $'\x17') _edit_op=kill_space_word_left ;;
            esac
            _form_edit "$_edit_op" || true
            FORM_KEY_RESULT="continue"
            ;;
        $'\t')
            local name="${FORM_FIELDS[$FORM_CURSOR]}"
            if [[ "$_FORM_OPTIONS_OPEN" == "false" && "${FORM_TYPES[$name]}" == "directory" ]]; then
                _form_open_options
            else
                _form_handle_tab
            fi
            FORM_KEY_RESULT="continue"
            ;;
        $'\x13')
            # Ctrl-S remains a global launch shortcut, including directory edit.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory
            else
                FORM_KEY_RESULT="submit"
            fi
            ;;
        $'\x0c')
            # Ctrl-L: launch Claude from the directory launcher.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory "claude"
            else
                FORM_KEY_RESULT="continue"
            fi
            ;;
        $'\x18')
            # Ctrl-X: launch Codex from the directory launcher.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory "codex"
            else
                FORM_KEY_RESULT="continue"
            fi
            ;;
        $'\x12')
            # Ctrl-R: launch Cursor from the directory launcher.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory "cursor"
            else
                FORM_KEY_RESULT="continue"
            fi
            ;;
        $'\x10')
            # Ctrl-P: launch pi from the directory launcher.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory "pi"
            else
                FORM_KEY_RESULT="continue"
            fi
            ;;
        $'\x0f')
            # Ctrl-O: launch opencode from the directory launcher.
            if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
                _form_launch_from_directory "opencode"
            else
                FORM_KEY_RESULT="continue"
            fi
            ;;
        *)
            if [[ "$key" =~ [[:print:]] ]]; then
                _form_handle_char "$key"
            fi
            FORM_KEY_RESULT="continue"
            ;;
    esac
}

# Number of inline directory suggestion lines. Default suits the smallest
# supported popup; _form_run grows it to fill the actual terminal height.
_FORM_DIR_SUGGESTION_LINES=7
_FORM_DIR_FILTER_MAX=50

# Grow the suggestion window to the terminal: header (3 lines + blank) +
# directory field + suggestions + 2 padding rows must stay above the bottom
# row, or the trailing newline scrolls the popup.
_form_size_to_terminal() {
    local rows="" cols=""
    rows=$(stty size < /dev/tty 2>/dev/null) || return 0
    cols="${rows##* }"
    rows="${rows%% *}"
    [[ "$cols" =~ ^[0-9]+$ ]] && _FORM_COLS=$cols
    [[ "$rows" =~ ^[0-9]+$ ]] || return 0
    if (( rows - 7 > _FORM_DIR_SUGGESTION_LINES )); then
        _FORM_DIR_SUGGESTION_LINES=$(( rows - 7 ))
    fi
}

# Row where dynamic content starts (after header)
_FORM_CONTENT_ROW=4

# Draw a stage-specific header.
_form_draw_header() {
    local hdr="${_FORM_CUP_PREFIX}0;0H"
    if [[ "$_FORM_OPTIONS_OPEN" == "false" ]]; then
        hdr+="${_FORM_BOLD}  New Session${_FORM_RESET}${_FORM_EL}"$'\n'
        hdr+="  Enter: launch ${FORM_VALUES[agent]}  Ctrl-L: Claude  Ctrl-X: Codex${_FORM_EL}"$'\n'
        hdr+="  Ctrl-R: Cursor  Ctrl-P: Pi  Tab: options  Esc: cancel${_FORM_EL}"$'\n'
    else
        hdr+="${_FORM_BOLD}  New Session — Options${_FORM_RESET}${_FORM_EL}"$'\n'
        hdr+="  ↑↓: move  ←→/Space: change  Enter: edit/launch${_FORM_EL}"$'\n'
        hdr+="  Ctrl-S: launch  Esc: back${_FORM_EL}"$'\n'
    fi
    hdr+="${_FORM_EL}"$'\n'
    printf '%s' "$hdr" > /dev/tty
}

# Draw the form fields to /dev/tty (not stdout, which may be captured by $()).
# The launcher shows directory suggestions; the options stage shows all fields.
# The content area is padded so switching stages cannot leave stale rows.
# All output is buffered into a single write to minimize flicker.
_form_draw() {
    local row=$_FORM_CONTENT_ROW
    _FORM_BUF="${_FORM_CUP_PREFIX}${row};0H"
    local rendered_lines=0

    # Render each field
    local i name
    for ((i=0; i<${#FORM_FIELDS[@]}; i++)); do
        name="${FORM_FIELDS[$i]}"
        if [[ "$_FORM_OPTIONS_OPEN" == "false" && "$name" != "directory" ]]; then
            continue
        fi
        local focused="false"
        [[ $i -eq $FORM_CURSOR ]] && focused="true"
        _form_render_field "$name" "$focused"
        rendered_lines=$((rendered_lines + 1))

        # Suggestions belong to the fast launcher; options use the selected path.
        if [[ "$name" == "directory" && "$_FORM_OPTIONS_OPEN" == "false" ]]; then
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
            rendered_lines=$((rendered_lines + scount))
        fi
    done

    # Clear stale suggestion or option rows when switching stages.
    while [[ $rendered_lines -lt $((_FORM_DIR_SUGGESTION_LINES + 3)) ]]; do
        _FORM_BUF+="${_FORM_EL}"$'\n'
        rendered_lines=$((rendered_lines + 1))
    done

    # Single write to terminal
    printf '%s' "$_FORM_BUF" > /dev/tty
}

# Main form loop
# Returns form values on stdout.
# All rendering and input go through /dev/tty so this works inside $() capture.
_form_run() {
    _form_size_to_terminal
    # Use smcup via tput (only called once, not per-frame)
    tput smcup > /dev/tty 2>/dev/null || true
    printf '%s%s' "${_FORM_HIDE_CURSOR}" "${_FORM_PASTE_ON}" > /dev/tty
    trap '_form_cleanup' EXIT INT TERM

    # Echo stays off for the whole form, not just inside each read: keys that
    # arrive while a frame is drawn (a paste) were echoed by the terminal
    # wherever the draw had left the cursor, scribbling over the header.
    # Non-canonical so Ctrl-U / Ctrl-W reach the editor; -ixon so Ctrl-S
    # does, -iexten so Ctrl-O / Ctrl-V do.
    local _form_old_stty
    _form_old_stty=$(stty -g < /dev/tty 2>/dev/null) || true
    stty -ixon -echo -icanon -iexten min 1 time 0 < /dev/tty 2>/dev/null || true
    exec {_FORM_TTY_FD}</dev/tty

    while true; do
        _form_draw_header
        _form_draw

        if ! _form_read_input; then
            _form_cleanup
            return 1
        fi
        # Handle everything already typed before the next frame: a paste
        # without bracketed-paste markers is a burst of keys, and a redraw
        # (plus a provider suggest call) per character made it crawl.
        while [[ "$FORM_KEY_RESULT" == "continue" ]] && read -t 0 -u "$_FORM_TTY_FD" 2>/dev/null; do
            _form_read_input || break
        done

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
    { printf '%s' "${_FORM_PASTE_OFF}"; tput rmcup 2>/dev/null || true; printf '%s' "${_FORM_SHOW_CURSOR}"; } > /dev/tty
    # Restore terminal settings (echo, canonical mode, XON/XOFF)
    [[ -n "${_form_old_stty:-}" ]] && stty "$_form_old_stty" < /dev/tty 2>/dev/null || true
    if (( _FORM_TTY_FD > 2 )); then
        exec {_FORM_TTY_FD}<&-
        _FORM_TTY_FD=0
    fi
    return 0
}

# Read one key from the tty and dispatch it to _form_process_key. ESC
# starts a sequence when more bytes follow within 50ms: CSI (`[` … final
# byte 0x40-0x7E, so `[1;5D` and `[3~` arrive whole), SS3 (`O` + one byte),
# or Alt+key (the key byte). ESC ESC + sequence is Alt+arrow on some
# terminals. A bracketed paste (`[200~` … ESC `[201~`) is read in one go and
# inserted as text, never interpreted as keys. Returns 1 at end of input.
_form_read_input() {
    local fd="$_FORM_TTY_FD" key="" ch="" seq="" ord=0 alt=false
    if ! IFS= read -rsn1 -u "$fd" key; then
        [[ -n "$key" ]] || return 1
    fi
    if [[ "$key" != $'\x1b' ]]; then
        _form_process_key "$key"
        return 0
    fi

    IFS= read -rsn1 -t 0.05 -u "$fd" ch || ch=""
    if [[ "$ch" == $'\x1b' ]]; then
        alt=true
        IFS= read -rsn1 -t 0.05 -u "$fd" ch || ch=""
    fi
    case "$ch" in
        "[")
            seq="["
            while IFS= read -rsn1 -t 0.05 -u "$fd" ch; do
                seq+="$ch"
                printf -v ord '%d' "'$ch"
                if (( ord >= 64 && ord <= 126 )); then break; fi
            done
            ;;
        O)
            seq="O"
            if IFS= read -rsn1 -t 0.05 -u "$fd" ch; then seq+="$ch"; fi
            ;;
        *)
            seq="$ch"
            ;;
    esac
    if [[ "$alt" == "true" ]]; then
        case "$seq" in
            "[C"|"OC") seq="[1;3C" ;;
            "[D"|"OD") seq="[1;3D" ;;
        esac
    fi

    if [[ "$seq" == "[200~" ]]; then
        _form_read_paste "$fd"
        _form_handle_paste "$_FORM_PASTE"
        return 0
    fi
    _form_process_key $'\x1b' "$seq"
}

# Read a bracketed paste body up to its closing ESC [201~ into _FORM_PASTE.
# An ESC inside the pasted text is kept. Gives up after 2s without input so
# a terminal that never sends the closing marker cannot hang the form.
# Usage: _form_read_paste <fd>
_form_read_paste() {
    local fd="$1" chunk="" c="" got="" marker="[201~" rc i
    _FORM_PASTE=""
    while true; do
        rc=0
        IFS= read -rs -d $'\x1b' -t 2 -u "$fd" chunk || rc=$?
        _FORM_PASTE+="$chunk"
        (( rc == 0 )) || return 0
        # After an ESC: the end marker, or text that merely contains an ESC.
        # Match byte by byte so a mismatch never swallows the real marker.
        while true; do
            got=""
            for ((i = 0; i < ${#marker}; i++)); do
                c=""
                IFS= read -rsn1 -d '' -t 0.1 -u "$fd" c || break
                [[ "$c" == "${marker:i:1}" ]] || break
                got+="$c"
            done
            [[ "$got" == "$marker" ]] && return 0
            _FORM_PASTE+=$'\x1b'"$got"
            # The mismatching byte may itself be the ESC that starts the marker.
            [[ "$c" == $'\x1b' ]] && continue
            _FORM_PASTE+="$c"
            break
        done
    done
}

_form_cleanup() {
    _form_cleanup_screen
    trap - EXIT INT TERM
}

# Format form values as tab-free \x1f-separated output:
# directory<US>agent<US>task<US>flags  (US = \x1f unit separator)
# flags carries --preset=<name> when a preset was picked; cmd_new consumes it
# rather than passing it to the agent. A `@spec` directory is passed through
# unvalidated (cmd_new resolves it) once a dir_provider is configured.
_form_output() {
    local directory="${FORM_VALUES[directory]}"
    local agent="${FORM_VALUES[agent]}"
    local task="${FORM_VALUES[task]}"

    directory="${directory/#\~/$HOME}"

    if [[ "$directory" == @* ]]; then
        if [[ -z "$(am_dir_provider)" ]]; then
            log_error "No directory provider configured for $directory (am config set dir_provider <cmd>)"
            return 1
        fi
    elif [[ -z "$directory" || ! -d "$directory" ]]; then
        log_error "Directory does not exist: ${directory:-<empty>}"
        return 1
    fi

    if [[ -z "$agent" || -z "${AGENT_COMMANDS[$agent]:-}" ]]; then
        log_error "Invalid agent type: ${agent:-<empty>}"
        return 1
    fi

    local flags=""
    # The picked preset's agent args and shell flag are applied by cmd_new.
    local preset="${FORM_VALUES[preset]:-}"
    if [[ -n "$preset" && "$preset" != "-" ]]; then
        flags+=" --preset=$preset"
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\n' "$directory" "$agent" "$task" "$flags"
}

# Entry point: parse prefill values, then run the tput form.
# Output: directory<US>agent<US>task<US>flags  (US = \x1f)
am_new_session_form() {
    local prefill_directory="${1:-}"
    local prefill_agent="${2:-$(am_default_agent)}"
    local prefill_task="${3:-}"

    local directory="${prefill_directory/#\~/$HOME}"

    _form_init "$directory" "$prefill_agent" "$prefill_task"
    _form_run
}
