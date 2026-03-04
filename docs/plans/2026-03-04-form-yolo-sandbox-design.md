# Design: Preview Fix, Yolo/Sandbox Split, New Session Form

Date: 2026-03-04

## 1. macOS Preview Fix

**Problem**: `sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }'` fails on macOS sed — compound blocks with semicolons aren't supported.

**Fix**: Split into per-command `-e` flags: `sed -e :a -e '/^[[:space:]]*$/{' -e '$d' -e N -e ba -e '}'`

**Files**: `lib/preview:54`, `am:peek_capture_output`

**Status**: Done.

## 2. Yolo / Sandbox Separation

### Current behavior
`--yolo` implies sandbox when docker is available. They are a single concept.

### New behavior
Two independent options:

| Option | Flag | Config key | Default | Effect |
|--------|------|-----------|---------|--------|
| Yolo mode | `--yolo` / `--no-yolo` | `default_yolo` | false | Agent permissive flag only |
| Sandbox | `--sandbox` / `--no-sandbox` | `default_sandbox` | false | Docker container isolation |

### Rules
- `--yolo` does NOT auto-enable sandbox
- `--sandbox` without docker available = hard error, session not created
- Both can be enabled independently or together
- Config defaults apply independently

### Rename
All UI references of "Permissive" / "permissive mode" become "Yolo" / "yolo mode".

### Files affected
- `lib/config.sh` — add `default_sandbox`, `am_default_sandbox_enabled()`, aliases, validation
- `lib/agents.sh` — `agent_launch()` takes separate `wants_sandbox` param; decouple the conditional
- `lib/fzf.sh` — form adds sandbox row; rename Permissive label to Yolo
- `am` — `--sandbox`/`--no-sandbox` flags, default application, help text
- `lib/tmux.sh` — status bar already shows yolo/sandbox independently (no change needed)

## 3. New Session Form Redesign

### Current problems
- Enter required to edit text fields (extra keypress)
- Preview panel wastes space duplicating form state
- Screen real estate underutilized

### New interaction model

| Key | Action |
|-----|--------|
| Enter | Create session (from any field) |
| Esc | Cancel |
| Space | Toggle checkboxes; cycle select options |
| Up/Down | Move between fields |
| Tab | Complete directory path |
| Typing | Edits current text field inline |

### Field types

**Directory (first row, 10-line area)**:
- Freeform text input at top
- 9 suggestion lines below, filtered by typed prefix
- Tab triggers path completion (reload suggestions)
- Embedded fzf_pick_directory behavior

**Text fields (task, worktree name)**:
- Inline editable — fzf query bar maps to field value
- `transform-query` syncs value on field change

**Select fields (agent, mode)**:
- Space cycles through options inline
- Current value shown in row

**Checkboxes (yolo, sandbox)**:
- Space toggles `[ ]` / `[x]`
- Sandbox shows `[disabled]` when docker unavailable; Space shows "Docker not available" message

### Layout
- No preview panel — full width for form
- Directory field: 10 lines (1 input + 9 suggestions)
- Remaining fields: 1 line each
- Submit row removed (Enter from any field creates session)

### Files affected
- `lib/fzf.sh` — `fzf_new_session_form()` rewrite, remove `_new_session_form_preview`, update `_new_session_form_rows`
