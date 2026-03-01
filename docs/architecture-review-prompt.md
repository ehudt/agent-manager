# Architecture Review Prompt

Paste this into a new session:

---

Review this repo's architecture for structural simplification opportunities. The codebase is a bash CLI tool (~4400 lines) for managing AI coding agent sessions via tmux. Read CLAUDE.md, AGENTS.md, and all source files before starting.

Focus on these specific questions:

1. **Two data stores**: `sessions.json` (registry - live session metadata, GC'd when tmux sessions die) and `history.jsonl` (persistent session log, pruned after 7 days). They store overlapping data (directory, task, agent_type, branch). Could they be unified? What would break?

2. **`_fzf_export_functions` elimination**: fzf reload subshells need 22 manually-exported functions. Could the reload command just invoke `am list-internal` (a new hidden subcommand) instead of sourcing libs in a subshell? What are the trade-offs (startup cost vs maintenance burden)?

3. **Auto-titler complexity**: `claude_first_user_message()` parses Claude JSONL, `_title_fallback()` cleans it, `auto_title_scan()` orchestrates with throttling + fire-and-forget Haiku upgrade. Is this pipeline over-engineered? Could it be simpler while keeping the same UX?

4. **`agent_launch()` decomposition**: 150 lines, handles validation, tmux setup, registry, history, pane splitting, log streaming, command building, yolo normalization, sandbox setup, worktree polling. What's the right factoring? Which pieces are separable without creating pointless abstractions?

5. **N+1 subprocess patterns**: `fzf_list_sessions` and `fzf_list_json` spawn jq and tmux per session. The bulk-read fix is documented in `docs/known-issues.md`. Design the concrete API changes needed (function signatures, data flow) to fix issues 1-3 from that doc.

6. **Anything else**: Are there modules that should be merged or split? Functions that exist but shouldn't? Abstractions that leak? Patterns that fight bash instead of working with it?

For each finding: explain what changes, what the risk is, and whether it's worth doing. Don't implement anything - just produce a prioritized list of recommendations with concrete sketches of the new code structure where relevant. Write the output to `docs/architecture-review.md`.
