# README Uplift & Product Polish Design

Date: 2026-02-17

## Overview

Restructure README.md around the user journey and fix product/UX rough edges before launch.

## Decisions

- **Audience**: End-users first
- **Scope**: All features documented, but organized so core workflow dominates and advanced features don't clutter
- **Polish scope**: Both docs/presentation and code-level UX improvements
- **Approach**: Product-first README (Approach A) with install near top
- **AINAV.md**: Rename to AGENTS.md (industry standard, auto-discovered by agents)
- **Aider**: Remove agent support

## README Structure

```
# Agent Manager (am)
<tagline: "Manage multiple AI coding agents from one terminal. Tmux + fzf powered.">

## Installation                   ← Concise: prerequisites, clone, install, verify
  ### Prerequisites
  ### Install
  ### Verify
  (link to Configuration section for tmux bindings and install options)

## Quick Start                    ← 4-5 commands showing the happy path

## Browsing Sessions              ← fzf browser keybindings (core daily UX)
  - ASCII mockup (keep existing)
  - Full keybinding table including Ctrl-J/K/D/U for preview scrolling

## Creating Sessions
  ### Interactive Creation Flow   ← NEW: document 3-step flow
    - Directory picker (tab complete, Ctrl-U parent, zoxide if available)
    - Mode picker (new / resume / continue / yolo variants)
    - Agent picker
  ### CLI Usage                   ← am new flags and examples

## Inside a Session               ← Combined: pane layout + tmux keybindings
  - Pane layout diagram
  - Prefix+a (switch last), Prefix+s (browser popup), Prefix+d (detach)
  - Prefix Up/Down (switch panes), :am command alias

## Agent Types                    ← Table (no aider)
  | Agent   | Command  | --yolo flag                      |
  |---------|----------|----------------------------------|
  | claude  | claude   | --dangerously-skip-permissions   |
  | codex   | codex    | --yolo                           |
  | gemini  | gemini   | --yolo                           |

## Advanced Features
  - Zoxide integration (frecent directories in picker)
  - Sandbox (sb) integration (auto-started with --yolo when sb is on PATH)
  - Claude session title extraction (shows first user message in preview)
  - Resume/continue modes (pass --resume or --continue to agent)

## Commands Reference             ← One flat table
  | Command | Aliases | Flags | Description |
  All commands, all aliases, all flags in one place.

## Configuration
  ### tmux Keybindings            ← The full config snippet (moved from top)
  ### Install Options             ← All install.sh flags
  ### Session Storage             ← ~/.agent-manager/ structure

## Troubleshooting
## Development
## License
```

## Product/UX Polish

### P0 - Fix Before Launch

1. **Duplicate kill message**: `am kill --all` prints "Killed N sessions" twice.
   - Fix: Remove `log_info` from `agent_kill_all`; let `cmd_kill` handle the message.

2. **Remove config.yaml reference**: README mentions future `config.yaml` that doesn't exist.
   - Fix: Remove from config directory listing.

3. **Empty state**: `am status` with no sessions just shows "Active sessions: 0".
   - Fix: Add "No sessions. Run 'am new' to create one."

4. **Kill --all with no sessions**: Asks for confirmation when there's nothing to kill.
   - Fix: Skip confirmation, just say "No sessions to kill."

5. **Help text completeness**: Missing aliases, short flags, `am <path>` shortcut.
   - Fix: Update help function in `am` to show all aliases and shortcuts.

6. **Remove aider agent type**: Drop from AGENT_COMMANDS array, YOLO_FLAGS, and help text.

7. **Rename AINAV.md to AGENTS.md**: Update CLAUDE.md reference.

8. **Fix AGENTS.md stale reference**: `fzf_preview()` no longer exists (now `lib/preview`).

### P1 - Soon After Launch

9. **Install hints in errors**: When tmux/fzf/jq not found, show install command for detected OS.

10. **`am attach` suggest list**: When no match found, suggest "Run 'am list' to see sessions."

11. **kill-and-switch silent failure**: Add error message when no argument given.

12. **Unknown agent type flow**: Combine warn + error into one clear message listing supported agents.

### P2 - Nice to Have

13. **Preview height responsiveness**: Use `$FZF_PREVIEW_LINES` instead of hardcoded 33.

14. **fzf_list_json guard**: Handle empty activity/created fields to prevent jq tonumber error.

15. **First-run welcome**: Show welcome message when user presses Esc on empty state placeholder.

16. **Consistent confirmation style**: Use logging framework for kill --all prompt.

17. **Clean up --task alias**: Either document or remove the hidden `--task` synonym for `--name`.
