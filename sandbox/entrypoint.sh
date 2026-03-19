#!/bin/bash
set -e

BASE_USER="ubuntu"
RUNTIME_USER="${HOST_USER:-$BASE_USER}"
USER_HOME="${HOST_HOME:-/home/${RUNTIME_USER}}"
SUDOERS_UNSAFE_DROPIN="/etc/sudoers.d/90-sb-unsafe-root"
SB_UNSAFE_ROOT="${SB_UNSAFE_ROOT:-0}"

# Align the container identity with the host username/home.
if [ "$RUNTIME_USER" != "$BASE_USER" ] && ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    groupmod -n "$RUNTIME_USER" "$BASE_USER"
    usermod -l "$RUNTIME_USER" "$BASE_USER"
fi

current_home=$(getent passwd "$RUNTIME_USER" | cut -d: -f6)
if [ -n "$current_home" ] && [ "$current_home" != "$USER_HOME" ]; then
    usermod -d "$USER_HOME" -m "$RUNTIME_USER"
fi
[ -n "${HOST_GID:-}" ] && {
    current_gid=$(id -g "$RUNTIME_USER")
    if [ "$current_gid" != "$HOST_GID" ]; then
        if getent group "$HOST_GID" >/dev/null 2>&1; then
            usermod -g "$(getent group "$HOST_GID" | cut -d: -f1)" "$RUNTIME_USER"
        else
            groupmod -g "$HOST_GID" "$RUNTIME_USER"
            usermod -g "$HOST_GID" "$RUNTIME_USER"
        fi
    fi
}
[ -n "${HOST_UID:-}" ] && {
    current_uid=$(id -u "$RUNTIME_USER")
    [ "$current_uid" != "$HOST_UID" ] && usermod -u "$HOST_UID" "$RUNTIME_USER"
}

RUNTIME_GROUP=$(id -gn "$RUNTIME_USER")

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
        chown -h "${RUNTIME_USER}:${RUNTIME_GROUP}" "$target" 2>/dev/null || true
    done
fi

chown -R "${RUNTIME_USER}:${RUNTIME_GROUP}" "$USER_HOME" 2>/dev/null || true

# Passwordless sudo: disabled by default, opt-in via SB_UNSAFE_ROOT=1.
if [ "$SB_UNSAFE_ROOT" = "1" ] && [ -w /etc/sudoers.d ]; then
    echo "${RUNTIME_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_UNSAFE_DROPIN"
    chmod 440 "$SUDOERS_UNSAFE_DROPIN"
else
    rm -f "$SUDOERS_UNSAFE_DROPIN" 2>/dev/null || true
fi

touch /tmp/am-entrypoint-ready
exec tail -f /dev/null
