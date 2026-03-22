export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt INTERACTIVE_COMMENTS
setopt AUTO_CD
setopt PROMPT_SUBST
setopt NO_NOMATCH
unsetopt BEEP

# Completion
autoload -Uz compinit
compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' menu select

# Key bindings
bindkey -e

# Pure prompt (installed to /usr/local/share/zsh/site-functions via npm)
autoload -Uz promptinit
promptinit
prompt pure

# fzf keybindings and completion (Ctrl-R history, Ctrl-T files, Alt-C cd)
source <(fzf --zsh)
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
