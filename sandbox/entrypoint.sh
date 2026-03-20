#!/bin/bash
set -e

USER="ubuntu"
USER_HOME="/home/ubuntu"
SUDOERS_APT_DROPIN="/etc/sudoers.d/80-sb-apt"
SUDOERS_UNSAFE_DROPIN="/etc/sudoers.d/90-sb-unsafe-root"
SB_UNSAFE_ROOT="${SB_UNSAFE_ROOT:-0}"

# Align UID/GID with the host so bind-mounted files have correct ownership.
uid_changed=0
if [ -n "${HOST_GID:-}" ]; then
    current_gid=$(id -g "$USER")
    if [ "$current_gid" != "$HOST_GID" ]; then
        if getent group "$HOST_GID" >/dev/null 2>&1; then
            usermod -g "$(getent group "$HOST_GID" | cut -d: -f1)" "$USER"
        else
            groupmod -g "$HOST_GID" "$USER"
            usermod -g "$HOST_GID" "$USER"
        fi
        uid_changed=1
    fi
fi
if [ -n "${HOST_UID:-}" ]; then
    current_uid=$(id -u "$USER")
    if [ "$current_uid" != "$HOST_UID" ]; then
        usermod -u "$HOST_UID" "$USER"
        uid_changed=1
    fi
fi

GROUP=$(id -gn "$USER")

# Only chown home if UID/GID actually changed.
if [ "$uid_changed" = "1" ]; then
    chown -R "${USER}:${GROUP}" "$USER_HOME" 2>/dev/null || true
fi

# Manifest-driven state hydration.
STATE_DIR="$USER_HOME/.am-state"
MANIFEST="$STATE_DIR/mappings.json"
if [ -f "$MANIFEST" ]; then
    jq -r '.mappings[]? | [.source, .target, (.mode // "")] | @tsv' "$MANIFEST" |
    while IFS=$'\t' read -r source target mode; do
        [ -n "$source" ] || continue
        target="${target/#\~/$USER_HOME}"
        full_source="$STATE_DIR/data/$source"
        [ -e "$full_source" ] || continue

        mkdir -p "$(dirname "$target")"
        rm -rf "$target"
        ln -sfn "$full_source" "$target"
        [ -n "$mode" ] && chmod "$mode" "$full_source" 2>/dev/null || true
        chown -h "${USER}:${GROUP}" "$target" 2>/dev/null || true
    done
fi

# Always allow passwordless apt-get/apt so agents can install packages.
if [ -w /etc/sudoers.d ]; then
    printf '%s ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt\n' "$USER" \
        > "$SUDOERS_APT_DROPIN"
    chmod 440 "$SUDOERS_APT_DROPIN"
fi

# Full passwordless sudo: disabled by default, opt-in via SB_UNSAFE_ROOT=1.
if [ "$SB_UNSAFE_ROOT" = "1" ] && [ -w /etc/sudoers.d ]; then
    echo "${USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_UNSAFE_DROPIN"
    chmod 440 "$SUDOERS_UNSAFE_DROPIN"
else
    rm -f "$SUDOERS_UNSAFE_DROPIN" 2>/dev/null || true
fi

touch /tmp/am-entrypoint-ready
exec tail -f /dev/null
