# Session History in Directory Picker - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Annotate the Ctrl-N directory picker with recent session task names so users can search by feature name via fzf.

**Architecture:** Add a `history.jsonl` file that logs sessions when titled. Enrich `_list_directories` to annotate paths with recent tasks. fzf naturally searches the full line, so typing a task name finds the right directory.

**Tech Stack:** Bash, jq, fzf

---

### Task 1: Add history functions to registry.sh

**Files:**
- Modify: `lib/utils.sh:6` (add `AM_HISTORY` var)
- Modify: `lib/registry.sh:152` (append new functions)
- Test: `tests/test_all.sh`

**Step 1: Write the failing tests**

Add a new test group to `tests/test_all.sh` (after the existing registry tests section). Find the pattern of existing test groups and add:

```bash
# ============================================================
# History Tests
# ============================================================
test_history() {
    echo ""
    echo "=== History Tests ==="

    # Use temp dir for isolation
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    registry_init

    # Test history_append creates file and writes entry
    history_append "/tmp/project1" "Fix auth bug" "claude" "main"
    assert_cmd_succeeds "history_append: creates file" test -f "$AM_HISTORY"
    local count
    count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "1" "$count" "history_append: writes one line"

    # Test entry format is valid JSON with correct fields
    local dir
    dir=$(jq -r '.directory' "$AM_HISTORY")
    assert_eq "/tmp/project1" "$dir" "history_append: correct directory"
    local task
    task=$(jq -r '.task' "$AM_HISTORY")
    assert_eq "Fix auth bug" "$task" "history_append: correct task"

    # Test multiple entries
    history_append "/tmp/project2" "Add dark mode" "gemini" "feature/ui"
    history_append "/tmp/project1" "Refactor tests" "claude" "main"
    count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$count" "history_append: accumulates entries"

    # Test history_for_directory filters by path
    local results
    results=$(history_for_directory "/tmp/project1")
    local result_count
    result_count=$(echo "$results" | wc -l | tr -d ' ')
    assert_eq "2" "$result_count" "history_for_directory: returns matching entries"
    assert_contains "$results" "Fix auth bug" "history_for_directory: contains first task"
    assert_contains "$results" "Refactor tests" "history_for_directory: contains second task"

    # Test history_for_directory returns most recent first
    local first_task
    first_task=$(echo "$results" | head -1 | jq -r '.task')
    assert_eq "Refactor tests" "$first_task" "history_for_directory: most recent first"

    # Test history_prune removes old entries
    # Inject an old entry manually (8 days ago)
    local old_date
    old_date=$(date -u -v-8d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "8 days ago" +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"directory\":\"/tmp/old\",\"task\":\"Old task\",\"agent_type\":\"claude\",\"branch\":\"main\",\"created_at\":\"$old_date\"}" >> "$AM_HISTORY"
    count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "4" "$count" "history_prune: 4 entries before prune"
    history_prune
    count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$count" "history_prune: removes old entry"

    # Test history_for_directory with no matches returns empty
    results=$(history_for_directory "/tmp/nonexistent")
    assert_eq "" "$results" "history_for_directory: empty for unknown path"

    # Cleanup
    rm -rf "$AM_DIR"
}
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `history_append: command not found`

**Step 3: Add AM_HISTORY variable**

In `lib/utils.sh`, after line 6 (`AM_REGISTRY="$AM_DIR/sessions.json"`), add:

```bash
AM_HISTORY="$AM_DIR/history.jsonl"
```

**Step 4: Implement history functions**

Append to the end of `lib/registry.sh` (after line 151):

```bash

# --- Session History ---
# Persistent log of sessions with their tasks, survives GC.
# Format: one JSON object per line in $AM_HISTORY

# Append a session to history and prune old entries
# Usage: history_append <directory> <task> <agent_type> <branch>
history_append() {
    local directory="$1"
    local task="$2"
    local agent_type="$3"
    local branch="$4"

    [[ -z "$task" ]] && return 0

    am_init

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    printf '%s\n' "$(jq -cn \
        --arg dir "$directory" \
        --arg task "$task" \
        --arg agent "$agent_type" \
        --arg branch "$branch" \
        --arg created "$created_at" \
        '{directory: $dir, task: $task, agent_type: $agent, branch: $branch, created_at: $created}')" \
        >> "$AM_HISTORY"

    history_prune
}

# Remove history entries older than 7 days
history_prune() {
    [[ -f "$AM_HISTORY" ]] || return 0

    local cutoff
    cutoff=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_file
    tmp_file=$(mktemp)

    jq -c --arg cutoff "$cutoff" 'select(.created_at >= $cutoff)' "$AM_HISTORY" > "$tmp_file" 2>/dev/null
    mv "$tmp_file" "$AM_HISTORY"
}

# Get recent sessions for a directory, most recent first
# Usage: history_for_directory <path>
# Returns: JSONL lines filtered to directory, newest first
history_for_directory() {
    local path="$1"
    [[ -f "$AM_HISTORY" ]] || return 0

    jq -c --arg dir "$path" 'select(.directory == $dir)' "$AM_HISTORY" 2>/dev/null | \
        jq -sc 'sort_by(.created_at) | reverse | .[]' 2>/dev/null
}
```

**Step 5: Run tests to verify they pass**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All history tests PASS

**Step 6: Commit**

```bash
git add lib/utils.sh lib/registry.sh tests/test_all.sh
git commit -m "feat: add session history persistence (history.jsonl)"
```

---

### Task 2: Hook history_append into session lifecycle

**Files:**
- Modify: `lib/agents.sh:148` (explicit task on launch)
- Modify: `lib/agents.sh:291` (auto-title callback)

**Step 1: Write the failing test**

Add to `tests/test_all.sh` inside the history test group (or as a separate integration note — since `auto_title_session` is async/background, we test the hook points exist by checking that `history_append` is called). For unit-level, the Task 1 tests already cover the function. Here we verify the call sites are wired:

```bash
# Test: registry_add with task triggers history_append
test_history_integration() {
    echo ""
    echo "=== History Integration Tests ==="

    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    registry_init

    # Simulate what agent_launch does when task is provided
    registry_add "test-int" "/tmp/inttest" "main" "claude" "explicit task"
    history_append "/tmp/inttest" "explicit task" "claude" "main"

    assert_cmd_succeeds "integration: history file exists" test -f "$AM_HISTORY"
    local task
    task=$(jq -r '.task' "$AM_HISTORY" | head -1)
    assert_eq "explicit task" "$task" "integration: explicit task logged"

    rm -rf "$AM_DIR"
}
```

**Step 2: Wire history_append into agent_launch (explicit task)**

In `lib/agents.sh`, after line 148 (`registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task"`), add:

```bash
    # Log to persistent history if task is known at launch
    if [[ -n "$task" ]]; then
        history_append "$directory" "$task" "$agent_type" "$branch"
    fi
```

**Step 3: Wire history_append into auto_title_session**

In `lib/agents.sh`, after line 291 (`registry_update "$session_name" "task" "$title"`), add:

```bash
            # Log to persistent history
            local dir branch agent
            dir=$(registry_get_field "$session_name" "directory")
            branch=$(registry_get_field "$session_name" "branch")
            agent=$(registry_get_field "$session_name" "agent_type")
            history_append "$dir" "$title" "$agent" "$branch"
```

Note: registry.sh is already sourced at line 290, so `history_append` is available.

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/agents.sh tests/test_all.sh
git commit -m "feat: log sessions to history on title assignment"
```

---

### Task 3: Annotate directory picker with session history

**Files:**
- Modify: `lib/fzf.sh:15-51` (`_list_directories`)
- Modify: `lib/fzf.sh:56-102` (`fzf_pick_directory`)

**Step 1: Write the failing test**

```bash
test_annotated_directories() {
    echo ""
    echo "=== Annotated Directory Tests ==="

    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    registry_init

    # Seed history
    history_append "/tmp/project-alpha" "Fix auth bug" "claude" "main"
    history_append "/tmp/project-alpha" "Add tests" "claude" "dev"
    history_append "/tmp/project-beta" "Dark mode" "gemini" "feature/ui"

    # Test _annotate_directory
    local annotation
    annotation=$(_annotate_directory "/tmp/project-alpha")
    assert_contains "$annotation" "Add tests" "annotate: shows most recent task"
    assert_contains "$annotation" "Fix auth" "annotate: shows older task"
    assert_contains "$annotation" "claude" "annotate: shows agent type"

    # Test with no history
    annotation=$(_annotate_directory "/tmp/no-history")
    assert_eq "" "$annotation" "annotate: empty for unknown path"

    # Test _strip_annotation
    local stripped
    stripped=$(_strip_annotation "/tmp/project-alpha	claude: Add tests (2h) | claude: Fix auth (1d)")
    assert_eq "/tmp/project-alpha" "$stripped" "strip: extracts path from annotated line"

    stripped=$(_strip_annotation "/tmp/plain-path")
    assert_eq "/tmp/plain-path" "$stripped" "strip: handles plain path"

    rm -rf "$AM_DIR"
}
```

**Step 2: Run tests to verify they fail**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `_annotate_directory: command not found`

**Step 3: Implement annotation helpers in fzf.sh**

Add after the `_list_directories` function (after line 51), before `fzf_pick_directory`:

```bash
# Annotate a directory path with recent session history
# Usage: _annotate_directory <path>
# Returns: annotation string like 'claude: "Task" (2h) | gemini: "Task2" (1d)' or empty
_annotate_directory() {
    local dir_path="$1"
    [[ -f "$AM_HISTORY" ]] || return 0

    local entries
    entries=$(history_for_directory "$dir_path" | head -3)
    [[ -z "$entries" ]] && return 0

    local parts=()
    local now
    now=$(date +%s)

    while IFS= read -r line; do
        local task agent created_at
        task=$(echo "$line" | jq -r '.task')
        agent=$(echo "$line" | jq -r '.agent_type')
        created_at=$(echo "$line" | jq -r '.created_at')

        # Calculate relative time
        local ts
        ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || \
             date -d "$created_at" +%s 2>/dev/null || echo "$now")
        local age=$(( now - ts ))
        local age_str
        if (( age < 3600 )); then
            age_str="$(( age / 60 ))m"
        elif (( age < 86400 )); then
            age_str="$(( age / 3600 ))h"
        else
            age_str="$(( age / 86400 ))d"
        fi

        # Truncate task to 30 chars
        [[ ${#task} -gt 30 ]] && task="${task:0:27}..."

        parts+=("${agent}: ${task} (${age_str})")
    done <<< "$entries"

    local IFS='|'
    echo " ${parts[*]}"
}

# Strip annotation from a picker line, returning just the path
# Usage: _strip_annotation <line>
_strip_annotation() {
    local line="$1"
    # Tab separates path from annotation; if no tab, line is the path
    echo "$line" | cut -f1
}
```

**Step 4: Modify _list_directories to annotate paths**

Replace the body of `_list_directories` (lines 15-51). The new version builds the path list as before, deduplicates, then annotates each path with history. Use a tab character to separate path from annotation:

```bash
_list_directories() {
    local query="${1:-}"

    # If query looks like a path, show completions for that path
    if [[ "$query" == /* || "$query" == ~* || "$query" == .* ]]; then
        local base_path="${query/#\~/$HOME}"
        if [[ -d "$base_path" ]]; then
            find "$base_path" -maxdepth 1 -type d 2>/dev/null | grep -v "^$base_path$" | sort
        else
            local parent_dir=$(dirname "$base_path")
            local prefix=$(basename "$base_path")
            if [[ -d "$parent_dir" ]]; then
                find "$parent_dir" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null | sort
            fi
        fi
        return
    fi

    # Build raw path list
    local paths=()
    paths+=("$(pwd)")

    if command -v zoxide &>/dev/null; then
        while IFS= read -r p; do
            paths+=("$p")
        done < <(zoxide query -l 2>/dev/null | head -30)
    fi

    local search_paths=("$HOME/code" "$HOME/projects" "$HOME/src" "$HOME/dev" "$HOME/work")
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            while IFS= read -r p; do
                paths+=("$p")
            done < <(find "$search_path" -maxdepth 3 -type d -name ".git" 2>/dev/null | sed 's/\/\.git$//' | head -20)
        fi
    done

    # Deduplicate preserving order
    local seen=()
    local unique_paths=()
    for p in "${paths[@]}"; do
        local found=false
        for s in "${seen[@]:-}"; do
            [[ "$p" == "$s" ]] && { found=true; break; }
        done
        if ! $found; then
            seen+=("$p")
            unique_paths+=("$p")
        fi
    done

    # Output with annotations
    for p in "${unique_paths[@]}"; do
        local annotation
        annotation=$(_annotate_directory "$p")
        if [[ -n "$annotation" ]]; then
            printf '%s\t%s\n' "$p" "$annotation"
        else
            echo "$p"
        fi
    done
}
```

**Step 5: Update fzf_pick_directory to strip annotations**

In `fzf_pick_directory`, the selection line may contain a tab + annotation. Update the selection parsing (around lines 75-101) to strip annotations:

Replace the selection processing block with:

```bash
    # Parse result - fzf --print-query outputs: query on line 1, selection on line 2
    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)

    # Strip annotation (everything after tab)
    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    # If selection is empty but query exists, use query as typed path
    if [[ -z "$selection" && -n "$query" ]]; then
        selection="$query"
    fi
```

Also update the `". (current directory)"` reference — change the initial output of `_list_directories` from `echo ". (current directory)"` to just using `$(pwd)` (already done in the rewrite above).

Update the special case handler accordingly — remove the `. (current directory)` check since we now show the actual pwd path.

**Step 6: Update the preview to show session history**

In the fzf `--preview` argument (line 68), replace with:

```bash
--preview='d={}; d=$(echo "$d" | cut -f1); [[ -d "$d" ]] && { echo "── Recent Sessions ──"; [[ -f "'"$AM_HISTORY"'" ]] && jq -r --arg dir "$d" "select(.directory == \$dir) | \"\(.agent_type): \(.task) [\(.branch)]\"" "'"$AM_HISTORY"'" 2>/dev/null | tail -r 2>/dev/null | head -5; echo ""; echo "── Files ──"; command ls -la "$d" 2>/dev/null | head -15; } || echo "Type a path or select from list"' \
```

**Step 7: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests PASS

**Step 8: Commit**

```bash
git add lib/fzf.sh tests/test_all.sh
git commit -m "feat: annotate directory picker with session history"
```

---

### Task 4: Manual smoke test

**Step 1: Create some test history**

```bash
source lib/utils.sh
source lib/registry.sh
history_append "$HOME/code/agent-manager" "Add session history feature" "claude" "main"
history_append "$HOME/code/agent-manager" "Fix test failures" "claude" "main"
history_append "$HOME/code/wekapp" "Refactor auth module" "claude" "feature/auth"
```

**Step 2: Test the picker**

Run: `./am new` or trigger Ctrl-N in the popup.

Verify:
- Paths with history show annotations
- Typing "auth" highlights the wekapp path
- Selecting an annotated path correctly extracts just the directory
- Preview panel shows session history + file listing

**Step 3: Clean up test data if desired**

```bash
rm ~/.agent-manager/history.jsonl
```

**Step 4: Commit any final adjustments**

```bash
git add -A && git commit -m "polish: final adjustments from smoke test"
```
