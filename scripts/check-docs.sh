#!/usr/bin/env bash
# check-docs.sh - verify AGENTS.md references match the codebase
#
# Checks:
# 1. Every file in the "Key Files" table exists on disk
# 2. Every function in the "Key Functions" section exists in lib/*.sh or am

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

# --- Check Key Files ---
printf 'Checking Key Files table...\n'
# Extract file paths from markdown table rows: | `path` | description |
while IFS= read -r file; do
    if [[ ! -e "$file" ]]; then
        printf '  MISSING file: %s\n' "$file" >&2
        errors=$((errors + 1))
    fi
done < <(sed -n '/^## Key Files/,/^## /p' AGENTS.md \
    | grep -oP '(?<=\| `)[^`]+(?=`)' \
    | head -n -1)

# --- Check Key Functions ---
printf 'Checking Key Functions...\n'
# Extract function names from lines like: - `func_name(...)` - description
while IFS= read -r func; do
    # Handle compound entries like "registry_add/get_field/update/remove/list"
    # First part is full name, rest get the prefix prepended
    if [[ "$func" == */* ]]; then
        first="${func%%/*}"
        prefix="${first%_*}_"  # e.g. "registry_add" → "registry_"
        # Check first part as-is
        if ! grep -rq "^${first}()" lib/ am 2>/dev/null; then
            printf '  MISSING function: %s\n' "$first" >&2
            errors=$((errors + 1))
        fi
        # Check remaining parts with prefix
        rest="${func#*/}"
        IFS='/' read -ra parts <<< "$rest"
        for part in "${parts[@]}"; do
            local_name="${prefix}${part}"
            if ! grep -rq "^${local_name}()" lib/ am 2>/dev/null; then
                printf '  MISSING function: %s\n' "$local_name" >&2
                errors=$((errors + 1))
            fi
        done
    else
        # Simple function name
        name="${func%%(*}"  # strip trailing parens
        if ! grep -rq "^${name}()" lib/ am 2>/dev/null; then
            printf '  MISSING function: %s\n' "$name" >&2
            errors=$((errors + 1))
        fi
    fi
done < <(sed -n '/^## Key Functions/,/^## /p' AGENTS.md \
    | grep -oP '(?<=`)[a-z_][a-z_/]+(?=[\(`])' )

if [[ $errors -gt 0 ]]; then
    printf '\nDoc sync check FAILED: %d error(s)\n' "$errors" >&2
    exit 1
fi

printf 'Doc sync check passed\n'
