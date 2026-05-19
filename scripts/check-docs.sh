#!/usr/bin/env bash
# check-docs.sh - verify AGENTS.md references match the codebase
#
# Checks:
# 1. Every file in the "Key Files" table exists on disk
# 2. Every function in the "Key Functions" section exists in lib/*.sh or am
#
# Portable: uses awk + perl (no GNU-only `grep -oP` / `head -n -1`).

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

# Extract a `##` section from AGENTS.md (excluding the next heading line).
section() {
    awk -v hdr="$1" '
        $0 == hdr {f=1; next}
        f && /^## / {exit}
        f
    ' AGENTS.md
}

# --- Check Key Files ---
printf 'Checking Key Files table...\n'
# Markdown table rows: | `path` | description |
# Skip the header divider row (| --- | --- |).
mapfile -t files < <(
    section '## Key Files' \
        | perl -ne 'next if /^\|\s*-+/; print "$1\n" if /^\|\s*`([^`]+)`/'
)
if (( ${#files[@]} == 0 )); then
    printf 'ERROR: no file entries extracted from "## Key Files" — script regex broken or section missing.\n' >&2
    exit 2
fi
for file in "${files[@]}"; do
    if [[ ! -e "$file" ]]; then
        printf '  MISSING file: %s\n' "$file" >&2
        errors=$((errors + 1))
    fi
done

# --- Check Key Functions ---
printf 'Checking Key Functions...\n'
# Function tokens are backticked lowercase identifiers ending at `(` or backtick:
#   `func_name(args)` or `func_name`
mapfile -t funcs < <(
    section '## Key Functions' \
        | perl -ne 'print "$1\n" while /`([a-z_][a-z_\/]+)[(`]/g'
)
if (( ${#funcs[@]} == 0 )); then
    printf 'ERROR: no function tokens extracted from "## Key Functions" — script regex broken or section missing.\n' >&2
    exit 2
fi

func_exists() {
    grep -rq "^${1}()" lib/ am 2>/dev/null
}

for func in "${funcs[@]}"; do
    if [[ "$func" == */* ]]; then
        # Compound entry: "registry_add/get_field/update/remove/list".
        # First part is full name; rest inherit the prefix before the underscore.
        first="${func%%/*}"
        prefix="${first%_*}_"
        if ! func_exists "$first"; then
            printf '  MISSING function: %s\n' "$first" >&2
            errors=$((errors + 1))
        fi
        rest="${func#*/}"
        IFS='/' read -ra parts <<< "$rest"
        for part in "${parts[@]}"; do
            name="${prefix}${part}"
            if ! func_exists "$name"; then
                printf '  MISSING function: %s\n' "$name" >&2
                errors=$((errors + 1))
            fi
        done
    else
        name="${func%%(*}"
        if ! func_exists "$name"; then
            printf '  MISSING function: %s\n' "$name" >&2
            errors=$((errors + 1))
        fi
    fi
done

if (( errors > 0 )); then
    printf '\nDoc sync check FAILED: %d error(s)\n' "$errors" >&2
    exit 1
fi

printf 'Doc sync check passed\n'
