#!/usr/bin/env bash
# tests/test_completions.sh - `am completions bash|zsh` and the shell
# functions they print (subcommands, per-command flags, live session names).

# A fake `am` for the completer to call at completion time: session names
# from `list --json`, preset names from `preset list`.
_completions_fake_am() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/am" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "list --json") echo '[{"name":"am-abc123","state":"ready"},{"name":"am-def456","state":"running"}]' ;;
    "preset list") printf 'fix\nreview\n' ;;
    *) exit 1 ;;
esac
FAKE
    chmod +x "$dir/am"
}

# Run the bash completer for one command line; prints COMPREPLY one per line.
_complete_bash() {
    local fake="$1"; shift
    PATH="$fake:$PATH" bash -c '
        source <("'"$PROJECT_DIR"'/am" completions bash)
        COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ))
        _am
        printf "%s\n" "${COMPREPLY[@]}"' _ "$@"
}

test_completions_print() {
    $SUMMARY_MODE || echo "=== Testing am completions output ==="
    local out rc

    out=$("$PROJECT_DIR/am" completions bash)
    assert_contains "$out" "complete -F _am am" "completions bash: registers _am"
    out=$("$PROJECT_DIR/am" completions zsh)
    assert_contains "$out" "compdef _am am" "completions zsh: registers _am"

    rc=0; out=$("$PROJECT_DIR/am" completions fish 2>&1) || rc=$?
    assert_eq "1" "$rc" "completions fish: exits 1"
    assert_contains "$out" "bash|zsh" "completions fish: names the supported shells"
    rc=0; out=$("$PROJECT_DIR/am" completions 2>&1) || rc=$?
    assert_eq "1" "$rc" "completions (no shell): exits 1"

    assert_cmd_succeeds "completions bash: parses" bash -n "$PROJECT_DIR/completions/am.bash"
    if command -v zsh >/dev/null 2>&1; then
        assert_cmd_succeeds "completions zsh: parses" zsh -n "$PROJECT_DIR/completions/am.zsh"
    fi
    $SUMMARY_MODE || echo ""
}

test_completions_bash() {
    $SUMMARY_MODE || echo "=== Testing bash completer ==="
    local fake out
    fake=$(mktemp -d)
    _completions_fake_am "$fake"

    out=$(_complete_bash "$fake" am se)
    assert_contains "$out" "send" "bash: partial subcommand completes"
    assert_not_contains "$out" "kill" "bash: only matching subcommands"

    out=$(_complete_bash "$fake" am "")
    assert_contains "$out" "new" "bash: bare am lists subcommands"
    assert_contains "$out" "uninstall" "bash: uninstall is a subcommand"

    out=$(_complete_bash "$fake" am send "")
    assert_contains "$out" "am-abc123" "bash: send completes live session names"
    assert_contains "$out" "am-def456" "bash: every session offered"
    out=$(_complete_bash "$fake" am send am-d)
    assert_contains "$out" "am-def456" "bash: session prefix filters"
    assert_not_contains "$out" "am-abc123" "bash: non-matching session dropped"

    out=$(_complete_bash "$fake" am send --)
    assert_contains "$out" "--wait" "bash: send flags"
    assert_contains "$out" "--queue" "bash: send flags (queue)"
    out=$(_complete_bash "$fake" am wait "")
    assert_contains "$out" "am-abc123" "bash: wait completes sessions"
    out=$(_complete_bash "$fake" am kill --)
    assert_contains "$out" "--all" "bash: kill flags"

    out=$(_complete_bash "$fake" am new -p "")
    assert_contains "$out" "review" "bash: new -p completes preset names"
    out=$(_complete_bash "$fake" am new -t "")
    assert_contains "$out" "claude" "bash: new -t completes agent types"
    assert_contains "$out" "opencode" "bash: new -t lists every manifest agent"
    out=$(_complete_bash "$fake" am config set "")
    assert_contains "$out" "notify_states" "bash: config set completes keys"
    out=$(_complete_bash "$fake" am completions "")
    assert_contains "$out" "zsh" "bash: completions completes shells"

    rm -rf "$fake"
    $SUMMARY_MODE || echo ""
}

run_completions_tests() {
    _run_test test_completions_print
    _run_test test_completions_bash
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_completions_tests
    test_report
fi
