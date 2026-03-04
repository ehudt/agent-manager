#!/usr/bin/env bash
# install.sh - Install agent-manager commands for local shell usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${PREFIX:-$HOME/.local/bin}"
SHELL_RC=""
TMUX_CONF="${TMUX_CONF:-$HOME/.tmux.conf}"
AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-agent-manager}"
USE_SYMLINK=true
UPDATE_SHELL=true
UPDATE_TMUX=true
ASSUME_YES=false

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Install am into a local bin directory and optionally clean up legacy tmux config.

Options:
  --prefix <dir>      Install directory (default: ~/.local/bin)
  --shell-rc <file>   Shell rc file to update (default: auto-detect zshrc/bashrc)
  --tmux-conf <file>  tmux config file to clean up (default: ~/.tmux.conf)
  --copy              Copy files instead of creating symlinks
  --no-shell          Do not modify shell rc file
  --no-tmux           Do not touch tmux config cleanup
  -y, --yes           Non-interactive mode (accept prompts)
  -h, --help          Show this help
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }

auto_detect_shell_rc() {
    if [[ -n "${ZDOTDIR:-}" && -f "$ZDOTDIR/.zshrc" ]]; then
        echo "$ZDOTDIR/.zshrc"
        return
    fi
    if [[ -f "$HOME/.zshrc" ]]; then
        echo "$HOME/.zshrc"
        return
    fi
    echo "$HOME/.bashrc"
}

confirm() {
    local prompt="$1"
    if $ASSUME_YES; then
        return 0
    fi

    printf "%s [y/N] " "$prompt"
    read -r answer || true
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

install_link_or_copy() {
    local src="$1"
    local dest="$2"

    if $USE_SYMLINK; then
        ln -sfn "$src" "$dest"
    else
        cp "$src" "$dest"
        chmod +x "$dest"
    fi
}

replace_managed_block() {
    local file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local content="$4"
    local tmp_file

    mkdir -p "$(dirname "$file")"
    touch "$file"

    tmp_file=$(mktemp)

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { in_block=1; next }
        $0 == end { in_block=0; next }
        !in_block { print }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"

    {
        printf '\n%s\n' "$begin_marker"
        printf '%s\n' "$content"
        printf '%s\n' "$end_marker"
    } >> "$file"

    log "Updated $file"
}

remove_managed_block() {
    local file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local tmp_file

    mkdir -p "$(dirname "$file")"
    touch "$file"

    tmp_file=$(mktemp)

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { in_block=1; next }
        $0 == end { in_block=0; next }
        !in_block { print }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"

    log "Updated $file"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --shell-rc)
            SHELL_RC="$2"
            shift 2
            ;;
        --tmux-conf)
            TMUX_CONF="$2"
            shift 2
            ;;
        --copy)
            USE_SYMLINK=false
            shift
            ;;
        --no-shell)
            UPDATE_SHELL=false
            shift
            ;;
        --no-tmux)
            UPDATE_TMUX=false
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$SHELL_RC" ]]; then
    SHELL_RC="$(auto_detect_shell_rc)"
fi

mkdir -p "$PREFIX"

install_link_or_copy "$REPO_DIR/am" "$PREFIX/am"
install_link_or_copy "$REPO_DIR/bin/switch-last" "$PREFIX/switch-last"
install_link_or_copy "$REPO_DIR/bin/kill-and-switch" "$PREFIX/kill-and-switch"
log "Installed commands into $PREFIX"

if $UPDATE_SHELL; then
    if confirm "Update $SHELL_RC to ensure $PREFIX is on PATH?"; then
        shell_block='export PATH="'"$PREFIX"':$PATH"'
        replace_managed_block "$SHELL_RC" \
            '# >>> agent-manager >>>' \
            '# <<< agent-manager <<<' \
            "$shell_block"
    else
        log "Skipped shell rc update"
    fi
fi

if $UPDATE_TMUX; then
    if confirm "Remove legacy agent-manager bindings from $TMUX_CONF?"; then
        remove_managed_block "$TMUX_CONF" \
            '# >>> agent-manager >>>' \
            '# <<< agent-manager <<<'
        log "agent-manager now uses its own tmux server/socket: $AM_TMUX_SOCKET"
        log "No shared-server tmux bindings are required."
    else
        log "Skipped tmux config cleanup"
    fi
fi

log "Installation complete"
log "Verify with: am version"
