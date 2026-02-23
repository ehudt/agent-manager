# Auto-Title Scanner Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace per-session background subshells with a piggyback scanner that titles untitled sessions during user touchpoints.

**Architecture:** `auto_title_scan()` runs alongside `registry_gc()` from fzf/list entry points, throttled to once/60s. It writes a fallback title immediately, then spawns a fire-and-forget Haiku upgrade. A shared `_title_generate` helper contains the title logic so both scanner and tests use the same code.

**Tech Stack:** bash, jq, sed, tmux

---

### Task 1: Extract title helpers into registry.sh

The current title logic lives only in `auto_title_session` (agents.sh:261-283) and duplicated in tests. Extract it into reusable functions.

**Files:**
- Modify: `lib/registry.sh` (append after `history_prune`, ~line 170)

**Step 1: Add `_title_fallback` function**

Append to `lib/registry.sh`:

```bash
# Generate a fallback title from a user message (first sentence, cleaned)
# Usage: _title_fallback <message>
_title_fallback() {
    local msg="$1"
    echo "$msg" | sed 's/https\?:\/\/[^ ]*//g; s/  */ /g; s/[.?!].*//' | head -c 60
}
```

**Step 2: Add `_title_strip_haiku` function**

```bash
# Strip markdown/quotes from Haiku output
# Usage: _title_strip_haiku <raw_title>
_title_strip_haiku() {
    echo "$1" | sed 's/^[#*"`'\'']*//; s/[#*"`'\'']*$//' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
```

**Step 3: Add `_title_valid` function**

```bash
# Check if a title is valid (<=60 chars, no newlines)
# Usage: _title_valid <title> && echo yes
_title_valid() {
    local t="$1"
    [[ -n "$t" && ${#t} -le 60 && "$t" != *$'\n'* ]]
}
```

**Step 4: Run existing tests to verify no regressions**

Run: `./tests/test_all.sh`
Expected: All tests pass (helpers are internal, not yet called)

**Step 5: Commit**

```bash
git add lib/registry.sh
git commit -m "refactor: extract title helper functions into registry.sh"
```

---

### Task 2: Add `auto_title_scan` function

**Files:**
- Modify: `lib/registry.sh` (append after title helpers)

**Step 1: Write `auto_title_scan`**

Append to `lib/registry.sh`:

```bash
# Scan untitled active sessions and generate titles.
# Writes fallback immediately, spawns fire-and-forget Haiku upgrade.
# Throttled to once per 60s unless force=1.
# Usage: auto_title_scan [force]
auto_title_scan() {
    local force="${1:-0}"

    # Throttle
    local marker="$AM_DIR/.title_scan_last"
    local now
    now=$(date +%s)
    if [[ "$force" != "1" && -f "$marker" ]]; then
        local last
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if (( now - last < 60 )); then
            return 0
        fi
    fi
    echo "$now" > "$marker"

    local name dir task first_msg fallback
    for name in $(registry_list); do
        task=$(registry_get_field "$name" "task")
        [[ -n "$task" ]] && continue  # already titled

        dir=$(registry_get_field "$name" "directory")
        [[ -z "$dir" ]] && continue

        first_msg=$(claude_first_user_message "$dir" 2>/dev/null)
        first_msg="${first_msg:0:200}"
        [[ -z "$first_msg" ]] && continue

        # Write fallback title immediately
        fallback=$(_title_fallback "$first_msg")
        [[ -z "$fallback" ]] && continue

        registry_update "$name" "task" "$fallback"
        local branch agent
        branch=$(registry_get_field "$name" "branch")
        agent=$(registry_get_field "$name" "agent_type")
        history_append "$dir" "$fallback" "$agent" "$branch"

        # Fire-and-forget Haiku upgrade
        if command -v claude &>/dev/null; then
            (
                set +e +o pipefail
                unset CLAUDECODE

                local haiku_title
                haiku_title=$(printf '%s' "$first_msg" | claude -p --model haiku \
                    "Reply with a short 2-5 word title summarizing this task. Plain text only, no markdown, no quotes, no punctuation. Examples: Fix auth login bug, Add user settings page, Refactor database layer" 2>/dev/null) &
                local _pid=$!
                ( command sleep 30 && kill "$_pid" 2>/dev/null ) &
                local _wd=$!
                wait "$_pid" 2>/dev/null
                kill "$_wd" 2>/dev/null; wait "$_wd" 2>/dev/null

                haiku_title=$(_title_strip_haiku "$haiku_title")
                if _title_valid "$haiku_title"; then
                    source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
                    registry_update "$name" "task" "$haiku_title"
                fi
            ) >/dev/null 2>&1 &
        fi
    done
}
```

**Step 2: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass (function exists but not yet called)

**Step 3: Commit**

```bash
git add lib/registry.sh
git commit -m "feat: add auto_title_scan with fallback-first strategy"
```

---

### Task 3: Wire scanner into touchpoints and remove old code

**Files:**
- Modify: `lib/fzf.sh:254` and `lib/fzf.sh:398` (add scan calls)
- Modify: `lib/fzf.sh:268` (export new functions)
- Modify: `lib/agents.sh:213-216` (remove auto_title_session call)
- Modify: `lib/agents.sh:225-299` (remove auto_title_session function)

**Step 1: Add `auto_title_scan` calls in fzf.sh**

In `fzf_list_sessions()` (line 254), after `registry_gc`:
```bash
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1
```

In `fzf_list_json()` (line 398), after `registry_gc`:
```bash
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1
```

**Step 2: Export new functions in `_fzf_export_functions` (line 265-272)**

Add to the export block:
```bash
    export -f auto_title_scan _title_fallback _title_strip_haiku _title_valid
    export -f claude_first_user_message
```

**Step 3: Remove `auto_title_session` call from `agent_launch`**

In `lib/agents.sh`, remove lines 213-216:
```bash
    # Auto-title in background (Claude only, no task already set)
    if [[ "$agent_type" == "claude" && -z "$task" ]]; then
        auto_title_session "$session_name" "$directory"
    fi
```

**Step 4: Remove `auto_title_session` function**

Delete the entire function `auto_title_session()` from `lib/agents.sh` (lines 222-299, including the comment block above it).

**Step 5: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass. The `test_auto_title_session` tests exercise the pure title logic (helpers), not the removed function. Check the `test_history_integration` test still passes (it simulates the auto-title registry path).

**Step 6: Commit**

```bash
git add lib/agents.sh lib/fzf.sh
git commit -m "feat: wire auto_title_scan into touchpoints, remove per-session subshell"
```

---

### Task 4: Add tests for `auto_title_scan`

**Files:**
- Modify: `tests/test_all.sh` (add new test function, add to main)

**Step 1: Write `test_auto_title_scan`**

Add after `test_auto_title_session` (after line 1257):

```bash
# ============================================
# Test: auto_title_scan (piggyback scanner)
# ============================================
test_auto_title_scan() {
    echo ""
    echo "=== Auto-Title Scan Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "auto-title scan tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated AM environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Stub claude_first_user_message
    claude_first_user_message() {
        case "$1" in
            */has-msg) echo "Fix the login bug in auth. Also refactor." ;;
            *) echo "" ;;
        esac
    }

    # --- Test 1: Titles untitled session with fallback ---
    registry_add "test-scan-1" "/tmp/has-msg" "main" "claude" ""
    auto_title_scan 1  # force
    local task
    task=$(registry_get_field "test-scan-1" "task")
    assert_contains "$task" "Fix the login bug in auth" \
        "scan: writes fallback title for untitled session"

    # --- Test 2: Skips already-titled sessions ---
    registry_add "test-scan-2" "/tmp/has-msg" "main" "claude" "Existing Title"
    auto_title_scan 1
    task=$(registry_get_field "test-scan-2" "task")
    assert_eq "Existing Title" "$task" \
        "scan: skips already-titled session"

    # --- Test 3: Skips sessions with no user message ---
    registry_add "test-scan-3" "/tmp/no-msg" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-3" "task")
    assert_eq "" "$task" \
        "scan: skips session with no user message"

    # --- Test 4: Throttling works ---
    registry_add "test-scan-4" "/tmp/has-msg" "main" "claude" ""
    auto_title_scan  # throttled (ran <60s ago from test 1)
    task=$(registry_get_field "test-scan-4" "task")
    assert_eq "" "$task" \
        "scan: throttled within 60s"

    # --- Test 5: Force bypasses throttle ---
    auto_title_scan 1
    task=$(registry_get_field "test-scan-4" "task")
    assert_contains "$task" "Fix the login bug" \
        "scan: force bypasses throttle"

    # --- Test 6: History entry created ---
    local hist_count=0
    [[ -f "$AM_HISTORY" ]] && hist_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_not_empty "$hist_count" \
        "scan: history entries created"

    # --- Cleanup ---
    unset -f claude_first_user_message
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    echo ""
}
```

**Step 2: Register in main()**

In `main()`, add after `test_auto_title_session`:
```bash
    test_auto_title_scan
```

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass including new scan tests

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "test: add auto_title_scan tests"
```

---

### Task 5: Update docs

**Files:**
- Modify: `AGENTS.md` (update architecture diagram and function list)

**Step 1: Update references**

- Remove `auto_title_session` from the function list and architecture diagram
- Add `auto_title_scan` description
- Note the piggyback-on-touchpoints pattern

**Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md for auto-title scanner refactor"
```
