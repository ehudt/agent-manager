# =============================================================================
# PATH Configuration
# =============================================================================
export PATH="$HOME/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"

# =============================================================================
# Environment Variables
# =============================================================================
export WORDCHARS=''
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# fzf options
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
export FZF_CTRL_R_OPTS='
  --preview "echo {}"
  --preview-window up:3:wrap
  --bind "ctrl-y:execute-silent(echo -n {2..} | xclip -sel clip)+abort"
'

# =============================================================================
# System Limits
# =============================================================================
ulimit -n 300000

# =============================================================================
# History Configuration (100k entries)
# =============================================================================
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000

setopt EXTENDED_HISTORY          # Write timestamps to history
setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicates first when trimming
setopt HIST_IGNORE_DUPS          # Don't record duplicates
setopt HIST_IGNORE_ALL_DUPS      # Remove old duplicates
setopt HIST_IGNORE_SPACE         # Don't record commands starting with space
setopt HIST_VERIFY               # Show command before executing from history
setopt SHARE_HISTORY             # Share history between sessions
setopt APPEND_HISTORY            # Append to history file
setopt INC_APPEND_HISTORY        # Add commands immediately

# =============================================================================
# Shell Options
# =============================================================================
setopt AUTO_CD                   # cd by typing directory name
setopt INTERACTIVE_COMMENTS      # Allow comments in interactive shell
setopt PROMPT_SUBST              # Enable prompt substitution
setopt NO_NOMATCH                # Don't error on no glob matches
setopt NOTIFY                    # Report background job status immediately
unsetopt BEEP                    # No beeping
unsetopt EXTENDED_GLOB           # Disable extended globbing
unsetopt CORRECT                 # No spelling correction

# =============================================================================
# Prompt (Pure)
# =============================================================================
fpath+=(/usr/local/share/zsh/site-functions)
autoload -Uz promptinit
promptinit
prompt pure
zstyle :prompt:pure:prompt:success color 'green'
RPROMPT='%F{blue}%T%f'  # Right-side clock

# =============================================================================
# Completion
# =============================================================================
autoload -Uz compinit
compinit

# Completion styles
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # Case-insensitive
zstyle ':completion:*' menu select                          # Menu selection
zstyle ':completion:*' complete-options true                # Complete files for aliased commands

# =============================================================================
# Key Bindings
# =============================================================================
bindkey -e  # Emacs key bindings

# Word navigation
bindkey '\e[1;3D' backward-word      # Alt+Left (iTerm2)
bindkey '\e\e[D' backward-word       # Alt+Left (Terminal.app)
bindkey '\eb' backward-word          # Meta+B fallback
bindkey '\e[1;3C' forward-word       # Alt+Right (iTerm2)
bindkey '\e\e[C' forward-word        # Alt+Right (Terminal.app)
bindkey '\ef' forward-word           # Meta+F fallback
bindkey '\e[1;5D' backward-word      # Ctrl+Left
bindkey '\e[1;5C' forward-word       # Ctrl+Right

# Word deletion
bindkey '\e^?' backward-kill-word    # Alt+Backspace
bindkey '\e\x7f' backward-kill-word  # Alt+Backspace (alternative)
bindkey '\e[3;3~' kill-word          # Alt+Delete (iTerm2)
bindkey '\e\e[3~' kill-word          # Alt+Delete (Terminal.app)
bindkey '\ed' kill-word              # Meta+D fallback
bindkey '^W' backward-kill-word      # Ctrl+W

# Line navigation
bindkey '\e[H' beginning-of-line     # Home
bindkey '\e[F' end-of-line           # End
bindkey '\e[1~' beginning-of-line    # Home (alternative)
bindkey '\e[4~' end-of-line          # End (alternative)
bindkey '^[[1~' beginning-of-line    # Home (extra alternative)
bindkey '^[[4~' end-of-line          # End (extra alternative)
bindkey '^A' beginning-of-line       # Ctrl+A
bindkey '^E' end-of-line             # Ctrl+E

# Line editing
bindkey '\e[3~' delete-char          # Delete key
bindkey '^[[3~' delete-char          # Delete key (alternative)
bindkey '^U' backward-kill-line      # Ctrl+U
bindkey '^K' kill-line               # Ctrl+K

# History search
bindkey '^[[A' history-search-backward  # Up arrow
bindkey '^[[B' history-search-forward   # Down arrow

# Arrow keys (simple cursor movement fallback)
[[ -n "${terminfo[kcub1]:-}" ]] && bindkey "${terminfo[kcub1]}" backward-char   # ←
[[ -n "${terminfo[kcuf1]:-}" ]] && bindkey "${terminfo[kcuf1]}" forward-char    # →

# =============================================================================
# Colors
# =============================================================================
autoload -Uz colors && colors

# ls colors (for GNU ls)
export LS_COLORS='di=1;36:ln=1;35:so=1;33:pi=1;33:ex=1;32:bd=1;34:cd=1;34:su=0;41:sg=0;46:tw=0;42:ow=0;43:'

# Colored output
export GREP_OPTIONS='--color=auto'
export LESS='-R'
export MANPAGER='less -R'

# less colors (for man pages)
export LESS_TERMCAP_mb=$'\e[1;31m'     # Begin bold
export LESS_TERMCAP_md=$'\e[1;36m'     # Begin blink (bold cyan)
export LESS_TERMCAP_me=$'\e[0m'        # End mode
export LESS_TERMCAP_so=$'\e[1;44;33m'  # Begin standout (yellow on blue)
export LESS_TERMCAP_se=$'\e[0m'        # End standout
export LESS_TERMCAP_us=$'\e[1;32m'     # Begin underline (bold green)
export LESS_TERMCAP_ue=$'\e[0m'        # End underline

# =============================================================================
# Aliases - Navigation
# =============================================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ~='cd ~'
alias -- -='cd -'

# =============================================================================
# Aliases - Listing
# =============================================================================
if command -v eza &> /dev/null; then
    alias ls='eza --color=auto --icons=always'
    alias ll='eza -l --color=auto --icons=always --git'
    alias la='eza -la --color=auto --icons=always --git'
    alias l='eza -l --color=auto --icons=always'
    alias lt='eza -T --color=auto --icons=always'  # Tree view
else
    alias ls='ls --color=auto -F'
    alias ll='ls -alhF'
    alias la='ls -A'
    alias l='ls -CF'
fi

# =============================================================================
# Aliases - Modern CLI Tools
# =============================================================================
if command -v bat &> /dev/null; then
    alias cat='bat --paging=never'
    alias catp='bat'  # With paging
fi

if command -v rg &> /dev/null; then
    alias rg='rg --color=auto'
fi

alias tree='tree -C'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'

# =============================================================================
# Aliases - File Operations
# =============================================================================
alias mkdir='mkdir -pv'
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -iv'
alias ln='ln -iv'
alias df='df -h'
alias du='du -h'

# =============================================================================
# Aliases - Utilities
# =============================================================================
alias path='echo $PATH | tr ":" "\n"'
alias ts='date +%Y-%m-%d_%H%M'
alias c='clear'
alias cls='clear'
alias zshrc='${EDITOR:-vim} ~/.zshrc'
alias vimrc='${EDITOR:-vim} ~/.vimrc'
alias reload='source ~/.zshrc'
alias myip='curl -s ifconfig.me'
alias localip='ip addr show | grep "inet " | grep -v 127.0.0.1 | awk "{print \$2}" | cut -d/ -f1'
alias o='xdg-open'
alias clipboard='xclip -sel clip'
alias ipy='ipython'
alias tmux-reload='tmux source-file ~/.tmux.conf && echo "Tmux config reloaded"'

# =============================================================================
# Aliases - Git
# =============================================================================
alias g='git'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'
alias glog='git log --oneline --graph --decorate'
alias latest_branch="git for-each-ref --count=10 --sort=-committerdate refs/heads/ --format='%(refname:short)'"

# =============================================================================
# Aliases - Custom
# =============================================================================
alias rsyncpb='rsync -a --human-readable --info=progress2 --partial --append-verify --log-file="/home/ehud/logs/rsync-$(date +%F_%T).log"'
alias sgpt='function _sgpt() { command sgpt "$(IFS=" "; echo "$*")"; }; _sgpt'

# =============================================================================
# Functions
# =============================================================================

# Generate random password
mkpw() {
    head /dev/urandom | uuencode -m - | sed -n 2p | cut -c1-${1:-20}
}

# Show exit code of last command
wat() {
    echo $?
}
alias what="wat"

# Open current git branch in browser
open-branch() {
    remote=$(git config --get remote.origin.url)
    branch=$(git rev-parse --abbrev-ref HEAD)
    xdg-open "${remote:0:-4}/tree/${branch}"
}

# Wait for a process to finish
wait_finish() {
    while pgrep "${1}" > /dev/null; do
        sleep 1;
    done;
}

# =============================================================================
# Tool Initializations (must be at end)
# =============================================================================

# fzf key bindings and completion
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# uv (Python package manager)
if [ -f "$HOME/.local/bin/env" ]; then
    . "$HOME/.local/bin/env"
fi

# zoxide (smart cd)
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init zsh)"
fi

# fnm (Fast Node Manager)
FNM_PATH="$HOME/.local/share/fnm"
if [ -d "$FNM_PATH" ]; then
    export PATH="$FNM_PATH:$PATH"
    eval "`fnm env`"
fi
