#!/bin/bash
# Test: ~/.claude/ must be writable inside the container
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

HOST_USER=$(id -un)

echo "TEST: ~/.claude/ is writable..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.claude/.sb-write-test" && rm "$HOME/.claude/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.claude/ is writable"
else
  echo "FAIL: ~/.claude/ is read-only"
  exit 1
fi
