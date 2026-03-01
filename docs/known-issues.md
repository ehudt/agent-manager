# Known Issues

Performance and maintainability issues documented for future cleanup.

## 1. N+1 tmux calls in session listing

**Files:** `lib/fzf.sh` (`fzf_list_sessions`), `lib/agents.sh` (`agent_display_name`)

`tmux_list_am_sessions_with_activity()` returns `session_name activity_timestamp` pairs, but `fzf_list_sessions()` discards the activity column with `awk '{print $1}'`. Then `agent_display_name()` re-fetches each session's activity by running `tmux list-sessions` and grepping for that one name. With N sessions this is N+1 tmux subprocess invocations instead of 1.

**Impact:** Runs on every fzf render/reload. Noticeable with 10+ sessions.

**Fix:** Pass pre-fetched activity into `agent_display_name()`. Requires changing its signature and updating every caller plus `_fzf_export_functions`.

## 2. N+1 jq calls in JSON output

**File:** `lib/fzf.sh` (`fzf_list_json`)

Each session spawns 4 processes: jq to read registry fields, `tmux list-sessions` for activity, `tmux list-sessions` again for creation time, and `jq -n` to build the JSON object. With N sessions that's 4N process forks.

**Impact:** Only on `am list --json`, but scales poorly.

**Fix:** Read all registry data in one jq call, get all tmux data in one `tmux list-sessions -F '#{session_name} #{session_activity} #{session_created}'` call, then join in pure bash or a single jq invocation.

## 3. Registry field extraction pattern duplicated x3

**Files:** `lib/agents.sh` (`agent_display_name`, `agent_info`), `lib/fzf.sh` (`fzf_list_json`)

All three inline the same jq + IFS pipe-split pattern:

```bash
fields=$(jq -r --arg name "$name" \
    '.sessions[$name] | "\(.directory // "")|\(.branch // "")|\(.agent_type // "")|\(.task // "")"' \
    "$AM_REGISTRY")
IFS='|' read -r directory branch agent_type task <<< "$fields"
```

`agent_info` adds `worktree_path` as a fifth field but is otherwise identical. Adding a new metadata field means updating all three sites.

**Fix:** Add a `registry_get_fields <name> <field>...` helper in `lib/registry.sh` that returns pipe-delimited values.

## 4. `_fzf_export_functions` maintenance burden

**File:** `lib/fzf.sh` (`_fzf_export_functions`)

fzf reload subshells (`ctrl-r`, `ctrl-x`) run in a fresh bash process and need access to all functions in the `fzf_list_sessions` call chain. Currently 22 functions and 5 variables are manually listed. Adding a new helper anywhere in the dependency chain requires remembering to add it here; forgetting causes silent breakage in fzf reload.

Bash has no "export all functions from this file" mechanism. Alternatives and their trade-offs:

- **Re-source all libs in the reload command** -- partially done (`$src_libs`), but slow and fragile.
- **Single-file bundling** -- eliminates the problem but adds a build step.
- **`export -f $(declare -F | awk '{print $3}')`** -- exports everything, including functions from the parent shell.
