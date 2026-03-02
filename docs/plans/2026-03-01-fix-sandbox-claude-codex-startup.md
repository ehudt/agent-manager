# Fix Claude Hang & Codex Permission Errors in Sandbox

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Claude Code and Codex CLI fully functional inside sandbox containers by fixing directory ownership and mount writability issues.

**Architecture:** Two root causes, both in the container startup chain. (1) `~/.claude/` is bind-mounted read-only, but Claude Code must write session state during init. Fix: mount it read-write. (2) `--cap-drop=ALL` removes `CAP_CHOWN`, so the entrypoint cannot fix `root:root` ownership on directories Docker auto-creates for file-bind-mounts. Fix: add `CAP_CHOWN` and `CAP_FOWNER` to the container, and harden `ensure_dir` to explicitly chown as a fallback.

**Tech Stack:** Bash (sb CLI, entrypoint.sh), Docker

---

## Diagnosis Summary

### Claude hangs indefinitely
- `~/.claude/` mounted `:ro` at `sb` line 220
- Claude must write to `~/.claude/` during init (session state, history, telemetry)
- Read-only mount causes silent infinite hang — no error, no output
- Proven: `HOME=/tmp/writable-copy` → Claude responds instantly

### Codex "os error 13"
- `sb` mounts individual files (`config.toml`, `auth.json`) into `$HOME/.codex/`
- Docker auto-creates `$HOME/.codex/` as `root:root` to host file-bind-mounts
- Entrypoint's `ensure_dir` tries `install -d -o user`, fails silently (no `CAP_CHOWN`)
- `.codex/` and `.codex/tmp/` stay `root:root`, user gets EACCES

---

## Task 1: Mount `~/.claude/` read-write

The `:ro` flag on the `~/.claude/` mount prevents Claude from writing session state. Remove it.

**Files:**
- Modify: `sb` (the `ensure_running` function, around line 220)

**Step 1: Write a test script to verify the current broken behavior**

Create `tests/test_claude_mount.sh`:

```bash
#!/bin/bash
# Test: ~/.claude/ must be writable inside the container
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

HOST_USER=$(id -un)

echo "TEST: ~/.claude/ is writable..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.claude/.sb-write-test" && rm "$HOME/.claude/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.claude/ is writable"
else
  echo "FAIL: ~/.claude/ is read-only"
  exit 1
fi
```

**Step 2: Run test to verify it fails against a current container**

Run: `bash tests/test_claude_mount.sh sb-agent-manager-7g5dae`
Expected: `FAIL: ~/.claude/ is read-only`

**Step 3: Fix the mount flag in `sb`**

In `sb`, in the `ensure_running` function, change the `~/.claude/` mount from `:ro` to read-write.

Find this line (around line 220):
```bash
MOUNTS+=(-v "$claude_dir_src:$HOME/.claude:ro")
```

Change to:
```bash
MOUNTS+=(-v "$claude_dir_src:$HOME/.claude")
```

**Step 4: Recreate the container and verify**

To test, you need to clean the existing container and start fresh:
```bash
./sb /home/ehud/code/agent-manager --clean
./sb /home/ehud/code/agent-manager --start
```
Then run: `bash tests/test_claude_mount.sh <new-container-name>`
Expected: `PASS: ~/.claude/ is writable`

**Step 5: Verify Claude actually works**

```bash
CONTAINER=$(docker ps --filter "label=agent-sandbox.dir=/home/ehud/code/agent-manager" --format '{{.Names}}' | head -1)
docker exec -u $(id -un) "$CONTAINER" timeout 15 claude -p "say hi" 2>&1
```
Expected: Claude responds with text (not a timeout/hang).

**Step 6: Commit**

```bash
git add sb tests/test_claude_mount.sh
git commit -m "fix: mount ~/.claude/ read-write so Claude Code can write session state

Claude Code hangs indefinitely during initialization when ~/.claude/ is
read-only because it must write session state, history, and telemetry.
Removing the :ro flag allows Claude to start normally."
```

---

## Task 2: Add `CAP_CHOWN` and `CAP_FOWNER` capabilities

`--cap-drop=ALL` removes every capability including `CAP_CHOWN` and `CAP_FOWNER`, which the entrypoint needs to fix directory ownership on paths Docker auto-creates as `root:root`.

**Files:**
- Modify: `sb` (the `ensure_running` function, around line 274)

**Step 1: Write a test script to verify capability presence**

Create `tests/test_cap_chown.sh`:

```bash
#!/bin/bash
# Test: container must have CAP_CHOWN so entrypoint can fix ownership
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

echo "TEST: CAP_CHOWN is available..."
# Bit 0 = CAP_CHOWN. CapPrm must have bit 0 set.
cap_prm=$(docker exec "$CONTAINER" sh -c 'cat /proc/1/status | grep CapPrm | awk "{print \$2}"')
# Convert hex to check bit 0
chown_bit=$(python3 -c "print(int('$cap_prm', 16) & 1)")
if [ "$chown_bit" = "1" ]; then
  echo "PASS: CAP_CHOWN is present"
else
  echo "FAIL: CAP_CHOWN is missing (CapPrm=$cap_prm)"
  exit 1
fi

echo "TEST: CAP_FOWNER is available..."
# Bit 3 = CAP_FOWNER
fowner_bit=$(python3 -c "print((int('$cap_prm', 16) >> 3) & 1)")
if [ "$fowner_bit" = "1" ]; then
  echo "PASS: CAP_FOWNER is present"
else
  echo "FAIL: CAP_FOWNER is missing (CapPrm=$cap_prm)"
  exit 1
fi
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test_cap_chown.sh sb-agent-manager-7g5dae`
Expected: `FAIL: CAP_CHOWN is missing`

**Step 3: Add capabilities in `sb`**

In `sb`, in the `ensure_running` function, after `--cap-drop=ALL`, add back the two capabilities the entrypoint needs.

Find (around line 274):
```bash
local RUN_OPTS=(
    --pids-limit "$sb_pids_limit"
    --memory "$sb_memory_limit"
    --cpus "$sb_cpus_limit"
    --cap-drop=ALL
)
```

Change to:
```bash
local RUN_OPTS=(
    --pids-limit "$sb_pids_limit"
    --memory "$sb_memory_limit"
    --cpus "$sb_cpus_limit"
    --cap-drop=ALL
    --cap-add=CHOWN
    --cap-add=FOWNER
)
```

**Step 4: Recreate container and verify capabilities**

```bash
./sb /home/ehud/code/agent-manager --clean
./sb /home/ehud/code/agent-manager --start
CONTAINER=$(docker ps --filter "label=agent-sandbox.dir=/home/ehud/code/agent-manager" --format '{{.Names}}' | head -1)
bash tests/test_cap_chown.sh "$CONTAINER"
```
Expected: Both PASS.

**Step 5: Commit**

```bash
git add sb tests/test_cap_chown.sh
git commit -m "fix: add CAP_CHOWN and CAP_FOWNER so entrypoint can fix ownership

--cap-drop=ALL removes CAP_CHOWN, preventing the entrypoint from fixing
root:root ownership on directories Docker auto-creates for file-bind-mounts.
Adding these two narrow capabilities lets the entrypoint chown .codex/ and
similar directories while keeping all other capabilities dropped."
```

---

## Task 3: Harden `ensure_dir` to chown explicitly and log failures

The current `ensure_dir` in `entrypoint.sh` silently swallows errors via `2>/dev/null`. If `install -d` fails, the fallback `mkdir -p` doesn't set ownership. Add an explicit `chown` fallback and log failures.

**Files:**
- Modify: `entrypoint.sh` (the `ensure_dir` function, lines 22-29)

**Step 1: Write a test to verify .codex ownership is correct**

Create `tests/test_codex_permissions.sh`:

```bash
#!/bin/bash
# Test: ~/.codex/ and ~/.codex/tmp/ must be writable by the runtime user
set -e

CONTAINER="$1"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container-name>"
  exit 1
fi

HOST_USER=$(id -un)

echo "TEST: ~/.codex/ is writable by $HOST_USER..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.codex/.sb-write-test" && rm "$HOME/.codex/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.codex/ is writable"
else
  echo "FAIL: ~/.codex/ is not writable by $HOST_USER"
  exit 1
fi

echo "TEST: ~/.codex/tmp/ is writable by $HOST_USER..."
if docker exec -u "$HOST_USER" "$CONTAINER" sh -c 'touch "$HOME/.codex/tmp/.sb-write-test" && rm "$HOME/.codex/tmp/.sb-write-test"' 2>/dev/null; then
  echo "PASS: ~/.codex/tmp/ is writable"
else
  echo "FAIL: ~/.codex/tmp/ is not writable by $HOST_USER"
  exit 1
fi
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test_codex_permissions.sh sb-agent-manager-7g5dae`
Expected: `FAIL: ~/.codex/ is not writable`

**Step 3: Fix `ensure_dir` in `entrypoint.sh`**

Replace the current `ensure_dir` function (lines 22-29):

```bash
ensure_dir() {
    local path="$1"
    shift

    if ! install -d "$@" "$path" 2>/dev/null; then
        mkdir -p "$path"
    fi
}
```

With:

```bash
ensure_dir() {
    local path="$1"
    shift

    # Parse -o and -g flags for ownership fallback
    local owner="" group=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) owner="$2"; args+=("$1" "$2"); shift 2 ;;
            -g) group="$2"; args+=("$1" "$2"); shift 2 ;;
            *)  args+=("$1"); shift ;;
        esac
    done

    if ! install -d "${args[@]}" "$path" 2>/dev/null; then
        mkdir -p "$path" 2>/dev/null || true
        # Explicit chown/chmod fallback
        if [ -n "$owner" ] && [ -n "$group" ]; then
            chown "$owner:$group" "$path" 2>/dev/null || echo "Warning: cannot chown $path to $owner:$group" >&2
        fi
        for arg in "${args[@]}"; do
            case "$arg" in
                -m) ;;  # next arg is mode, handled below
                [0-9]*) chmod "$arg" "$path" 2>/dev/null || true ;;
            esac
        done
    fi
}
```

**Step 4: Recreate container and verify**

```bash
./sb /home/ehud/code/agent-manager --clean
./sb /home/ehud/code/agent-manager --start
CONTAINER=$(docker ps --filter "label=agent-sandbox.dir=/home/ehud/code/agent-manager" --format '{{.Names}}' | head -1)
bash tests/test_codex_permissions.sh "$CONTAINER"
```
Expected: Both PASS.

**Step 5: Verify Codex no longer shows "os error 13"**

```bash
docker exec -u $(id -un) "$CONTAINER" codex --version 2>&1
```
Expected: Version output WITHOUT the `WARNING: proceeding, even though we could not update PATH: Permission denied (os error 13)` line.

**Step 6: Commit**

```bash
git add entrypoint.sh tests/test_codex_permissions.sh
git commit -m "fix: harden ensure_dir with explicit chown fallback and warnings

ensure_dir silently swallowed install -d failures via 2>/dev/null, and the
mkdir -p fallback never set ownership. Now it explicitly calls chown as a
fallback and logs a warning if that also fails."
```

---

## Task 4: End-to-end verification

Run all three test scripts and manually verify both tools work.

**Files:**
- None (verification only)

**Step 1: Run all test scripts**

```bash
CONTAINER=$(docker ps --filter "label=agent-sandbox.dir=/home/ehud/code/agent-manager" --format '{{.Names}}' | head -1)
bash tests/test_claude_mount.sh "$CONTAINER"
bash tests/test_cap_chown.sh "$CONTAINER"
bash tests/test_codex_permissions.sh "$CONTAINER"
```
Expected: All PASS.

**Step 2: Verify Claude works end-to-end**

```bash
docker exec -u $(id -un) "$CONTAINER" timeout 15 claude -p "say hi" 2>&1
```
Expected: Claude responds with text within seconds.

**Step 3: Verify Codex works end-to-end**

```bash
docker exec -u $(id -un) "$CONTAINER" codex --version 2>&1
```
Expected: Clean version output, no "os error 13" warning.

**Step 4: Verify security posture is still tight**

```bash
# Confirm all caps except CHOWN, FOWNER, NET_ADMIN are still dropped
docker exec "$CONTAINER" sh -c 'cat /proc/1/status | grep CapPrm'
# Expected: 0x0000000000001009 (bits 0=CHOWN, 3=FOWNER, 12=NET_ADMIN)

# Confirm no-new-privileges is still set
docker inspect "$CONTAINER" --format '{{json .HostConfig.SecurityOpt}}'
# Expected: ["no-new-privileges:true"]
```

**Step 5: Commit test scripts and final cleanup**

```bash
git add tests/
git commit -m "test: add sandbox startup verification scripts for Claude and Codex"
```
