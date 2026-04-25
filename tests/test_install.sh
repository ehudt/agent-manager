#!/usr/bin/env bash
# tests/test_install.sh - Tests for install

test_installer_replaces_managed_blocks() {
    $SUMMARY_MODE || echo "=== Testing installer block replacement ==="

    local temp_root prefix shell_rc tmux_conf shell_contents tmux_contents
    temp_root=$(mktemp -d)
    prefix="$temp_root/bin"
    shell_rc="$temp_root/.zshrc"
    tmux_conf="$temp_root/.tmux.conf"

    cat > "$shell_rc" <<'EOF'
export PATH="/usr/bin:$PATH"
# >>> agent-manager >>>
export PATH="/old/prefix:$PATH"
# <<< agent-manager <<<
EOF

    cat > "$tmux_conf" <<'EOF'
set -g mouse on
# >>> agent-manager >>>
bind x kill-pane
# <<< agent-manager <<<
EOF

    "$PROJECT_DIR/scripts/install.sh" --prefix "$prefix" --shell-rc "$shell_rc" --tmux-conf "$tmux_conf" -y >/dev/null

    shell_contents=$(cat "$shell_rc")
    # shellcheck disable=SC2034  # tmux_contents used by assertion helpers
    tmux_contents=$(cat "$tmux_conf")

    assert_contains "$shell_contents" "export PATH=\"$prefix:\$PATH\"" \
        "installer: shell block updated to current prefix"
    assert_eq "1" "$(grep -Fc '# >>> agent-manager >>>' "$shell_rc")" \
        "installer: shell managed block not duplicated"
    assert_cmd_fails "installer: old shell block removed" grep -Fq '/old/prefix' "$shell_rc"
    assert_cmd_fails "installer: old tmux block removed" grep -Fq 'bind x kill-pane' "$tmux_conf"
    assert_cmd_fails "installer: tmux managed block removed" grep -Fq '# >>> agent-manager >>>' "$tmux_conf"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_installer_defaults_prompts_to_yes() {
    $SUMMARY_MODE || echo "=== Testing installer default yes prompts ==="

    local temp_root prefix shell_rc tmux_conf shell_contents
    temp_root=$(mktemp -d)
    prefix="$temp_root/bin"
    shell_rc="$temp_root/.zshrc"
    tmux_conf="$temp_root/.tmux.conf"

    cat > "$shell_rc" <<'EOF'
export PATH="/usr/bin:$PATH"
EOF

    cat > "$tmux_conf" <<'EOF'
set -g mouse on
# >>> agent-manager >>>
bind x kill-pane
# <<< agent-manager <<<
EOF

    printf '\n\n' | "$PROJECT_DIR/scripts/install.sh" \
        --prefix "$prefix" --shell-rc "$shell_rc" --tmux-conf "$tmux_conf" >/dev/null

    shell_contents=$(cat "$shell_rc")
    assert_contains "$shell_contents" "export PATH=\"$prefix:\$PATH\"" \
        "installer: Enter accepts shell rc update by default"
    assert_cmd_fails "installer: Enter accepts tmux cleanup by default" \
        grep -Fq '# >>> agent-manager >>>' "$tmux_conf"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_install() {
    $SUMMARY_MODE || echo "=== Testing am install ==="

    # Test help mentions install
    local help_output
    help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "install" "am help: mentions install command"

    # Test install --help
    local install_help
    install_help=$("$PROJECT_DIR/am" install --help 2>&1)
    assert_contains "$install_help" "First-time setup" "am install --help: shows description"
    assert_contains "$install_help" "--prefix" "am install --help: shows --prefix option"

    # Test version comparison via sort -V (same logic as _install_version_ge)
    local oldest
    oldest=$(printf '3.0\n3.4' | sort -V | head -1)
    assert_eq "3.0" "$oldest" "version_ge: 3.4 >= 3.0"
    oldest=$(printf '0.40\n0.35' | sort -V | head -1)
    assert_eq "0.35" "$oldest" "version_ge: 0.35 < 0.40"
    oldest=$(printf '0.40\n0.40' | sort -V | head -1)
    assert_eq "0.40" "$oldest" "version_ge: 0.40 == 0.40"

    # Test full install in temp environment
    local temp_root
    temp_root=$(mktemp -d)
    local temp_am_dir="$temp_root/am-dir"
    local temp_skills_dir="$temp_root/claude-skills"
    local temp_prefix="$temp_root/bin"
    local temp_shell_rc="$temp_root/.zshrc"
    local fake_bin="$temp_root/fakebin"
    touch "$temp_shell_rc"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/go" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
    echo "go version go1.19.4 test/amd64"
    exit 0
fi
echo "unexpected go invocation: $*" >&2
exit 99
EOF
    chmod +x "$fake_bin/go"

    local install_output
    install_output=$(PATH="$fake_bin:$PATH" \
        AM_DIR="$temp_am_dir" AM_CONFIG="$temp_am_dir/config.json" \
        AM_CLAUDE_SKILLS_DIR="$temp_skills_dir" \
        "$PROJECT_DIR/am" install \
        --prefix "$temp_prefix" --shell-rc "$temp_shell_rc" --no-tmux -y 2>&1)

    # Verify config was created
    assert_cmd_succeeds "install: config file created" test -f "$temp_am_dir/config.json"

    # Verify skills symlink was created
    assert_cmd_succeeds "install: skills symlink created" test -L "$temp_skills_dir/am-orchestration"
    local link_target
    link_target=$(readlink "$temp_skills_dir/am-orchestration")
    assert_eq "$PROJECT_DIR/skills/am-orchestration" "$link_target" "install: skills symlink target correct"

    # Verify am binary was installed
    assert_cmd_succeeds "install: am binary installed" test -e "$temp_prefix/am"

    # Verify dependency check output
    assert_contains "$install_output" "tmux" "install: checks tmux"
    assert_contains "$install_output" "fzf" "install: checks fzf"
    assert_contains "$install_output" "jq" "install: checks jq"
    assert_contains "$install_output" "git" "install: checks git"
    assert_contains "$install_output" "Go 1.19.4 ... too old for compiled helpers" \
        "install: skips Go helper build with old Go"
    assert_not_contains "$install_output" "invalid go version" \
        "install: old Go does not parse go.mod"
    assert_not_contains "$install_output" "unexpected go invocation" \
        "install: old Go guard avoids go build"

    # Verify summary output
    assert_contains "$install_output" "Setup complete" "install: shows completion message"

    # Verify idempotent (run again)
    local install_output2
    install_output2=$(PATH="$fake_bin:$PATH" \
        AM_DIR="$temp_am_dir" AM_CONFIG="$temp_am_dir/config.json" \
        AM_CLAUDE_SKILLS_DIR="$temp_skills_dir" \
        "$PROJECT_DIR/am" install \
        --prefix "$temp_prefix" --shell-rc "$temp_shell_rc" --no-tmux -y 2>&1)
    assert_contains "$install_output2" "already exists" "install: skills symlink idempotent"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

run_install_tests() {
    _run_test test_installer_replaces_managed_blocks
    _run_test test_installer_defaults_prompts_to_yes
    _run_test test_install
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_install_tests
    test_report
fi
