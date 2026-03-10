#!/usr/bin/env bash
# clean-history.sh - remove agent-manager test noise from zsh history
#
# Removes entries matching stub_agent, shell-peek-ready, am-prompt-test,
# bare "bash" commands, and docker exec sandbox commands from test runs.
#
# Usage: ./scripts/clean-history.sh [--dry-run]

set -euo pipefail

HISTFILE="${ZSH_HISTFILE:-$HOME/.zsh_history}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

if [[ ! -f "$HISTFILE" ]]; then
    echo "History file not found: $HISTFILE"
    exit 1
fi

before=$(wc -l < "$HISTFILE")

# Patterns that identify agent-manager test entries
# zsh extended history format: ": timestamp:duration;command"
NOISE_PATTERNS=(
    'stub_agent'
    'shell-peek-ready'
    'am-prompt-test'
    'test-am-'
    '^: [0-9]+:0;bash$'
    ";cat '/tmp/am-prompt-"
)

# Build grep -v pattern
filter=$(printf '|%s' "${NOISE_PATTERNS[@]}")
filter="${filter:1}"  # remove leading |

if $DRY_RUN; then
    matched=$(grep -cE "$filter" "$HISTFILE" || true)
    echo "Would remove $matched / $before lines from $HISTFILE"
    echo ""
    echo "Sample matches:"
    grep -E "$filter" "$HISTFILE" | tail -10
    exit 0
fi

tmp=$(mktemp)
grep -vE "$filter" "$HISTFILE" > "$tmp" || true

after=$(wc -l < "$tmp")
removed=$((before - after))

cp "$HISTFILE" "${HISTFILE}.bak"
mv "$tmp" "$HISTFILE"

echo "Cleaned $removed / $before lines from $HISTFILE"
echo "Backup saved to ${HISTFILE}.bak"
