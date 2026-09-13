# Contributing

Most of what a contributor needs is already in [AGENTS.md](AGENTS.md):
the commands, the code style, the gotchas, the key files and functions,
and the state-detection design. This page is the short route through it.

## Set up

```bash
./am install --dry-run    # see what the install would touch
./am install              # deps check, config, skills, PATH, hooks, Go build
```

Requirements: bash 4.4+, tmux 3.2+, fzf 0.40+, jq 1.6+, git, and Go 1.19+
for the compiled browser and helpers (`make -s build`).

## Run the tests

```bash
./tests/test_all.sh --summary   # the whole suite, failures only
bash tests/test_registry.sh     # one file
go vet ./... && go test ./...   # the Go side
./scripts/check-docs.sh         # AGENTS.md references and the CHANGELOG entry
```

The suite builds the Go binaries first and runs the files in parallel
workers. Every test gets its own `AM_DIR`, tmux socket, and hook state dir;
a test that points `AM_DIR` elsewhere must keep that isolation (the hook
state dir is shared by every am on the machine). The hook tests need a real
tmux, so CI for a fork's pull request may need to be enabled by a maintainer.

The live labs under `tests/live_lab/` drive real agents and spend tokens.
They are opt-in; run the matching one when an agent updates or when you
change `lib/state.sh` or `lib/hooks/`, and update `tests/live_lab/VERIFIED`
only when the report agrees.

## How the code is split

- `am` is the CLI entry point; `lib/*.sh` are sourced libraries (no shebang,
  no `set -e`), functions prefixed by module (`registry_add`,
  `tmux_create_session`), results on stdout and everything else on stderr.
- The maintenance and query paths (title refresh, restore scan, GC, the
  sessions-log rewrites) run in Go, `bin/am-core`, behind one-line bash
  wrappers in `lib/registry.sh` / `lib/utils.sh`. The browser
  (`bin/am-browse`), the fast list, and the review pane are Go too. Bash
  and Go share the registry lock and the agent manifest
  (`lib/agents.manifest`).
- A change to a stored shape (registry row, sessions-log entry, sidecar,
  manifest field) moves both sides in one commit, with the parity test in
  `internal/sessions/maintenance_test.go` and the bash test file that covers
  the wrapper.
- State detection reads documented signals only (hooks, title glyphs,
  process tree). Pull requests that classify pane text for state are
  declined; the history behind that rule is in AGENTS.md.

## Before you open a pull request

- Tests first: the project uses TDD. A behaviour change comes with the test
  that fails without it.
- `bash -n am lib/*.sh` and `./scripts/check-docs.sh` pass.
- Bump `AM_VERSION` in `am` when the change earns it (AGENTS.md >
  Versioning) and add the `CHANGELOG.md` entry in the same commit.
- Update AGENTS.md when you add a file, a function worth finding, a config
  key, or a gotcha you hit.
- Commit messages say what changed and why, in the style of `git log`.
