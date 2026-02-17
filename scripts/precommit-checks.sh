#!/usr/bin/env bash
# precommit-checks.sh - fast local checks for commits

set -euo pipefail

printf 'Running bash syntax checks...\n'
bash -n am lib/*.sh bin/* scripts/*.sh tests/test_all.sh

printf 'Running secret scan (tracked files)...\n'
./scripts/scan-secrets.sh

printf 'Pre-commit checks passed\n'
