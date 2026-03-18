#!/bin/bash
set -e

BASE_USER="dev"
RUNTIME_USER="${HOST_USER:-$BASE_USER}"
USER_HOME="${HOST_HOME:-/home/${RUNTIME_USER}}"
CONFIG_BACKUP="/opt/dev_config"
SUDOERS_UNSAFE_DROPIN="/etc/sudoers.d/90-sb-unsafe-root"
SB_UNSAFE_ROOT="${SB_UNSAFE_ROOT:-0}"
SB_ENABLE_TAILSCALE="${SB_ENABLE_TAILSCALE:-1}"
ENABLE_SSH="${ENABLE_SSH:-0}"
TS_ENABLE_SSH="${TS_ENABLE_SSH:-1}"

# Align the container identity with the host username/home.
if id "$BASE_USER" >/dev/null 2>&1 && [ "$RUNTIME_USER" != "$BASE_USER" ] && ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    groupmod -n "$RUNTIME_USER" "$BASE_USER" || true
    usermod -l "$RUNTIME_USER" "$BASE_USER" || true
fi

if id "$RUNTIME_USER" >/dev/null 2>&1; then
    current_home=$(getent passwd "$RUNTIME_USER" | cut -d: -f6)
    if [ -n "$current_home" ] && [ "$current_home" != "$USER_HOME" ]; then
        usermod -d "$USER_HOME" -m "$RUNTIME_USER" || true
    fi
fi

if ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    RUNTIME_USER="$BASE_USER"
    USER_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
fi

if id "$RUNTIME_USER" >/dev/null 2>&1 && [ -n "${HOST_GID:-}" ]; then
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

if id "$RUNTIME_USER" >/dev/null 2>&1 && [ -n "${HOST_UID:-}" ]; then
    current_uid=$(id -u "$RUNTIME_USER")
    if [ "$current_uid" != "$HOST_UID" ]; then
        usermod -u "$HOST_UID" "$RUNTIME_USER" || true
    fi
fi

RUNTIME_GROUP=$(id -gn "$RUNTIME_USER")

# Keep legacy path references working.
if [ "$USER_HOME" != "/home/dev" ] && [ ! -e /home/dev ]; then
    ln -s "$USER_HOME" /home/dev
fi

# Restore config defaults if missing (from /opt/dev_config baked into the image).
# On first boot the .sb mount is empty; these ensure a usable shell environment.
for file in .zshrc .vimrc .tmux.conf; do
    target="$USER_HOME/$file"
    if [ ! -s "$target" ]; then
        cp "$CONFIG_BACKUP/$file" "$target"
        chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$target"
    fi
done

# Ensure standard home directories exist (creates them in .sb on first boot).
for dir in .claude .codex .codex/tmp .local .local/bin .local/share; do
    if [ ! -d "$USER_HOME/$dir" ]; then
        mkdir -p "$USER_HOME/$dir"
        chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$USER_HOME/$dir"
    fi
done

# Ensure uv cache is writable.
mkdir -p /tmp/uv-cache
chown "${RUNTIME_USER}:${RUNTIME_GROUP}" /tmp/uv-cache

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

if [ "$TS_ENABLE_SSH" = "1" ] && [ "$SB_ENABLE_TAILSCALE" != "1" ]; then
    echo "Warning: TS_ENABLE_SSH=1 ignored because SB_ENABLE_TAILSCALE=0."
fi

if [ "$SB_ENABLE_TAILSCALE" = "1" ] && [ -n "$TS_AUTHKEY" ]; then
    tailscaled --state=/var/lib/tailscale/tailscaled.state &
    sleep 2
    if [ "$TS_ENABLE_SSH" = "1" ]; then
        tailscale up --authkey="$TS_AUTHKEY" --hostname="${HOSTNAME}" --ssh
    else
        tailscale up --authkey="$TS_AUTHKEY" --hostname="${HOSTNAME}"
    fi
elif [ "$SB_ENABLE_TAILSCALE" = "1" ] && [ -z "$TS_AUTHKEY" ]; then
    echo "Warning: SB_ENABLE_TAILSCALE=1 but TS_AUTHKEY is unset; skipping tailscale startup."
fi

exec tail -f /dev/null
