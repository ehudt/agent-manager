# Agent Manager

Bash CLI tool managing multiple AI coding sessions (Claude, Gemini) via tmux + fzf.

See AINAV.md for architecture, key functions, and extension points.

## Dev

- Run tests: `./tests/test_all.sh`
- Shell style: bash, no shebang in libs (sourced), functions prefixed by module name
- Dependencies: tmux, fzf, jq