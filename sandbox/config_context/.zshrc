export PATH="$HOME/.local/bin:$PATH"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000

setopt APPEND_HISTORY
setopt HIST_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS
setopt AUTO_CD

autoload -Uz compinit
compinit

bindkey -e

autoload -Uz colors && colors
PROMPT='%n@%m:%~ %# '

alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
