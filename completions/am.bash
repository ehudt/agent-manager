# bash completion for am (Agent Manager). Printed by `am completions bash`;
# `am install` adds  eval "$(am completions bash)"  to the shell rc.
# Session names come from the live registry (`am list --json`), preset
# names from `am preset list`, so they are current at every <TAB>.

_am_commands="list new send peek attach shell review id cd owner diff kill config preset info status doctor log wait done result interrupt restore install uninstall completions help version"
_am_agent_types="@AGENT_TYPES@"
_am_states="ready running waiting_user background starting idle dead unknown"
_am_config_keys="agent auto_restore logs shell dir_provider notify notify_states notify_cmd"

_am_sessions() { am list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null; }
_am_presets() { am preset list 2>/dev/null | awk 'NF { print $1 }'; }

_am_flags_for() {
    case "$1" in
        list) echo "--json --state" ;;
        new) echo "-t --type -p --preset -n --name -d --dir --shell --no-shell --detach --print-session --" ;;
        send) echo "--wait --queue --force -f --timeout" ;;
        peek) echo "--pane --follow -f --lines --history --grep" ;;
        diff) echo "--ack --reset --checkpoint -c --list -l --stat --name-only --numstat -w" ;;
        wait) echo "--state --timeout --json --any --all" ;;
        status) echo "--json" ;;
        kill) echo "--all --state" ;;
        doctor) echo "--capture" ;;
        log) echo "-n --lines --grep -g -f --follow --path" ;;
        result) echo "--wait" ;;
        interrupt) echo "-i --interactive" ;;
        install) echo "--refresh --dry-run --prefix --shell-rc --tmux-conf --no-shell --no-tmux --copy -y --yes" ;;
        uninstall) echo "--dry-run --purge -y --yes --prefix --shell-rc" ;;
    esac
}

_am() {
    local cur prev cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]:-}"

    if (( COMP_CWORD == 1 )); then
        COMPREPLY=($(compgen -W "$_am_commands" -- "$cur"))
        return
    fi

    # Values for the flag before the cursor
    case "$prev" in
        -t|--type) COMPREPLY=($(compgen -W "$_am_agent_types" -- "$cur")); return ;;
        -p|--preset) COMPREPLY=($(compgen -W "$(_am_presets)" -- "$cur")); return ;;
        --state) COMPREPLY=($(compgen -W "$_am_states" -- "$cur")); return ;;
        --pane) COMPREPLY=($(compgen -W "agent shell" -- "$cur")); return ;;
        -d|--dir|--prefix) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --shell-rc|--tmux-conf) COMPREPLY=($(compgen -f -- "$cur")); return ;;
        --timeout|--lines|--grep|-n|--name|--checkpoint|-c) return ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$(_am_flags_for "$cmd")" -- "$cur"))
        return
    fi

    case "$cmd" in
        send|peek|attach|shell|review|kill|info|status|wait|result|interrupt|doctor|log|diff)
            COMPREPLY=($(compgen -W "$(_am_sessions)" -- "$cur")) ;;
        new|cd|owner)
            COMPREPLY=($(compgen -d -- "$cur")) ;;
        config)
            if (( COMP_CWORD == 2 )); then
                COMPREPLY=($(compgen -W "list get set" -- "$cur"))
            elif (( COMP_CWORD == 3 )); then
                COMPREPLY=($(compgen -W "$_am_config_keys" -- "$cur"))
            fi ;;
        preset)
            if (( COMP_CWORD == 2 )); then
                COMPREPLY=($(compgen -W "save list show rm" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == show || "${COMP_WORDS[2]}" == rm ]]; then
                COMPREPLY=($(compgen -W "$(_am_presets)" -- "$cur"))
            fi ;;
        completions)
            COMPREPLY=($(compgen -W "bash zsh" -- "$cur")) ;;
    esac
}

complete -F _am am
