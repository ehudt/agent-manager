#!/bin/bash
set -e

BASE_USER="dev"
RUNTIME_USER="${HOST_USER:-$BASE_USER}"
USER_HOME="${HOST_HOME:-/home/${RUNTIME_USER}}"
CONFIG_BACKUP="/opt/dev_config"
SUDOERS_UNSAFE_DROPIN="/etc/sudoers.d/90-sb-unsafe-root"
SB_UNSAFE_ROOT="${SB_UNSAFE_ROOT:-0}"
ENABLE_SSH="${ENABLE_SSH:-0}"
SB_READ_ONLY_ROOTFS="${SB_READ_ONLY_ROOTFS:-0}"

if [ "$SB_READ_ONLY_ROOTFS" = "1" ]; then
    # Read-only rootfs cannot support rewriting /home paths or moving the
    # runtime user's home directory. Keep the stable in-image home instead.
    RUNTIME_USER="$BASE_USER"
    USER_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
fi

ensure_dir() {
    local path="$1"
    shift

    # Parse -o and -g flags for ownership fallback
    local owner="" group="" mode=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) owner="$2"; args+=("$1" "$2"); shift 2 ;;
            -g) group="$2"; args+=("$1" "$2"); shift 2 ;;
            -m) mode="$2"; args+=("$1" "$2"); shift 2 ;;
            *)  args+=("$1"); shift ;;
        esac
    done

    if ! install -d "${args[@]}" "$path" 2>/dev/null; then
        mkdir -p "$path" 2>/dev/null || true
        # Explicit chown/chmod fallback
        if [ -n "$owner" ] && [ -n "$group" ]; then
            chown "$owner:$group" "$path" 2>/dev/null ||
                echo "Warning: cannot chown $path to $owner:$group" >&2
        fi
        if [ -n "$mode" ]; then
            chmod "$mode" "$path" 2>/dev/null || true
        fi
    fi
}

# Align the container identity with the host username/home.
if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && id "$BASE_USER" >/dev/null 2>&1 && [ "$RUNTIME_USER" != "$BASE_USER" ] && ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    groupmod -n "$RUNTIME_USER" "$BASE_USER" || true
    usermod -l "$RUNTIME_USER" "$BASE_USER" || true
fi

if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && id "$RUNTIME_USER" >/dev/null 2>&1; then
    current_home=$(getent passwd "$RUNTIME_USER" | cut -d: -f6)
    if [ -n "$current_home" ] && [ "$current_home" != "$USER_HOME" ]; then
        usermod -d "$USER_HOME" -m "$RUNTIME_USER" || true
    fi
fi

if ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    RUNTIME_USER="$BASE_USER"
    USER_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
fi

if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && id "$RUNTIME_USER" >/dev/null 2>&1 && [ -n "${HOST_GID:-}" ]; then
    current_gid=$(id -g "$RUNTIME_USER")
    if [ "$current_gid" != "$HOST_GID" ]; then
        if getent group "$HOST_GID" >/dev/null 2>&1; then
            target_group=$(getent group "$HOST_GID" | cut -d: -f1)
            usermod -g "$target_group" "$RUNTIME_USER" || true
        else
            groupmod -g "$HOST_GID" "$RUNTIME_USER" || true
            usermod -g "$HOST_GID" "$RUNTIME_USER" || true
        fi
    fi
fi

if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && id "$RUNTIME_USER" >/dev/null 2>&1 && [ -n "${HOST_UID:-}" ]; then
    current_uid=$(id -u "$RUNTIME_USER")
    if [ "$current_uid" != "$HOST_UID" ]; then
        usermod -u "$HOST_UID" "$RUNTIME_USER" || true
    fi
fi

RUNTIME_GROUP=$(id -gn "$RUNTIME_USER")

# Keep legacy path references working.
if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && [ "$USER_HOME" != "/home/dev" ] && [ ! -e /home/dev ]; then
    ln -s "$USER_HOME" /home/dev
fi

# Ensure Codex state directory is writable by runtime user.
# File mounts like $HOME/.codex/config.toml can cause Docker to create the
# parent directory as root-owned if it doesn't already exist.
if [ "$SB_READ_ONLY_ROOTFS" = "1" ]; then
    mkdir -p "$USER_HOME/.codex/tmp"
else
    # File mounts like $HOME/.local/bin/claude can leave parent directories
    # root-owned, which breaks tools that write XDG state during shell startup.
    ensure_dir "$USER_HOME/.local" -m 755 -o "${RUNTIME_USER}" -g "${RUNTIME_GROUP}"
    ensure_dir "$USER_HOME/.local/share" -m 755 -o "${RUNTIME_USER}" -g "${RUNTIME_GROUP}"
    ensure_dir "$USER_HOME/.codex" -m 755 -o "${RUNTIME_USER}" -g "${RUNTIME_GROUP}"
    ensure_dir "$USER_HOME/.codex/tmp" -m 755 -o "${RUNTIME_USER}" -g "${RUNTIME_GROUP}"
fi

# Ensure uv cache is writable inside sandboxed sessions.
if [ "$SB_READ_ONLY_ROOTFS" = "1" ]; then
    mkdir -p /tmp/uv-cache
else
    ensure_dir /tmp/uv-cache -m 755 -o "${RUNTIME_USER}" -g "${RUNTIME_GROUP}"
fi

# Mirror mapped workspace path while preserving /workspace compatibility.
if [ "$SB_READ_ONLY_ROOTFS" != "1" ] && [ -n "${TARGET_DIR:-}" ] && [ ! -e /workspace ]; then
    mkdir -p "$(dirname "$TARGET_DIR")"
    ln -s "$TARGET_DIR" /workspace
fi

# Phase 2: manifest-driven state hydration
# The state volume is mounted at the host-home path selected by sandbox_start.
# Hydration should follow that layout even if the runtime user's passwd home
# diverges (for example, when account renaming/migration is partial).
STATE_HOME="${HOST_HOME:-$USER_HOME}"
STATE_DIR="$STATE_HOME/.am-state"
MANIFEST="$STATE_DIR/mappings.json"
if [ -f "$MANIFEST" ]; then
    jq -r '.mappings[]? | [.source, .target, (.mode // "")] | @tsv' "$MANIFEST" |
    while IFS=$'	' read -r source target mode; do
        [ -n "$source" ] || continue
        target="${target/#\~/$STATE_HOME}"
        full_source="$STATE_DIR/data/$source"
        [ -e "$full_source" ] || continue

        mkdir -p "$(dirname "$target")"
        rm -rf "$target"
        ln -sfn "$full_source" "$target"
        [ -n "$mode" ] && chmod "$mode" "$full_source" 2>/dev/null || true
        chown -h "${RUNTIME_USER}:${RUNTIME_GROUP}" "$target" 2>/dev/null || true
    done
fi

# Restore config files if missing or empty
for file in .zshrc .vimrc; do
    target="$USER_HOME/$file"
    if [ ! -e "$target" ]; then
        cp "$CONFIG_BACKUP/$file" "$target"
        chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$target"
    fi
done

# Default hardened mode disables passwordless sudo. Compatibility mode
# restores it explicitly when requested.
if [ "$SB_UNSAFE_ROOT" = "1" ]; then
    if [ -w /etc/sudoers.d ]; then
        echo "Warning: SB_UNSAFE_ROOT=1 enabled; passwordless sudo is allowed."
        echo "${RUNTIME_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_UNSAFE_DROPIN"
        chmod 440 "$SUDOERS_UNSAFE_DROPIN"
    else
        echo "Warning: SB_UNSAFE_ROOT=1 requested but /etc/sudoers.d is not writable."
    fi
else
    if [ -w /etc/sudoers.d ]; then
        rm -f "$SUDOERS_UNSAFE_DROPIN"
    fi
fi

if [ "$ENABLE_SSH" = "1" ]; then
    # Copy authorized_keys to a writable location (host ~/.ssh is mounted read-only)
    if [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
        mkdir -p "$USER_HOME/.ssh_writable"
        cp "$USER_HOME/.ssh/authorized_keys" "$USER_HOME/.ssh_writable/authorized_keys"
        chmod 700 "$USER_HOME/.ssh_writable"
        chmod 600 "$USER_HOME/.ssh_writable/authorized_keys"
        chown -R "${RUNTIME_USER}:${RUNTIME_GROUP}" "$USER_HOME/.ssh_writable"
        if [ -w /etc/ssh/sshd_config ]; then
            sed -i "s|AuthorizedKeysFile .ssh/authorized_keys|AuthorizedKeysFile ${USER_HOME}/.ssh_writable/authorized_keys|" /etc/ssh/sshd_config
        else
            echo "Warning: /etc/ssh/sshd_config is not writable; using default AuthorizedKeysFile."
        fi
    fi
    service ssh start
fi

touch /tmp/am-entrypoint-ready
exec tail -f /dev/null
