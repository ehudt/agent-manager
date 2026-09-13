#!/usr/bin/env bash
# check-changelog.sh - fail when AM_VERSION has no CHANGELOG.md entry.
#
# AGENTS.md ties every version bump to the commit that earns it; this
# makes the changelog part of that commit, so it cannot stop at the
# release it was written for. Run by scripts/check-docs.sh (CI).
#
# Usage: check-changelog.sh [am_path] [changelog_path]
# An entry is a heading of the form "## [<version>]" or "## <version>",
# followed by end of line, whitespace, or a dash.

set -euo pipefail

am_path="${1:-$(cd "$(dirname "$0")/.." && pwd)/am}"
log_path="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"

if [[ ! -f "$log_path" ]]; then
    printf 'check-changelog: %s not found\n' "$log_path" >&2
    exit 1
fi

version=$(sed -n 's/^AM_VERSION="\([^"]*\)"/\1/p' "$am_path" | head -1)
if [[ -z "$version" ]]; then
    printf 'check-changelog: no AM_VERSION in %s\n' "$am_path" >&2
    exit 1
fi

escaped=$(printf '%s' "$version" | sed 's/\./\\./g')
if grep -Eq "^## \[?${escaped}\]?([[:space:]]|$|[[:space:]]*[-—])" "$log_path"; then
    printf 'check-changelog: %s has an entry for %s\n' "$(basename "$log_path")" "$version"
    exit 0
fi

printf 'check-changelog: AM_VERSION is %s but %s has no "## [%s]" entry.\n' \
    "$version" "$(basename "$log_path")" "$version" >&2
printf 'Add the entry in the same commit as the bump (see AGENTS.md > Versioning).\n' >&2
exit 1
