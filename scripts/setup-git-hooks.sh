#!/usr/bin/env bash
# setup-git-hooks.sh - configure repo-local git hooks path

set -euo pipefail

git config core.hooksPath .githooks
echo 'Configured git hooks path to .githooks'
echo 'Verify: git config --get core.hooksPath'
