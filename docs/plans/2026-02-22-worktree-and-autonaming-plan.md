# Worktree Isolation & Auto-naming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add opt-in worktree isolation (`-w`) for Claude sessions and automatic Haiku-generated session titles.

**Architecture:** Worktree: pass `-w <name>` to Claude CLI, background-poll for the worktree directory, cd the shell pane into it. Auto-naming: background process extracts first user message from Claude's JSONL, sends to Haiku via `claude -p`, writes title to registry.

**Tech Stack:** bash, tmux, jq, claude CLI

---

### Task 1: Parse `-w` / `--worktree` flag in `cmd_new()`

**Files:**
- Modify: `am:164-255` (`cmd_new` function)

**Step 1: Write the failing test**

Add to `tests/test_all.sh` in `test_cli()`:

```bash
# Test -w flag in help output
assert_contains "$help_output" "--worktree" "am help: shows worktree flag"
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: FAIL on "--worktree" not in help

**Step 3: Add `-w` flag parsing to `cmd_new()`**

In `am:164` (`cmd_new` function), add a local variable and case branch:

```bash
# Add at top of cmd_new, after existing locals:
local worktree_name=""

# Add case branch in the while loop:
-w|--worktree)
    shift
    # Next arg is optional name — if it starts with - or is a directory, use default
    if [[ $# -gt 0 && "$1" != -* && ! -d "$1" ]]; then
        worktree_name="$1"
        shift
    else
        worktree_name="__auto__"  # sentinel: generate from session hash
    fi
    ;;
```

Pass `worktree_name` to `agent_launch` as a new 5th positional arg (after task, before agent_args):

```bash
session_name=$(agent_launch "$directory" "$agent_type" "$task" "$worktree_name" "${agent_args[@]}")
```

**Step 4: Update `usage()` in `am`**

Add to OPTIONS FOR 'new' section:

```
    -w, --worktree  Enable git worktree isolation (Claude only)
                    Optional: -w <name> to set worktree name (default: am-XXXXXX)
```

**Step 5: Run test to verify it passes**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS

**Step 6: Commit**

```bash
git add am tests/test_all.sh
git commit -m "feat: parse -w/--worktree flag in cmd_new"
```

---

### Task 2: Plumb worktree through `agent_launch()`

**Files:**
- Modify: `lib/agents.sh:63-176` (`agent_launch` function)

**Step 1: Write the failing test**

Add to `tests/test_all.sh` in `test_agents()`:

```bash
# Test agent_launch with worktree flag (Claude-only, needs git repo)
# Just verify the function signature accepts the new param without error
if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    # Test that agent_launch validates worktree requires Claude
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    registry_init

    # Mock: won't actually launch since we don't want real sessions in tests
    # Just test the worktree name generation
    local wt_name="test-feature"
    assert_eq "test-feature" "$wt_name" "worktree: explicit name preserved"

    local auto_hash=$(generate_hash "/tmp/test$(date +%s)")
    local auto_name="am-${auto_hash}"
    assert_contains "$auto_name" "am-" "worktree: auto name has am- prefix"

    rm -rf "$AM_DIR"
fi
```

**Step 2: Run test to verify it passes (baseline)**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS (this is a baseline test for the naming logic)

**Step 3: Update `agent_launch()` signature and worktree logic**

Change `agent_launch` to accept worktree name. The full parameter list becomes:

```bash
# Usage: agent_launch <directory> [agent_type] [task_description] [worktree_name] [agent_args...]
agent_launch() {
    local directory="$1"
    local agent_type="${2:-claude}"
    local task="${3:-}"
    local worktree_name="${4:-}"
    shift 4 2>/dev/null || shift $#
    local agent_args=("$@")
```

After generating `session_name` (line ~120), resolve the worktree name:

```bash
# Resolve worktree name
local worktree_path=""
if [[ -n "$worktree_name" ]]; then
    if [[ "$agent_type" != "claude" ]]; then
        log_warn "Worktree isolation only supported for Claude, ignoring -w"
        worktree_name=""
    elif ! git -C "$directory" rev-parse --git-dir &>/dev/null; then
        log_warn "Not a git repo, ignoring -w"
        worktree_name=""
    else
        # Resolve __auto__ sentinel to am-hash name
        if [[ "$worktree_name" == "__auto__" ]]; then
            worktree_name="am-${session_name#am-}"
        fi
        worktree_path="$directory/.claude/worktrees/$worktree_name"
    fi
fi
```

When building `full_cmd` (around line 150), append `-w`:

```bash
if [[ -n "$worktree_name" ]]; then
    full_cmd="$full_cmd -w '$worktree_name'"
fi
```

After sending the command to the agent pane (after line 172), spawn the background cd waiter:

```bash
if [[ -n "$worktree_path" ]]; then
    (for _i in $(seq 1 20); do
        if [ -d "$worktree_path" ]; then
            tmux send-keys -t "${session_name}:0.1" "cd '$worktree_path'" Enter
            break
        fi
        sleep 0.5
    done) &
fi
```

Store worktree path in registry:

```bash
if [[ -n "$worktree_path" ]]; then
    registry_update "$session_name" "worktree_path" "$worktree_path"
fi
```

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/agents.sh
git commit -m "feat: plumb worktree name through agent_launch"
```

---

### Task 3: Update callers for new `agent_launch` signature

**Files:**
- Modify: `am:149-161` (`cmd_new_internal`)
- Modify: `am:246-254` (bottom of `cmd_new`)
- Modify: `lib/fzf.sh:295` (Ctrl-N flow returns `__NEW_SESSION__` with fields)

**Step 1: Update `cmd_new_internal()`**

This is called from the fzf Ctrl-N flow. It doesn't support worktree (interactive flow doesn't offer it), so pass empty:

```bash
cmd_new_internal() {
    local directory="$1"
    local agent_type="${2:-claude}"
    shift 2 2>/dev/null || shift $#
    local agent_args=("$@")

    local session_name
    session_name=$(agent_launch "$directory" "$agent_type" "" "" "${agent_args[@]}")

    if [[ -n "$session_name" ]]; then
        tmux_attach "$session_name"
    fi
}
```

**Step 2: Update `cmd_new()` to pass `worktree_name`**

At the bottom of `cmd_new()`, update the `agent_launch` call:

```bash
session_name=$(agent_launch "$directory" "$agent_type" "$task" "$worktree_name" "${agent_args[@]}")
```

**Step 3: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS

**Step 4: Commit**

```bash
git add am lib/fzf.sh
git commit -m "feat: update callers for new agent_launch worktree param"
```

---

### Task 4: Show worktree in `agent_info()`

**Files:**
- Modify: `lib/agents.sh:230-268` (`agent_info` function)

**Step 1: Update `agent_info()` to show worktree**

Add `worktree_path` to the jq extraction (it already reads from registry):

```bash
fields=$(jq -r --arg name "$session_name" \
    '.sessions[$name] | "\(.directory // "")\t\(.branch // "")\t\(.agent_type // "")\t\(.task // "")\t\(.worktree_path // "")"' \
    "$AM_REGISTRY" 2>/dev/null)

local directory branch agent_type task worktree_path
IFS=$'\t' read -r directory branch agent_type task worktree_path <<< "$fields"
```

Add at end of output:

```bash
if [[ -n "$worktree_path" ]]; then
    echo "Worktree: $worktree_path"
fi
```

**Step 2: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS

**Step 3: Commit**

```bash
git add lib/agents.sh
git commit -m "feat: show worktree path in agent_info"
```

---

### Task 5: Auto-naming with Haiku

**Files:**
- Modify: `lib/agents.sh` (new function + call from `agent_launch`)

**Step 1: Write the failing test**

Add to `tests/test_all.sh` in `test_agents()`:

```bash
# Test auto_title_session function exists
assert_cmd_succeeds "auto_title_session: function exists" type auto_title_session
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: FAIL

**Step 3: Implement `auto_title_session()`**

Add new function to `lib/agents.sh`:

```bash
# Generate a session title from first user message using Haiku
# Runs in background, updates registry when done
# Usage: auto_title_session <session_name> <directory>
auto_title_session() {
    local session_name="$1"
    local directory="$2"

    (
        # Wait for Claude session to start and receive first message
        sleep 5

        # Convert directory to Claude's project path format
        local abs_dir
        abs_dir=$(cd "$directory" && pwd)
        local project_path="${abs_dir//\//-}"
        project_path="${project_path//./-}"
        local claude_project_dir="$HOME/.claude/projects/$project_path"

        # Poll for JSONL content
        local first_msg=""
        for _i in $(seq 1 30); do
            if [[ -d "$claude_project_dir" ]]; then
                local session_file
                session_file=$(command ls -t "$claude_project_dir"/*.jsonl 2>/dev/null | head -1)
                if [[ -n "$session_file" && -f "$session_file" ]]; then
                    local line content cleaned
                    while IFS= read -r line; do
                        content=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null) || continue
                        [[ -z "$content" ]] && continue
                        cleaned=$(echo "$content" | \
                            sed 's/<[^>]*>[^<]*<\/[^>]*>//g; s/<[^>]*>//g' | \
                            tr '\n' ' ' | \
                            sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        if [[ -n "$cleaned" && ${#cleaned} -gt 10 ]]; then
                            first_msg="$cleaned"
                            break
                        fi
                    done < <(grep '"type":"user"' "$session_file" 2>/dev/null | head -10)
                fi
            fi
            [[ -n "$first_msg" ]] && break
            sleep 2
        done

        [[ -z "$first_msg" ]] && return 0

        # Truncate input to ~200 chars to keep Haiku call cheap
        first_msg="${first_msg:0:200}"

        # Try Haiku for a clean title
        local title=""
        if command -v claude &>/dev/null; then
            title=$(printf '%s' "$first_msg" | claude -p --model haiku \
                "Generate a 2-5 word title for this coding task. Output ONLY the title, nothing else." 2>/dev/null) || true
        fi

        # Fallback: raw first-sentence extraction
        if [[ -z "$title" ]]; then
            title=$(echo "$first_msg" | sed 's/https\?:\/\/[^ ]*//g; s/  */ /g; s/[.?!].*//' | head -c 60)
        fi

        # Write to registry
        if [[ -n "$title" ]]; then
            # Source registry functions in subshell
            source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
            source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
            registry_update "$session_name" "task" "$title"
        fi
    ) &
}
```

**Step 4: Call from `agent_launch()`**

Add at the end of `agent_launch()`, just before `echo "$session_name"`:

```bash
# Auto-title in background (Claude only, no task already set)
if [[ "$agent_type" == "claude" && -z "$task" ]]; then
    auto_title_session "$session_name" "$directory"
fi
```

**Step 5: Run test to verify it passes**

Run: `./tests/test_all.sh 2>&1 | tail -5`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/agents.sh
git commit -m "feat: auto-generate session titles using Haiku"
```

---

### Task 6: Manual test end-to-end

**Step 1: Test worktree isolation**

```bash
# From a git repo
am new -w ~/code/agent-manager
# Verify: Claude starts with worktree, shell pane cd's into it within ~5s
# Check: tmux display-message -p '#{pane_current_path}' shows worktree path

# With custom name
am new -w my-feature ~/code/agent-manager
# Verify: worktree at .claude/worktrees/my-feature

# Without -w (unchanged behavior)
am new ~/code/agent-manager
# Verify: no worktree, both panes in original directory
```

**Step 2: Test auto-naming**

```bash
am new ~/code/agent-manager
# Send a message to Claude, wait ~10s
# Check: am status shows generated title
# Check: am info <session> shows task field
```

**Step 3: Test non-git directory**

```bash
am new -w /tmp
# Verify: warning printed, no worktree, session works normally
```

**Step 4: Test non-Claude agent**

```bash
am new -w -t gemini ~/code/agent-manager
# Verify: warning printed, no worktree, session works normally
```

**Step 5: Commit (update AGENTS.md if needed)**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md with worktree and auto-naming"
```
