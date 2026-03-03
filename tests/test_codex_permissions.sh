#!/bin/bash
# Test: ~/.codex/ and ~/.codex/tmp/ must be writable by the runtime user
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

HOST_USER=$(id -un)

echo "TEST: ~/.codex/ is writable by $HOST_USER..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.codex/.sb-write-test" && rm "$HOME/.codex/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.codex/ is writable"
else
  echo "FAIL: ~/.codex/ is not writable by $HOST_USER"
  exit 1
fi

echo "TEST: ~/.codex/tmp/ is writable by $HOST_USER..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.codex/tmp/.sb-write-test" && rm "$HOME/.codex/tmp/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.codex/tmp/ is writable"
else
  echo "FAIL: ~/.codex/tmp/ is not writable by $HOST_USER"
  exit 1
fi
