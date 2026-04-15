# Performance techniques: `am list --json` (1.2s to 200ms)

Lessons from optimizing a bash command that summarizes ~20 concurrent agent sessions. Most techniques apply to any bash tool that shells out per-item in a loop.

## Batch external commands

The biggest win. Every `jq` or `tmux` invocation costs ~5ms of fork+exec overhead. With N sessions that adds up fast.

**Before** (N+1 calls):
```bash
for s in "${sessions[@]}"; do
  dir=$(registry_get_field "$s" directory)
  agent=$(registry_get_field "$s" agent_type)
done
```

**After** (1 call):
```bash
# One jq call reads all fields for all sessions
eval "$(jq -r '
  to_entries[] | "registry_dir[\(.key)]=\(.value.directory);\nagistry_agent[\(.key)]=\(.value.agent_type)"
' "$SESSIONS_FILE")"
```

Same idea applies to `tmux list-sessions` -- one call returns activity timestamps for every session.

## Parallel state detection

State detection reads JSONL files and parses pane content -- I/O-bound work that parallelizes well.

```bash
for s in "${sessions[@]}"; do
  ( _agent_get_state_fast "$s" "$dir" "$agent" > "$tmp/$s" ) &
done
wait
```

Results land in temp files; the parent reads them after `wait`. Cap parallelism if session counts grow large.

## Single-pass JSON assembly

Don't spawn `jq -n` per session to build each JSON object. Instead, collect everything into a single TSV string and pipe it through one `jq` invocation that builds the entire array.

```bash
printf '%s\t%s\t%s\n' "$name" "$dir" "$state" >> "$tsv"
# ... after loop:
jq -R -s 'split("\n") | map(select(. != "") | split("\t") |
  {name:.[0], directory:.[1], state:.[2]})' < "$tsv"
```

One process instead of N.

## Lean hot-path functions

The general-purpose `agent_get_state()` validates tmux session existence, reads registry fields, and detects the agent type -- all things the caller already knows during a list operation. A dedicated `_agent_get_state_fast()` that accepts pre-fetched metadata as arguments skips the redundant work.

## Process cache warming

Some values are expensive to compute but stable within a single run (e.g., the path to a generated tmux config file). Compute them once in the parent before forking parallel subshells:

```bash
am_tmux_config_path  # caches in a global variable
for s in "${sessions[@]}"; do
  ( ... uses cached value ... ) &
done
```

Without this, every subshell independently regenerates the same file.

## Skip file regeneration

Guard writes of stable generated files:

```bash
[[ -f "$config_path" ]] || _generate_tmux_config > "$config_path"
```

Avoids redundant disk writes and, more importantly, avoids contention when multiple subshells would each try to write the same file.

## `set -e` safety in subshells

This is a subtle bug source. Under `set -e`, a failing `[[` on the left side of `&&` kills the subshell:

```bash
# BROKEN under set -e: if condition is false, subshell exits immediately
( [[ -f "$jsonl" ]] && _state_from_jsonl "$jsonl" > "$tmp/$s" )

# SAFE:
( if [[ -f "$jsonl" ]]; then _state_from_jsonl "$jsonl" > "$tmp/$s"; fi )
```

The `&&` form is fine in the main shell (where `set -e` ignores the LHS of `&&`), but inside a subshell the rules are more strict on some bash versions.

## Delimiter choice for `read`

`IFS=$'\t' read -r a b c` treats tab as whitespace, meaning consecutive tabs (empty fields) get collapsed. If any field can be empty, use a non-whitespace delimiter:

```bash
printf '%s|%s|%s\n' "$name" "$dir" "$state"
# ...
IFS='|' read -r name dir state
```

Pipe `|` doesn't collapse and is rare enough in field values.

## Remove contending background work

GC sweeps (`registry_gc`) and title upgrade scans (`auto_title_scan`) write to the same JSON files that `list --json` reads. Running them concurrently causes I/O contention and occasional read-corruption (partial writes). Move these to interactive-only code paths (e.g., `fzf_main`) so they never overlap with batch reads.

## JSONL bulk parsing (avoid per-line jq)

Calling `jq` once per line of a JSONL file is the single most expensive anti-pattern in this codebase. Each `jq` fork costs ~4-6ms; with 100 lines that's 400-600ms of pure overhead.

**Before** (N jq calls):
```bash
while IFS= read -r line; do
    fields=$(printf '%s' "$line" | jq -r '[.name, .id] | join("|")')
    IFS='|' read -r name id <<< "$fields"
done < "$JSONL_FILE"
```

**After** (1 jq call, parallel arrays):
```bash
# Parse all lines in one call
local all_fields
all_fields=$(jq -r '[.name // "", .id // ""] | join("|")' "$JSONL_FILE")

# Read raw lines and parsed fields into parallel arrays
local lines=() fields_arr=()
while IFS= read -r line; do lines+=("$line"); done < "$JSONL_FILE"
while IFS= read -r f; do fields_arr+=("$f"); done <<< "$all_fields"

# Iterate by index
for (( i=0; i<${#lines[@]}; i++ )); do
    IFS='|' read -r name id <<< "${fields_arr[$i]}"
done
```

For updating the last matching entry, use `jq -sc` (slurp + compact):
```bash
jq -sc --arg sname "$name" --arg field "$field" --arg value "$value" '
    . as $arr |
    (reduce range(length) as $i (-1;
        if $arr[$i].session_name == $sname then $i else . end)) as $last_idx |
    if $last_idx >= 0 then .[$last_idx][$field] = $value else . end |
    .[]
' "$JSONL_FILE" > "$tmp_file"
```

Note the `. as $arr` binding — inside `reduce`, bare `.` refers to the accumulator, not the original array.

## ISO 8601 string comparison (avoid per-entry date)

UTC timestamps in ISO 8601 format (`2026-04-14T14:16:38Z`) sort lexicographically. Compute a cutoff string once instead of converting each entry's timestamp to epoch:

```bash
# One date call for the cutoff
cutoff=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ")

# String comparison — no subprocess per entry
if [[ "$created_at" < "$cutoff" ]]; then ...
```

---

## Measuring performance

### End-to-end: `am list-internal`

The existing perf benchmark covers the fzf reload path:

```bash
./tests/perf_test.sh                  # 100 iterations, P50/P95/P99
PERF_ITERATIONS=20 ./tests/perf_test.sh   # quick check
```

### Per-function breakdown

Source the libraries and use `gdate +%s%N` (requires `brew install coreutils` on macOS) to time individual functions:

```bash
#!/usr/bin/env bash
set -uo pipefail
source lib/utils.sh && source lib/config.sh && source lib/tmux.sh
source lib/registry.sh && source lib/state.sh && source lib/agents.sh
source lib/fzf.sh

time_fn() {
    local label="$1"; shift
    local start end
    start=$(gdate +%s%N)
    "$@" >/dev/null 2>&1 || true
    end=$(gdate +%s%N)
    printf '%-40s %4dms\n' "$label" "$(( (end - start) / 1000000 ))"
}

# Clear throttle caches for cold measurement
rm -f ~/.agent-manager/.gc_last ~/.agent-manager/.title_scan_last

time_fn "fzf_list_sessions"        fzf_list_sessions
time_fn "sessions_log_restorable"  sessions_log_restorable
time_fn "sessions_log_gc"          sessions_log_gc
time_fn "sessions_log_update"      sessions_log_update "am-XXXX" "task" "test"
time_fn "registry_gc (forced)"     registry_gc 1
time_fn "auto_title_scan (forced)" auto_title_scan 1
```

### Baselines (as of 2026-04-15, ~105 sessions_log entries)

| Function | Target | Typical |
|---|---|---|
| `fzf_list_sessions` | <100ms | ~50ms |
| `sessions_log_restorable` | <100ms | ~50ms |
| `sessions_log_gc` | <100ms | ~65ms |
| `sessions_log_update` | <50ms | ~15ms |
| `registry_gc` (forced) | <200ms | ~100ms |
| `am list-internal` (end-to-end) | <200ms | ~100ms |
