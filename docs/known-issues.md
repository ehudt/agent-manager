# Known Issues

Performance and maintainability issues documented for future cleanup.

**All previously documented issues have been resolved.** See `docs/architecture-review.md` for details.

~~1. N+1 tmux calls in session listing~~ — Fixed: `agent_display_name` accepts pre-fetched activity timestamp.

~~2. N+1 jq calls in JSON output~~ — Fixed: `fzf_list_json` bulk-reads tmux data with associative arrays.

~~3. Registry field extraction pattern duplicated x3~~ — Fixed: `registry_get_fields` helper in `lib/registry.sh`.

~~4. `_fzf_export_functions` maintenance burden~~ — Fixed: fzf reload uses `am list-internal` subcommand.
