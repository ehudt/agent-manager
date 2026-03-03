#!/bin/bash
# Test: container must have CAP_CHOWN, CAP_DAC_OVERRIDE, and CAP_FOWNER
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

cap_prm=$(docker exec "$CONTAINER" sh -c 'grep CapPrm /proc/1/status | awk "{print \$2}"')

check_cap() {
  local name="$1" bit="$2"
  echo "TEST: $name is available..."
  local present
  present=$(python3 -c "print((int('$cap_prm', 16) >> $bit) & 1)")
  if [ "$present" = "1" ]; then
    echo "PASS: $name is present"
  else
    echo "FAIL: $name is missing (CapPrm=$cap_prm)"
    exit 1
  fi
}

check_cap CAP_CHOWN 0
check_cap CAP_DAC_OVERRIDE 1
check_cap CAP_FOWNER 3
