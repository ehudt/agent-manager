#!/bin/bash
set -e

USER="ubuntu"
USER_HOME="/home/ubuntu"
SUDOERS_APT_DROPIN="/etc/sudoers.d/80-sb-apt"
SUDOERS_UNSAFE_DROPIN="/etc/sudoers.d/90-sb-unsafe-root"
SB_UNSAFE_ROOT="${SB_UNSAFE_ROOT:-0}"

# Align UID/GID with the host so bind-mounted files have correct ownership.
if [ -n "${HOST_GID:-}" ]; then
    current_gid=$(id -g "$USER")
    if [ "$current_gid" != "$HOST_GID" ]; then
        if getent group "$HOST_GID" >/dev/null 2>&1; then
            usermod -g "$(getent group "$HOST_GID" | cut -d: -f1)" "$USER"
        else
            groupmod -g "$HOST_GID" "$USER"
            usermod -g "$HOST_GID" "$USER"
        fi
    fi
fi
if [ -n "${HOST_UID:-}" ]; then
    current_uid=$(id -u "$USER")
    if [ "$current_uid" != "$HOST_UID" ]; then
        usermod -u "$HOST_UID" "$USER"
    fi
fi

GROUP=$(id -gn "$USER")

# Seed skeleton files into home if missing (first run with empty bind mount).
if [ -d /etc/skel ]; then
    for f in /etc/skel/.*; do
        base="$(basename "$f")"
        [ "$base" = "." ] || [ "$base" = ".." ] && continue
        [ -e "$USER_HOME/$base" ] || cp -a "$f" "$USER_HOME/$base"
    done
fi

# Always chown home — it's a bind mount so ownership may differ.
# Runs after skeleton seeding so copied files get correct ownership too.
chown -R "${USER}:${GROUP}" "$USER_HOME" 2>/dev/null || true

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

# Install user-level tools into bind-mounted home (idempotent, runs as ubuntu).
_install_user_tools() {
    # Rust toolchain (--no-modify-path: we source .cargo/env in .zshrc)
    if [ ! -x "$USER_HOME/.cargo/bin/rustc" ]; then
        su - "$USER" -c 'curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path' >&2
        su - "$USER" -c '. "$HOME/.cargo/env" && rustup component add rustfmt' >&2
    fi

    # uv-managed Python
    if ! su - "$USER" -c 'uv python list --only-installed 2>/dev/null' | grep -q cpython; then
        su - "$USER" -c 'uv python install' >&2
    fi

    # ipython
    if [ ! -x "$USER_HOME/.local/bin/ipython" ]; then
        su - "$USER" -c 'uv tool install ipython' >&2
    fi
}
# Signal readiness immediately — tool installs continue in the background.
touch /tmp/am-entrypoint-ready

_install_user_tools &

# Wait for background installs, then idle. Cannot exec here — that would
# replace PID 1 and orphan the background job.
wait
exec tail -f /dev/null
