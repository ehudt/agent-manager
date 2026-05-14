#!/usr/bin/env bash
# tests/state_lab/run.sh - State-detection lab runner
#
# Usage:
#   tests/state_lab/run.sh                       # run all cases
#   tests/state_lab/run.sh 01-jsonl-newest       # run by prefix match
#   tests/state_lab/run.sh --list                # list cases
#   LAB_KEEP=true tests/state_lab/run.sh CASE    # keep LAB_DIR after run
#   LAB_VERBOSE=true ...                         # extra logging

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="$DIR/cases"

list_cases() {
    find "$CASES_DIR" -maxdepth 1 -name '*.sh' -type f | sort
}

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    list_cases | xargs -n1 basename | sed 's/\.sh$//'
    exit 0
fi

filter="${1:-}"

total_run=0; total_pass=0; total_fail=0
failed_cases=()

while IFS= read -r case_path; do
    name=$(basename "$case_path" .sh)
    if [[ -n "$filter" && "$name" != "$filter"* ]]; then continue; fi
    printf '\n\033[1m== %s ==\033[0m\n' "$name" >&2
    # Run each case in a subshell so env exports don't leak between cases.
    if bash "$case_path"; then
        total_pass=$((total_pass+1))
    else
        total_fail=$((total_fail+1))
        failed_cases+=("$name")
    fi
    total_run=$((total_run+1))
done < <(list_cases)

printf '\n\033[1m== summary ==\033[0m\n' >&2
printf 'cases: %d run, %d ok, %d failed\n' "$total_run" "$total_pass" "$total_fail" >&2
if (( total_fail > 0 )); then
    for f in "${failed_cases[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi
