# Road to Public: Product Polish for `am`

**Date:** 2026-09-13
**Context:** An audit of the agent-manager project's product readiness for a wider
audience — preserving the tool's power and tailored feel while removing barriers
for new users. Every claim below was checked against the checkout at 0.34.1;
items the repo already covers are listed at the end so they are not re-proposed.

The project has genuine competitive depth (state detection architecture, the Go
back end behind the maintenance path, A2A primitives with `am send`/`am wait`/
`am peek`/`am done`, review checkpoint system, recovery/reboot resilience). The
polish gaps are in *first-run success, reversibility, and discoverability* —
not missing features.

`am` stays an opinionated tool. Its defaults are the author's preferences and
that is the product; nothing here proposes changing them. The work is to make
the first ten minutes succeed for someone who is not the author, and to make
every change `am` makes to a user's machine visible and reversible.

---

## Tier 1: Make the First Run Succeed

### 1.1 Fix the bash version story

This is the most likely first-run failure on macOS and it is missing from the
docs. macOS ships bash 3.2; the entry point requires bash ≥ 4.4
(`BASH_VERSINFO` check at the top of `am`); the README dependency table says
"4.0+". A new macOS user who follows the README hits a version error whose
message does not say how to fix it.

- README table: `bash 4.4+`, with `brew install bash` as the macOS install.
- The entry point's version error should name the fix: `brew install bash` on
  macOS, the distro package elsewhere.
- Quick Start should mention bash in the dependency one-liner where it is not
  a given (macOS).

Cheapest item on the list and the highest impact.

### 1.2 One documented install path: `./am install`

`am install` is the full installer: it checks dependencies with minimum
versions (tmux ≥ 3.2, fzf ≥ 0.40, jq, git), writes the config, links the
skills, runs `scripts/install.sh` for PATH / tmux.conf / hooks, and builds the
Go binaries. The README's Quick Start and Install sections tell people to run
`scripts/install.sh` directly, which skips the skills and the Go build — a
fresh install has no browser until the stale-stamp refresh runs on the next
bare `am`.

- README: `./am install` everywhere `./scripts/install.sh` appears; the
  script's flags (`--yes`, `--no-shell`, `--prefix`, `--copy`) are forwarded,
  so the option block stays the same.
- `scripts/install.sh`, when run directly, ends with one line pointing at
  `am install` for skills and binaries.

No merge of the two scripts is needed; the wrapper relationship is already
right, only the documentation points at the wrong end of it.

### 1.3 Visual hook in the README

The README has carried four `<!-- TODO: Screenshot / Video -->` comments for
many releases. The structure around them is fine (short "Why", Quick Start
with the install block right after, Orchestration section with a real
example), so this is an asset problem, not a rewrite.

- One screenshot of the browser with 3–4 sessions and the status-bar tabs.
- One 10–20s recording: `am new`, detach, `am`, pick a session, reattach.
- Optionally a second recording of the orchestration example (the TODO at the
  end of the A2A section).
- `assets/tagline.png` is a plain-text render. Either a simple mark or drop it
  for the heading alone.

### 1.4 Platform expectations

The project is macOS-first but does not state it. Linux runs in CI, but the
notification path (`osascript` on macOS; `notify-send` on Linux, with the
`terminal-notifier` / `alerter` fallbacks) and the macOS-specific doctor
sections are undocumented, and Windows is unsupported (no tmux). A short
"Platform support" subsection in the README — not a separate doc — sets this
before someone invests in the install.

---

## Tier 2: Make Every Change Reversible

`am install` edits five other tools' configuration: `~/.claude/settings.json`,
`~/.codex/config.toml` and Codex's hooks file, `~/.cursor/hooks.json` (plus a
byte copy of the state hook), pi's extension dir, and opencode's plugin dir.
For the author this is fine; for a stranger it is the scariest thing the tool
does, and today there is no way to see the changes before they happen or to
undo them.

### 2.1 `am install --dry-run`

Print every file the install would create, link, or edit, and the managed
block it would add, without touching anything. The install code already knows
each target; this is a mode flag on the same functions.

### 2.2 `am uninstall`

Remove the managed blocks from each agent's config (the `remove_managed_block`
helper already exists in `scripts/install.sh`), the hook entries, the skill
symlinks, the PATH line, and optionally `~/.agent-manager`. Print what was
removed. Without this, trying `am` is a one-way door.

### 2.3 Doctor flags versions below the minimum

`am doctor` prints tmux / fzf / jq versions but does not compare them to the
minimums that `am install` checks. Reuse the install check inside doctor's
"versions" section so a too-old tmux shows as a warning there too. No new
command; `am health` would duplicate what doctor is for.

---

## Tier 3: Discoverability

### 3.1 Shell completions — dynamic, not a static file

`am` has 20+ subcommands and no completion. The completion that matters most
is `am send <TAB>` / `am peek <TAB>` / `am kill <TAB>` listing live session
names, which a static `_am` file cannot do. Ship `am completions zsh|bash`
printing a script whose session completer calls the fast Go list; `am
install` adds the one `source`/`eval` line to the shell rc (inside the
managed block, so `am uninstall` removes it). Same effort as a static file,
much more useful.

### 3.2 CHANGELOG.md, with a CI check

SemVer is bumped steadily (0.28 → 0.34 in a few weeks) and AGENTS.md already
ties every bump to the commit that earns it, but there is no changelog. A new
user seeing `0.34.1` cannot tell what changed or what "stable enough" means.

- `CHANGELOG.md` at the repo root, one entry per minor release, user-facing
  changes only. Seed it from commit history; key milestones: the Go back end
  for maintenance, `am restore` and reboot recovery, `am doctor`, presets,
  `am send --queue`/`--wait`, notifications, the review pane, opencode.
- Extend `scripts/check-docs.sh` (already run in CI) so a change to
  `AM_VERSION` without a matching entry fails the build. A changelog without
  enforcement stops at the release it was written for.

### 3.3 Targeted error bridge to `am doctor`

The diagnostic infrastructure exists; the bridge is one line of output. But
append it only to *environment* failures — binary not built, tmux missing or
too old, hooks not installed, state dir unwritable — not to every error.
Semantic errors (`no running agent`, `unknown session`) are clear already,
and a doctor hint on each of them is daily noise for the primary user.

### 3.4 Config keys documented in one table

The keys are sane and stay as they are. What is missing is a single table
listing every key (`agent`, `logs`, `shell`, `auto_restore`, `notify`,
`notify_states`, `notify_cmd`, `dir_provider`), its default, and one
sentence. Most appear in prose somewhere in the README; a table is what a
new user scans. No first-run wizard: eight keys with defaults that work do
not justify an interactive setup, and it would be the first verbose thing in
a terse CLI.

### 3.5 Contribution surface

- `CONTRIBUTING.md` as a one-page pointer: AGENTS.md already holds the
  commands, code style, and gotchas, so the file names those sections and
  adds only what is not there — how to run one test file, that hook tests
  need a real tmux (fork PRs may need opt-in), and the current division of
  labor between bash and Go (the maintenance and query paths run in
  `bin/am-core`; bash is the CLI and the one-line wrappers; a schema change
  moves both sides in one commit). Do not describe Go as a "mirror" of bash;
  that model is from before the maintenance path moved.
- `SECURITY.md` with a reporting path. The repo already runs a secrets scan
  in CI; say so.
- CI status badge in the README; GitHub issue templates (bug report, feature
  request).

---

## Already Covered (do not re-propose)

Checked against the checkout so the plan does not spend effort here:

- **Agent-to-Agent section in the README** — exists, with the core pattern,
  parallel workers, presets, session states, and the dispatch skill. Only the
  recording is missing (1.3).
- **README structure** — "Why" is three short paragraphs; Quick Start with the
  install block follows it directly. No rewrite or philosophy split needed.
- **Dependency check** — `am install` checks tmux, fzf, jq, and git with
  minimum versions. Doctor only needs to reuse it (2.3).
- **Install wrapper** — `am install` already calls `scripts/install.sh`; the
  fix is which command the README names (1.2).
- **Config defaults** — they are the product's opinion and stay. Documentation
  only (3.4).

## What Would *Not* Change

- The terse, fast CLI voice. Verbose output for new users would annoy the
  primary user daily. The right fix is diagnostics and discoverability
  (completions, doctor bridge on environment failures), not rewriting the CLI.
- The defaults. See above.
- The bash/Go split. Contributors need it explained (3.5), not changed.
- The state detection code. It is the core IP; no public-facing polish needed.
- The test suite. Thorough, parallel, with summary mode. The live labs spend
  real tokens and are opt-in; CONTRIBUTING should say so.

---

## Suggested Priority Order

1. **Bash 4.4** in the README table and the entry point's error text (1.1)
2. **`./am install` as the documented path** (1.2)
3. **`am install --dry-run` and `am uninstall`** (2.1, 2.2)
4. **Screenshot and one recording**, replacing the TODO comments (1.3)
5. **Dynamic shell completions** (3.1)
6. **CHANGELOG.md with the CI check** (3.2)
7. **Doctor minimum-version flags** and the **targeted error bridge** (2.3, 3.3)
8. **Config table** in the README (3.4)
9. **CONTRIBUTING.md, SECURITY.md, CI badge, issue templates** (3.5)
10. **Platform subsection** in the README (1.4)
