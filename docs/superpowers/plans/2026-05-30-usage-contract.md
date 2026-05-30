# Usage Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Bring implementation, tests, and user-facing help/docs into alignment with the updated `am usage()` contract.

**Architecture:** Treat the edited top-level `usage()` output in `am` as the public CLI contract. Preserve hidden/backward-compatible behavior unless it contradicts documented behavior, while updating public help surfaces and tests to match the shorter command and keybinding surface.

**Tech Stack:** Bash CLI, tmux/fzf integration, Go Bubble Tea browser, shell tests, Go tests.

---

### Task 1: Core CLI Behavior

**Files:**
- Modify: `am`
- Test: `tests/test_cli.sh`
- Test: `tests/test_state.sh` only if JSON state coverage changes

- [x] **Step 1: Add failing tests for `peek --lines`**

Add coverage in `tests/test_cli.sh` showing that `am peek --lines 1 --pane shell <session>` returns only the requested tail content for a plain snapshot.

- [x] **Step 2: Add failing tests for public subcommand help**

Assert `am new --help`, `am send --help`, and `am peek --help` match the shorter public surface: no public yolo/no-yolo/no-worktree in new help, no public wait/timeout in send help, and no public json/history/grep in peek help.

- [x] **Step 3: Add failing test for detailed `status <session>`**

Assert non-json `am status <session>` includes detailed session info such as `Directory:` plus a readable `State:` line.

- [x] **Step 4: Implement minimal CLI changes**

Update `peek_capture_output`, follow helpers, and `cmd_peek` so `--lines` affects plain snapshots and follow output. Update command help text. Change single-session non-json `cmd_status` to show detailed info plus state. Preserve hidden flags unless the tests intentionally remove public advertising only.

- [x] **Step 5: Verify**

Run:

```bash
bash -n lib/*.sh am
./tests/test_all.sh --summary
```

### Task 2: Browser/Fzf Help And README

**Files:**
- Modify: `cmd/am-browse/main.go`
- Modify: `cmd/am-browse/browse_test.go`
- Modify: `lib/fzf.sh`
- Modify: `README.md`

- [x] **Step 1: Update Go browser help**

Shorten `helpText()` to remove hidden restore/preview controls while keeping core navigation visible: Up/Down, Enter, Esc/q, Ctrl-N, Ctrl-X, Ctrl-R, `?`, and tmux Prefix + 1-9.

- [x] **Step 2: Update browser help tests**

Adjust `cmd/am-browse/browse_test.go` so it expects only the public keybindings.

- [x] **Step 3: Update fallback fzf public help**

Shorten the fallback help/header text in `lib/fzf.sh` to the same public surface, while preserving hidden binds.

- [x] **Step 4: Update README**

Remove public command aliases from the command table, remove the documented `am <path>` shortcut, replace public `am peek --json` examples with plain `am peek --lines N`, and trim the browser keybinding table to match the corrected inline help surface.

- [x] **Step 5: Verify**

Run:

```bash
bash -n lib/*.sh am
go test ./cmd/am-browse
```

### Task 3: Extra Args And Hidden Manager Flags

**Files:**
- Modify: `am`
- Test: `tests/test_cli.sh`

- [x] **Step 1: Add failing test for manager flags before `--`**

Add a CLI test proving `am new --sandbox ... -- extra-args` preserves manager flags parsed before `--` instead of replacing them with extra agent args.

- [x] **Step 2: Implement minimal parser fix**

Keep manager-controlled flags, especially sandbox/yolo state, separate from passthrough agent args so parsing `--` cannot drop earlier manager state.

- [x] **Step 3: Verify**

Run:

```bash
bash -n lib/*.sh am
./tests/test_all.sh --summary
```

### Task 4: Integration Review

**Files:**
- Review all changed files

- [x] **Step 1: Inspect diffs**

Run `git diff --stat` and review every changed hunk for accidental public-contract drift.

- [x] **Step 2: Resolve conflicts or overlaps**

Keep user-authored `usage()` wording as the source of truth. Preserve hidden compatibility where possible.

- [x] **Step 3: Final verification**

Run:

```bash
bash -n lib/*.sh am
go test ./cmd/am-browse
./tests/test_all.sh --summary
```
