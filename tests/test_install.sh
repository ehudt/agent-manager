#!/usr/bin/env bash
# tests/test_install.sh - Tests for install

# Run scripts/install.sh with every host-config hook/extension target
# redirected under the given temp root. Installer tests MUST go through
# this (or pass the same overrides explicitly): a bare invocation writes
# into the real ~/.claude/settings.json, ~/.codex/*, ~/.cursor/* and
# ~/.pi/agent/extensions of whoever runs the suite (observed live: each
# test run silently rewrote the host's hook files).
_run_installer_isolated() {
    local temp_root="$1"; shift
    CLAUDE_SETTINGS="$temp_root/claude-settings.json" \
    CODEX_HOME="$temp_root/codex" \
    CURSOR_CONFIG_DIR="$temp_root/cursor" \
    PI_EXT_DIR="$temp_root/pi-extensions" \
        "$PROJECT_DIR/scripts/install.sh" "$@"
}

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

    _run_installer_isolated "$temp_root" \
        --prefix "$prefix" --shell-rc "$shell_rc" --tmux-conf "$tmux_conf" -y >/dev/null

    # Isolation canary: hook installs must land under the temp root, not in
    # the runner's real home. Fails if an env override name drifts.
    assert_cmd_succeeds "installer: Claude hooks written to temp settings" \
        test -f "$temp_root/claude-settings.json"

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

    printf '\n\n' | _run_installer_isolated "$temp_root" \
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

    # Test install --help
    local install_help
    install_help=$("$PROJECT_DIR/am" install --help 2>&1)
    assert_contains "$install_help" "First-time setup" "am install --help: shows description"

    # Test version comparison (production helper extracted from am)
    eval "$(sed -n '/^_install_version_ge()/,/^}/p' "$PROJECT_DIR/am")"
    assert_cmd_succeeds "_install_version_ge: 3.4 >= 3.0" _install_version_ge "3.0" "3.4"
    assert_cmd_fails "_install_version_ge: 0.35 < 0.40" _install_version_ge "0.40" "0.35"
    assert_cmd_succeeds "_install_version_ge: 0.40 == 0.40" _install_version_ge "0.40" "0.40"

    # Test full install in temp environment
    local temp_root
    temp_root=$(mktemp -d)
    local temp_am_dir="$temp_root/am-dir"
    local temp_skills_dir="$temp_root/claude-skills"
    local temp_cursor_skills_dir="$temp_root/cursor-skills"
    local temp_prefix="$temp_root/bin"
    local temp_shell_rc="$temp_root/.zshrc"
    local fake_bin="$temp_root/fakebin"
    # Hook/extension install targets. Every one of these MUST be overridden
    # when invoking `am install`, or the test writes into the real
    # ~/.claude/settings.json, ~/.codex/*, ~/.cursor/* and
    # ~/.pi/agent/extensions of whoever runs the suite (observed live: each
    # test run silently rewrote the host's Cursor hooks).
    local temp_claude_settings="$temp_root/claude-settings.json"
    local temp_codex_home="$temp_root/codex"
    local temp_cursor_config="$temp_root/cursor"
    local temp_pi_ext="$temp_root/pi-extensions"
    touch "$temp_shell_rc"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/go" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    version)
        echo "go version go1.19.4 test/amd64"
        ;;
    build)
        shift
        out=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o)
                    out="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        mkdir -p "$(dirname "$out")"
        # Never clobber a real prebuilt binary: parallel test workers exec
        # bin/am-list-internal / bin/am-browse and there is no bash fallback.
        if [[ ! -s "$out" ]]; then
            : > "$out"
            chmod +x "$out"
        fi
        ;;
    *)
        echo "unexpected go invocation: $*" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "$fake_bin/go"

    # Stub the Cursor Agent and pi CLIs so the `command -v agent` /
    # `command -v pi` gates in install.sh pass on any machine and the
    # cursor/pi install paths are always exercised (against temp targets).
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/agent"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/pi"
    chmod +x "$fake_bin/agent" "$fake_bin/pi"

    # Snapshot any pre-existing Go binaries so the fake-go stub created by
    # `am install` doesn't clobber a real build for the duration of a
    # parallel test run. Other workers exec these binaries from
    # $PROJECT_DIR/bin and a 0-byte stub there would produce empty output.
    local _saved_bin="$temp_root/saved-bin"
    mkdir -p "$_saved_bin"
    local _bin
    for _bin in am-list-internal am-browse am-core am-review; do
        if [[ -f "$PROJECT_DIR/bin/$_bin" ]]; then
            cp -p "$PROJECT_DIR/bin/$_bin" "$_saved_bin/$_bin"
        fi
    done

    # Seed a legacy symlink from the skill's pre-rename name (am-orchestration
    # -> agent-manager-dispatch). After the rename it dangles; install must
    # remove it, not leave a broken skill behind.
    mkdir -p "$temp_skills_dir"
    ln -s "$PROJECT_DIR/skills/am-orchestration" "$temp_skills_dir/am-orchestration"

    local install_output
    install_output=$(PATH="$fake_bin:$PATH" \
        AM_DIR="$temp_am_dir" AM_CONFIG="$temp_am_dir/config.json" \
        AM_CLAUDE_SKILLS_DIR="$temp_skills_dir" \
        AM_CURSOR_SKILLS_DIR="$temp_cursor_skills_dir" \
        CLAUDE_SETTINGS="$temp_claude_settings" \
        CODEX_HOME="$temp_codex_home" \
        CURSOR_CONFIG_DIR="$temp_cursor_config" \
        PI_EXT_DIR="$temp_pi_ext" \
        "$PROJECT_DIR/am" install \
        --prefix "$temp_prefix" --shell-rc "$temp_shell_rc" --no-tmux -y 2>&1)

    # Verify config was created
    assert_cmd_succeeds "install: config file created" test -f "$temp_am_dir/config.json"

    # Verify skills symlink was created
    assert_cmd_succeeds "install: skills symlink created" test -L "$temp_skills_dir/agent-manager-dispatch"
    local link_target
    link_target=$(readlink "$temp_skills_dir/agent-manager-dispatch")
    assert_eq "$PROJECT_DIR/skills/agent-manager-dispatch" "$link_target" "install: skills symlink target correct"
    assert_cmd_succeeds "install: Cursor skills symlink created" \
        test -L "$temp_cursor_skills_dir/agent-manager-dispatch"
    assert_eq "$PROJECT_DIR/skills/agent-manager-dispatch" \
        "$(readlink "$temp_cursor_skills_dir/agent-manager-dispatch")" \
        "install: Cursor skills symlink target correct"
    assert_cmd_fails "install: legacy am-orchestration symlink removed" \
        test -e "$temp_skills_dir/am-orchestration" -o -L "$temp_skills_dir/am-orchestration"

    # Verify hook/extension installs landed in the overridden temp targets.
    # These are the isolation canaries: if an env override is renamed or
    # dropped, the install lands in the real home dir and these fail.
    assert_cmd_succeeds "install: Claude hooks written to temp settings" \
        test -f "$temp_claude_settings"
    assert_cmd_succeeds "install: Codex hooks written to temp codex home" \
        test -f "$temp_codex_home/hooks.json"
    assert_cmd_succeeds "install: Cursor hooks.json written to temp cursor dir" \
        test -f "$temp_cursor_config/hooks.json"
    assert_cmd_succeeds "install: Cursor hook helper copied to temp cursor dir" \
        test -f "$temp_cursor_config/hooks/am-state-hook.sh"
    assert_cmd_succeeds "install: pi extension symlinked into temp ext dir" \
        test -L "$temp_pi_ext/am-state.ts"

    # Verify am binary was installed
    assert_cmd_succeeds "install: am binary installed" test -e "$temp_prefix/am"

    # Verify dependency check output
    assert_contains "$install_output" "tmux" "install: checks tmux"
    assert_contains "$install_output" "fzf" "install: checks fzf"
    assert_contains "$install_output" "jq" "install: checks jq"
    assert_contains "$install_output" "git" "install: checks git"
    assert_contains "$install_output" "Go 1.19.4 ... OK (>= 1.19)" \
        "install: Go 1.19 is accepted for helper builds"
    assert_contains "$install_output" "Built bin/am-list-internal" \
        "install: builds am-list-internal with Go 1.19"
    assert_contains "$install_output" "Built bin/am-browse" \
        "install: builds am-browse with Go 1.19"
    assert_contains "$install_output" "Built bin/am-core" \
        "install: builds am-core with Go 1.19"
    assert_not_contains "$install_output" "unexpected go invocation" \
        "install: fake Go handled all invocations"

    # Verify summary output
    assert_contains "$install_output" "Setup complete" "install: shows completion message"

    # Verify idempotent (run again)
    local install_output2
    install_output2=$(PATH="$fake_bin:$PATH" \
        AM_DIR="$temp_am_dir" AM_CONFIG="$temp_am_dir/config.json" \
        AM_CLAUDE_SKILLS_DIR="$temp_skills_dir" \
        AM_CURSOR_SKILLS_DIR="$temp_cursor_skills_dir" \
        CLAUDE_SETTINGS="$temp_claude_settings" \
        CODEX_HOME="$temp_codex_home" \
        CURSOR_CONFIG_DIR="$temp_cursor_config" \
        PI_EXT_DIR="$temp_pi_ext" \
        "$PROJECT_DIR/am" install \
        --prefix "$temp_prefix" --shell-rc "$temp_shell_rc" --no-tmux -y 2>&1)
    assert_contains "$install_output2" "already exists" "install: skills symlink idempotent"

    # Restore the real binaries that the fake-go stub clobbered, or remove the
    # stubs so other workers fall back to the bash path instead of exec'ing a
    # 0-byte file. Never write over the live file in place: on macOS that
    # invalidates the code signature of the mapped binary and every am-core /
    # am-browse another worker is running at that instant dies with SIGKILL
    # (seen as rc=137 and "Taskgated Invalid Signature" crash reports). The
    # stub leaves a non-empty binary alone, so usually nothing changed; when
    # it did, copy to a sibling temp file and rename it into place.
    for _bin in am-list-internal am-browse am-core am-review; do
        if [[ -f "$_saved_bin/$_bin" ]]; then
            cmp -s "$_saved_bin/$_bin" "$PROJECT_DIR/bin/$_bin" 2>/dev/null && continue
            cp -p "$_saved_bin/$_bin" "$PROJECT_DIR/bin/.$_bin.restore.$$" \
                && mv -f "$PROJECT_DIR/bin/.$_bin.restore.$$" "$PROJECT_DIR/bin/$_bin"
        else
            rm -f "$PROJECT_DIR/bin/$_bin"
        fi
    done

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

_ensure_install_lib_sourced() {
    if [[ "$(type -t _install_claude_hooks)" != "function" || "$(type -t _install_codex_hooks)" != "function" || "$(type -t _install_cursor_hooks)" != "function" || "$(type -t _install_pi_extension)" != "function" ]]; then
        # Extract just the hook installer functions from install.sh (can't
        # source the whole file because it runs install logic at top level).
        # They report progress through install.sh's `log`, which sits outside
        # the extracted range: give them a silent one. Without it Linux fails
        # with "log: command not found" (macOS was masked by /usr/bin/log).
        [[ "$(type -t log)" == function ]] || log() { :; }
        eval "$(awk '/^_install_claude_hooks\(\)/ {p=1} /^while \[\[/ {p=0} p {print}' "$PROJECT_DIR/scripts/install.sh")"
    fi
}

test_install_cursor_hooks_preserves_existing_and_is_idempotent() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local hooks="$tmp_dir/hooks.json"
    local hooks_dir="$tmp_dir/hooks"
    cat > "$hooks" <<'JSON'
{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"echo existing"}]}}
JSON

    _install_cursor_hooks "$hooks" "$hooks_dir" "$PROJECT_DIR/lib/hooks/state-hook.sh"
    _install_cursor_hooks "$hooks" "$hooks_dir" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    assert_eq "1" "$(jq '.version' "$hooks")" "Cursor hooks: schema version retained"
    assert_eq "2" "$(jq '.hooks.beforeSubmitPrompt | length' "$hooks")" \
        "Cursor hooks: existing prompt hook preserved and am hook added once"
    assert_eq "echo existing" "$(jq -r '.hooks.beforeSubmitPrompt[0].command' "$hooks")" \
        "Cursor hooks: existing hook unchanged"
    assert_eq "true" "$(jq '[.hooks[][] | select((.command // "") | contains("# am-state-hook"))] | length == 8' "$hooks")" \
        "Cursor hooks: eight lifecycle hooks installed idempotently"
    assert_cmd_succeeds "Cursor hooks: stable helper copies state hook" \
        cmp -s "$PROJECT_DIR/lib/hooks/state-hook.sh" "$hooks_dir/am-state-hook.sh"

    rm -rf "$tmp_dir"
}

test_enable_cursor_status_indicators() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local config="$tmp_dir/cli-config.json"
    cat > "$config" <<'JSON'
{"version":1,"editor":{"vimMode":true},"permissions":{"allow":["Shell(git status)"],"deny":[]},"notifications":false}
JSON

    _enable_cursor_status_indicators "$config"
    _enable_cursor_status_indicators "$config"

    assert_eq "true" "$(jq -r '.display.showStatusIndicators' "$config")" \
        "Cursor config: status indicators enabled"
    assert_eq "true" "$(jq -r '.editor.vimMode' "$config")" \
        "Cursor config: unrelated editor setting preserved"
    assert_eq "Shell(git status)" "$(jq -r '.permissions.allow[0]' "$config")" \
        "Cursor config: unrelated permissions preserved"

    rm -rf "$tmp_dir"
}

test_install_hooks_into_empty_settings() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/empty-settings.json"
    echo '{}' > "$settings"

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$settings")
    assert_eq "1" "$stop_count" "Stop hook installed"

    local notif_count
    notif_count=$(jq '.hooks.Notification | length' "$settings")
    assert_eq "3" "$notif_count" "3 Notification hooks installed"

    local upsub_count
    upsub_count=$(jq '.hooks.UserPromptSubmit | length' "$settings")
    assert_eq "1" "$upsub_count" "UserPromptSubmit hook installed"

    local post_count
    post_count=$(jq '.hooks.PostToolUse | length' "$settings")
    assert_eq "1" "$post_count" "PostToolUse hook installed"
}

test_install_hooks_preserves_existing() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/existing-settings.json"
    cat > "$settings" <<'JSON'
{"hooks":{"PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"echo existing"}]}],"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"echo user-hook"}]}]}}
JSON

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    # Existing hooks preserved
    local precompact_count
    precompact_count=$(jq '.hooks.PreCompact | length' "$settings")
    assert_eq "1" "$precompact_count" "existing PreCompact hook preserved"

    # Existing UserPromptSubmit hook preserved + ours added
    local upsub_count
    upsub_count=$(jq '.hooks.UserPromptSubmit | length' "$settings")
    assert_eq "2" "$upsub_count" "existing + new UserPromptSubmit hooks"

    # Verify the existing one is first (untouched)
    local existing_cmd
    existing_cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
    assert_eq "echo user-hook" "$existing_cmd" "existing UserPromptSubmit hook unchanged"
}

test_install_hooks_idempotent() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/idem-settings.json"
    echo '{}' > "$settings"

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"
    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$settings")
    assert_eq "1" "$stop_count" "idempotent: Stop hook not duplicated"

    local notif_count
    notif_count=$(jq '.hooks.Notification | length' "$settings")
    assert_eq "3" "$notif_count" "idempotent: Notification hooks not duplicated"
}

test_install_codex_hooks_into_empty_file() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local hooks="$tmp_dir/hooks.json"
    echo '{}' > "$hooks"

    _install_codex_hooks "$hooks" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local perm_count upsub_count pre_count post_count stop_count
    perm_count=$(jq '.hooks.PermissionRequest | length' "$hooks")
    upsub_count=$(jq '.hooks.UserPromptSubmit | length' "$hooks")
    pre_count=$(jq '.hooks.PreToolUse | length' "$hooks")
    post_count=$(jq '.hooks.PostToolUse | length' "$hooks")
    stop_count=$(jq '.hooks.Stop | length' "$hooks")

    assert_eq "1" "$perm_count" "Codex PermissionRequest hook installed"
    assert_eq "1" "$upsub_count" "Codex UserPromptSubmit hook installed"
    assert_eq "1" "$pre_count" "Codex PreToolUse hook installed"
    assert_eq "1" "$post_count" "Codex PostToolUse hook installed"
    assert_eq "1" "$stop_count" "Codex Stop hook installed"

    local timeout
    timeout=$(jq '.hooks.PermissionRequest[0].hooks[0].timeout' "$hooks")
    assert_eq "5" "$timeout" "Codex hooks use seconds timeout"

    rm -rf "$tmp_dir"
}

test_install_codex_hooks_preserves_existing_and_idempotent() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local hooks="$tmp_dir/hooks.json"
    cat > "$hooks" <<'JSON'
{"hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo existing"}]}]}}
JSON

    _install_codex_hooks "$hooks" "$PROJECT_DIR/lib/hooks/state-hook.sh"
    _install_codex_hooks "$hooks" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local perm_count existing_cmd am_count
    perm_count=$(jq '.hooks.PermissionRequest | length' "$hooks")
    assert_eq "2" "$perm_count" "Codex existing + am PermissionRequest hooks"

    existing_cmd=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$hooks")
    assert_eq "echo existing" "$existing_cmd" "Codex existing hook unchanged"

    am_count=$(jq '[.hooks[][] | select((.hooks // []) | any((.command // "") | contains("# am-state-hook")))] | length' "$hooks")
    assert_eq "5" "$am_count" "Codex am hooks are idempotent"

    rm -rf "$tmp_dir"
}

test_enable_codex_hooks_feature_new_file() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local cfg="$tmp_dir/config.toml"

    _enable_codex_hooks_feature "$cfg"

    assert_cmd_succeeds "codex feature: [features] section present" \
        grep -q '^\[features\]' "$cfg"
    assert_cmd_succeeds "codex feature: hooks = true present" \
        grep -q '^hooks[[:space:]]*=[[:space:]]*true' "$cfg"

    local deprecated_count
    deprecated_count=$(grep -c '^codex_hooks[[:space:]]*=' "$cfg" || true)
    assert_eq "0" "$deprecated_count" "codex feature: deprecated codex_hooks line absent"

    rm -rf "$tmp_dir"
}

test_enable_codex_hooks_feature_existing_section() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local cfg="$tmp_dir/config.toml"
    cat > "$cfg" <<'TOML'
[model]
provider = "openai"

[features]
other_flag = "keep"
TOML

    _enable_codex_hooks_feature "$cfg"

    local other_kept
    other_kept=$(grep -c '^other_flag[[:space:]]*=[[:space:]]*"keep"' "$cfg" || true)
    assert_eq "1" "$other_kept" "codex feature: existing keys preserved"

    local hooks_count
    hooks_count=$(grep -c '^hooks[[:space:]]*=[[:space:]]*true' "$cfg" || true)
    assert_eq "1" "$hooks_count" "codex feature: hooks = true added under [features]"

    local model_kept
    model_kept=$(grep -c '^\[model\]' "$cfg" || true)
    assert_eq "1" "$model_kept" "codex feature: other sections preserved"

    rm -rf "$tmp_dir"
}

test_enable_codex_hooks_feature_idempotent() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local cfg="$tmp_dir/config.toml"

    _enable_codex_hooks_feature "$cfg"
    _enable_codex_hooks_feature "$cfg"
    _enable_codex_hooks_feature "$cfg"

    local features_count hooks_count deprecated_count
    features_count=$(grep -c '^\[features\]' "$cfg" || true)
    hooks_count=$(grep -c '^hooks[[:space:]]*=' "$cfg" || true)
    deprecated_count=$(grep -c '^codex_hooks[[:space:]]*=' "$cfg" || true)
    assert_eq "1" "$features_count" "codex feature: idempotent — no duplicate [features]"
    assert_eq "1" "$hooks_count" "codex feature: idempotent - no duplicate hooks line"
    assert_eq "0" "$deprecated_count" "codex feature: idempotent - no deprecated codex_hooks line"

    rm -rf "$tmp_dir"
}

test_enable_codex_hooks_feature_replaces_false() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local cfg="$tmp_dir/config.toml"
    cat > "$cfg" <<'TOML'
[features]
codex_hooks = false
TOML

    _enable_codex_hooks_feature "$cfg"

    assert_cmd_succeeds "codex feature: deprecated false -> hooks true upgrade" \
        grep -Eq '^hooks[[:space:]]*=[[:space:]]*true' "$cfg"

    local deprecated_count
    deprecated_count=$(grep -c '^codex_hooks[[:space:]]*=' "$cfg" || true)
    assert_eq "0" "$deprecated_count" "codex feature: deprecated codex_hooks removed"

    rm -rf "$tmp_dir"
}

test_install_pi_extension() {
    _ensure_install_lib_sourced

    # --- _install_pi_extension ---
    local pi_tmp pi_ext_dir
    pi_tmp=$(mktemp -d)
    pi_ext_dir="$pi_tmp/extensions"
    _install_pi_extension "$pi_ext_dir" "$PROJECT_DIR/lib/hooks/am-state.ts"
    assert_cmd_succeeds "_install_pi_extension: symlink created" test -L "$pi_ext_dir/am-state.ts"
    assert_eq "$PROJECT_DIR/lib/hooks/am-state.ts" "$(readlink "$pi_ext_dir/am-state.ts")" \
        "_install_pi_extension: symlink target"
    # idempotent re-run
    _install_pi_extension "$pi_ext_dir" "$PROJECT_DIR/lib/hooks/am-state.ts"
    assert_cmd_succeeds "_install_pi_extension: idempotent" test -L "$pi_ext_dir/am-state.ts"
    assert_eq "$PROJECT_DIR/lib/hooks/am-state.ts" "$(readlink "$pi_ext_dir/am-state.ts")" \
        "_install_pi_extension: idempotent re-run keeps the target"
    rm -rf "$pi_tmp"
}

# Stale-install detection: `am install --refresh` links skills, regenerates
# the tmux config and writes a fingerprint stamp; the browser calls the same
# path when the stamp no longer matches the checkout.
test_install_refresh_stamp() {
    $SUMMARY_MODE || echo "=== Testing am install --refresh / stamp ==="

    local temp_root
    temp_root=$(mktemp -d)
    local am_dir="$temp_root/am-dir" claude_skills="$temp_root/claude-skills" cursor_skills="$temp_root/cursor-skills"
    mkdir -p "$am_dir"
    local cursor_hooks="$temp_root/cursor-hooks"
    local env_common=(AM_DIR="$am_dir" AM_CLAUDE_SKILLS_DIR="$claude_skills" AM_CURSOR_SKILLS_DIR="$cursor_skills" AM_CURSOR_HOOKS_DIR="$cursor_hooks" PATH="$temp_root/nogo:$PATH")
    mkdir -p "$temp_root/nogo"

    local out rc=0
    out=$(env "${env_common[@]}" "$PROJECT_DIR/am" install --refresh 2>&1) || rc=$?
    assert_eq "0" "$rc" "install --refresh: exits 0"
    assert_contains "$out" "install refreshed" "install --refresh: prints a summary line"
    assert_cmd_succeeds "install --refresh: writes the stamp" test -s "$am_dir/.install_stamp"
    assert_cmd_succeeds "install --refresh: links the dispatch skill for Claude" \
        test -L "$claude_skills/agent-manager-dispatch"
    assert_cmd_succeeds "install --refresh: links the peek skill for Cursor" test -L "$cursor_skills/am-peek"
    assert_cmd_succeeds "install --refresh: generates the tmux config" test -s "$am_dir/tmux.conf"

    local stamp1 stamp2
    stamp1=$(cat "$am_dir/.install_stamp")
    assert_contains "$stamp1" "$("$PROJECT_DIR/am" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
        "install stamp: starts with the version"
    env "${env_common[@]}" "$PROJECT_DIR/am" install --refresh >/dev/null 2>&1
    stamp2=$(cat "$am_dir/.install_stamp")
    assert_eq "$stamp1" "$stamp2" "install stamp: deterministic for an unchanged checkout"

    # A stale stamp is detected and rewritten by the browser-side check
    eval "$(sed -n '/^_install_inputs()/,/^}/p; /^_install_fingerprint()/,/^}/p; /^_install_is_stale()/,/^}/p' "$PROJECT_DIR/am")"
    source "$LIB_DIR/utils.sh"
    local AM_SCRIPT_DIR="$PROJECT_DIR" AM_VERSION
    AM_VERSION=$(grep -E '^AM_VERSION=' "$PROJECT_DIR/am" | head -1 | cut -d'"' -f2)
    AM_DIR="$am_dir"
    assert_eq "false" "$(_install_is_stale && echo true || echo false)" "install stamp: matches right after refresh"
    printf 'stale\n' > "$am_dir/.install_stamp"
    assert_eq "true" "$(_install_is_stale && echo true || echo false)" "install stamp: a different stamp is stale"
    assert_eq "$stamp1" "$(_install_fingerprint)" "install fingerprint: recomputes the same value"

    # Cursor hook copy: a stale managed copy is rewritten, a foreign file is left alone
    mkdir -p "$cursor_hooks"
    cp "$PROJECT_DIR/lib/hooks/state-hook.sh" "$cursor_hooks/am-state-hook.sh"
    printf '\n# drifted\n' >> "$cursor_hooks/am-state-hook.sh"
    out=$(env "${env_common[@]}" "$PROJECT_DIR/am" install --refresh 2>&1)
    assert_contains "$out" "cursor hook copy" "install --refresh: reports the Cursor hook copy refresh"
    assert_cmd_succeeds "install --refresh: Cursor hook copy matches the source again" \
        cmp -s "$cursor_hooks/am-state-hook.sh" "$PROJECT_DIR/lib/hooks/state-hook.sh"
    out=$(env "${env_common[@]}" "$PROJECT_DIR/am" install --refresh 2>&1)
    assert_not_contains "$out" "cursor hook copy" "install --refresh: identical copy is not rewritten"
    printf '#!/usr/bin/env bash\necho mine\n' > "$cursor_hooks/am-state-hook.sh"
    env "${env_common[@]}" "$PROJECT_DIR/am" install --refresh >/dev/null 2>&1
    assert_eq "echo mine" "$(tail -1 "$cursor_hooks/am-state-hook.sh")" "install --refresh: unmanaged helper is left alone"

    rm -rf "$temp_root"
}

run_install_tests() {
    _run_test test_install_refresh_stamp
    _run_test test_installer_replaces_managed_blocks
    _run_test test_installer_defaults_prompts_to_yes
    _run_test test_install
    _run_test test_install_hooks_into_empty_settings
    _run_test test_install_hooks_preserves_existing
    _run_test test_install_hooks_idempotent
    _run_test test_install_cursor_hooks_preserves_existing_and_is_idempotent
    _run_test test_enable_cursor_status_indicators
    _run_test test_install_codex_hooks_into_empty_file
    _run_test test_install_codex_hooks_preserves_existing_and_idempotent
    _run_test test_enable_codex_hooks_feature_new_file
    _run_test test_enable_codex_hooks_feature_existing_section
    _run_test test_enable_codex_hooks_feature_idempotent
    _run_test test_enable_codex_hooks_feature_replaces_false
    _run_test test_install_pi_extension
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_install_tests
    test_report
fi
