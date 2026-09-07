# presets.sh - Named launch presets for `am new`
#
# A preset is a saved set of `am new` inputs: directory (a path or a `@spec`
# for the directory provider), agent type, task, shell panel, and extra agent
# args. It lives under the "presets" key of config.json:
#
#   "presets": {
#     "review": {"agent": "claude", "directory": "@", "task": "",
#                "shell": false, "args": ["--model", "opus", "--effort", "high"]}
#   }
#
# Presets saved before 0.24 carried `workspace: true` + `branch`; they read
# back as directory `@<branch>`.
#
# `am new -p review` applies the preset as defaults; explicit flags win. The
# new-session form shows a Preset field when any preset exists and fills the
# other fields when one is picked. Managed with `am preset save|list|show|rm`.

_PRESETS_LIB_DIR="${AM_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Names, sorted, one per line. Empty when none.
am_preset_names() {
    [[ -f "$AM_CONFIG" ]] || return 0
    jq -r '.presets // {} | keys[]' "$AM_CONFIG" 2>/dev/null
}

# JSON object of one preset on stdout; returns 1 when missing.
am_preset_get() {
    local name="$1"
    [[ -f "$AM_CONFIG" ]] || return 1
    local obj
    obj=$(jq -c --arg n "$name" '.presets[$n] // empty' "$AM_CONFIG" 2>/dev/null)
    [[ -n "$obj" ]] || return 1
    printf '%s\n' "$obj"
}

# One scalar field of a preset (directory|agent|task as strings, shell as
# true/false, args newline-separated). Empty when unset.
# Usage: am_preset_field <name> <field>
am_preset_field() {
    local name="$1" field="$2"
    local obj
    obj=$(am_preset_get "$name") || return 1
    case "$field" in
        args)      jq -r '.args // [] | .[]' <<< "$obj" ;;
        shell)     jq -r '.shell // false' <<< "$obj" ;;
        directory) jq -r 'if (.directory // "") != "" then .directory
                          elif .workspace == true then "@" + (.branch // "")
                          else "" end' <<< "$obj" ;;
        *)         jq -r --arg f "$field" '.[$f] // ""' <<< "$obj" ;;
    esac
}

# Validate a preset name: letters, digits, dash, underscore, dot.
_preset_name_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Write a preset object (JSON) under its name. Creates config.json if needed.
# Usage: am_preset_save <name> <json-object>
am_preset_save() {
    local name="$1" obj="$2"
    _preset_name_valid "$name" || { log_error "Invalid preset name: $name"; return 1; }
    am_config_init
    local tmp
    tmp=$(mktemp "${AM_CONFIG}.XXXXXX") || return 1
    if jq --arg n "$name" --argjson o "$obj" '.presets = ((.presets // {}) + {($n): $o})' "$AM_CONFIG" > "$tmp" 2>/dev/null; then
        command mv "$tmp" "$AM_CONFIG"
    else
        rm -f "$tmp"
        log_error "Could not write preset $name"
        return 1
    fi
}

# Remove a preset. Returns 1 when it did not exist.
am_preset_rm() {
    local name="$1"
    am_preset_get "$name" >/dev/null || return 1
    local tmp
    tmp=$(mktemp "${AM_CONFIG}.XXXXXX") || return 1
    if jq --arg n "$name" 'del(.presets[$n]) | if (.presets // {}) == {} then del(.presets) else . end' "$AM_CONFIG" > "$tmp" 2>/dev/null; then
        command mv "$tmp" "$AM_CONFIG"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Build a preset object from `am new`-style flags. Prints JSON.
# Usage: _preset_from_flags [-t agent] [-d dir|@spec] [-n task] [--shell|--no-shell] [-- agent args...]
_preset_from_flags() {
    local agent="" directory="" task="" shell=false
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type) agent="${2:-}"; shift 2 ;;
            -d|--dir) directory="${2:-}"; shift 2 ;;
            -n|--name|--task) task="${2:-}"; shift 2 ;;
            --shell) shell=true; shift ;;
            --no-shell) shell=false; shift ;;
            --) shift; args=("$@"); break ;;
            -*) log_error "Unknown preset option: $1"; return 1 ;;
            *) directory="$1"; shift ;;
        esac
    done
    if [[ -n "$agent" ]]; then
        agent=$(agent_normalize_type "$agent" 2>/dev/null || echo "$agent")
        [[ -n "${AGENT_COMMANDS[$agent]:-}" ]] || { log_error "Unknown agent type: $agent"; return 1; }
    fi
    directory="${directory/#\~/$HOME}"
    jq -cn --arg agent "$agent" --arg directory "$directory" --arg task "$task" \
        --argjson shell "$shell" \
        --args '{agent: $agent, directory: $directory, task: $task, shell: $shell,
                 args: $ARGS.positional}
                | with_entries(select(.value != "" and .value != false and .value != []))' \
        -- "${args[@]}"
}

# Render one preset as an `am new` command line (for `list` / `show`).
_preset_render() {
    local name="$1"
    local obj
    obj=$(am_preset_get "$name") || return 1
    local agent shell task directory
    # \x1f separator: tabs are IFS whitespace and would collapse empty fields
    IFS=$'\x1f' read -r agent shell task directory < <(
        jq -r '[.agent // "",
                (.shell // false | tostring), .task // "", .directory // ""] | join("")' <<< "$obj")
    # Pre-0.24 presets stored workspace/branch instead of a @spec directory.
    [[ -n "$directory" ]] || directory=$(am_preset_field "$name" directory)
    local -a parts=()
    [[ -n "$agent" ]] && parts+=("-t" "$agent")
    [[ "$shell" == "true" ]] && parts+=("--shell")
    [[ -n "$task" ]] && parts+=("-n" "$task")
    [[ -n "$directory" ]] && parts+=("$directory")
    local -a args=()
    mapfile -t args < <(jq -r '.args // [] | .[]' <<< "$obj")
    (( ${#args[@]} > 0 )) && parts+=("--" "${args[@]}")
    local out="" p
    for p in "${parts[@]}"; do
        if [[ "$p" =~ [[:space:]\"\'] ]]; then out+=" '${p//\'/\'\\\'\'}'"; else out+=" $p"; fi
    done
    printf '%s\n' "${out# }"
}

# Entry point. Usage: preset_main save|list|show|rm ...
preset_main() {
    local sub="${1:-list}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        save|add)
            local name="${1:-}"
            [[ -n "$name" ]] || { echo "Usage: am preset save <name> [-t agent] [-d dir|@spec] [-n task] [--shell] [-- agent-args...]" >&2; return 1; }
            shift
            local obj
            obj=$(_preset_from_flags "$@") || return 1
            am_preset_save "$name" "$obj" || return 1
            log_success "Saved preset $name: am new -p $name  ≡  am new $(_preset_render "$name")"
            ;;
        list|ls)
            local n line
            while IFS= read -r n; do
                [[ -n "$n" ]] || continue
                line=$(_preset_render "$n")
                printf '%-16s am new %s\n' "$n" "$line"
            done < <(am_preset_names)
            ;;
        show|get)
            local name="${1:-}"
            [[ -n "$name" ]] || { echo "Usage: am preset show <name>" >&2; return 1; }
            am_preset_get "$name" | jq . || { log_error "No such preset: $name"; return 1; }
            ;;
        rm|remove|delete)
            local name="${1:-}"
            [[ -n "$name" ]] || { echo "Usage: am preset rm <name>" >&2; return 1; }
            if am_preset_rm "$name"; then log_success "Removed preset $name"; else log_error "No such preset: $name"; return 1; fi
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage: am preset <save|list|show|rm> ...

  am preset save <name> [-t agent] [-d dir|@spec] [-n task] [--shell] [-- agent-args...]
  am preset list
  am preset show <name>
  am preset rm <name>

Apply with `am new -p <name> [overrides...]`; explicit flags win over the
preset, and agent args after `--` are appended to the preset's. The
new-session form offers a Preset field once any preset exists.

Examples:
  am preset save review @ -- --model opus --effort high
  am preset save scratch -t pi ~/code/tools
  am new -p review @48351
EOF
            ;;
        *)
            log_error "Unknown preset subcommand: $sub"
            echo "Run 'am preset help' for usage" >&2
            return 1
            ;;
    esac
}
