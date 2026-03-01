# Architecture Review

Review of the agent-manager codebase (~2200 lines across 7 modules + 578-line entry point) for structural simplification opportunities.

---

## 1. Two Data Stores: sessions.json + history.jsonl

**Current state:** `sessions.json` is a keyed JSON object (`{sessions: {am-XXXXXX: {...}}}`) holding live session metadata. `history.jsonl` is an append-only log pruned after 7 days. They share 5 fields: `directory`, `task`, `agent_type`, `branch`, `created_at`. The only field unique to sessions.json is `name`; the only structural difference is that history is directory-scoped and survives session death.

**Could they be unified?** No — they serve fundamentally different lifecycles. sessions.json is GC'd when tmux sessions die; history.jsonl persists across session death for directory annotation in `fzf_pick_directory`. Merging them would require either (a) keeping dead session entries with a status flag and querying around them, or (b) a separate GC pass that preserves some fields but deletes others. Both are more complex than the current design.

**What would break:** `registry_gc()` currently does a simple delete-if-tmux-dead pass. Adding "but keep the history fields" logic would couple GC to the annotation feature. `history_for_directory()` currently does a simple `jq select(.directory==X)` over a flat file; adding it to the sessions.json structure would require filtering by lifecycle state.

**Recommendation: Keep both stores.** The duplication is a few bytes per session at write time. The simplicity of two single-purpose stores outweighs the cost of the field overlap.

**One fix worth making:** `history_append()` calls `history_prune()` on every invocation, triggering a full file rewrite via `jq` + `mktemp` + `mv` on every new session. Move pruning to a throttled check (same 60s pattern as `registry_gc`) or to `am_init`.

Priority: **Low** (keep as-is, except the prune-on-every-append fix which is trivial).

---

## 2. `_fzf_export_functions` Elimination

**Current state:** `_fzf_export_functions` manually exports 22 functions and 5 variables so that fzf's `reload(...)` subshells can call `fzf_list_sessions`. The reload commands also re-source the full lib chain as a safety fallback, making the exports partially redundant.

**Proposed alternative:** Replace fzf reload bindings with a hidden subcommand:

```bash
# In fzf_main(), the reload binding becomes:
--bind="ctrl-r:reload(am list-internal)"
```

Where `am list-internal` is the existing `cmd_list` internal path (already exists as `list-internal` in the `case` router). This means the reload forks a new `am` process that sources all libs normally — no exports needed.

**Trade-offs:**

| | Current (export) | Proposed (subcommand) |
|---|---|---|
| Startup cost per reload | ~0ms (functions already in env) | ~50-80ms (source 7 files + jq init) |
| Maintenance burden | High (manual manifest, silent breakage) | Zero (normal sourcing) |
| Correctness risk | Function list drift | None |
| Reload frequency | Every keypress that triggers reload | Same |

**The 50-80ms overhead is acceptable** for an interactive fzf reload that already takes 100-200ms for the tmux + jq calls in `fzf_list_sessions`. The user will not perceive the difference.

**Concrete change:**

1. In `fzf_main()`, change all `reload(...)` bindings from:
   ```
   reload(source $src_libs && fzf_list_sessions)
   ```
   to:
   ```
   reload(am list-internal)
   ```
2. Add a `list-internal` case in `am`'s `main()` that calls `fzf_list_sessions` directly (this already exists).
3. Delete `_fzf_export_functions` entirely.
4. Remove all `export -f` calls.

The `--preview` binding already calls the standalone `lib/preview` script, so it's unaffected.

**Risk:** If `am` is not in PATH (e.g., user sources the script), the reload will fail. Mitigate by using `$0 list-internal` or `$SCRIPT_DIR/am list-internal`.

Priority: **High** — eliminates a persistent maintenance hazard with minimal risk.

---

## 3. Auto-titler Complexity

**Current state:** Three-stage pipeline:
1. `claude_first_user_message(dir)` — probes filesystem for Claude JSONL, parses with `jq` in a `while read` loop, strips XML tags.
2. `_title_fallback(message)` — extracts first sentence via sed, truncates to 60 chars.
3. `auto_title_scan([force])` — iterates untitled sessions, writes fallback immediately, spawns fire-and-forget `claude` CLI call for Haiku upgrade, with 60s throttle.

**Is it over-engineered?** The individual pieces are each necessary:
- Fallback titles are needed because Haiku upgrades take 2-3 seconds and fzf needs something to display immediately.
- The throttle prevents hammering the API on every fzf reload.
- Fire-and-forget is correct because blocking fzf on an API call would be unacceptable.

**What could be simpler:**

The background Haiku subshell re-sources `registry.sh` via `BASH_SOURCE[0]`, which is fragile in subshells. The `_titler_log` inner function is defined in `auto_title_scan`'s scope but referenced semantically from within a subshell (currently safe but confusing).

Simplification: extract the background Haiku call into a standalone script (like `lib/preview` already is). This:
- Eliminates the re-source hack
- Makes the subshell self-contained and testable
- Removes the confusing inner function scoping

```
lib/title-upgrade    # standalone: takes session_name, calls Haiku, writes result
```

`auto_title_scan` becomes: iterate sessions → write fallback → `lib/title-upgrade "$name" &`.

**Risk:** Low. The standalone script sources libs normally, same as `lib/preview`.

Priority: **Medium** — the current code works, but the re-source pattern is a latent bug.

---

## 4. `agent_launch()` Decomposition

**Current state:** ~150 lines handling: arg parsing, validation, tmux setup, registry write, history write, pane splitting, log streaming, command assembly, yolo normalization, sandbox setup, worktree polling.

**What's separable without pointless abstractions:**

The function has a clear sequential flow where each step depends on the previous. Extracting steps into helpers only makes sense where:
(a) the step has a natural interface (clear inputs → clear outputs), and
(b) the step is independently testable or reusable.

**Worth extracting:**

1. **Yolo flag normalization** (lines scanning `agent_args` for `--yolo`/`--dangerously-skip-permissions`, stripping, re-appending canonical flag) → `_normalize_yolo_flags args_array agent_type`. This is a pure transformation with no side effects — easy to test, easy to understand in isolation. ~15 lines.

2. **Command assembly** (building `$full_cmd` from agent command + worktree flag + args) → already almost a one-liner, but the string concatenation is fragile with special characters. Worth isolating to make quoting testable. ~10 lines.

3. **Sandbox setup** (the `sb --start` + attach-to-sandbox branch) → `_setup_sandbox session_name`. This is a self-contained side-effect block. ~15 lines.

**Not worth extracting:**

- **Pane splitting + log streaming** — these are 10 lines of sequential tmux calls with no logic. Extracting them adds indirection without reducing complexity.
- **Worktree polling** — already a self-contained background subshell. Making it a function would just wrap the subshell.
- **Registry + history writes** — two lines. Extraction would be absurd.

**Recommendation:** Extract yolo normalization and sandbox setup. Leave the rest. This brings `agent_launch` to ~120 lines, which is acceptable for a lifecycle orchestrator.

Priority: **Low** — the function is long but linear. The extractions are nice-to-have.

---

## 5. N+1 Subprocess Patterns

Three related issues documented in `docs/known-issues.md`. Here are concrete API changes:

### Issue 1: N+1 tmux calls in `fzf_list_sessions`

**Current flow:**
```
tmux_list_am_sessions_with_activity()  →  "name1 ts1\nname2 ts2\n..."
    ↓ (awk discards ts)
for name in ...; agent_display_name(name)  →  tmux_get_activity(name)  →  tmux list-sessions | grep
```

**Fix:** Pass the already-fetched activity timestamp through.

```bash
# Change agent_display_name signature:
agent_display_name(name, activity_ts)   # activity_ts optional; if empty, fetches from tmux

# Change fzf_list_sessions:
fzf_list_sessions() {
    registry_gc 2>/dev/null
    auto_title_scan &
    while IFS=' ' read -r name activity; do
        local display
        display=$(agent_display_name "$name" "$activity")
        [[ -n "$display" ]] && echo "${name}|${display}"
    done < <(tmux_list_am_sessions_with_activity)
}
```

This eliminates N tmux subprocess calls, leaving only the single `tmux list-sessions` in `tmux_list_am_sessions_with_activity`.

### Issue 2: N+1 jq calls in `fzf_list_json`

**Current flow:** Per session: 1 jq for registry fields + 2 tmux calls + 1 jq for JSON construction = 4N processes.

**Fix:** Bulk-read both data sources, join in a single jq call.

```bash
fzf_list_json() {
    registry_gc 2>/dev/null
    auto_title_scan 2>/dev/null

    local registry_data tmux_data
    registry_data=$(cat "$AM_REGISTRY")
    tmux_data=$(tmux list-sessions -F '#{session_name} #{session_activity} #{session_created}' \
        | grep "^${AM_SESSION_PREFIX}" | sort -t' ' -k2 -rn)

    # Build associative array of tmux data
    declare -A tmux_activity tmux_created
    while IFS=' ' read -r name activity created; do
        tmux_activity[$name]=$activity
        tmux_created[$name]=$created
    done <<< "$tmux_data"

    # Single jq call to extract all sessions
    local sessions_json
    sessions_json=$(echo "$registry_data" | jq -r '.sessions | to_entries[] | "\(.key)|\(.value.directory // "")|\(.value.branch // "")|\(.value.agent_type // "")|\(.value.task // "")"')

    local result="["
    local first=true
    while IFS='|' read -r name directory branch agent_type task; do
        [[ -z "${tmux_activity[$name]+x}" ]] && continue
        $first || result+=","
        first=false
        result+=$(jq -n \
            --arg name "$name" \
            --arg directory "$directory" \
            --arg branch "$branch" \
            --arg agent_type "$agent_type" \
            --arg task "$task" \
            --arg activity "${tmux_activity[$name]}" \
            --arg created "${tmux_created[$name]}" \
            '{name:$name, directory:$directory, branch:$branch, agent_type:$agent_type, task:$task, activity:($activity|tonumber), created:($created|tonumber)}')
    done <<< "$sessions_json"
    result+="]"
    echo "$result"
}
```

This reduces from 4N processes to 3 total (1 cat + 1 tmux + 1 jq for registry, plus 1 jq per session for safe JSON construction — could be reduced further with a single jq join but the bash loop is clearer).

**Further optimization:** Replace the per-session `jq -n` with string construction using `printf`, relying on the fact that the values came from jq and are already safe. This gets to 3 total processes.

### Issue 3: Duplicated registry field extraction

**Current state:** The `jq -r ... IFS='|' read` pattern appears in `agent_display_name`, `agent_info`, and `fzf_list_json`.

**Fix:** Add a registry helper:

```bash
# In lib/registry.sh:
registry_get_fields() {
    local name=$1; shift
    local jq_expr
    jq_expr=$(printf '\\(.%s // "")' "$@" | sed 's/\\/(/\\(/g; s/)/)/' )
    # Build: "\(.field1 // "")|\(.field2 // "")|..."
    local parts=()
    for field in "$@"; do
        parts+=("\\(.${field} // \"\")")
    done
    local template
    template=$(IFS='|'; echo "${parts[*]}")
    jq -r --arg name "$name" ".sessions[\$name] | \"${template}\"" "$AM_REGISTRY"
}
```

Usage:
```bash
# In agent_display_name:
IFS='|' read -r directory branch agent_type task \
    <<< "$(registry_get_fields "$name" directory branch agent_type task)"

# In agent_info (adds worktree_path):
IFS='|' read -r directory branch agent_type task worktree_path \
    <<< "$(registry_get_fields "$name" directory branch agent_type task worktree_path)"
```

Priority: **High** for issues 1 and 3 (measurable perf improvement + DRY). **Medium** for issue 2 (only affects `am list --json`).

---

## 6. Anything Else

### 6a. `format_time_ago` / `format_duration` duplication

`lib/utils.sh` has two near-identical functions implementing seconds-to-human-readable conversion. The only differences: `format_time_ago` appends "ago", `format_duration` omits "ago" and adds a days+hours branch.

**Fix:** Single implementation with a format flag, or extract the bucketing into a shared helper. ~10 lines saved.

Priority: **Low** — cosmetic.

### 6b. `tmux_get_activity` / `tmux_get_created` duplication

Both do `tmux list-sessions -F '...' | grep "^$name" | cut -d' ' -f2`. They differ only in the format token.

**Fix:**
```bash
_tmux_get_session_field() {
    local name=$1 format=$2
    tmux list-sessions -F "#{session_name} #{$format}" 2>/dev/null \
        | grep "^${name} " | cut -d' ' -f2
}
tmux_get_activity() { _tmux_get_session_field "$1" session_activity; }
tmux_get_created()  { _tmux_get_session_field "$1" session_created; }
```

Priority: **Low** — cosmetic, but trivial to do.

### 6c. `registry_gc` bypasses `tmux_session_exists`

`registry_gc` calls `tmux has-session` directly instead of using `tmux_session_exists` from `tmux.sh`. This is a minor abstraction leak — if the session-existence check ever changes (e.g., to handle tmux server not running), the GC won't pick it up.

**Fix:** One-line change to call `tmux_session_exists`.

Priority: **Low** — trivial.

### 6d. Test duplication of title helpers

`test_auto_title_session` defines inline copies of `_title_fallback`, `_title_strip_haiku`, and `_title_valid` rather than calling the production functions. These can silently drift.

**Fix:** Since these three functions are pure (no tmux or API side effects), tests should call the production functions directly. They're already sourced via `lib/registry.sh`.

Priority: **Medium** — test drift is a real risk for title validation logic.

### 6e. Inline preview in `fzf_pick_directory`

The directory picker embeds a multi-line shell script as a `--preview=` string inside a double-quoted fzf argument. This is hard to read, test, or modify.

**Fix:** Extract to a standalone script `lib/dir-preview` (same pattern as `lib/preview` for sessions).

Priority: **Low** — works fine, just ugly.

### 6f. `history_prune` on every append

As noted in section 1, `history_append` unconditionally calls `history_prune`, doing a full file rewrite on every new session. For a file that might have hundreds of entries, this is wasteful.

**Fix:** Add a simple throttle (check file mtime or a timestamp file, skip if pruned within the last hour).

Priority: **Medium** — easy fix, removes unnecessary I/O on every session creation.

---

## Prioritized Summary

| # | Change | Priority | Status |
|---|--------|----------|--------|
| 1 | Eliminate `_fzf_export_functions` via `am list-internal` subcommand | High | **Done** |
| 2 | Fix N+1 tmux calls — pass activity through `agent_display_name` | High | **Done** |
| 3 | Extract `registry_get_fields` helper to DRY up jq pattern | High | **Done** |
| 4 | Throttle `history_prune` (not on every append) | Medium | **Done** — throttle in `history_append` call site |
| 5 | Extract Haiku background call to standalone `lib/title-upgrade` | Medium | **Done** |
| 6 | Fix test duplication — call production title functions directly | Medium | **Done** |
| 7 | Bulk-read optimization for `fzf_list_json` | Medium | **Done** |
| 8 | Extract yolo normalization from `agent_launch` | Low | **Skipped** — `agent_get_yolo_flag` already extracted; further extraction not worthwhile |
| 9 | Unify `format_time_ago`/`format_duration` | Low | **Done** — shared `_format_seconds` helper |
| 10 | Unify `tmux_get_activity`/`tmux_get_created` | Low | **Done** — shared `_tmux_get_session_field` helper |
| 11 | Fix `registry_gc` to use `tmux_session_exists` | Low | **Done** |
| 12 | Extract directory preview to standalone script | Low | **Done** — `lib/dir-preview` |

**All items complete.** 210/210 tests pass.

**Do not unify sessions.json and history.jsonl.** The separation is correct.

**Do not further decompose `agent_launch`** beyond the yolo normalization extract. The function is long but linear, and bash doesn't benefit from fine-grained function decomposition the way structured languages do.
