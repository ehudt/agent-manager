# doctor.sh - `am doctor`: print every input behind a session's state in one shot
#
# The status bar, the browser, and `am status` show one resolved state per
# session. When that state looks wrong the inputs live in five places (the
# registry row, the tmux pane, the hook state file and its sidecars, the
# durable identity mirror, and the process tree) and the decision table in
# lib/state.sh picks between them. This module prints all of them, plus the
# layer that produced the answer, so "why is tab 3 showing X" is one command.
#
# Usage:
#   am doctor                 global health + one summary row per session
#   am doctor <session>       full report for one session
#   am doctor --capture [s]   same, and write a tarball under $AM_DIR/doctor/
#
# Everything here is read-only. Sourced by `am`; needs utils, tmux, registry,
# state, recovery (recovery only for the desired-session record).

_DOCTOR_LIB_DIR="${AM_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# --- formatting -------------------------------------------------------------

_doc_h1() { printf '\n%b== %s ==%b\n' "${BOLD:-}" "$1" "${RESET:-}"; }
_doc_h2() { printf '%b-- %s --%b\n' "${DIM:-}" "$1" "${RESET:-}"; }
_doc_kv() { printf '  %-22s %s\n' "$1:" "${2:-}"; }
_doc_warn() { printf '  %b! %s%b\n' "${YELLOW:-}" "$1" "${RESET:-}"; }
_doc_ok() { printf '  %b✓ %s%b\n' "${GREEN:-}" "$1" "${RESET:-}"; }

# Epoch mtime / size in bytes / octal mode of a path, via the flavor-aware
# utils.sh stat helpers (a hand-rolled `stat -f … || stat -c …` returned a
# filesystem blob on GNU coreutils and crashed the global report with
# "File: unbound variable" inside the size compare). Empty when missing.
_doc_mtime() { am_file_mtime "$1" || true; }
_doc_size()  { am_file_size "$1" || true; }
_doc_mode()  { am_file_mode "$1" || true; }

# "<age> ago" for an epoch, or "-".
_doc_age() {
    local epoch="$1" now="${2:-$(date +%s)}"
    [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]] || { echo "-"; return; }
    format_time_ago $(( now - epoch ))
}

# Human size.
_doc_human() {
    local b="${1:-0}"
    if (( b >= 1048576 )); then printf '%dMB' $(( b / 1048576 ))
    elif (( b >= 1024 )); then printf '%dKB' $(( b / 1024 ))
    else printf '%dB' "$b"; fi
}

# Show the first bytes of a title as hex so glyph problems are visible even
# when the terminal cannot render them.
_doc_hexhead() {
    printf '%s' "$1" | head -c 12 | od -An -tx1 2>/dev/null | tr -s ' \n' ' ' | sed -E 's/^ //; s/ $//'
}

# --- global section ---------------------------------------------------------

_doc_versions() {
    _doc_h2 "versions"
    _doc_kv "am" "${AM_VERSION:-unknown} ($AM_LIB_DIR)"
    _doc_kv "bash" "${BASH_VERSION}"
    _doc_kv "tmux" "$(tmux -V 2>/dev/null || echo missing)"
    _doc_kv "jq" "$(jq --version 2>/dev/null || echo missing)"
    local agent bin ver
    for agent in $(_doc_version_bins); do
        bin=$(command -v "$agent" 2>/dev/null) || { _doc_kv "$agent" "not installed"; continue; }
        ver=$("$agent" --version 2>/dev/null | head -1 | tr -d '\r')
        _doc_kv "$agent" "${ver:-?} ($bin)"
    done
    _doc_kv "AM_STATE_DEBUG" "${AM_STATE_DEBUG:-unset}"
    _doc_kv "AM_HOOK_DEBUG" "${AM_HOOK_DEBUG:-unset}"
}

_doc_dirs() {
    _doc_h2 "directories"
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}" log_dir="/tmp/am-logs"
    local d mode
    for d in "$AM_DIR" "$state_dir" "$log_dir"; do
        if [[ -d "$d" ]]; then
            mode=$(_doc_mode "$d")
            _doc_kv "$d" "mode $mode"
            [[ "$mode" == "700" || "$mode" == "0700" ]] || _doc_warn "$d is mode $mode (expected 700)"
        else
            _doc_kv "$d" "missing"
        fi
    done
    local f sz
    for f in "$AM_DIR/titler.log" "$AM_DIR/.state-debug.log" "$AM_DIR/.hook-debug.log" "$AM_SESSIONS_LOG"; do
        [[ -f "$f" ]] || continue
        sz=$(_doc_size "$f")
        _doc_kv "${f##*/}" "$(_doc_human "$sz")"
        (( ${sz:-0} > 50 * 1048576 )) && _doc_warn "${f##*/} is $(_doc_human "$sz"); consider rotating"
    done
    local leaked
    leaked=$(find "$AM_DIR" -maxdepth 1 -name '.sessions-log.*' 2>/dev/null | wc -l | tr -d ' ')
    (( leaked > 0 )) && _doc_warn "$leaked leaked .sessions-log.* temp files in $AM_DIR"
    local snaps
    snaps=$(find "$AM_DIR/snapshots" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    _doc_kv "snapshots" "$snaps files"
    return 0
}

_doc_markers() {
    _doc_h2 "periodic work markers"
    local now m v
    now=$(date +%s)
    for m in .title_scan_last .restore_scan_last .gc_last .gc_extras_last; do
        if [[ -f "$AM_DIR/$m" ]]; then
            IFS= read -r v < "$AM_DIR/$m" || true
            _doc_kv "$m" "$(_doc_age "$v" "$now")"
        else
            _doc_kv "$m" "never"
        fi
    done
}

# Check that <file>'s .hooks[<event>] entries include the am state hook, for
# every event scripts/install.sh registers for that family. Codex and Cursor
# hook files are optional (only present when that agent is installed).
# Claude/Codex nest commands as .hooks[ev][].hooks[].command; Cursor keeps
# them flat as .hooks[ev][].command, and its command runs a *copy* of the
# hook (<hooks_dir>/am-state-hook.sh, written by scripts/install.sh) — so
# when <helper> is given, the command must name the helper and the helper
# must be byte-identical to the expected hook script (a stale copy is what
# `am install --refresh` fixes).
# Usage: _doc_hooks_check <label> <file> <optional:true|false> <helper|-> <event>...
_doc_hooks_check() {
    local label="$1" file="$2" optional="$3" helper="$4"; shift 4
    local expected="$AM_LIB_DIR/hooks/state-hook.sh"
    if [[ ! -f "$file" ]]; then
        if [[ "$optional" == true ]]; then _doc_kv "$label" "not configured ($file)"
        else _doc_warn "$label: no $file"; fi
        return 0
    fi
    local ev cmds target="$expected"
    [[ "$helper" != "-" ]] && target="$helper"
    for ev in "$@"; do
        cmds=$(jq -r --arg ev "$ev" '.hooks[$ev][]? | (.hooks[]?.command // .command) // empty' "$file" 2>/dev/null | grep -F 'state-hook' || true)
        if [[ -z "$cmds" ]]; then
            _doc_warn "$label $ev: no am state hook installed"
        elif ! grep -qF "$target" <<< "$cmds"; then
            _doc_warn "$label $ev: hook points elsewhere: $(head -1 <<< "$cmds")"
        else
            _doc_ok "$label $ev"
        fi
    done
    if [[ "$helper" != "-" ]]; then
        if [[ ! -f "$helper" ]]; then
            _doc_warn "$label helper missing: $helper"
        elif ! cmp -s "$helper" "$expected"; then
            _doc_warn "$label helper $helper is a stale copy of the hook; run: am install --refresh"
        fi
    fi
}

_doc_hooks_installed() {
    _doc_h2 "state hooks installed"
    local expected="$AM_LIB_DIR/hooks/state-hook.sh"
    local cursor_home="${CURSOR_CONFIG_HOME:-$HOME/.cursor}"
    # Event lists mirror scripts/install.sh (_install_claude_hooks,
    # _install_codex_hooks, _install_cursor_hooks).
    _doc_hooks_check claude "$HOME/.claude/settings.json" false - \
        Stop Notification UserPromptSubmit PostToolUse
    _doc_hooks_check codex "${CODEX_HOME:-$HOME/.codex}/hooks.json" true - \
        Stop UserPromptSubmit PreToolUse PostToolUse PermissionRequest
    _doc_hooks_check cursor "$cursor_home/hooks.json" true "${CURSOR_HOOKS_DIR:-$cursor_home/hooks}/am-state-hook.sh" \
        sessionStart beforeSubmitPrompt preToolUse postToolUse afterAgentResponse stop
    [[ -x "$expected" || -f "$expected" ]] || _doc_warn "hook script missing: $expected"
}

# --- version-drift canary ----------------------------------------------------
#
# State detection rests on empirical agent behavior (see AGENTS.md, State
# Detection). Two signals catch an agent upgrade quietly moving that ground:
#  - tests/live_lab/VERIFIED pins the agent versions the live labs last
#    confirmed; a newer installed version is a prompt to re-run the lab.
#  - the state hook records the top-level keys of every payload it sees
#    ($AM_DIR/hook-schema/<agent>.<event>.keys); a load-bearing field that
#    disappears is reported here.

# First line of `<agent> --version`; fails when the agent is not installed.
_doc_agent_version() {
    command -v "$1" >/dev/null 2>&1 || return 1
    "$1" --version 2>/dev/null | head -1 | tr -d '\r'
}

# Leading dotted-numeric core of a version string:
# "2.1.263 (Claude Code)" → 2.1.263, "v2026.09.02-c22c1a3" → 2026.09.02.
_doc_ver_core() {
    local v="${1#v}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)* ]] && printf '%s' "${BASH_REMATCH[0]}"
    return 0
}

# _doc_ver_newer A B: success when dotted version A is strictly newer than B.
# Missing components count as 0 (2.1 == 2.1.0); non-numeric input → false.
_doc_ver_newer() {
    local a b i x y
    a=$(_doc_ver_core "$1"); b=$(_doc_ver_core "$2")
    [[ -n "$a" && -n "$b" ]] || return 1
    local -a pa=() pb=()
    IFS=. read -r -a pa <<< "$a"
    IFS=. read -r -a pb <<< "$b"
    for (( i = 0; i < ${#pa[@]} || i < ${#pb[@]}; i++ )); do
        x=$(( 10#${pa[i]:-0} )); y=$(( 10#${pb[i]:-0} ))
        (( x > y )) && return 0
        (( x < y )) && return 1
    done
    return 1
}

# Payload fields the state machine reads (the single jq extraction in
# lib/hooks/state-hook.sh). "<agent>.*" applies to every event of that agent.
_doc_required_keys() {
    case "$1" in
        "claude.*") printf 'hook_event_name session_id transcript_path cwd' ;;
        claude.Stop) printf 'stop_hook_active background_tasks' ;;
        claude.Notification|codex.Notification) printf 'notification_type' ;;
        "codex.*") printf 'hook_event_name cwd' ;;
        "cursor.*") printf 'hook_event_name conversation_id' ;;
    esac
}

# Comma-separated key sets → " -removed +added" summary.
_doc_keys_diff() {
    local prev="$1" cur="$2" k out=""
    local IFS=,
    for k in $prev; do [[ ",$cur," == *",$k,"* ]] || out+=" -$k"; done
    for k in $cur; do [[ ",$prev," == *",$k,"* ]] || out+=" +$k"; done
    printf '%s' "${out# }"
}

_doc_drift() {
    _doc_h2 "version drift"
    local verified="${AM_VERIFIED_FILE:-$AM_LIB_DIR/../tests/live_lab/VERIFIED}"
    local -A pin=() pin_date=() pin_lab=()
    local agent ver date lab note installed
    if [[ -f "$verified" ]]; then
        while read -r agent ver date lab note; do
            [[ -z "$agent" || "$agent" == \#* ]] && continue
            pin[$agent]=$ver; pin_date[$agent]=$date; pin_lab[$agent]=$lab
        done < "$verified"
    else
        _doc_warn "no verified-version pin file at $verified"
    fi
    local type
    for type in "${AM_AGENT_TYPES[@]}"; do
        am_agent_field "$type" version_bin agent
        installed=$(_doc_agent_version "$agent") || continue
        if [[ -z "${pin[$agent]:-}" ]]; then
            am_agent_field "$type" lab lab
            if [[ -n "$lab" ]]; then
                _doc_kv "$agent" "$installed (no verified pin; run $lab and add a line to tests/live_lab/VERIFIED)"
            else
                _doc_kv "$agent" "$installed (no live lab; state detection unverified)"
            fi
        elif _doc_ver_newer "$installed" "${pin[$agent]}"; then
            _doc_warn "$agent $installed is newer than the last live-lab verified ${pin[$agent]} (${pin_date[$agent]}); run ${pin_lab[$agent]} and update tests/live_lab/VERIFIED"
        else
            _doc_ok "$agent $installed (verified ${pin[$agent]}, ${pin_date[$agent]})"
        fi
    done

    _doc_h2 "hook payload schema"
    local dir="$AM_DIR/hook-schema" f base keys prev key missing when now
    if [[ ! -d "$dir" ]] || ! ls "$dir"/*.keys >/dev/null 2>&1; then
        _doc_kv "observed" "none yet (the state hook records one file per agent+event)"
        return 0
    fi
    now=$(date +%s)
    for f in "$dir"/*.keys; do
        base="${f##*/}"; base="${base%.keys}"
        keys=""; IFS= read -r keys < "$f" || true
        when=$(_doc_age "$(_doc_mtime "$f")" "$now")
        _doc_kv "$base" "$keys"
        missing=""
        for key in $(_doc_required_keys "${base%%.*}.*") $(_doc_required_keys "${base%.sub}"); do
            [[ ",$keys," == *",$key,"* ]] || missing+=" $key"
        done
        [[ -n "$missing" ]] && _doc_warn "$base: load-bearing field(s) missing:$missing (last change $when)"
        if [[ -f "$f.prev" ]]; then
            prev=""; IFS= read -r prev < "$f.prev" || true
            _doc_kv "  changed $when" "$(_doc_keys_diff "$prev" "$keys")"
        fi
    done
    return 0
}

# One row per live session: name, state, layer, hook age, title signal.
_doc_summary_rows() {
    _doc_h2 "sessions"
    local name state layer hook_state hook_age title sig
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}" now
    now=$(date +%s)
    printf '  %-10s %-13s %-9s %-14s %-9s %s\n' SESSION STATE LAYER HOOK AGE TITLE
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        _doc_resolve_state "$name" state layer
        hook_state="-"; hook_age="-"
        if [[ -f "$state_dir/$name" ]]; then
            IFS= read -r hook_state < "$state_dir/$name" || true
            hook_age=$(_doc_age "$(_doc_mtime "$state_dir/$name")" "$now")
        fi
        title=$(tmux_pane_title "${name}:.{top}" 2>/dev/null || true)
        _state_title_signal "$title" sig
        printf '  %-10s %-13s %-9s %-14s %-9s %s\n' "$name" "$state" "$layer" "$hook_state" "$hook_age" "${sig}:${title:0:40}"
    done < <(tmux_list_am_sessions)
}

# --- per-session section ----------------------------------------------------

# Resolve state and capture the layer that decided it. Uses the debug sink
# override in _state_debug (AM_STATE_DEBUG_SINK) so the report never depends
# on the user's global debug flag. Falls back to "?" when unavailable.
# Usage: _doc_resolve_state <session> <state_var> <layer_var>
_doc_resolve_state() {
    local __s="$1"
    local -n __state_out="$2" __layer_out="$3"
    local sink
    sink=$(mktemp "${TMPDIR:-/tmp}/am-doctor.XXXXXX")
    __state_out=$(AM_STATE_DEBUG=1 AM_STATE_DEBUG_SINK="$sink" agent_get_state "$__s" 2>/dev/null || echo "?")
    __layer_out="?"
    if [[ -s "$sink" ]]; then
        __layer_out=$(tail -1 "$sink" | cut -f4)
    fi
    rm -f "$sink"
}

_doc_registry_row() {
    _doc_h2 "registry row ($AM_REGISTRY)"
    local row
    row=$(jq -r --arg n "$1" '.sessions[$n] // empty' "$AM_REGISTRY" 2>/dev/null)
    if [[ -z "$row" ]]; then
        _doc_warn "no registry row (session unknown to am; only tmux knows it)"
        return 0
    fi
    local k v
    while IFS=$'\t' read -r k v; do _doc_kv "$k" "$v"; done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' <<< "$row" 2>/dev/null)
}

_doc_tmux() {
    local name="$1"
    _doc_h2 "tmux"
    if ! tmux_session_exists "$name"; then
        _doc_warn "tmux session does not exist"
        return 0
    fi
    local now created activity attached
    now=$(date +%s)
    created=$(tmux_get_created "$name" 2>/dev/null || true)
    activity=$(tmux_get_activity "$name" 2>/dev/null || true)
    attached=$(am_tmux display-message -p -t "$name" '#{session_attached}' 2>/dev/null || echo "?")
    _doc_kv "created" "$(_doc_age "$created" "$now")"
    _doc_kv "activity" "$(_doc_age "$activity" "$now")"
    _doc_kv "attached clients" "$attached"
    printf '  %-6s %-8s %-7s %-16s %s\n' WIN PANE PID CMD "TITLE (raw)"
    am_tmux list-panes -s -t "$name" -F '#{window_name} #{pane_id} #{pane_pid} #{pane_current_command} #{pane_title}' 2>/dev/null |
        while IFS=' ' read -r win pane pid cmd title; do
            printf '  %-6s %-8s %-7s %-16s %s\n' "$win" "$pane" "$pid" "$cmd" "$title"
        done
    local title sig csig
    title=$(tmux_pane_title "${name}:.{top}" 2>/dev/null || true)
    _state_title_signal "$title" sig
    _state_cursor_title_signal "$title" csig
    _doc_kv "top pane title" "${title:-<empty>}"
    _doc_kv "title bytes" "$(_doc_hexhead "$title")"
    _doc_kv "claude title signal" "$sig"
    [[ "$csig" != "none" ]] && _doc_kv "cursor title signal" "$csig"
    return 0
}

_doc_hook_files() {
    local name="$1"
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    local id_dir="${AM_IDENTITY_DIR:-$AM_DIR/identities}"
    _doc_h2 "hook state ($state_dir)"
    local now f v
    now=$(date +%s)
    if [[ -f "$state_dir/$name" ]]; then
        IFS= read -r v < "$state_dir/$name" || true
        _doc_kv "state file" "$v (entered $(_doc_age "$(_doc_mtime "$state_dir/$name")" "$now"))"
    else
        _doc_kv "state file" "missing (no hook event yet, or not a hook-driven agent)"
    fi
    for f in sid transcript cwd bg; do
        if [[ -f "$state_dir/$name.$f" ]]; then
            v=$(head -c 300 "$state_dir/$name.$f" | tr '\n' ' ')
            _doc_kv ".$f" "$v ($(_doc_age "$(_doc_mtime "$state_dir/$name.$f")" "$now"))"
        else
            _doc_kv ".$f" "-"
        fi
    done
    _doc_h2 "durable identity ($id_dir)"
    for f in sid transcript rebind; do
        if [[ -f "$id_dir/$name.$f" ]]; then
            v=$(head -c 300 "$id_dir/$name.$f" | tr '\n' ' ')
            _doc_kv ".$f" "${v:-<empty>}"
        else
            _doc_kv ".$f" "-"
        fi
    done
    if [[ -f "$state_dir/$name.sid" && -f "$id_dir/$name.sid" ]]; then
        local a b
        IFS= read -r a < "$state_dir/$name.sid" || true
        IFS= read -r b < "$id_dir/$name.sid" || true
        [[ "$a" == "$b" ]] || _doc_warn "ephemeral and durable session ids differ ($a vs $b)"
    fi
    return 0
}

_doc_transcript() {
    local name="$1" agent="$2" dir="$3"
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    local id_dir="${AM_IDENTITY_DIR:-$AM_DIR/identities}"
    _doc_h2 "transcript"
    local sid="" tp="" f
    for f in "$state_dir/$name.sid" "$id_dir/$name.sid"; do
        [[ -f "$f" ]] && { IFS= read -r sid < "$f" || true; [[ -n "$sid" ]] && break; }
    done
    for f in "$state_dir/$name.transcript" "$id_dir/$name.transcript"; do
        [[ -f "$f" ]] && { IFS= read -r tp < "$f" || true; [[ -n "$tp" ]] && break; }
    done
    if [[ -z "$sid" ]]; then
        _doc_kv "session id" "none bound yet (title fallback and restore unavailable until the first hook event)"
        return 0
    fi
    _doc_kv "session id" "$sid"
    local resolved path=""
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    local store
    am_agent_field "$agent" store store
    case "$store" in
        pi)
            local matches=("$(_pi_sessions_root)/$(_slog_encode_pi_dir "$resolved")"/*_"${sid}".jsonl)
            [[ -f "${matches[0]}" ]] && path="${matches[0]}"
            ;;
        cursor)
            if [[ -n "$tp" ]]; then path="$tp"
            else path="$(_cursor_projects_root)/$(_slog_encode_cursor_dir "$resolved")/agent-transcripts/$sid/$sid.jsonl"; fi
            ;;
        claude)
            path="$HOME/.claude/projects/$(_slog_encode_dir "$resolved")/$sid.jsonl"
            ;;
        *)
            path="($agent: id only; no local transcript check)"
            ;;
    esac
    _doc_kv "path" "$path"
    if [[ -f "$path" ]]; then
        _doc_kv "exists" "yes, $(_doc_human "$(_doc_size "$path")"), modified $(_doc_age "$(_doc_mtime "$path")")"
        local first
        case "$store" in
            pi)     first=$(pi_first_user_message "$dir" "$sid" 2>/dev/null || true) ;;
            cursor) first=$(cursor_first_user_message "$dir" "$sid" "$tp" 2>/dev/null || true) ;;
            claude) first=$(claude_first_user_message "$dir" "$sid" 2>/dev/null || true) ;;
            *)      first="" ;;
        esac
        [[ -n "$first" ]] && _doc_kv "first user message" "${first:0:80}"
    elif [[ "$store" == "pi" || "$store" == "cursor" || "$store" == "claude" ]]; then
        _doc_warn "transcript file missing: restore will not offer this session"
    fi
    return 0
}

# Version binaries of every manifest agent, one per line (doctor probes and
# the VERIFIED pins are keyed by these names, e.g. cursor-agent for cursor).
_doc_version_bins() {
    local type bin
    for type in "${AM_AGENT_TYPES[@]}"; do
        am_agent_field "$type" version_bin bin
        [[ -n "$bin" ]] && printf '%s\n' "$bin"
    done
}

_doc_processes() {
    local name="$1"
    _doc_h2 "process tree (top pane)"
    local pane_pid
    pane_pid=$(am_tmux display-message -p -t "${name}:.{top}" '#{pane_pid}' 2>/dev/null || true)
    [[ -n "$pane_pid" ]] || { _doc_kv "pane pid" "unknown"; return 0; }
    local -A children=() comm=() etime=()
    local p pp e c
    while read -r p pp e c; do
        [[ -n "$p" ]] || continue
        children[$pp]="${children[$pp]:-} $p"
        comm[$p]="$c"
        etime[$p]="$e"
    done < <(ps -eo pid=,ppid=,etime=,comm= 2>/dev/null || true)
    _doc_ps_walk "$pane_pid" 0 children comm etime
}

_doc_ps_walk() {
    local pid="$1" depth="$2"
    local -n __ch="$3" __co="$4" __et="$5"
    (( depth > 6 )) && return 0
    local indent
    printf -v indent '%*s' $(( depth * 2 )) ''
    local args
    args=$(ps -o args= -p "$pid" 2>/dev/null | head -c 100)
    printf '  %s%s %s [%s] %s\n' "$indent" "$pid" "${__co[$pid]:-?}" "${__et[$pid]:-?}" "$args"
    local child
    for child in ${__ch[$pid]:-}; do
        _doc_ps_walk "$child" $(( depth + 1 )) "$3" "$4" "$5"
    done
}

_doc_desired() {
    local name="$1"
    local desired="${AM_DESIRED_SESSIONS:-$AM_DIR/desired_sessions.json}"
    _doc_h2 "desired session record ($desired)"
    [[ -f "$desired" ]] || { _doc_kv "record" "no desired_sessions.json"; return 0; }
    local rec
    rec=$(jq -c --arg n "$name" '.sessions // {} | to_entries[] | .value | select(.session_name == $n or .logical_id == $n)' "$desired" 2>/dev/null | head -1)
    if [[ -z "$rec" ]]; then
        _doc_warn "no desired record: this session will not be recovered after a reboot"
        return 0
    fi
    local k v
    while IFS=$'\t' read -r k v; do _doc_kv "$k" "$v"; done < <(jq -r 'to_entries[] | select(.key != "task") | [.key, (.value|tostring)] | @tsv' <<< "$rec" 2>/dev/null)
    local src sid
    src=$(jq -r '.identity_source // ""' <<< "$rec")
    sid=$(jq -r '.session_id // ""' <<< "$rec")
    [[ -n "$sid" && -n "$src" ]] || _doc_warn "no durable identity yet: not restorable across reboot until the next hook event syncs it"
    return 0
}

_doc_recent_debug() {
    local name="$1"
    local hook_log="$AM_DIR/.hook-debug.log" state_log="$AM_DIR/.state-debug.log"
    if [[ -f "$hook_log" ]]; then
        local lines
        lines=$(grep -F "$name" "$hook_log" 2>/dev/null | tail -5 || true)
        if [[ -n "$lines" ]]; then
            _doc_h2 "last hook-debug lines mentioning $name"
            sed 's/^/  /' <<< "$lines"
        fi
    fi
    if [[ -f "$state_log" && "${AM_STATE_DEBUG:-}" == "1" ]]; then
        _doc_h2 "last state-debug transitions"
        awk -F'\t' -v s="$name" '$2 == s { if ($5 != last) { print "  " $1 "\t" $4 "\t" $5; last = $5 } }' "$state_log" 2>/dev/null | tail -8
    fi
    return 0
}

_doc_session() {
    local name="$1"
    _doc_h1 "session $name"
    local fields directory workdir branch agent_type task
    fields=$(registry_get_fields "$name" directory workdir branch agent_type task 2>/dev/null || true)
    IFS='|' read -r directory workdir branch agent_type task <<< "$fields"
    local state layer
    _doc_resolve_state "$name" state layer
    _doc_kv "resolved state" "$state (decided by: $layer)"
    _doc_kv "agent" "${agent_type:-?}"
    _doc_kv "directory" "${directory:-?}"
    [[ -n "$workdir" ]] && _doc_kv "workdir" "$workdir"
    _doc_kv "branch (registry)" "${branch:--}"
    local live_branch
    git_head_branch "${workdir:-$directory}" live_branch 2>/dev/null || live_branch=""
    [[ -n "$live_branch" && "$live_branch" != "$branch" ]] && _doc_warn "live branch is $live_branch (registry says ${branch:--}); next title scan will update it"
    _doc_kv "task" "${task:--}"
    _doc_registry_row "$name"
    _doc_tmux "$name"
    _doc_hook_files "$name"
    _doc_transcript "$name" "${agent_type:-claude}" "${directory:-$PWD}"
    _doc_processes "$name"
    _doc_desired "$name"
    _doc_recent_debug "$name"
}

_doc_global() {
    _doc_h1 "am doctor"
    _doc_versions
    _doc_dirs
    _doc_markers
    _doc_hooks_installed
    _doc_drift
    _doc_h2 "registry vs tmux"
    local -A live=() reg=()
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && live[$n]=1; done < <(tmux_list_am_sessions)
    while IFS= read -r n; do [[ -n "$n" ]] && reg[$n]=1; done < <(jq -r '.sessions | keys[]' "$AM_REGISTRY" 2>/dev/null || true)
    for n in "${!live[@]}"; do [[ -n "${reg[$n]:-}" ]] || _doc_warn "$n is live in tmux but not in the registry"; done
    for n in "${!reg[@]}"; do [[ -n "${live[$n]:-}" ]] || _doc_warn "$n is in the registry but not in tmux (gc will remove it)"; done
    _doc_kv "live sessions" "${#live[@]}"
    _doc_summary_rows
}

# Write the report plus raw artifacts to a tarball.
_doc_capture() {
    local session="$1"
    local ts dir out
    ts=$(date +%Y%m%d-%H%M%S)
    dir=$(mktemp -d "${TMPDIR:-/tmp}/am-doctor-capture.XXXXXX")
    mkdir -p "$AM_DIR/doctor"
    out="$AM_DIR/doctor/doctor-${session:-all}-$ts.tar.gz"
    {
        _doc_global
        if [[ -n "$session" ]]; then
            _doc_session "$session"
        else
            local n
            while IFS= read -r n; do [[ -n "$n" ]] && _doc_session "$n"; done < <(tmux_list_am_sessions)
        fi
    } > "$dir/report.txt" 2>&1
    cp "$AM_REGISTRY" "$dir/sessions.json" 2>/dev/null || true
    cp "$AM_DIR/desired_sessions.json" "$dir/" 2>/dev/null || true
    tail -200 "$AM_SESSIONS_LOG" > "$dir/sessions_log.tail.jsonl" 2>/dev/null || true
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    mkdir -p "$dir/am-state"
    cp "$state_dir"/* "$dir/am-state/" 2>/dev/null || true
    cp -R "$AM_DIR/hook-schema" "$dir/hook-schema" 2>/dev/null || true
    for f in .hook-debug.log .state-debug.log titler.log; do
        [[ -f "$AM_DIR/$f" ]] && tail -2000 "$AM_DIR/$f" > "$dir/$f.tail" 2>/dev/null
    done
    local n
    for n in $(tmux_list_am_sessions); do
        [[ -n "$session" && "$n" != "$session" ]] && continue
        tmux_capture_pane "${n}:.{top}" 200 > "$dir/pane-$n.txt" 2>/dev/null || true
    done
    tar -czf "$out" -C "$dir" . 2>/dev/null
    rm -rf "$dir"
    echo "$out"
}

# Entry point. Usage: doctor_main [--capture] [<session>]
doctor_main() {
    local capture=false session_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --capture) capture=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: am doctor [--capture] [<session>]

Print every input behind session state: registry row, tmux panes and raw
title, hook state file and sidecars with ages, durable identity, transcript
resolution, process tree, desired-session record, and which resolver layer
decided the state. Without a session: global health and one row per session.

  --capture   also write a tarball (report, registry, state files, pane
              captures, log tails) under ~/.agent-manager/doctor/
EOF
                return 0 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) session_arg="$1"; shift ;;
        esac
    done
    local resolved=""
    if [[ -n "$session_arg" ]]; then
        if ! resolved=$(resolve_session_fuzzy "$session_arg"); then
            log_error "Session not found: $session_arg"
            return 1
        fi
    fi
    if $capture; then
        local out
        out=$(_doc_capture "$resolved")
        log_success "Wrote $out"
        return 0
    fi
    if [[ -n "$resolved" ]]; then
        _doc_session "$resolved"
    else
        _doc_global
    fi
}
