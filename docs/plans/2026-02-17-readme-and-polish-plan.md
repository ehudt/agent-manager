# README Uplift & Product Polish — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure README for end-user clarity, fix P0 UX issues, remove aider, migrate AINAV.md to AGENTS.md.

**Architecture:** All changes are to existing files. No new runtime code. README rewrite is the largest task; P0 polish items are small targeted edits to `am`, `lib/agents.sh`, and markdown files.

**Tech Stack:** Bash, Markdown

---

### Task 1: Remove aider from agent types

**Files:**
- Modify: `lib/agents.sh:15` (AGENT_COMMANDS array)
- Modify: `am:43` (usage help text)
- Modify: `am:185` (inline help text for new command, if present)

**Step 1: Edit lib/agents.sh — remove aider entry**

In `lib/agents.sh`, remove the `[aider]="aider"` line from the AGENT_COMMANDS array (line 15):

```bash
# BEFORE:
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [codex]="codex"
    [gemini]="gemini"
    [aider]="aider"
)

# AFTER:
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [codex]="codex"
    [gemini]="gemini"
)
```

**Step 2: Edit am — remove aider from usage() help text**

In `am`, line 43, change:
```
    -t, --type      Agent type: claude (default), codex, gemini, aider
```
to:
```
    -t, --type      Agent type: claude (default), codex, gemini
```

Also check line ~185 for a second help string and update similarly.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass (no aider tests exist).

**Step 4: Commit**

```bash
git add lib/agents.sh am
git commit -m "Remove aider agent type"
```

---

### Task 2: Rename AINAV.md to AGENTS.md and fix stale references

**Files:**
- Rename: `AINAV.md` → `AGENTS.md`
- Modify: `CLAUDE.md:5` (reference to AINAV.md)
- Modify: `AGENTS.md` (fix stale `fzf_preview()` reference → `lib/preview`)

**Step 1: Rename the file**

```bash
git mv AINAV.md AGENTS.md
```

**Step 2: Update CLAUDE.md reference**

In `CLAUDE.md`, line 5, change:
```
See AINAV.md for architecture, key functions, and extension points.
```
to:
```
See AGENTS.md for architecture, key functions, and extension points.
```

**Step 3: Fix stale function reference in AGENTS.md**

In `AGENTS.md`, in the Extension Points table, change:
```
| Change preview content | `lib/fzf.sh` → `fzf_preview()` |
```
to:
```
| Change preview content | `lib/preview` (standalone script) |
```

Also in the Key Functions section under **fzf:**, change:
```
- `fzf_preview(name)` - Renders preview panel
```
to:
```
- `lib/preview` - Standalone preview script for fzf panel
```

**Step 4: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add AINAV.md AGENTS.md CLAUDE.md
git commit -m "Rename AINAV.md to AGENTS.md (industry standard)"
```

---

### Task 3: Fix duplicate kill message (P0)

**Files:**
- Modify: `lib/agents.sh:289` (agent_kill_all function)

**Step 1: Remove the duplicate log_info from agent_kill_all**

In `lib/agents.sh`, the `agent_kill_all` function currently has:
```bash
agent_kill_all() {
    local session
    local count=0

    for session in $(tmux_list_am_sessions); do
        agent_kill "$session" && ((count++))
    done

    log_info "Killed $count sessions"
    echo "$count"
}
```

Remove the `log_info` line so only the caller (`cmd_kill` in `am`) handles the message:
```bash
agent_kill_all() {
    local session
    local count=0

    for session in $(tmux_list_am_sessions); do
        agent_kill "$session" && ((count++))
    done

    echo "$count"
}
```

**Step 2: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass.

**Step 3: Commit**

```bash
git add lib/agents.sh
git commit -m "Fix duplicate kill message in am kill --all"
```

---

### Task 4: Fix empty state and kill-all-with-no-sessions (P0)

**Files:**
- Modify: `am` — `cmd_status` function (~line 351)
- Modify: `am` — `cmd_kill` function (~line 298)

**Step 1: Improve cmd_status empty state**

In `am`, the `cmd_status` function currently shows "Active sessions: 0" with no guidance. After the `echo "Active sessions: $count"` line, add an else branch:

```bash
# BEFORE (lines ~361-366):
    if [[ $count -gt 0 ]]; then
        echo "${BOLD}Sessions:${RESET}"
        fzf_list_simple
    fi

# AFTER:
    if [[ $count -gt 0 ]]; then
        echo "${BOLD}Sessions:${RESET}"
        fzf_list_simple
    else
        echo "Run 'am new' to create your first session."
    fi
```

**Step 2: Skip confirmation in cmd_kill --all when no sessions exist**

In `am`, the `cmd_kill` function's `--all|-a` branch, add an early return:

```bash
# BEFORE:
        --all|-a)
            echo -n "Kill ALL agent-manager sessions? [y/N] "
            read -r answer

# AFTER:
        --all|-a)
            local session_count
            session_count=$(tmux_count_am_sessions)
            if [[ $session_count -eq 0 ]]; then
                log_info "No sessions to kill"
                return 0
            fi
            echo -n "Kill ALL agent-manager sessions? [y/N] "
            read -r answer
```

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass.

**Step 4: Commit**

```bash
git add am
git commit -m "Improve empty state messaging for status and kill --all"
```

---

### Task 5: Update help text with aliases and shortcuts (P0)

**Files:**
- Modify: `am:21-71` (usage function)

**Step 1: Rewrite the usage() function**

Replace the entire `usage()` function body with updated text that includes command aliases, short flags, and the `am <path>` shortcut:

```bash
usage() {
    cat <<'EOF'
am - Agent Manager v0.1.0

Manage multiple AI coding agent sessions with an interactive fzf interface.

USAGE:
    am [command] [options]

COMMANDS:
    (default)           Open interactive session browser
    list, ls            List all sessions
    list --json, -j     Output sessions as JSON
    new, create, n      Create a new agent session
    attach, a           Attach to a session by name (exact, prefix, or fuzzy)
    kill, rm, k         Kill a session
    kill --all, -a      Kill all agent-manager sessions
    info, i             Show detailed session info
    status, s           Show summary of all sessions
    help                Show this help message

SHORTCUT:
    am <path>           Same as 'am new <path>'

OPTIONS FOR 'new':
    -t, --type      Agent type: claude (default), codex, gemini
    -n, --name      Custom task description
    -d, --dir       Directory (can also be positional arg)
    --yolo          Enable permissive mode (mapped per agent, uses sb sandbox)
    --              Pass remaining args to agent (e.g., -- --resume)

KEYBINDINGS (interactive browser):
    Enter           Attach to selected session
    Ctrl-N          Create new session (interactive: directory → mode → agent)
    Ctrl-X          Kill selected session
    Ctrl-R          Refresh session list
    Ctrl-P          Toggle preview panel
    Ctrl-J/K        Scroll preview up/down
    Ctrl-D/U        Scroll preview half-page down/up
    ?               Show inline help

KEYBINDINGS (inside tmux session):
    Prefix + a      Switch to last am session
    Prefix + s      Open am browser popup
    Prefix + d      Detach from session
    Prefix ↑/↓      Switch panes (agent/shell)
    :am             Open am browser (tmux command)

EXAMPLES:
    am                              # Open interactive browser
    am new                          # New claude session in current dir
    am new ~/code/myproject         # New session in specific directory
    am new -t codex ~/code/proj     # New codex session
    am new -n "fix auth" .          # Session with task description
    am attach am-abc123             # Attach to session by name
    am kill am-abc123               # Kill specific session

DEPENDENCIES:
    tmux >= 3.0, fzf >= 0.40, jq, git

CONFIGURATION:
    Sessions stored in: ~/.agent-manager/
    See README for tmux keybinding setup.

EOF
}
```

**Step 2: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass.

**Step 3: Commit**

```bash
git add am
git commit -m "Update help text with command aliases and all keybindings"
```

---

### Task 6: Rewrite README.md

This is the largest task. Rewrite the full README following the structure from the design doc. The full content is provided below.

**Files:**
- Rewrite: `README.md`

**Step 1: Write the new README.md**

Replace the entire file with the new content. The structure is:

1. **Header + tagline** — one-liner + bullet features
2. **Installation** — concise: prerequisites, install, verify, link to config section
3. **Quick Start** — 5 commands
4. **Browsing Sessions** — ASCII mockup + full keybinding table
5. **Creating Sessions** — interactive flow docs + CLI flags
6. **Inside a Session** — pane layout + tmux keybindings combined
7. **Agent Types** — table (no aider)
8. **Advanced Features** — zoxide, sandbox, Claude titles, resume/continue
9. **Commands Reference** — one authoritative table
10. **Configuration** — tmux config, install options, session storage
11. **Troubleshooting**
12. **Development**
13. **License**

Key content guidelines:
- The ASCII mockup from the current README (lines 139-155) is good — keep it.
- The tmux config snippet currently at the top moves to the Configuration section.
- Remove the `config.yaml # (future)` line from the directory listing.
- All fzf keybindings in one table (including Ctrl-J/K/D/U for preview scroll).
- NEW section: Interactive Creation Flow documenting the 3-step picker (directory → mode → agent).
- NEW section: Advanced Features documenting zoxide, sandbox, Claude title extraction, resume/continue.
- Commands Reference: single flat table with command, aliases, flags, and description.
- No aider mentions anywhere.

**Step 2: Review the README**

Visually scan for:
- Broken markdown (tables, code blocks)
- Missing sections from the design
- Any remaining aider references
- Any remaining config.yaml references

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All pass (README changes don't affect tests).

**Step 4: Commit**

```bash
git add README.md
git commit -m "Rewrite README with product-first structure"
```

---

### Task 7: Final verification

**Step 1: Run full test suite**

Run: `./tests/test_all.sh`
Expected: All pass.

**Step 2: Grep for stale references**

Search for any remaining references to "aider", "AINAV", or "config.yaml" across the codebase:

```bash
grep -r "aider" --include="*.sh" --include="*.md" .
grep -r "AINAV" .
grep -r "config\.yaml" .
```

Expected: No matches (except possibly in the design doc, which is fine).

**Step 3: Verify am help output**

```bash
./am help
```

Expected: Updated help text with aliases, all keybindings, no aider.

**Step 4: Commit any fixes if needed**

Only if stale references were found.
