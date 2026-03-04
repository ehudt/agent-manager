# Form, Yolo/Sandbox Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Decouple yolo and sandbox into independent options, rename "permissive" to "yolo mode", and redesign the new session form for inline editing with Enter-to-submit.

**Architecture:** Three independent changes: (1) config/CLI/launch plumbing for sandbox as separate option, (2) rename permissive→yolo across UI, (3) rewrite fzf_new_session_form using fzf's query/reload/transform-query bindings for inline editing.

**Tech Stack:** bash, fzf (>=0.40), tmux, jq

**Design doc:** `docs/plans/2026-03-04-form-yolo-sandbox-design.md`

---

## Progress

| Task | Status | Commit |
|------|--------|--------|
| 1: Sandbox config plumbing | DONE | f6b3fc3 |
| 2: Decouple sandbox from yolo | DONE | d5be472 |
| 3: --sandbox CLI flag | DONE | f76f4ef |
| 3.5: CLI integration tests | TODO | |
| 4: Rename permissive→yolo | TODO | |
| 5: Sandbox row in form | TODO | |
| 6: Rewrite form (inline editing) | TODO | |
| 7: Update form tests | TODO | |
| 8: Wire sandbox through pipeline | TODO | |
| 9: Final integration/syntax | TODO | |

### Implementation notes from Tasks 1-3

- The plan's `test_sandbox_yolo_independence` uses PATH manipulation to hide docker — this doesn't work because docker lives in `/usr/local/bin` or `/opt/homebrew/bin` which don't contain "docker" in the directory name. **Fix:** mock `am_docker_available()` directly instead: `am_docker_available() { return 1; }` then restore after.
- The existing worktree test (`codex sandbox worktree` around line ~1795) passes `"--yolo"` expecting a container — changed to `"--sandbox"` since yolo no longer creates containers.
- Pre-existing flaky tests: `am peek: captures agent pane`, `am new --detach: stdin prompt reaches agent pane` (timing), `sandbox pytest SSH test` (OSError). These are NOT caused by our changes.

---

### Task 1: Add sandbox config plumbing

**Files:**
- Modify: `lib/config.sh`
- Test: `tests/test_all.sh` (test_config function)

**Step 1: Write the failing tests**

Add to `test_config()` in `tests/test_all.sh`, after the existing sandbox-unrelated assertions (around line 295):

```bash
    # Sandbox config
    assert_eq "false" "$(am_default_sandbox_enabled && echo true || echo false)" "config: default sandbox fallback"

    am_config_set "default_sandbox" "true" "boolean"
    assert_eq "true" "$(am_default_sandbox_enabled && echo true || echo false)" "config: saved default sandbox"

    export AM_DEFAULT_SANDBOX="false"
    assert_eq "false" "$(am_default_sandbox_enabled && echo true || echo false)" "config: env overrides saved sandbox"
    unset AM_DEFAULT_SANDBOX
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | head -80`
Expected: FAIL — `am_default_sandbox_enabled: command not found`

**Step 3: Implement sandbox config**

In `lib/config.sh`:

1. Add `"default_sandbox": false` to the default config JSON in `am_config_init()`.

2. Add `am_default_sandbox_enabled()`:
```bash
am_default_sandbox_enabled() {
    if [[ -n "${AM_DEFAULT_SANDBOX:-}" ]]; then
        am_bool_is_true "${AM_DEFAULT_SANDBOX,,}"
        return $?
    fi

    local configured
    configured=$(am_config_get "default_sandbox")
    am_bool_is_true "${configured,,}"
}
```

3. Add to `am_config_key_alias()`:
```bash
        sandbox|default-sandbox|default_sandbox) echo "default_sandbox" ;;
```

4. Add to `am_config_key_type()`:
```bash
        default_sandbox) echo "boolean" ;;
```

5. Add to `am_config_value_is_valid()`:
```bash
        default_sandbox)
            [[ "$value" =~ ^(1|0|true|false|yes|no|on|off)$ ]]
            ;;
```

6. Add to `am_config_print()`:
```bash
    local default_sandbox_value
    if am_default_sandbox_enabled; then
        default_sandbox_value=true
    else
        default_sandbox_value=false
    fi
```
And add `default_sandbox=$default_sandbox_value` to the output.

7. Add `am_docker_available()`:
```bash
am_docker_available() {
    command -v docker &>/dev/null
}
```

**Step 4: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | grep -E 'sandbox|FAIL|Results'`
Expected: All sandbox config tests PASS

**Step 5: Commit**

```bash
git add lib/config.sh tests/test_all.sh
git commit -m "Add sandbox config plumbing (default_sandbox key, env override, validation)"
```

---

### Task 2: Decouple sandbox from yolo in agent_launch

**Files:**
- Modify: `lib/agents.sh`
- Test: `tests/test_all.sh` (test_agents, test_integration_lifecycle)

**Step 1: Write the failing test**

Add a new test function `test_sandbox_yolo_independence()` in `tests/test_all.sh`:

```bash
test_sandbox_yolo_independence() {
    echo "=== Testing sandbox/yolo independence ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "sandbox/yolo tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Test: yolo without sandbox — no container_name in registry
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "yolo-only" "" --yolo 2>/dev/null)
    assert_not_empty "$session_name" "yolo-only: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "yolo-only: yolo_mode is true"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "yolo-only: no container_name"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # Test: sandbox without docker fails with descriptive error
    local orig_path="$PATH"
    # Hide docker from PATH
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v docker | tr '\n' ':')
    local sandbox_rc=0
    local sandbox_err
    sandbox_err=$(set +u; agent_launch "$test_dir" "claude" "sandbox-no-docker" "" --sandbox 2>&1 >/dev/null) || sandbox_rc=$?
    assert_eq "false" "$(test $sandbox_rc -eq 0 && echo true || echo false)" \
        "sandbox-no-docker: fails when docker unavailable"
    assert_contains "$sandbox_err" "docker" \
        "sandbox-no-docker: error mentions docker"
    PATH="$orig_path"

    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}
```

Register it in the test runner at the bottom of the file.

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | grep -E 'yolo-only|sandbox-no-docker|FAIL'`
Expected: FAIL — `--sandbox` flag not recognized; yolo still creates containers

**Step 3: Modify agent_launch**

In `lib/agents.sh`, update `agent_launch()`:

1. In the argument normalization loop (around line 194), add `--sandbox` handling:
```bash
            --sandbox)
                wants_sandbox=true
                ;;
            --no-sandbox)
                wants_sandbox=false
                ;;
```

2. Initialize `wants_sandbox=false` alongside `wants_yolo=false` (line 192).

3. Replace the existing sandbox block (lines 294-306):
```bash
    # Sandbox mode (independent of yolo)
    if $wants_sandbox; then
        if ! am_docker_available; then
            log_error "Sandbox requires Docker but docker is not available"
            tmux_kill_session "$session_name" 2>/dev/null
            registry_remove "$session_name"
            return 1
        fi
        sandbox_start "$session_name" "$sandbox_directory"
        registry_update "$session_name" "container_name" "$session_name"
        agent_refresh_tmux_status "$session_name"
        local attach_cmd
        attach_cmd=$(sandbox_attach_cmd "$session_name" "$session_directory")
        tmux_send_keys "$session_name:.{bottom}" "$attach_cmd" Enter
        tmux_send_keys "$session_name:.{top}" "$attach_cmd" Enter
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi
```

4. Store sandbox mode in registry (add after yolo_mode line 259):
```bash
    registry_update "$session_name" "sandbox_mode" "$wants_sandbox"
```

**Step 4: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | grep -E 'yolo-only|sandbox-no-docker|FAIL|Results'`
Expected: All PASS

**Step 5: Commit**

```bash
git add lib/agents.sh tests/test_all.sh
git commit -m "Decouple sandbox from yolo in agent_launch"
```

---

### Task 3: Add --sandbox CLI flag and defaults

**Files:**
- Modify: `am`
- Modify: `lib/config.sh`
- Test: `tests/test_all.sh` (test_cli, test_cli_extended)

**Step 1: Write the failing test**

Add to `test_cli()`:
```bash
    assert_contains "$help_output" "--sandbox" "am help: mentions sandbox flag"
```

Add to `test_cli_extended()` (after the config tests around line 1392):
```bash
    # --- Test: am config sandbox ---
    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set sandbox true 2>/dev/null)
    assert_contains "$config_output" "default_sandbox=true" "am config set sandbox: persists default"
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get sandbox 2>/dev/null)
    assert_eq "true" "$config_get" "am config get sandbox: returns saved default"
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | grep -E 'sandbox|FAIL'`
Expected: FAIL on the new assertions

**Step 3: Add --sandbox flag to am CLI**

In `am`, `cmd_new()`:

1. Add `local sandbox_override=""` alongside `yolo_override=""` (line 209).

2. Add flag parsing in the while loop:
```bash
            --sandbox)
                agent_args+=("--sandbox")
                sandbox_override="true"
                shift
                ;;
            --no-sandbox)
                sandbox_override="false"
                shift
                ;;
```

3. After the yolo default application block (lines 323-325), add sandbox defaults:
```bash
        if [[ "$sandbox_override" != "false" ]] && am_maybe_apply_default_sandbox "${agent_args[@]}"; then
            agent_args+=("--sandbox")
        fi
```

4. Add `am_maybe_apply_default_sandbox()` to `lib/config.sh`:
```bash
am_maybe_apply_default_sandbox() {
    if ! am_default_sandbox_enabled; then
        return 1
    fi
    local arg
    for arg in "$@"; do
        case "$arg" in
            --sandbox) return 1 ;;
        esac
    done
    return 0
}
```

5. Add `sandbox` to the config `get` command's case statement in `cmd_config()`:
```bash
                default_sandbox)
                    am_default_sandbox_enabled && echo true || echo false
                    ;;
```

6. Update help text: change `--yolo` description from "Enable permissive mode (mapped per agent, uses sb sandbox)" to "Enable yolo mode (agent permissive flags)". Add `--sandbox` line: "Run session in Docker sandbox container".

**Step 4: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | grep -E 'sandbox|FAIL|Results'`
Expected: All PASS

**Step 5: Commit**

```bash
git add am lib/config.sh tests/test_all.sh
git commit -m "Add --sandbox/--no-sandbox CLI flag with configurable default"
```

---

### Task 3.5: CLI-level integration tests for yolo/sandbox independence

**Files:**
- Modify: `tests/test_all.sh` (new test function + register in runner)

**Step 1: Write the integration tests**

Add a new `test_cli_yolo_sandbox_integration()` function:

```bash
test_cli_yolo_sandbox_integration() {
    echo "=== Testing CLI yolo/sandbox integration ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "cli yolo/sandbox tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # --- Test: am new --yolo creates session with yolo but no container ---
    local session_name
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$session_name" "cli yolo-only: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli yolo-only: yolo_mode is true"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli yolo-only: no container (sandbox not requested)"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --sandbox without docker fails ---
    local orig_path="$PATH"
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v docker | tr '\n' ':')
    local sandbox_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" \
        >/dev/null 2>/dev/null || sandbox_rc=$?
    assert_eq "false" "$(test $sandbox_rc -eq 0 && echo true || echo false)" \
        "cli sandbox-no-docker: fails when docker unavailable"
    PATH="$orig_path"

    # --- Test: am new --yolo --sandbox enables both independently ---
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null) || true
    if [[ -n "$session_name" ]]; then
        assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
            "cli yolo+sandbox: yolo_mode is true"
        assert_eq "true" "$(registry_get_field "$session_name" sandbox_mode)" \
            "cli yolo+sandbox: sandbox_mode is true"
        agent_kill "$session_name" 2>/dev/null
    else
        # If docker unavailable, sandbox creation fails — that's expected
        skip_test "cli yolo+sandbox: skipped (docker unavailable)"
    fi

    # --- Test: config default_sandbox applies ---
    am_config_set "default_sandbox" "false" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$session_name" "cli sandbox-default-off: session created"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli sandbox-default-off: no container when default_sandbox=false"
    assert_eq "false" "$(registry_get_field "$session_name" sandbox_mode)" \
        "cli sandbox-default-off: sandbox_mode is false"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: --no-sandbox overrides config default ---
    am_config_set "default_sandbox" "true" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --no-sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$session_name" "cli no-sandbox-override: session created"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli no-sandbox-override: no container with --no-sandbox"
    assert_eq "false" "$(registry_get_field "$session_name" sandbox_mode)" \
        "cli no-sandbox-override: sandbox_mode is false"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: --no-yolo overrides config default ---
    am_config_set "default_yolo" "true" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --no-yolo --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$session_name" "cli no-yolo-override: session created"
    assert_eq "false" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli no-yolo-override: yolo_mode is false with --no-yolo"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}
```

Register it in the test runner (where all `test_*` functions are called at the bottom of the file).

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | grep -E 'cli yolo|cli sandbox|cli no-|FAIL'`
Expected: FAIL — `--sandbox` flag not yet wired, `sandbox_mode` field not in registry

**Step 3: These tests should pass after Tasks 1-3 are implemented**

No implementation in this task — this is test-only. The tests validate the CLI integration that Tasks 1-3 provide.

**Step 4: Run tests after Tasks 1-3**

Run: `./tests/test_all.sh 2>&1 | grep -E 'cli yolo|cli sandbox|cli no-|FAIL|Results'`
Expected: All PASS

**Step 5: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add CLI-level integration tests for yolo/sandbox independence"
```

---

### Task 4: Rename "permissive" to "yolo mode"

**Files:**
- Modify: `am` (help text, comments)
- Modify: `lib/agents.sh` (comments)
- Modify: `lib/fzf.sh` (form label, preview text)
- Test: `tests/test_all.sh`

**Step 1: Write the failing test**

Update the existing fzf helpers test (`test_fzf_helpers`) — the form preview test around line 741:

Change the assertion that checks for "Permissive:" to check for "Yolo:" instead:
```bash
    # The preview should show "Yolo:" not "Permissive:"
    local yolo_preview_line
    yolo_preview_line=$(printf '%s\n' "$worktree_preview" | grep "Permissive:" || true)
    assert_eq "" "$yolo_preview_line" "fzf helpers: preview does not say Permissive"
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | grep -E 'Permissive|FAIL'`

**Step 3: Rename all occurrences**

In `lib/fzf.sh`:
- `_new_session_form_rows()` line 311: change `Permissive` to `Yolo`
- `_new_session_form_preview()` line 351: change `Permissive:` to `Yolo:`

In `lib/agents.sh`:
- Comment on line 17: "Get the permissive/sandbox-bypass flag" → "Get the yolo mode flag"
- Comment on line 190: "Normalize permissive mode args" → "Normalize yolo mode args"
- Comment on line 294: "Sandbox mode when permissive flags are active" → remove (already rewritten in Task 2)

In `am`:
- Help text line 55: "Enable permissive mode" → "Enable yolo mode (agent permissive flags)"
- Help text line 56: "Disable permissive mode" → "Disable yolo mode"
- `cmd_new --help` lines 272-273: same changes
- Config help line 678: "Default permissive mode" → "Default yolo mode"

**Step 4: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | grep -E 'Permissive|FAIL|Results'`
Expected: All PASS, no "Permissive" in output

**Step 5: Commit**

```bash
git add lib/fzf.sh lib/agents.sh am tests/test_all.sh
git commit -m "Rename 'permissive' to 'yolo mode' across UI and help text"
```

---

### Task 5: Add sandbox row to new session form

**Files:**
- Modify: `lib/fzf.sh`
- Test: `tests/test_all.sh` (test_fzf_helpers)

**Step 1: Write the failing test**

Add to `test_fzf_helpers()`:
```bash
    # Sandbox row appears in form
    local sandbox_rows
    sandbox_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "false" "false" "" "")
    assert_contains "$sandbox_rows" $'sandbox\tSandbox' \
        "fzf helpers: sandbox row present"

    # Sandbox disabled when docker unavailable
    local sandbox_disabled_rows
    sandbox_disabled_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "false" "false" "" "" "false")
    assert_contains "$sandbox_disabled_rows" "[disabled]" \
        "fzf helpers: sandbox disabled without docker"
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | grep -E 'sandbox row|FAIL'`

**Step 3: Add sandbox to form rows**

In `lib/fzf.sh`, update `_new_session_form_rows()`:

1. Add `sandbox` and `docker_available` parameters:
```bash
_new_session_form_rows() {
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local sandbox="$6"
    local worktree_enabled="$7"
    local worktree_name="$8"
    local docker_available="${9:-true}"
```

2. Add sandbox toggle logic:
```bash
    local sandbox_toggle="[ ]"
    if [[ "$docker_available" != "true" ]]; then
        sandbox_toggle="[disabled]"
    elif [[ "$sandbox" == "true" ]]; then
        sandbox_toggle="[x]"
    fi
```

3. Add sandbox row after yolo row:
```bash
    printf 'sandbox\tSandbox\t%s\n' "$sandbox_toggle"
```

4. Update `_new_session_form_row_position()` — add sandbox and bump worktree positions:
```bash
    case "$1" in
        directory) echo 1 ;;
        agent) echo 2 ;;
        task) echo 3 ;;
        mode) echo 4 ;;
        yolo) echo 5 ;;
        sandbox) echo 6 ;;
        worktree_enabled) echo 7 ;;
        worktree_name) echo 8 ;;
        *) echo 1 ;;
    esac
```

5. Update `fzf_new_session_form()` to track sandbox state, pass `docker_available` to rows, handle space-toggle for sandbox, and include `--sandbox` in output flags.

6. Update all callers of `_new_session_form_rows` in the test to pass the new parameters.

**Step 4: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | grep -E 'sandbox|FAIL|Results'`

**Step 5: Commit**

```bash
git add lib/fzf.sh tests/test_all.sh
git commit -m "Add sandbox row to new session form with docker availability check"
```

---

### Task 6: Rewrite new session form for inline editing

**Files:**
- Modify: `lib/fzf.sh`
- Test: manual testing (fzf interactive forms can't be unit-tested)

This is the largest task. The form rewrite changes the interaction model entirely.

**Step 1: Remove preview panel and submit row**

Remove `_new_session_form_preview()` entirely.
Remove the `submit` entry from `_new_session_form_rows()`.
Remove the preview file creation/cleanup from `fzf_new_session_form()`.

**Step 2: Implement directory field with inline suggestions**

The directory field uses a dedicated fzf instance at the top of the form area with 10 lines:

```bash
_new_session_form_directory() {
    local current="$1"
    local initial_list
    initial_list=$(_list_directories | grep -v '^$')

    local selected
    selected=$(echo "$initial_list" | fzf \
        --sync \
        --ansi \
        --height=10 \
        --layout=reverse \
        --print-query \
        --query="$current" \
        --header="Directory  Tab:complete  Type to filter" \
        --bind="tab:reload(bash -c '_list_directories {q}' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | grep -v '^$')+transform-query(dirname {q})" \
        --expect="shift-tab" \
    ) || true

    local key query selection
    key=$(echo "$selected" | head -n1)
    query=$(echo "$selected" | sed -n '2p')
    selection=$(echo "$selected" | tail -n1)

    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    if [[ -z "$selection" && -n "$query" ]]; then
        selection="$query"
    fi

    selection="${selection/#\~/$HOME}"

    if [[ -n "$selection" ]]; then
        echo "$selection"
    else
        echo "$current"
    fi
}
```

**Step 3: Implement the main form loop**

The main form uses a single fzf instance per iteration. Each non-directory field is a row. The key changes:

- `--expect="space"` for toggle/cycle actions
- Enter (default action) → break and create session
- The form loop only re-renders for space actions (toggle/cycle)
- Text fields (task, worktree_name) use `_new_session_form_edit_text` popups (keep existing)
- Directory editing launches `_new_session_form_directory`

```bash
fzf_new_session_form() {
    # ... initialization same as current ...
    local docker_available="true"
    am_docker_available || docker_available="false"

    # Directory picker first
    if selection=$(_new_session_form_directory "$directory"); then
        directory="$selection"
    fi

    # Main field loop
    while true; do
        local rows
        rows=$(_new_session_form_rows "$directory" "$agent" "$task" "$mode" \
            "$yolo" "$sandbox" "$worktree_enabled" "$worktree_name" "$docker_available")

        selection=$(echo "$rows" | fzf \
            --sync --ansi --height=100% \
            --delimiter=$'\t' --with-nth=2,3 \
            --header="New Session  Enter:create  Space:toggle/cycle  Esc:cancel" \
            --no-preview \
            --bind="start:pos($(_new_session_form_row_position "$current_field"))" \
            --expect="space")

        key=$(echo "$selection" | head -n1)
        selected_row=$(echo "$selection" | tail -n1)
        selected_field=$(echo "$selected_row" | cut -f1)

        [[ -z "$selected_row" ]] && return 1

        current_field="$selected_field"

        if [[ "$key" == "space" ]]; then
            case "$selected_field" in
                agent)
                    local options
                    options=$(fzf_agent_options "$agent")
                    local current_idx next_idx count
                    count=$(echo "$options" | wc -l | tr -d ' ')
                    current_idx=$(echo "$options" | grep -n "^${agent}$" | head -1 | cut -d: -f1)
                    next_idx=$(( (current_idx % count) + 1 ))
                    agent=$(echo "$options" | sed -n "${next_idx}p")
                    ;;
                mode)
                    case "$mode" in
                        new) mode="resume" ;;
                        resume) mode="continue" ;;
                        continue) mode="new" ;;
                    esac
                    ;;
                yolo)
                    [[ "$yolo" == "true" ]] && yolo="false" || yolo="true"
                    ;;
                sandbox)
                    if [[ "$docker_available" == "true" ]]; then
                        [[ "$sandbox" == "true" ]] && sandbox="false" || sandbox="true"
                    else
                        message="Docker is not available. Sandbox mode is disabled."
                    fi
                    ;;
                worktree_enabled)
                    if agent_supports_worktree "$agent"; then
                        [[ "$worktree_enabled" == "true" ]] && worktree_enabled="false" || worktree_enabled="true"
                    fi
                    ;;
            esac
            continue
        fi

        # Enter pressed — for text fields, open editor; for everything else, create session
        case "$selected_field" in
            directory)
                if selection=$(_new_session_form_directory "$directory"); then
                    directory="$selection"
                fi
                ;;
            task)
                if selection=$(_new_session_form_prompt "Task" "$task"); then
                    task="$selection"
                fi
                ;;
            worktree_name)
                if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
                    if selection=$(_new_session_form_prompt "Worktree name" "$worktree_name"); then
                        if _new_session_validate_worktree_name "$selection"; then
                            worktree_name="$selection"
                        fi
                    fi
                fi
                ;;
            *)
                # Any other field on Enter → create session
                break
                ;;
        esac
    done

    # ... validation and output same as current, plus --sandbox flag ...
}
```

**Step 4: Test manually**

Run: `am new` and verify:
- Directory picker appears first (10 lines, Tab completes, type to filter)
- Field list appears with no preview panel
- Space cycles agent/mode, toggles yolo/sandbox/worktree
- Enter on non-text fields creates session
- Enter on task/worktree opens inline editor, then back to form
- Enter on directory re-opens directory picker
- Sandbox row shows `[disabled]` if docker missing
- Esc cancels

**Step 5: Commit**

```bash
git add lib/fzf.sh
git commit -m "Redesign new session form: inline editing, no preview, Enter-to-create"
```

---

### Task 7: Update form tests for new API

**Files:**
- Modify: `tests/test_all.sh` (test_fzf_helpers)

**Step 1: Update test_fzf_helpers**

The `_new_session_form_rows` signature changed (added sandbox, docker_available params). The preview function was removed. Update all test calls:

```bash
    # Updated form rows call with sandbox params
    local worktree_rows
    worktree_rows=$(_new_session_form_rows "/tmp/project" "gemini" "" "new" "false" "false" "true" "my-wt" "true")
    assert_contains "$worktree_rows" $'worktree_enabled\tWorktree\t<unsupported>' \
        "fzf helpers: unsupported agent marks worktree as unavailable"

    # No submit row anymore
    local submit_check
    submit_check=$(echo "$worktree_rows" | grep "^submit" || true)
    assert_eq "" "$submit_check" "fzf helpers: no submit row in form"

    # Sandbox disabled
    local disabled_rows
    disabled_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "false" "false" "" "false")
    assert_contains "$disabled_rows" "[disabled]" \
        "fzf helpers: sandbox disabled without docker"
```

Remove the `_new_session_form_preview` test (function no longer exists).

**Step 2: Run all tests**

Run: `./tests/test_all.sh`
Expected: All PASS

**Step 3: Commit**

```bash
git add tests/test_all.sh
git commit -m "Update form tests for new session form API"
```

---

### Task 8: Wire sandbox flag through fzf_main and cmd_new

**Files:**
- Modify: `lib/fzf.sh` (fzf_main output parsing)
- Modify: `am` (cmd_list, cmd_new, cmd_new_internal)

**Step 1: Verify the integration path**

The form already outputs `--sandbox` in flags via Task 5/6. Verify the flow:
- `fzf_new_session_form()` outputs `directory\tagent\ttask\tworktree\tflags`
- `fzf_main()` parses this and passes to `cmd_new_internal`
- `cmd_new_internal` passes flags as `agent_args` to `agent_launch`
- `agent_launch` parses `--sandbox` from agent_args (Task 2)

This should already work end-to-end. Verify with:

Run: `./tests/test_all.sh`
Expected: All PASS, no regressions

**Step 2: Commit (only if changes needed)**

```bash
git add am lib/fzf.sh
git commit -m "Wire sandbox flag through form → launch pipeline"
```

---

### Task 9: Final integration test and syntax check

**Step 1: Syntax check all scripts**

Run: `bash -n lib/*.sh am`
Expected: No errors

**Step 2: Run full test suite**

Run: `./tests/test_all.sh`
Expected: All PASS

**Step 3: Manual smoke test**

1. `am new` — verify new form UX
2. `am new --yolo .` — verify yolo without sandbox
3. `am new --sandbox .` — verify sandbox without yolo (or error if no docker)
4. `am config set sandbox true` — verify default
5. `am config` — verify all 4 keys shown
6. `am info <session>` — verify yolo/sandbox shown independently

**Step 4: Commit any fixups**

```bash
git add -A
git commit -m "Final integration fixes for yolo/sandbox split and form redesign"
```
