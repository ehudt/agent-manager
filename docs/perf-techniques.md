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
