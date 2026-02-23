# Session History in Directory Picker

## Problem

When creating a new session via Ctrl-N, the directory picker shows paths without context. Users remember *what* they worked on (task/feature name), not *where* (directory path). Session data is GC'd when tmux dies, so past work context is lost.

## Solution: Annotated Directory Picker

Add a persistent session history log. Annotate directory picker paths with recent session task names, making them searchable by feature name via fzf.

## Design

### Session History Storage

**File:** `~/.agent-manager/history.jsonl` (one JSON object per line)

```json
{"directory":"/Users/ehud/code/agent-manager","task":"Add session history","agent_type":"claude","branch":"main","created_at":"2026-02-22T10:00:00Z"}
```

**When to write:**
- After `auto_title_session` generates a title (agents.sh ~line 291), alongside `registry_update`
- On session launch when user provides an explicit task (agents.sh ~line 148)

**Pruning:** `history_prune` drops entries older than 7 days. Called on each append. At heavy usage (~20 sessions/day) that's ~140 lines max.

### New Functions (registry.sh)

- `history_append <directory> <task> <agent_type> <branch>` - append line + prune
- `history_prune` - remove entries older than 7 days
- `history_for_directory <path>` - return recent sessions for a given path

### Annotated Directory Picker (fzf.sh)

`_list_directories` annotates each path with recent session info:

```
~/code/agent-manager    claude: "Add session history" (2h) | claude: "Fix tests" (1d)
~/code/wekapp           claude: "Refactor auth" (3h)
~/code/tools
. (current directory)
```

- Annotations are display-only; selection extracts just the path
- Multiple sessions per path separated by `|`, most recent first, capped at 2-3
- Delimiter between path and annotations allows clean extraction

### Enhanced Preview Panel

Preview shows session history above file listing:

```
── Recent Sessions ──
claude: "Add session history" (2h ago) [main]
claude: "Fix tests" (1d ago) [feature/tests]

── Files ──
drwxr-xr-x  lib/
-rw-r--r--  CLAUDE.md
```

## Files Changed

| File | Change |
|---|---|
| `lib/registry.sh` | Add `history_append`, `history_prune`, `history_for_directory`, `AM_HISTORY` |
| `lib/agents.sh` | Call `history_append` after auto-title and on explicit-task launch |
| `lib/fzf.sh` | Annotate paths in `_list_directories`, strip annotations in `fzf_pick_directory`, enhance preview |
| `tests/test_all.sh` | Tests for history functions and annotated picker output |

No new dependencies. No changes to session lifecycle or GC.
