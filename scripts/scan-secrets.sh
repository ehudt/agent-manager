#!/usr/bin/env bash
# scan-secrets.sh - lightweight secret scanner for repo and git history

set -euo pipefail

scan_history=false

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--history] [--help]

Options:
  --history   Scan all git history, not only current tracked files
  -h, --help  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --history)
            scan_history=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

patterns=(
    'AKIA[0-9A-Z]{16}'
    'ASIA[0-9A-Z]{16}'
    'ghp_[A-Za-z0-9]{36}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'AIza[0-9A-Za-z_-]{35}'
    'sk-[A-Za-z0-9]{20,}'
    '-----BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY-----'
)

regex="$(IFS='|'; echo "${patterns[*]}")"

if $scan_history; then
    commits_file=$(mktemp)
    trap 'rm -f "$commits_file"' EXIT
    git rev-list --all > "$commits_file"

    echo "Scanning git history..."
    if git grep -n -I -E "$regex" $(cat "$commits_file") >/tmp/am_secret_hits.txt; then
        echo "Potential secrets found in history:" >&2
        cat /tmp/am_secret_hits.txt >&2
        exit 1
    fi
    echo "No known secret patterns found in history"
else
    echo "Scanning tracked files..."
    files=$(git ls-files)
    if [[ -z "$files" ]]; then
        echo "No tracked files"
        exit 0
    fi

    if rg -n --hidden -S -e "$regex" $files >/tmp/am_secret_hits.txt; then
        echo "Potential secrets found in tracked files:" >&2
        cat /tmp/am_secret_hits.txt >&2
        exit 1
    fi
    echo "No known secret patterns found in tracked files"
fi
