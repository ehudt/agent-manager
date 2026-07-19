# Pi Agent Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full support for the `pi` coding agent in agent-manager: launch, state detection, restore, auto-titling, install wiring, sandbox, tests, and a live-lab runner.

**Architecture:** Pi state detection is driven by a pi *extension* (`lib/hooks/am-state.ts`, TypeScript, in-process) that maps pi lifecycle events (`session_start`, `agent_start`, `agent_settled`) to writes of `$AM_STATE_DIR/<session>` — the same state-file contract the Claude hook uses. The resolver trusts pi's state file **ungated** (an in-process extension can't go silently stale; a dead pi drops the pane to a shell, which the shell-pane check catches). Restore/titling reuse the sessions-log machinery with agent-aware helpers dispatching between Claude's `~/.claude/projects/<enc>/<sid>.jsonl` and pi's `~/.pi/agent/sessions/<enc>/<ts>_<sid>.jsonl`.

**Tech Stack:** bash (lib/*.sh), Go (internal/sessions, cmd/am-browse), TypeScript (pi extension), Docker (sandbox), jq.

**Spec:** `docs/superpowers/specs/2026-07-19-pi-agent-support-design.md`

## Global Constraints

- Pi has NO yolo flag: `agent_get_yolo_flag pi` returns empty; `--yolo` on a pi session is a silent no-op.
- Pi state vocabulary: `starting|running|waiting_input|idle|dead|unknown` only. Never `waiting_permission`/`waiting_custom`/`waiting_background`.
- No pane-content heuristics for state (project doctrine). No title-glyph layer for pi.
- State-file writes are transition-only (mtime pins state-entry time for tab ages).
- Pi cwd encoding: `"--" + resolved_path_without_leading_slash with [/\:] → "-" + "--"` (e.g. `/Users/x/code/proj` → `--Users-x-code-proj--`). Dots are PRESERVED (unlike Claude's encoding).
- Pi session filename: `<timestamp>_<uuid>.jsonl`; sid = part after the last `_`, `.jsonl` stripped. Timestamps contain `-` but never `_`.
- Pi resume command: `pi --session <sid>`. Claude's: `claude --resume <sid>`.
- Sourced libs: no shebang, no `set -euo pipefail`. Functions prefixed by module. Logging to stderr. `sed -E` only (macOS + Linux portability). `stat -c %Y || stat -f %m` pattern for mtime.
- Run `./tests/test_all.sh --summary` before each commit; also `bash -n lib/*.sh am` for syntax.
- Never add a Co-Authored-By trailer to commits.
- Env override vars used by tests: `AM_STATE_DIR`, `AM_REGISTRY`, `AM_DIR`, `HOME` (tests point HOME at a temp dir). New override: `AM_PI_SESSIONS_DIR` (default `$HOME/.pi/agent/sessions`).

---

### Task 1: Launch support (lib/agents.sh)

**Files:**
- Modify: `lib/agents.sh` (AGENT_COMMANDS, `_agent_prompt_as_arg`, `agent_get_yolo_flag`, `agent_supports_worktree`, `agent_worktree_root`, the yolo-append site in `agent_launch`, the `sessions_log_append` gate in `agent_launch`)
- Test: `tests/test_agents.sh`

**Interfaces:**
- Produces: `agent_type_supported pi` → true; `agent_get_command pi` → `pi`; `_agent_prompt_as_arg pi` → 0; `agent_get_yolo_flag pi` → ""; `agent_worktree_root <dir> pi` → `<dir>/.pi/worktrees`. Later tasks assume `pi` is a first-class agent type.

- [ ] **Step 1: Write failing tests** — append to the end of the main test function in `tests/test_agents.sh` (follow the file's existing assert style):

```bash
    # --- pi agent type ---
    assert_eq "pi" "$(agent_get_command pi)" "agent_get_command: pi"
    agent_type_supported pi && pass "agent_type_supported: pi" || fail "agent_type_supported: pi"
    _agent_prompt_as_arg pi && pass "_agent_prompt_as_arg: pi takes prompt as arg" \
        || fail "_agent_prompt_as_arg: pi takes prompt as arg"
    assert_eq "" "$(agent_get_yolo_flag pi)" "agent_get_yolo_flag: pi has no yolo flag"
    agent_supports_worktree pi && pass "agent_supports_worktree: pi" || fail "agent_supports_worktree: pi"
    agent_cli_manages_worktree pi && fail "agent_cli_manages_worktree: pi is am-managed" \
        || pass "agent_cli_manages_worktree: pi is am-managed"
    assert_eq "/tmp/x/.pi/worktrees" "$(agent_worktree_root /tmp/x pi)" "agent_worktree_root: pi"
```

(If the file uses `assert_true`/direct asserts rather than pass/fail, match its local convention — read the top of the file first.)

- [ ] **Step 2: Run to verify failures**

Run: `bash tests/test_all.sh --summary 2>&1 | grep -i "pi"`
Expected: FAIL lines for the new assertions.

- [ ] **Step 3: Implement** in `lib/agents.sh`:

```bash
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [codex]="codex"
    [pi]="pi"
)
```

```bash
_agent_prompt_as_arg() {
    case "$1" in
        codex|pi) return 0 ;;
        *) return 1 ;;
    esac
}
```

In `agent_get_yolo_flag`, add before the catch-all (pi has no permission
system — `am new --yolo -a pi` must be a silent no-op):

```bash
        pi) echo "" ;;
```

In `agent_supports_worktree`: `claude|codex|pi) return 0 ;;`

In `agent_worktree_root`, add case: `pi) echo "$directory/.pi/worktrees" ;;`

In `agent_launch`, replace the yolo-append block:

```bash
    if $wants_yolo; then
        local _yolo_flag
        _yolo_flag=$(agent_get_yolo_flag "$agent_type")
        [[ -n "$_yolo_flag" ]] && normalized_args+=("$_yolo_flag")
    fi
```

Also in `agent_launch`, widen the sessions-log gate:

```bash
    # Append to sessions log for restore support (Claude and pi)
    if [[ "$agent_type" == "claude" || "$agent_type" == "pi" ]]; then
        sessions_log_append "$session_name" "$directory" "$branch" "$agent_type" "$task"
    fi
```

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/test_all.sh --summary`
Expected: no failures.

- [ ] **Step 5: Commit**

```bash
git add lib/agents.sh tests/test_agents.sh
git commit -m "Add pi as a first-class agent type (launch, worktree, no-yolo)"
```

---

### Task 2: Agent-aware sessions-log helpers + pi first-user-message (bash)

**Files:**
- Modify: `lib/registry.sh` (add `_slog_encode_pi_dir`, `_pi_sessions_root`; make `_sessions_log_jsonl_exists`, `_sessions_log_detect_id`, `_sessions_log_detect_id_for_session`, `_sessions_log_dir_is_shared` agent-aware via a trailing optional `[agent_type]` param defaulting to `claude`)
- Modify: `lib/utils.sh` (add `pi_first_user_message`)
- Test: `tests/test_registry.sh`, `tests/test_utils.sh`

**Interfaces:**
- Produces (used by Tasks 3, 7):
  - `_slog_encode_pi_dir <path>` → encoded dir name (stdout)
  - `_pi_sessions_root` → `${AM_PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}` (stdout)
  - `_sessions_log_jsonl_exists <dir> <sid> [agent]` → exit 0/1
  - `_sessions_log_detect_id <dir> [not_before_iso] [agent]` → sid (stdout)
  - `_sessions_log_detect_id_for_session <name> <dir> [created_at] [agent]` → sid (stdout)
  - `_sessions_log_dir_is_shared <name> <dir> [agent]` → exit 0/1
  - `pi_first_user_message <dir> [sid] [strict]` → cleaned text (stdout)

- [ ] **Step 1: Write failing tests.** In `tests/test_registry.sh` (inside its test function, using a temp HOME):

```bash
    # --- pi sessions-log helpers ---
    assert_eq "--Users-x.y-code-proj--" "$(_slog_encode_pi_dir /Users/x.y/code/proj)" \
        "_slog_encode_pi_dir: slashes to dashes, dots preserved, wrapped"

    local pi_home
    pi_home=$(mktemp -d)
    local pi_dir="$pi_home/proj"
    mkdir -p "$pi_dir"
    local resolved_pi_dir
    resolved_pi_dir=$(cd "$pi_dir" && pwd -P)
    local enc
    enc=$(_slog_encode_pi_dir "$resolved_pi_dir")
    export AM_PI_SESSIONS_DIR="$pi_home/.pi/agent/sessions"
    mkdir -p "$AM_PI_SESSIONS_DIR/$enc"
    touch "$AM_PI_SESSIONS_DIR/$enc/2026-07-19T08-00-00-000Z_0199aaaa-bbbb-cccc-dddd-eeeeffff0001.jsonl"

    _sessions_log_jsonl_exists "$pi_dir" "0199aaaa-bbbb-cccc-dddd-eeeeffff0001" "pi" \
        && pass "pi jsonl exists" || fail "pi jsonl exists"
    _sessions_log_jsonl_exists "$pi_dir" "0199aaaa-bbbb-cccc-dddd-eeeeffff9999" "pi" \
        && fail "pi jsonl missing sid" || pass "pi jsonl missing sid"

    assert_eq "0199aaaa-bbbb-cccc-dddd-eeeeffff0001" \
        "$(_sessions_log_detect_id "$pi_dir" "" "pi")" "pi detect id: newest jsonl"
    unset AM_PI_SESSIONS_DIR
```

In `tests/test_utils.sh`:

```bash
    # --- pi_first_user_message ---
    local pfum_home
    pfum_home=$(mktemp -d)
    local pfum_dir="$pfum_home/proj"
    mkdir -p "$pfum_dir"
    local pfum_resolved pfum_enc
    pfum_resolved=$(cd "$pfum_dir" && pwd -P)
    pfum_enc="--${pfum_resolved#/}--"
    pfum_enc="${pfum_enc//\//-}"
    export AM_PI_SESSIONS_DIR="$pfum_home/sessions"
    mkdir -p "$AM_PI_SESSIONS_DIR/$pfum_enc"
    local pfum_file="$AM_PI_SESSIONS_DIR/$pfum_enc/2026-07-19T08-00-00-000Z_0199aaaa-0000-0000-0000-000000000001.jsonl"
    printf '%s\n%s\n' \
        '{"type":"session","version":3,"id":"0199aaaa-0000-0000-0000-000000000001","cwd":"'"$pfum_resolved"'"}' \
        '{"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":"Refactor the state machine please"}}' \
        > "$pfum_file"
    assert_eq "Refactor the state machine please" \
        "$(pi_first_user_message "$pfum_dir")" "pi_first_user_message: string content"

    printf '%s\n%s\n' \
        '{"type":"session","version":3,"id":"0199aaaa-0000-0000-0000-000000000001","cwd":"'"$pfum_resolved"'"}' \
        '{"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Fix the flaky test in registry"}]}}' \
        > "$pfum_file"
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir")" "pi_first_user_message: block content"

    assert_eq "" "$(pi_first_user_message /nonexistent/xyz)" "pi_first_user_message: missing dir"

    # strict mode with two jsonls and no sid -> empty
    touch "$AM_PI_SESSIONS_DIR/$pfum_enc/2026-07-19T09-00-00-000Z_0199aaaa-0000-0000-0000-000000000002.jsonl"
    assert_eq "" "$(pi_first_user_message "$pfum_dir" "" 1)" "pi_first_user_message: strict ambiguous"
    # sid pin still works with two jsonls
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir" "0199aaaa-0000-0000-0000-000000000001" 1)" \
        "pi_first_user_message: sid pinned"
    unset AM_PI_SESSIONS_DIR
```

- [ ] **Step 2: Run to verify failures** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.** In `lib/registry.sh`, next to `_slog_encode_dir`:

```bash
# Encode a path as a pi session directory name. Mirrors pi's session-manager
# encoding: "--" + path minus leading slash, with / \ : replaced by -, + "--".
# Unlike Claude's encoding, dots are preserved.
_slog_encode_pi_dir() {
    local p="${1#/}"
    p=$(printf '%s' "$p" | sed -E 's|[/\\:]|-|g')
    printf -- '--%s--\n' "$p"
}

# Root of pi's session storage (override: AM_PI_SESSIONS_DIR, for tests).
_pi_sessions_root() {
    echo "${AM_PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
}
```

Rewrite `_sessions_log_jsonl_exists`:

```bash
# Check if an agent conversation JSONL still exists for a directory + sid.
# Usage: _sessions_log_jsonl_exists <directory> <session_id> [agent_type]
_sessions_log_jsonl_exists() {
    local dir="$1"
    local session_id="$2"
    local agent="${3:-claude}"

    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"

    if [[ "$agent" == "pi" ]]; then
        local pi_dir
        pi_dir="$(_pi_sessions_root)/$(_slog_encode_pi_dir "$resolved")"
        local matches=("$pi_dir"/*_"${session_id}".jsonl)
        [[ -f "${matches[0]}" ]]
        return
    fi

    local encoded project_dir
    encoded=$(_slog_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -f "$project_dir/${session_id}.jsonl" ]]
}
```

Extend `_sessions_log_detect_id` with a third param `agent` (default claude). The claude path is unchanged; add before it:

```bash
    local agent="${3:-claude}"
    if [[ "$agent" == "pi" ]]; then
        local pi_dir
        pi_dir="$(_pi_sessions_root)/$(_slog_encode_pi_dir "$resolved")"
        [[ -d "$pi_dir" ]] || return 0
        local jsonl_path base sid mtime
        while IFS= read -r jsonl_path; do
            [[ -n "$jsonl_path" && -f "$jsonl_path" ]] || continue
            if (( min_epoch > 0 )); then
                mtime=$(_slog_file_mtime "$jsonl_path" 2>/dev/null || echo 0)
                (( mtime > 0 && mtime < min_epoch )) && continue
            fi
            base=$(basename "$jsonl_path" .jsonl)
            sid="${base##*_}"
            _sessions_log_valid_id "$sid" || continue
            echo "$sid"
            return 0
        done < <(command ls -t "$pi_dir"/*.jsonl 2>/dev/null)
        return 0
    fi
```

(Restructure the function so `resolved` and `min_epoch` are computed once before the pi/claude branch — resolved via the existing `cd … pwd -P` pattern, min_epoch via `_slog_iso_epoch`.)

Extend `_sessions_log_detect_id_for_session` with a fourth param `agent="${4:-claude}"`; thread it into its `_sessions_log_jsonl_exists "$dir" "$sid" "$agent"`, `_sessions_log_dir_is_shared "$session_name" "$dir" "$agent"` and `_sessions_log_detect_id "$dir" "$created_at" "$agent"` calls.

Extend `_sessions_log_dir_is_shared` with a third param `agent="${3:-claude}"` and use `--arg agent "$agent"` + `.value.agent_type == $agent` in its jq filter.

In `lib/utils.sh`, next to `claude_first_user_message` (same contract/cleaning):

```bash
# Usage: pi_first_user_message <directory> [session_id] [strict]
# Pi twin of claude_first_user_message. Pi stores sessions at
# ~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl where the
# encoded cwd is "--" + path minus leading slash with [/\:] -> "-" + "--"
# (dots preserved). Message entries look like
# {"type":"message",...,"message":{"role":"user","content":<string|blocks>}}.
# Semantics of session_id/strict match the Claude version.
pi_first_user_message() {
    local directory="$1"
    local session_id="${2:-}"
    local strict="${3:-0}"

    local resolved
    resolved=$(cd "$directory" 2>/dev/null && pwd -P) || resolved="$directory"
    local encoded="${resolved#/}"
    encoded=$(printf '%s' "$encoded" | sed -E 's|[/\\:]|-|g')
    local pi_project_dir="${AM_PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}/--${encoded}--"

    [[ -d "$pi_project_dir" ]] || return 0

    local session_file=""
    if [[ -n "$session_id" ]]; then
        local _matches=("$pi_project_dir"/*_"${session_id}".jsonl)
        [[ -f "${_matches[0]}" ]] && session_file="${_matches[0]}"
    fi
    if [[ -z "$session_file" ]]; then
        if [[ "$strict" == "1" ]]; then
            local _jsonls=("$pi_project_dir"/*.jsonl)
            [[ ${#_jsonls[@]} -eq 1 && -f "${_jsonls[0]}" ]] || return 0
            session_file="${_jsonls[0]}"
        else
            session_file=$(command ls -t "$pi_project_dir"/*.jsonl 2>/dev/null | head -1)
        fi
    fi
    [[ -n "$session_file" && -f "$session_file" ]] || return 0

    local line content cleaned
    while IFS= read -r line; do
        content=$(echo "$line" | jq -r '
            select(.type == "message") | .message |
            select(.role == "user") | .content |
            if type == "string" then .
            elif type == "array" then
                [.[] | select(.type == "text") | .text] | join(" ")
            else empty
            end
        ' 2>/dev/null) || continue

        [[ -z "$content" ]] && continue

        cleaned=$(echo "$content" | \
            sed 's/<[^>]*>[^<]*<\/[^>]*>//g; s/<[^>]*>//g' | \
            tr '\n' ' ' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -n "$cleaned" && ${#cleaned} -gt 10 ]]; then
            echo "$cleaned"
            return 0
        fi
    done < <(grep '"role":"user"' "$session_file" 2>/dev/null | head -10)
}
```

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary`; expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/registry.sh lib/utils.sh tests/test_registry.sh tests/test_utils.sh
git commit -m "Add agent-aware sessions-log helpers and pi first-user-message"
```

---

### Task 3: Widen sessions-log call sites + pi auto-titling (bash)

**Files:**
- Modify: `lib/agents.sh` (`agent_kill` snapshot block)
- Modify: `lib/registry.sh` (`auto_title_scan`, `sessions_log_scan`, `sessions_log_gc`, `sessions_log_restorable`; add `_pi_title_extract`)
- Test: `tests/test_registry.sh`

**Interfaces:**
- Consumes: Task 2 helpers (agent params).
- Produces: `_pi_title_extract <title>` → task candidate (stdout, may be empty). `sessions_log_restorable` now emits pi rows.

- [ ] **Step 1: Write failing tests** in `tests/test_registry.sh`:

```bash
    # --- _pi_title_extract ---
    assert_eq "Refactor auth" "$(_pi_title_extract 'pi - Refactor auth - proj')" \
        "_pi_title_extract: named session"
    assert_eq "a - b" "$(_pi_title_extract 'pi - a - b - proj')" \
        "_pi_title_extract: name containing dashes"
    assert_eq "" "$(_pi_title_extract 'pi - proj')" "_pi_title_extract: unnamed"
    assert_eq "" "$(_pi_title_extract 'pi')" "_pi_title_extract: bare"
    assert_eq "plain title" "$(_pi_title_extract 'plain title')" "_pi_title_extract: non-pi shape"
```

And a restorable test (pattern-match the existing claude restorable test in this file — reuse its temp `AM_SESSIONS_LOG` / live-session stubbing approach): append a pi entry whose JSONL exists (fixture from Task 2 pattern) and one whose doesn't; assert only the first is emitted.

```bash
    # --- sessions_log_restorable accepts pi ---
    local pr_home; pr_home=$(mktemp -d)
    local pr_dir="$pr_home/proj"; mkdir -p "$pr_dir"
    local pr_resolved; pr_resolved=$(cd "$pr_dir" && pwd -P)
    export AM_PI_SESSIONS_DIR="$pr_home/sessions"
    local pr_enc; pr_enc=$(_slog_encode_pi_dir "$pr_resolved")
    mkdir -p "$AM_PI_SESSIONS_DIR/$pr_enc"
    touch "$AM_PI_SESSIONS_DIR/$pr_enc/2026-07-19T08-00-00-000Z_0199bbbb-0000-0000-0000-000000000001.jsonl"
    local pr_log; pr_log=$(mktemp)
    printf '%s\n%s\n' \
        '{"session_name":"am-pia01","session_id":"0199bbbb-0000-0000-0000-000000000001","directory":"'"$pr_dir"'","branch":"main","agent_type":"pi","task":"t1","created_at":"2026-07-19T08:00:00Z","closed_at":"2026-07-19T09:00:00Z","snapshot_file":""}' \
        '{"session_name":"am-pia02","session_id":"0199bbbb-0000-0000-0000-000000000002","directory":"'"$pr_dir"'","branch":"main","agent_type":"pi","task":"t2","created_at":"2026-07-19T08:00:00Z","closed_at":"2026-07-19T09:00:00Z","snapshot_file":""}' \
        > "$pr_log"
    local pr_out
    pr_out=$(AM_SESSIONS_LOG="$pr_log" sessions_log_restorable)
    echo "$pr_out" | grep -q "am-pia01" && pass "restorable: pi with jsonl kept" \
        || fail "restorable: pi with jsonl kept"
    echo "$pr_out" | grep -q "am-pia02" && fail "restorable: pi without jsonl dropped" \
        || pass "restorable: pi without jsonl dropped"
    unset AM_PI_SESSIONS_DIR
```

(Adapt: if `sessions_log_restorable` reads `$AM_SESSIONS_LOG` as a global set at source time, set the var the way existing tests in this file do.)

- [ ] **Step 2: Run to verify failures** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.**

`lib/registry.sh` — add near `_title_valid`:

```bash
# Extract a task candidate from pi's self-maintained terminal title.
# Pi titles: "pi - <session name> - <cwd basename>" when the session is
# named, "pi - <cwd basename>" otherwise. Named -> the middle part (the
# name may itself contain " - "; strip only the first and last segments).
# Unnamed/bare -> empty so the caller falls back to the JSONL first message.
# Non-pi-shaped titles pass through unchanged.
_pi_title_extract() {
    local t="$1"
    case "$t" in
        "pi - "*" - "*)
            t="${t#pi - }"
            printf '%s\n' "${t% - *}"
            ;;
        "pi - "*|pi)
            printf '\n'
            ;;
        *)
            printf '%s\n' "$t"
            ;;
    esac
}
```

`auto_title_scan` — after the leading-non-alnum trim, add:

```bash
        # Pi maintains its own "pi - [name -] dir" title; extract the session
        # name or blank it so the JSONL fallback kicks in.
        if [[ "${reg_agent[$name]}" == "pi" ]]; then
            title=$(_pi_title_extract "$title")
        fi
```

Then widen the fallback block:

```bash
            local fallback=""
            if [[ ( "${reg_agent[$name]}" == "claude" || "${reg_agent[$name]}" == "pi" ) && -n "${reg_dir[$name]}" ]]; then
                local _sid
                _sid=$(_sessions_log_detect_id_for_session "$name" "${reg_dir[$name]}" "${reg_created[$name]}" "${reg_agent[$name]}" 2>/dev/null || true)
                if [[ "${reg_agent[$name]}" == "pi" ]]; then
                    fallback=$(pi_first_user_message "${reg_dir[$name]}" "$_sid" 1 2>/dev/null || true)
                else
                    fallback=$(claude_first_user_message "${reg_dir[$name]}" "$_sid" 1 2>/dev/null || true)
                fi
                fallback="${fallback:0:60}"
            fi
```

`sessions_log_scan` — both `[[ "${reg_agent[$name]}" == "claude" ]] || continue` gates become:

```bash
        case "${reg_agent[$name]}" in claude|pi) ;; *) continue ;; esac
```

and every `_sessions_log_jsonl_exists`/`_sessions_log_detect_id_for_session` call in it gains a final `"${reg_agent[$name]}"` argument.

`sessions_log_gc` — the keep-check becomes:

```bash
        if [[ ( "$agent" == "claude" || "$agent" == "pi" ) && -n "$sid" && -n "$dir" ]]; then
            if ! _sessions_log_jsonl_exists "$dir" "$sid" "$agent"; then
                keep=false
            fi
        elif [[ ( "$agent" == "claude" || "$agent" == "pi" ) && -z "$sid" ]]; then
```

`sessions_log_restorable` — filter becomes:

```bash
        case "$agent" in claude|pi) ;; *) continue ;; esac
```

and `_sessions_log_jsonl_exists "$dir" "$sid" "$agent"`.

`lib/agents.sh` `agent_kill` — the snapshot block gate and calls:

```bash
    if [[ ( "$agent_type" == "claude" || "$agent_type" == "pi" ) ]] && tmux_session_exists "$session_name"; then
```

with `_sessions_log_jsonl_exists "$dir" "$sid" "$agent_type"` and
`_sessions_log_detect_id_for_session "$session_name" "$dir" "$created_at" "$agent_type"`.

Also update stale comments referencing "Claude only" at the touched sites.

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary`; expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/agents.sh lib/registry.sh tests/test_registry.sh
git commit -m "Widen sessions-log machinery to pi; pi pane-title task extraction"
```

---

### Task 4: Resolver — pi trusts its state file ungated (lib/state.sh)

**Files:**
- Modify: `lib/state.sh` (`_state_resolve` step 3; header comment)
- Test: `tests/test_state.sh`

**Interfaces:**
- Consumes: existing `_state_hook_raw <session> <out_var>`.
- Produces: `_state_resolve <session> pi <dir> …` returns the raw hook state for pi, `unknown` when no file.

- [ ] **Step 1: Write failing tests** in `tests/test_state.sh` (reuse the file's existing bulk-fixture pattern for `_state_resolve` — it builds `top_pid_map`/`comm_map`/`children_map` namerefs with a fake non-shell top process; follow the existing non-claude/codex resolver test as the template):

```bash
    # --- pi: hook state trusted without staleness gate ---
    printf 'running' > "$tmp_state_dir/am-pi1"
    # backdate the state file far beyond the 180s gate
    touch -t 202001010000 "$tmp_state_dir/am-pi1"
    # top pane process is a non-shell (the agent), no title signal
    local -A pi_top=( [am-pi1]=99991 )
    local -A pi_comm=( [99991]=node )
    local -A pi_child=()
    local pi_state
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top pi_comm pi_child "$(date +%s)")
    assert_eq "running" "$pi_state" "_state_resolve: pi stale running stays running (ungated)"

    printf 'waiting_input' > "$tmp_state_dir/am-pi1"
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top pi_comm pi_child "$(date +%s)")
    assert_eq "waiting_input" "$pi_state" "_state_resolve: pi waiting_input"

    rm -f "$tmp_state_dir/am-pi1"
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top pi_comm pi_child "$(date +%s)")
    assert_eq "unknown" "$pi_state" "_state_resolve: pi no state file -> unknown"

    # shell pane still wins over a pi state file
    printf 'running' > "$tmp_state_dir/am-pi1"
    local -A pi_top2=( [am-pi1]=99992 )
    local -A pi_comm2=( [99992]=zsh )
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top2 pi_comm2 pi_child "$(date +%s)")
    assert_eq "idle" "$pi_state" "_state_resolve: pi shell pane wins"
    rm -f "$tmp_state_dir/am-pi1"
```

(Verify against the file's actual fixture conventions before writing; keep variable names unique to avoid clobbering earlier test state.)

- [ ] **Step 2: Run to verify failures** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.** In `_state_resolve`, insert between the title-glyph section (step 2) and the gated fallback (step 3):

```bash
    # 3a. pi: the am-state extension is in-process, so its state file cannot
    # go silently stale the way out-of-process hooks can — read it ungated.
    # A dead pi drops the pane to a shell, which step 1 already catches, and
    # long quiet tool calls must not flap a live turn to unknown (the exact
    # failure the title glyph solves for Claude; pi has no glyph).
    if [[ "$agent_type" == "pi" ]]; then
        local pi_hook=""
        _state_hook_raw "$session" pi_hook
        if [[ -n "$pi_hook" ]]; then
            _state_debug "$_dbg_session" "$_dbg_agent" hook "$pi_hook"
            echo "$pi_hook"
            return
        fi
        _state_debug "$_dbg_session" "$_dbg_agent" fallback unknown
        echo "unknown"
        return
    fi
```

Update the header comment block in `lib/state.sh` (add a "pi" line under state sources: hook file written by the pi extension, trusted ungated).

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary`; expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "State resolver: trust pi extension state file ungated"
```

---

### Task 5: Pi extension (lib/hooks/am-state.ts)

**Files:**
- Create: `lib/hooks/am-state.ts`

**Interfaces:**
- Consumes: env `AM_SESSION_NAME`, `AM_STATE_DIR` (default `/tmp/am-state`), `AM_DIR` (default `~/.agent-manager`), `AM_REGISTRY` (default `$AM_DIR/sessions.json`), `AM_TMUX_SOCKET` (default `agent-manager`).
- Produces: `$AM_STATE_DIR/<session>` state file + `<session>.sid` sidecar — the exact contract `_state_hook_raw` / `_sessions_log_sidecar_id` already read.

No bash test cycle (TypeScript, exercised by the live lab in Task 11). Verify with `node --check` is NOT possible for TS; instead verify by loading it into a throwaway pi run in Step 2.

- [ ] **Step 1: Write the extension** — create `lib/hooks/am-state.ts`:

```typescript
/**
 * lib/hooks/am-state.ts - agent-manager state detection for pi sessions.
 *
 * Pi twin of lib/hooks/state-hook.sh (Claude/Codex): maps pi lifecycle
 * events to am session states and writes them to $AM_STATE_DIR/<session>.
 * Installed by `am install` as a symlink at ~/.pi/agent/extensions/am-state.ts
 * (auto-discovered by pi) and copied into the sandbox home by sandbox_start.
 *
 * Event mapping:
 *   session_start  -> waiting_input   (fresh session idle at its first
 *                     prompt; also rebinds the .sid sidecar — re-fires on
 *                     /new, /resume and /fork, keeping it authoritative)
 *   agent_start    -> running
 *   agent_settled  -> waiting_input   (pi will not continue on its own: no
 *                     retry, auto-compaction, or queued messages left)
 *
 * The resolver (lib/state.sh) trusts this file UNGATED for pi sessions:
 * the extension is in-process, so the file cannot go silently stale — a
 * dead pi drops the pane to a shell, which the shell-pane check catches.
 *
 * Writes are transition-only so the state file's mtime pins the moment the
 * state was entered (the status bar renders tab ages from it). Every side
 * effect is best-effort: a failure must never break the pi session.
 *
 * No-op unless AM_SESSION_NAME is set (exported into the pane by
 * agent_launch). When the registry file exists, the session must be in it;
 * when it is absent (sandbox container — the host registry is not mounted),
 * AM_SESSION_NAME alone is trusted.
 */
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const sessionName = process.env.AM_SESSION_NAME ?? "";
const stateDir = process.env.AM_STATE_DIR ?? "/tmp/am-state";
const amDir = process.env.AM_DIR ?? join(homedir(), ".agent-manager");
const registryPath = process.env.AM_REGISTRY ?? join(amDir, "sessions.json");
const tmuxSocket = process.env.AM_TMUX_SOCKET ?? "agent-manager";

function sessionRegistered(): boolean {
  if (!existsSync(registryPath)) return true;
  try {
    const reg = JSON.parse(readFileSync(registryPath, "utf8")) as {
      sessions?: Record<string, unknown>;
    };
    return Boolean(reg.sessions && sessionName in reg.sessions);
  } catch {
    return true;
  }
}

function writeState(state: string): void {
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, sessionName);
    let current = "";
    try {
      current = (readFileSync(file, "utf8").split("\n", 1)[0] ?? "").trim();
    } catch {
      /* no existing state file */
    }
    if (current !== state) writeFileSync(file, state);
  } catch {
    /* best-effort */
  }
  // Invalidate the list cache and the title-scan throttle (all three events
  // are prompt boundaries), then nudge the status bar. Mirrors state-hook.sh.
  try {
    rmSync(join(amDir, ".list_cache"), { force: true });
    rmSync(join(amDir, ".title_scan_last"), { force: true });
  } catch {
    /* best-effort */
  }
  try {
    execFile("tmux", ["-L", tmuxSocket, "refresh-client", "-S"], () => {});
  } catch {
    /* best-effort */
  }
}

function writeSid(sid: string | undefined): void {
  if (!sid || !/^[A-Za-z0-9._-]+$/.test(sid)) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, `${sessionName}.sid`), sid);
  } catch {
    /* best-effort */
  }
}

export default function (pi: ExtensionAPI) {
  if (!sessionName || !sessionRegistered()) return;

  pi.on("session_start", async (_event, ctx) => {
    writeSid(ctx.sessionManager.getSessionId());
    writeState("waiting_input");
  });

  pi.on("agent_start", async () => {
    writeState("running");
  });

  pi.on("agent_settled", async () => {
    writeState("waiting_input");
  });
}
```

- [ ] **Step 2: Smoke-verify against a real pi** (loads the extension, checks the state file appears; costs ~zero tokens because we exit immediately):

```bash
tmpstate=$(mktemp -d)
AM_SESSION_NAME=am-smoke AM_STATE_DIR="$tmpstate" AM_REGISTRY=/nonexistent-registry.json \
  pi --no-extensions -e lib/hooks/am-state.ts --no-session -p "" </dev/null >/dev/null 2>&1 || true
cat "$tmpstate/am-smoke" 2>/dev/null; ls "$tmpstate"
```

Expected: state file `am-smoke` exists (content `waiting_input` or `running`
depending on how far the print-mode run got); `am-smoke.sid` may be absent
with `--no-session` (ephemeral). If print mode skips `session_start`, rerun
interactively in a scratch tmux pane and check by hand. Any TS syntax/type
error will surface as a pi extension-load error — fix until it loads clean.

- [ ] **Step 3: Commit**

```bash
git add lib/hooks/am-state.ts
git commit -m "Add pi state-detection extension (am-state.ts)"
```

---

### Task 6: Go mirrors — restore filter, pi JSONL, titles (internal/sessions, cmd/am-browse)

**Files:**
- Modify: `internal/sessions/sessions.go` (`restorableEntriesFromLog`; add `piJSONLExists`, `encodedPiSessionDir`, `piSessionsRoot`)
- Modify: `internal/sessions/titles.go` (`RefreshTitles`; add `piTitleExtract`, `piFirstUserMessage`, `resolvePiSessionID`)
- Modify: `cmd/am-browse/main.go` (restore output gains agent field)
- Test: `internal/sessions/sessions_test.go`, `internal/sessions/titles_test.go`

**Interfaces:**
- Consumes: sessions-log entries with `agent_type: "pi"` (Task 1/3 write them).
- Produces: am-browse restore output `__RESTORE__\x1f<dir>\x1f<sid>\x1f<agent>` — Task 7's bash parser must accept the 4th field.

- [ ] **Step 1: Write failing Go tests.** In `internal/sessions/sessions_test.go` (mirror the existing claude fixtures — they create `$HOME/.claude/projects/<enc>/<sid>.jsonl` under a temp HOME):

```go
func TestRestorableEntriesIncludePi(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		resolved = dir
	}
	sid := "0199cccc-0000-0000-0000-000000000001"
	piDir := filepath.Join(home, ".pi", "agent", "sessions", encodedPiSessionDir(resolved))
	if err := os.MkdirAll(piDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(piDir, "2026-07-19T08-00-00-000Z_"+sid+".jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	logs := []SessionLogEntry{
		{SessionName: "am-pi1", SessionID: sid, Directory: resolved, AgentType: "pi", CreatedAt: "2026-07-19T08:00:00Z"},
		{SessionName: "am-pi2", SessionID: "0199cccc-0000-0000-0000-000000000002", Directory: resolved, AgentType: "pi", CreatedAt: "2026-07-19T08:00:00Z"},
	}
	entries := restorableEntriesFromLog(logs, home, home, map[string]bool{}, time.Now())
	if len(entries) != 1 {
		t.Fatalf("want 1 restorable pi entry, got %d", len(entries))
	}
	if entries[0].RestoreSessionID != sid {
		t.Fatalf("wrong sid: %s", entries[0].RestoreSessionID)
	}
}

func TestEncodedPiSessionDir(t *testing.T) {
	got := encodedPiSessionDir("/Users/x.y/code/proj")
	if got != "--Users-x.y-code-proj--" {
		t.Fatalf("encodedPiSessionDir: got %q", got)
	}
}
```

(Check `restorableEntriesFromLog`'s exact signature — `(logs, amDir, home, liveSessions, now)` — and match it. If the existing claude test passes `home` differently, follow it.)

In `internal/sessions/titles_test.go`:

```go
func TestPiTitleExtract(t *testing.T) {
	cases := []struct{ in, want string }{
		{"pi - Refactor auth - proj", "Refactor auth"},
		{"pi - a - b - proj", "a - b"},
		{"pi - proj", ""},
		{"pi", ""},
		{"plain title", "plain title"},
	}
	for _, c := range cases {
		if got := piTitleExtract(c.in); got != c.want {
			t.Errorf("piTitleExtract(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPiFirstUserMessage(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	dir := filepath.Join(tmp, "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		resolved = dir
	}
	piDir := filepath.Join(tmp, ".pi", "agent", "sessions", encodedPiSessionDir(resolved))
	if err := os.MkdirAll(piDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"session","version":3,"id":"x","cwd":"` + resolved + `"}
{"type":"message","id":"a1","message":{"role":"user","content":"Fix the flaky registry test"}}
`
	sid := "0199dddd-0000-0000-0000-000000000001"
	if err := os.WriteFile(filepath.Join(piDir, "2026-07-19T08-00-00-000Z_"+sid+".jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := piFirstUserMessage(resolved, "", false); got != "Fix the flaky registry test" {
		t.Fatalf("piFirstUserMessage = %q", got)
	}
	if got := piFirstUserMessage(resolved, sid, true); got != "Fix the flaky registry test" {
		t.Fatalf("piFirstUserMessage sid-pinned = %q", got)
	}
}
```

- [ ] **Step 2: Run to verify failures**

Run: `go test ./internal/sessions/`
Expected: compile errors (`encodedPiSessionDir` undefined etc.).

- [ ] **Step 3: Implement.** In `internal/sessions/sessions.go`:

```go
func piSessionsRoot(home string) string {
	if v := os.Getenv("AM_PI_SESSIONS_DIR"); v != "" {
		return v
	}
	return filepath.Join(home, ".pi", "agent", "sessions")
}

// encodedPiSessionDir mirrors pi's session-manager cwd encoding:
// "--" + path minus leading separator, with / \ : replaced by -, + "--".
// Dots are preserved (unlike Claude's encoding).
func encodedPiSessionDir(dir string) string {
	resolved := dir
	if abs, err := filepath.Abs(dir); err == nil {
		if st, statErr := os.Stat(abs); statErr == nil && st.IsDir() {
			if realPath, evalErr := filepath.EvalSymlinks(abs); evalErr == nil {
				resolved = realPath
			} else {
				resolved = abs
			}
		}
	}
	resolved = strings.TrimLeft(resolved, "/\\")
	return "--" + strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(resolved) + "--"
}

func piJSONLExists(home, dir, sessionID string) bool {
	if home == "" || dir == "" || sessionID == "" {
		return false
	}
	pattern := filepath.Join(piSessionsRoot(home), encodedPiSessionDir(dir), "*_"+sessionID+".jsonl")
	matches, err := filepath.Glob(pattern)
	return err == nil && len(matches) > 0
}
```

In `restorableEntriesFromLog`, replace the filter:

```go
		if (log.AgentType != "claude" && log.AgentType != "pi") || log.SessionID == "" {
			continue
		}
```

and the existence check:

```go
		exists := false
		if log.AgentType == "pi" {
			exists = piJSONLExists(home, log.Directory, log.SessionID)
		} else {
			exists = claudeJSONLExists(home, log.Directory, log.SessionID)
		}
		if !exists {
			continue
		}
```

In `internal/sessions/titles.go`:

```go
// piTitleExtract pulls a task candidate out of pi's self-maintained title.
// "pi - <name> - <base>" -> "<name>" (name may contain " - "; only the
// first and last segments are stripped). "pi - <base>" or "pi" -> "" so the
// caller falls back to the JSONL first message. Anything else passes through.
func piTitleExtract(title string) string {
	if title == "pi" {
		return ""
	}
	rest, ok := strings.CutPrefix(title, "pi - ")
	if !ok {
		return title
	}
	idx := strings.LastIndex(rest, " - ")
	if idx < 0 {
		return ""
	}
	return rest[:idx]
}

// piFirstUserMessage mirrors lib/utils.sh:pi_first_user_message.
func piFirstUserMessage(directory, sessionID string, strict bool) string {
	home := homeDir()
	piDir := filepath.Join(piSessionsRoot(home), encodedPiSessionDir(directory))

	var target string
	if sessionID != "" {
		matches, _ := filepath.Glob(filepath.Join(piDir, "*_"+sessionID+".jsonl"))
		if len(matches) > 0 {
			target = matches[0]
		}
	}

	if target == "" {
		entries, err := os.ReadDir(piDir)
		if err != nil {
			return ""
		}
		var jsonls []os.DirEntry
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".jsonl") {
				jsonls = append(jsonls, e)
			}
		}
		if strict && len(jsonls) != 1 {
			return ""
		}
		var newestMod time.Time
		for _, e := range jsonls {
			info, err := e.Info()
			if err != nil {
				continue
			}
			if target == "" || info.ModTime().After(newestMod) {
				target = filepath.Join(piDir, e.Name())
				newestMod = info.ModTime()
			}
		}
	}
	if target == "" {
		return ""
	}

	f, err := os.Open(target)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	count := 0
	for scanner.Scan() && count < 10 {
		line := scanner.Bytes()
		if !strings.Contains(string(line), `"role":"user"`) {
			continue
		}
		count++
		var rec struct {
			Type    string `json:"type"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		if rec.Type != "message" || rec.Message.Role != "user" {
			continue
		}
		text := cleanContent(extractContent(rec.Message.Content))
		if len(text) > 10 {
			return text
		}
	}
	return ""
}

// resolvePiSessionID mirrors resolveClaudeSessionID for pi session files
// (<timestamp>_<uuid>.jsonl under ~/.pi/agent/sessions/<encoded-cwd>/).
func resolvePiSessionID(home, stateDir, sessionName, dir, createdAt string) string {
	sidPath := filepath.Join(stateDir, sessionName+".sid")
	if b, err := os.ReadFile(sidPath); err == nil {
		sid := strings.TrimSpace(string(b))
		matches, _ := filepath.Glob(filepath.Join(piSessionsRoot(home), encodedPiSessionDir(dir), "*_"+sid+".jsonl"))
		if validSessionID.MatchString(sid) && len(matches) > 0 {
			return sid
		}
		return ""
	}

	piDir := filepath.Join(piSessionsRoot(home), encodedPiSessionDir(dir))
	entries, err := os.ReadDir(piDir)
	if err != nil {
		return ""
	}
	minTime := parseSessionLogTime(createdAt)
	var best string
	var bestMod time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if !minTime.IsZero() && info.ModTime().Before(minTime) {
			continue
		}
		base := strings.TrimSuffix(e.Name(), ".jsonl")
		idx := strings.LastIndex(base, "_")
		if idx < 0 {
			continue
		}
		sid := base[idx+1:]
		if !validSessionID.MatchString(sid) {
			continue
		}
		if best == "" || info.ModTime().After(bestMod) {
			best = sid
			bestMod = info.ModTime()
		}
	}
	return best
}
```

In `RefreshTitles`, after the leading-non-alnum trim:

```go
		if meta.AgentType == "pi" {
			title = piTitleExtract(title)
		}
```

and widen the fallback branch:

```go
		if !titleValid(title) {
			if (meta.AgentType == "claude" || meta.AgentType == "pi") && meta.Directory != "" {
				var fallback string
				if meta.AgentType == "pi" {
					sid := resolvePiSessionID(home, stateDir, s.Name, meta.Directory, meta.CreatedAt)
					fallback = piFirstUserMessage(meta.Directory, sid, true)
				} else {
					sid := resolveClaudeSessionID(home, stateDir, s.Name, meta.Directory, meta.CreatedAt)
					fallback = claudeFirstUserMessage(meta.Directory, sid, true)
				}
				if len(fallback) > titleMaxLen {
					fallback = fallback[:titleMaxLen]
				}
				if titleValid(fallback) {
					title = fallback
				} else {
					continue
				}
			} else {
				continue
			}
		}
```

In `cmd/am-browse/main.go` line ~244:

```go
					m.output = "__RESTORE__\x1f" + entry.Meta.Directory + "\x1f" + entry.RestoreSessionID + "\x1f" + entry.Meta.AgentType
```

- [ ] **Step 4: Run tests + build**

Run: `go test ./... && go build -o bin/am-list-internal ./cmd/am-list-internal/ && go build -o bin/am-browse ./cmd/am-browse/`
Expected: PASS, clean builds.

- [ ] **Step 5: Commit**

```bash
git add internal/sessions/ cmd/am-browse/main.go
git commit -m "Go mirrors: pi restore filter, pi JSONL helpers, pi titling"
```

---

### Task 7: Restore routing (am + lib/fzf.sh)

**Files:**
- Modify: `am` (`cmd_restore_internal` gains agent param; both `__RESTORE__` parse sites at ~line 199 and ~line 282; `cmd_restore` help text)
- Modify: `lib/fzf.sh` (`fzf_restore_picker` carries + emits agent)
- Test: `tests/test_agents.sh` (`agent_resume_args` lives in `lib/agents.sh`)

**Interfaces:**
- Consumes: protocol `__RESTORE__\x1f<dir>\x1f<sid>\x1f<agent>` (Task 6 emits it from am-browse; the bash picker emits it here). Missing 4th field defaults to `claude` (backward compat with an older am-browse binary).
- Produces: `cmd_restore_internal <dir> <sid> [agent]` launching `pi --session <sid>` for pi.

- [ ] **Step 1: Write failing test.** Restore launching is hard to test end-to-end; test the command-construction seam (`agent_resume_args`, new in `lib/agents.sh`). Append to `tests/test_agents.sh`:

```bash
    # --- agent_resume_args ---
    assert_eq "--resume|abc123" "$(agent_resume_args claude abc123 | paste -sd'|' -)" \
        "agent_resume_args: claude"
    assert_eq "--session|abc123" "$(agent_resume_args pi abc123 | paste -sd'|' -)" \
        "agent_resume_args: pi"
```

- [ ] **Step 2: Run to verify failure** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.** In `lib/agents.sh`:

```bash
# Print the CLI args (one per line) that resume a conversation for an agent.
# Usage: agent_resume_args <agent_type> <session_id>
agent_resume_args() {
    local agent_type="$1"
    local session_id="$2"
    case "$agent_type" in
        pi) printf '%s\n' "--session" "$session_id" ;;
        *)  printf '%s\n' "--resume" "$session_id" ;;
    esac
}
```

In `am`, `cmd_restore_internal`:

```bash
# Usage: cmd_restore_internal <directory> <session_id> [agent_type]
cmd_restore_internal() {
    local directory="$1"
    local session_id="$2"
    local agent_type="${3:-claude}"

    if [[ ! -d "$directory" ]]; then
        log_error "Directory no longer exists: $directory"
        return 1
    fi

    local resume_args=()
    while IFS= read -r _arg; do
        resume_args+=("$_arg")
    done < <(agent_resume_args "$agent_type" "$session_id")

    local session_name
    session_name=$(agent_launch "$directory" "$agent_type" "" "" "${resume_args[@]}")

    if [[ -n "$session_name" ]]; then
        # Pre-seed the resumed conversation id so the entry never needs the
        # directory-scan guess; the sidecar-authoritative scan corrects it if
        # the agent forks the resume to a new id.
        sessions_log_update "$session_name" "session_id" "$session_id"
        tmux_attach "$session_name"
    fi
}
```

Both `__RESTORE__` parse sites in `am` become:

```bash
        local directory session_id restore_agent
        IFS=$'\x1f' read -r _tag directory session_id restore_agent <<< "$result"
        cmd_restore_internal "$directory" "$session_id" "${restore_agent:-claude}"
```

(Keep each site's surrounding structure; only the parse + call change.)

In `lib/fzf.sh` `fzf_restore_picker`: append agent as field 5 of each row and emit it:

```bash
        lines+="${sid}|${dir}|${display}|${snap_path}|${agent}"$'\n'
```

```bash
    local selected_sid selected_dir selected_agent
    selected_sid=$(echo "$selected" | cut -d'|' -f1)
    selected_dir=$(echo "$selected" | cut -d'|' -f2)
    selected_agent=$(echo "$selected" | cut -d'|' -f5)

    printf '__RESTORE__\x1f%s\x1f%s\x1f%s\n' "$selected_dir" "$selected_sid" "${selected_agent:-claude}"
```

Update the function's contract comment and `cmd_restore` help text ("closed Claude sessions" → "closed Claude and pi sessions").

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary && bash -n lib/*.sh am`; expected: pass.

- [ ] **Step 5: Commit**

```bash
git add am lib/fzf.sh lib/agents.sh tests/
git commit -m "Agent-aware restore: pi resumes via --session"
```

---

### Task 8: Sandbox support

**Files:**
- Modify: `sandbox/Dockerfile` (line ~39)
- Modify: `lib/sandbox.sh` (`sandbox_start` mounts + extension seed; `sandbox_exec_cmd` env)
- Test: `tests/test_sandbox.sh`

**Interfaces:**
- Consumes: `lib/hooks/am-state.ts` (Task 5); `_SANDBOX_LIB_DIR` (module dir var at top of sandbox.sh).
- Produces: containers with `/tmp/am-state` bind-mounted and `AM_SESSION_NAME` exported into the agent exec.

- [ ] **Step 1: Write failing test** in `tests/test_sandbox.sh` (this file tests command construction without docker; follow its conventions):

```bash
    # --- sandbox_exec_cmd exports AM_SESSION_NAME ---
    local exec_cmd
    exec_cmd=$(sandbox_exec_cmd "am-sbtest" "/tmp" "echo hi")
    echo "$exec_cmd" | grep -q "AM_SESSION_NAME=am-sbtest" \
        && pass "sandbox_exec_cmd: AM_SESSION_NAME exported" \
        || fail "sandbox_exec_cmd: AM_SESSION_NAME exported"
```

- [ ] **Step 2: Run to verify failure** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.**

`sandbox/Dockerfile` line ~39:

```dockerfile
RUN npm install -g @openai/codex @earendil-works/pi-coding-agent pure-prompt
```

`lib/sandbox.sh` `sandbox_exec_cmd` — add the env var to the docker exec string (between HOST_GID and TERM):

```bash
    printf "%s" "docker exec -it -u ubuntu -w '$target_dir' -e 'HOST_UID=$_SB_HOST_UID' -e 'HOST_GID=$_SB_HOST_GID' -e 'AM_SESSION_NAME=$session_name' -e 'TERM=\${TERM:-xterm-256color}' '$session_name' zsh -lc $quoted_cmd"
```

`sandbox_start` — after `mounts=(-v "$SB_HOME_DIR:/home/ubuntu" -v "$directory:$directory")` add:

```bash
    # State channel out of the container: agents inside write their state
    # files to /tmp/am-state, which is the host's state dir. Applies to the
    # pi am-state extension and to Claude hooks configured in sandbox-home.
    local host_state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    mkdir -p "$host_state_dir"
    mounts+=(-v "$host_state_dir:/tmp/am-state")

    # Seed the pi state extension into the sandbox home (a host symlink
    # cannot cross the bind mount, so copy; idempotent, refreshed each start).
    local pi_ext_src="$_SANDBOX_LIB_DIR/hooks/am-state.ts"
    if [[ -f "$pi_ext_src" ]]; then
        mkdir -p "$SB_HOME_DIR/.pi/agent/extensions"
        cp -f "$pi_ext_src" "$SB_HOME_DIR/.pi/agent/extensions/am-state.ts" 2>/dev/null || true
    fi
```

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary`; expected: pass. If docker is available locally, also `bash -c 'source lib/utils.sh; source lib/config.sh; source lib/sandbox.sh; sb_build'` is NOT required here (image rebuild is a user action; do not block the task on it).

- [ ] **Step 5: Commit**

```bash
git add sandbox/Dockerfile lib/sandbox.sh tests/test_sandbox.sh
git commit -m "Sandbox: pi CLI in image, state-dir mount, AM_SESSION_NAME env, extension seed"
```

---

### Task 9: Install wiring (scripts/install.sh)

**Files:**
- Modify: `scripts/install.sh` (add `_install_pi_extension`; invoke after the codex hooks block, ~line 357)
- Test: `tests/test_install.sh`

**Interfaces:**
- Produces: `~/.pi/agent/extensions/am-state.ts` symlink → `<repo>/lib/hooks/am-state.ts`. Override for tests: `PI_EXT_DIR`.

- [ ] **Step 1: Write failing test** in `tests/test_install.sh` (this file tests install.sh functions in isolation; follow its sourcing pattern):

```bash
    # --- _install_pi_extension ---
    local pi_ext_dir
    pi_ext_dir=$(mktemp -d)/extensions
    _install_pi_extension "$pi_ext_dir" "$REPO_DIR/lib/hooks/am-state.ts"
    [[ -L "$pi_ext_dir/am-state.ts" ]] \
        && pass "_install_pi_extension: symlink created" \
        || fail "_install_pi_extension: symlink created"
    assert_eq "$REPO_DIR/lib/hooks/am-state.ts" "$(readlink "$pi_ext_dir/am-state.ts")" \
        "_install_pi_extension: symlink target"
    # idempotent re-run
    _install_pi_extension "$pi_ext_dir" "$REPO_DIR/lib/hooks/am-state.ts"
    [[ -L "$pi_ext_dir/am-state.ts" ]] \
        && pass "_install_pi_extension: idempotent" \
        || fail "_install_pi_extension: idempotent"
```

(Use whatever variable the test file has for the repo root; if it can't source scripts/install.sh functions directly, follow how it tests `_install_claude_hooks`.)

- [ ] **Step 2: Run to verify failure** — `bash tests/test_all.sh --summary`

- [ ] **Step 3: Implement.** In `scripts/install.sh`, next to `_install_codex_hooks`:

```bash
# Install the pi state-detection extension: symlink into pi's global
# extensions directory (auto-discovered) so it stays version-fresh with the
# repo checkout. Idempotent.
# Usage: _install_pi_extension <pi_extensions_dir> <extension_source_path>
_install_pi_extension() {
    local ext_dir="$1"
    local src="$2"
    mkdir -p "$ext_dir"
    ln -sfn "$src" "$ext_dir/am-state.ts"
    log "Symlinked $ext_dir/am-state.ts -> $src"
}
```

After the codex hooks confirm-block (~line 357):

```bash
PI_EXT_DIR="${PI_EXT_DIR:-$HOME/.pi/agent/extensions}"
PI_EXT_SRC="$REPO_DIR/lib/hooks/am-state.ts"

if command -v pi >/dev/null 2>&1; then
    if confirm "Install state-detection extension into pi ($PI_EXT_DIR)?"; then
        _install_pi_extension "$PI_EXT_DIR" "$PI_EXT_SRC"
    else
        log "Skipped pi extension installation"
    fi
else
    log "pi CLI not found -- skipped pi state extension"
fi
```

- [ ] **Step 4: Run tests** — `bash tests/test_all.sh --summary && bash -n scripts/install.sh`; expected: pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh tests/test_install.sh
git commit -m "am install: symlink pi state extension into ~/.pi/agent/extensions"
```

---

### Task 10: Docs + version bump

**Files:**
- Modify: `AGENTS.md`
- Modify: `am` (`AM_VERSION` — MINOR bump, e.g. `0.X.Y` → `0.(X+1).0`; read the current value first)

- [ ] **Step 1: Update AGENTS.md**:
  - **State Detection section**: add a short "Pi sessions" paragraph after the Claude decision table: pi state comes from the in-process extension `lib/hooks/am-state.ts` (`session_start`/`agent_settled` → `waiting_input`, `agent_start` → `running`), read ungated by `_state_resolve` (in-process writes can't go silently stale; a dead pi drops the pane to a shell). Pi never reports `waiting_permission`/`waiting_custom`/`waiting_background`.
  - **Key Files table**: add `lib/hooks/am-state.ts` row.
  - **Key Functions**: add `pi_first_user_message`, `_pi_title_extract`, `_slog_encode_pi_dir`, `agent_resume_args`; note the agent-aware `[agent]` param on the `_sessions_log_*` helpers; update the `auto_title_scan` / `sessions_log_scan` descriptions ("Claude sessions" → "Claude and pi sessions").
  - **Data Flow**: update the restore line to mention agent-aware resume (`claude --resume` / `pi --session`).
  - **Extension Points table**: update "Add restore agent support" row (now: `agent_resume_args` + restorable filters); add "Change pi state mapping → `lib/hooks/am-state.ts`".
  - **Live lab**: mention `tests/live_lab/run_pi.sh` (Task 11).
- [ ] **Step 2: Bump `AM_VERSION`** in `am` (MINOR — new user-facing agent type).
- [ ] **Step 3: Run** `bash tests/test_all.sh --summary` (the pre-commit doc-sync check validates Key Files/Functions against the codebase).
- [ ] **Step 4: Commit**

```bash
git add AGENTS.md am
git commit -m "Docs + version bump for pi agent support"
```

---

### Task 11: Live lab pi runner

**Files:**
- Create: `tests/live_lab/run_pi.sh`
- Modify: `tests/live_lab/README.md` (mention the pi runner; if no README section fits, add a short usage note at the top of run_pi.sh only)

**Interfaces:**
- Consumes: `lib/hooks/am-state.ts` (loaded via `-e`), `lib/state.sh` `_state_resolve`.
- Produces: `results/<ts>/timeline.tsv`, `report.txt`, `snapshots/` — same artifact shapes as `run.sh`.

- [ ] **Step 1: Read `tests/live_lab/run.sh` fully** (298 lines) — reuse its helpers (`log`, `mark`, sampling loop, snapshot-on-transition) and tmux scaffolding idioms verbatim where applicable.

- [ ] **Step 2: Write `tests/live_lab/run_pi.sh`** with this structure (adapt helper details to what run.sh actually does; scenario content below is normative):

```bash
#!/usr/bin/env bash
# tests/live_lab/run_pi.sh - Drive a REAL pi session through every pi-visible
# am state and record ground truth: state-file transitions, sid sidecar,
# pane titles, and pane snapshots.
#
# Pi twin of run.sh (Claude). NOT part of test_all.sh (spends real tokens).
# Run it when pi updates or when changing lib/state.sh / lib/hooks/am-state.ts.
#
# Usage:
#   ./tests/live_lab/run_pi.sh [results_dir]
#   LAB_SCENARIOS="p1 p3" ./tests/live_lab/run_pi.sh
#   LAB_PI_ARGS="--provider anthropic --model claude-haiku-4-5" ./tests/live_lab/run_pi.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESULTS="${1:-$SCRIPT_DIR/results/pi-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RESULTS/snapshots"
LAB=$(mktemp -d -t am-live-lab-pi.XXXXXX)
SOCKET="am-live-lab-pi-$$"
SESSION="lab-pi-1"
WORKDIR="$SCRIPT_DIR/workdir"
mkdir -p "$WORKDIR"

export AM_STATE_DIR="$LAB/state"
export AM_REGISTRY="$LAB/am/sessions.json"
export AM_DIR="$LAB/am"
export AM_TMUX_SOCKET="$SOCKET"
mkdir -p "$AM_STATE_DIR" "$AM_DIR"

PI_ARGS="${LAB_PI_ARGS:-}"
SCENARIOS="${LAB_SCENARIOS:-p1 p2 p3 p4}"
```

Registry seeding (agent_type pi), then launch inside a lab tmux session:

```bash
cat > "$AM_REGISTRY" <<EOF
{"sessions":{"$SESSION":{"name":"$SESSION","directory":"$WORKDIR","branch":"main","agent_type":"pi","task":"live lab","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOF

tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$WORKDIR" -x 200 -y 50
tmux -L "$SOCKET" send-keys -t "$SESSION" \
    " export AM_SESSION_NAME='$SESSION' AM_STATE_DIR='$AM_STATE_DIR' AM_REGISTRY='$AM_REGISTRY' AM_DIR='$AM_DIR' AM_TMUX_SOCKET='$SOCKET'" Enter
tmux -L "$SOCKET" send-keys -t "$SESSION" \
    " pi --no-extensions -e '$PROJECT_DIR/lib/hooks/am-state.ts' --no-session $PI_ARGS" Enter
```

Sampling loop (1s cadence, like run.sh): record `ts scenario state_file_content state_file_age resolved_state pane_title` to `timeline.tsv`; snapshot the pane on every state transition. Resolve state by sourcing the libs:

```bash
source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/tmux.sh"
source "$PROJECT_DIR/lib/registry.sh"
source "$PROJECT_DIR/lib/state.sh"
```

(Note: `am_tmux` must talk to the lab socket — verify how run.sh handles this; it exports the socket override or calls `tmux -L "$SOCKET"` directly for pane queries. Follow run.sh exactly.)

Scenarios (each: `mark`, action via `tmux send-keys`, wait/assert on expected state-file value with a timeout, record PASS/FAIL to report.txt):

- **p1 fresh idle**: after pi boots, expect state file == `waiting_input` within 30s, and (when not `--no-session`) `.sid` sidecar present. Since we run `--no-session`, assert only the state file.
- **p2 prompt round-trip**: send `Reply with exactly: pong` + Enter; expect `running` within 10s, then `waiting_input` within 120s.
- **p3 long quiet tool call**: send `Run this exact bash command and tell me when done: sleep 200` + Enter; expect `running`; sample for 210s asserting the resolved state NEVER leaves `running` (this is the ungated-read guarantee — the Claude gate would have flapped to unknown at 180s); then `waiting_input`.
- **p4 death → shell**: `tmux send-keys C-c` (twice if needed) / `q` to quit pi; once the pane is a bare shell, expect `_state_resolve` == `idle` even though the state file still says `waiting_input` (shell check precedence).

Teardown: kill the lab tmux server, write `report.txt` summary, print results path. Keep `workdir/` clean (pi runs with `--no-session`, so no session files leak; the lab's AM dirs are under mktemp).

- [ ] **Step 3: Make executable + syntax check**

```bash
chmod +x tests/live_lab/run_pi.sh && bash -n tests/live_lab/run_pi.sh
```

- [ ] **Step 4: Run it for real** (requires pi + credentials; ~4-5 min):

```bash
./tests/live_lab/run_pi.sh
```

Expected: `report.txt` shows p1-p4 PASS. If pi's event timing deviates from the plan's expectations (e.g. print-mode vs interactive `session_start` ordering), fix `am-state.ts` / the scenario waits based on the recorded timeline — that is this lab's purpose.

- [ ] **Step 5: Commit**

```bash
git add tests/live_lab/run_pi.sh tests/live_lab/README.md
git commit -m "Live lab: pi runner exercising the am-state extension end-to-end"
```

---

## Final verification (after all tasks)

- [ ] `bash tests/test_all.sh --summary` — zero failures
- [ ] `go test ./...` — pass
- [ ] `bash -n lib/*.sh am scripts/install.sh` — clean
- [ ] Manual smoke: `am install` (accept pi extension), `session=$(am new --detach --print-session -a pi ~/tmp-dir)`, watch `am list --json` show `running` → `waiting_input`; `am kill` it; `am restore` shows the pi session and resumes it via `pi --session`.
