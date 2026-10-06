# zsh completion for am (Agent Manager). Printed by `am completions zsh`;
# `am install` adds  eval "$(am completions zsh)"  to the shell rc.
# Session names come from the live registry (`am list --json`), preset
# names from `am preset list`, so they are current at every <TAB>.

(( $+functions[compdef] )) || { autoload -Uz compinit; compinit -C; }

_am_sessions() { am list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null; }
_am_presets() { am preset list 2>/dev/null | awk 'NF { print $1 }'; }

_am_flags_for() {
    case "$1" in
        list) echo "--json --state" ;;
        new) echo "-t --type -p --preset -d --dir --shell --no-shell --detach --print-session --" ;;
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
    cur="${words[CURRENT]}"
    prev="${words[CURRENT-1]}"
    cmd="${words[2]}"
    local -a commands
    commands=(
        'list:List all sessions'
        'new:Create a new agent session'
        'send:Send a prompt to a running session'
        'peek:Show or follow a session pane'
        'attach:Attach to a session'
        'shell:Toggle the shell panel'
        'review:Toggle the review pane'
        'id:Print the current am session name'
        'cd:Record where the current session works now'
        'owner:Live session working in a directory'
        'diff:What a session changed since you last reviewed it'
        'kill:Kill a session'
        'config:Show or change saved defaults'
        'preset:Launch presets for new -p'
        'info:Registry metadata of a session'
        'status:Detailed session info'
        'doctor:Every input behind a session state'
        'log:Events log (launches, kills, sends, failures)'
        'wait:Block until sessions reach a state'
        'done:Record a result summary (inside a session)'
        'result:Read a session result'
        'interrupt:Send Ctrl-C to an agent pane'
        'restore:Resume a closed session'
        'install:First-time setup'
        'uninstall:Reverse the install'
        'completions:Print shell completions'
        'help:Show help'
        'version:Show version'
    )

    if (( CURRENT == 2 )); then
        _describe 'am command' commands
        return
    fi

    case "$prev" in
        -t|--type) compadd -- @AGENT_TYPES@; return ;;
        -p|--preset) compadd -- ${(f)"$(_am_presets)"}; return ;;
        --state) compadd -- ready running waiting_user background starting idle dead unknown; return ;;
        --pane) compadd -- agent shell; return ;;
        -d|--dir|--prefix) _files -/; return ;;
        --shell-rc|--tmux-conf) _files; return ;;
        --timeout|--lines|--grep|-n|--checkpoint|-c) return ;;
    esac

    if [[ "$cur" == -* ]]; then
        compadd -- ${=$(_am_flags_for "$cmd")}
        return
    fi

    case "$cmd" in
        send|peek|attach|shell|review|kill|info|status|wait|result|interrupt|doctor|log|diff)
            compadd -- ${(f)"$(_am_sessions)"} ;;
        new|cd|owner)
            _files -/ ;;
        config)
            if (( CURRENT == 3 )); then
                compadd -- list get set
            elif (( CURRENT == 4 )); then
                compadd -- agent auto_restore logs shell dir_provider notify notify_states notify_cmd
            fi ;;
        preset)
            if (( CURRENT == 3 )); then
                compadd -- save list show rm
            elif [[ "${words[3]}" == show || "${words[3]}" == rm ]]; then
                compadd -- ${(f)"$(_am_presets)"}
            fi ;;
        completions)
            compadd -- bash zsh ;;
    esac
}

compdef _am am
