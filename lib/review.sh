# Review checkpoints: `am diff` and the helpers the lifecycle calls.
#
# The store lives in Go (internal/sessions/review.go, reached through
# `am-core review-*`): per session, a chain of checkpoint commits under
# refs/am/<session>/checkpoints in the session's own repository, plus a
# refs/am/<session>/baseline pointer. Kinds: launch (worktree at launch),
# ack (worktree at `am diff --ack`), branch (HEAD's committed tree when the
# branch name changed; moves the baseline), head (same-branch HEAD move; does
# not). This file resolves the session and directory, formats the listing, and
# runs the diff itself through git so the user's pager and diff tooling (delta,
# difftastic, …) apply.
#
# Sourced lazily by the am entry point (_ensure_review); lib/agents.sh calls
# review_init / review_adopt through `am_core` directly so it never needs this
# file loaded.

# Effective directory of a session: the registry workdir when the agent moved,
# else the launch directory. Usage: review_session_dir <session_name>
review_session_dir() {
    local fields directory workdir
    fields=$(registry_get_fields "$1" directory workdir)
    IFS='|' read -r directory workdir <<< "$fields"
    [[ -n "$directory" ]] || return 1
    echo "${workdir:-$directory}"
}

# Record the launch checkpoint of a new session; silent outside a repository.
# Usage: review_init <session_name> <directory>
review_init() {
    am_core review-init "$1" "$2" >/dev/null 2>&1 || true
}

# Move a closed session's refs to the session that resumed its conversation
# (`am restore` gives it a new name). Usage: review_adopt <old> <new> <dir>
review_adopt() {
    am_core review-adopt "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# Short id for display.
_review_short() { echo "${1:0:7}"; }

# "<n><unit> ago" for a unix timestamp.
_review_age() {
    local now
    now=$(date +%s)
    format_time_ago $(( now - ${1:-$now} ))
}

# One line summarizing a stat: "7 files +212 −48" or "no changes".
_review_stat_line() {
    local files="$1" added="$2" deleted="$3"
    if (( files == 0 )); then
        echo "no changes"
        return
    fi
    local noun="files"
    (( files == 1 )) && noun="file"
    echo "${files} ${noun} +${added} −${deleted}"
}

# `am diff` entry point. Usage: review_diff_main [args...]
review_diff_main() {
    local mode="plain" from="" name="" show_help=false
    local -a git_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ack) mode="ack" ;;
            --reset) mode="reset" ;;
            --list|-l) mode="list" ;;
            --checkpoint|-c)
                from="${2:-}"
                if [[ -z "$from" ]]; then
                    log_error "--checkpoint needs an id (see am diff --list)"
                    return 1
                fi
                shift
                ;;
            --checkpoint=*) from="${1#--checkpoint=}" ;;
            --stat|--name-only|--name-status|--numstat|-w|--color|--no-color|-U*)
                git_args+=("$1") ;;
            --)
                shift
                git_args+=("$@")
                break
                ;;
            -h|--help) show_help=true ;;
            -*)
                log_error "Unknown option: $1"
                echo "Usage: am diff [session] [--ack|--reset|--list|--checkpoint <id>] [--stat] [-- <git diff args>]" >&2
                return 1
                ;;
            *)
                if [[ -n "$name" ]]; then
                    log_error "Unexpected argument: $1 (git diff arguments go after --)"
                    return 1
                fi
                name="$1"
                ;;
        esac
        shift
    done

    if $show_help; then
        cat <<'EOF'
Usage: am diff [session] [--ack|--reset|--list|--checkpoint <id>] [--stat] [-- <git diff args>]

Show what the agent changed since you last looked. The baseline is a review
checkpoint kept in the session's repository: the working copy at launch, then
whatever you acknowledged. Commits do not hide changes (trees are compared, not
HEAD); a branch switch moves the baseline to the new branch as checked out.

Without a session name the command applies to the am session you are inside
(agent pane or shell panel).

  (no flag)           diff from the baseline to the working copy (untracked
                      files included), through your git pager and diff tools
  --ack               mark the working copy as reviewed: new baseline
  --reset             baseline back to the launch checkpoint
  --checkpoint <id>   one-off diff from that checkpoint (baseline unchanged)
  --list, -l          list checkpoints: id, kind, branch, HEAD, age; * = baseline
  --stat              pass --stat to git diff (also: --name-only, --numstat, -w)
  -- <args>           remaining arguments go to git diff (e.g. -- -- lib/)

Exit codes: 0 ok, 1 error, 2 session not found, 3 not a git repository.
EOF
        return 0
    fi

    local resolved=""
    if [[ -n "$name" ]]; then
        if ! resolved=$(resolve_session_fuzzy "$name"); then
            log_error "Session not found: $name"
            return 2
        fi
    elif ! resolved=$(current_session); then
        log_error "Session name required (not inside an am session)"
        echo "Usage: am diff [session] [--ack|--reset|--list|--checkpoint <id>]" >&2
        return 2
    fi

    local dir
    if ! dir=$(review_session_dir "$resolved"); then
        log_error "Session not registered: $resolved"
        return 2
    fi
    if [[ ! -d "$dir" ]]; then
        log_error "Directory no longer exists: $dir"
        return 1
    fi

    local out rc=0
    case "$mode" in
        ack)
            out=$(am_core review-ack "$resolved" "$dir" 2>&1) || rc=$?
            if (( rc != 0 )); then
                _review_core_error "$out" "$rc"
                return $rc
            fi
            log_success "$resolved: working copy marked reviewed (checkpoint $(_review_short "$out"))"
            rm -f "$AM_DIR/.list_cache" 2>/dev/null || true
            am_refresh_sidebar_cache
            ;;
        reset)
            out=$(am_core review-baseline "$resolved" "$dir" --reset 2>&1) || rc=$?
            if (( rc != 0 )); then
                _review_core_error "$out" "$rc"
                return $rc
            fi
            local id kind branch head when
            read -r id kind branch head when <<< "$out"
            log_success "$resolved: baseline reset to the $kind checkpoint $(_review_short "$id") ($(_review_age "$when"))"
            rm -f "$AM_DIR/.title_scan_last" 2>/dev/null || true
            ;;
        list)
            _review_list "$resolved" "$dir"
            ;;
        plain)
            _review_show "$resolved" "$dir" "$from" "${git_args[@]+"${git_args[@]}"}"
            ;;
    esac
}

# Translate an am-core failure into a message and exit code (3 = not a repo).
_review_core_error() {
    local out="$1" rc="$2"
    if (( rc == 3 )); then
        log_error "Not a git repository: nothing to review here"
    else
        log_error "${out##*am-core review-*: }"
    fi
}

# Print the checkpoint table, newest first, baseline starred.
_review_list() {
    local session="$1" dir="$2" out rc=0
    am_core review-sync "$session" "$dir" >/dev/null 2>&1 || true
    out=$(am_core review-list "$session" "$dir" 2>&1) || rc=$?
    if (( rc != 0 )); then
        _review_core_error "$out" "$rc"
        return $rc
    fi
    if [[ -z "$out" ]]; then
        echo "No checkpoints for $session"
        return 0
    fi
    printf '%s %-8s %-7s %-24s %-8s %s\n' " " "ID" "KIND" "BRANCH" "HEAD" "WHEN"
    local id kind branch head when mark
    while read -r id kind branch head when mark; do
        [[ -n "$id" ]] || continue
        [[ "$mark" == "*" ]] || mark=" "
        [[ "$branch" == "-" ]] && branch="(detached)"
        [[ "$head" == "-" ]] && head="-" || head="${head:0:7}"
        printf '%s %-8s %-7s %-24s %-8s %s\n' "$mark" "${id:0:7}" "$kind" "$branch" "$head" "$(_review_age "$when")"
    done <<< "$out"
}

# Measure, print the header (stderr), and run git diff between the baseline
# tree and the worktree tree. from = one-off checkpoint id (baseline untouched).
_review_show() {
    local session="$1" dir="$2" from="$3"
    shift 3
    local -a git_args=("$@")
    local out rc=0
    if [[ -n "$from" ]]; then
        out=$(am_core review-stat "$session" "$dir" --from "$from" 2>&1) || rc=$?
    else
        out=$(am_core review-stat "$session" "$dir" --record 2>&1) || rc=$?
    fi
    if (( rc != 0 )); then
        _review_core_error "$out" "$rc"
        return $rc
    fi
    local files added deleted base_id base_kind base_time base_tree cur_tree moved
    read -r files added deleted base_id base_kind base_time base_tree cur_tree moved <<< "$out"

    local header="$session: $(_review_stat_line "$files" "$added" "$deleted") since the $base_kind checkpoint $(_review_short "$base_id") ($(_review_age "$base_time"))"
    if [[ "$moved" != "-" ]]; then
        header+="; HEAD moved: ${moved//_/ }"
    fi
    echo "$header" >&2
    (( files == 0 )) && return 0

    git -C "$dir" diff "${git_args[@]+"${git_args[@]}"}" "$base_tree" "$cur_tree"
}
