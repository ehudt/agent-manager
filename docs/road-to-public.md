# Road to Public: Product Polish for `am`

**Date:** 2026-09-13
**Context:** An audit of the agent-manager project's product readiness for a wider
audience — preserving the tool's power and tailored feel while removing barriers
for new users.

The project has genuine competitive depth (state detection architecture, Go
mirror discipline, A2A primitives with `am send`/`am wait`/`am peek`/`am done`,
review checkpoint system, recovery/reboot resilience). The polish gaps are in
*presentation, discoverability, and safety* — not missing features.

---

## Tier 1: Make It Discoverable & Approachable

### 1.1 README — add a visual hook and a 15-second path to "wow"

The current README leads with a philosophy section before showing anything.
A visitor should see the tool in action instantly.

- **Animated gif or recorded `script` cast** — showing `am`, the browser with
  3–4 sessions, switching tabs, `am peek`, a restore. Even a 10-second loop.
  Without it, there's no visceral sense of what the product does.
- **A screenshot** of the TUI browser with the status-bar tabs visible. The
  `<!-- TODO: Screenshot -->` comment has been there for multiple releases.
- **The tagline image** (`assets/tagline.png`) is a plain-text render with no
  visual design. Commission a simple logo mark or drop it.
- **Move "Why" to `docs/philosophy.md`** — the Concepts guide (`docs/concepts.md`)
  already serves as deep architecture reading. The README should lead with
  Quick Start, not justification.
- **A one-liner install block at the top**, before any prose:

```bash
brew install tmux fzf jq
git clone https://github.com/ehudt/agent-manager.git && cd agent-manager && ./scripts/install.sh
```

### 1.2 Ship shell completions

`am` has 20+ subcommands with their own flags. No tab completion exists. Every
command the user types without `--help` is friction. A static `_am` completions
file for bash/zsh, shipped via `am install`, would be the single highest-impact
polish change. Priority: high.

### 1.3 Publish a CHANGELOG.md

You bump SemVer regularly (0.28 → 0.33 in ~2 weeks of commits), but no
changelog exists. A new user seeing `0.33.2` has no idea what has changed since
`0.1` or what "stable enough" means. Create `CHANGELOG.md` at the repo root with
entries per minor release capturing user-facing changes. Key events to include:
review pane, notifications, `am send --queue`/`--wait`, presets, `am doctor`,
`am restore`, state detection improvements, Go mirror introduction.

### 1.4 Add a CONTRIBUTING.md

Without this, the project is unlikely to receive contributions. It should cover:

- Dev environment setup
- How to run tests: `./tests/test_all.sh --summary`
- The mirror discipline: "bash defines semantics, Go buys latency — schema
  changes must move both sides in one commit"
- Code style: lib functions are prefixed by module name, return values via
  stdout, all logging/UI to stderr
- CI constraint: hook tests require real tmux; fork PRs may need opt-in

---

## Tier 2: Reduce the Confidence Gap

### 2.1 Error messages that include a diagnostic path

Current errors are terse — fine when you know the domain, opaque when you don't.
When a compound command fails (`am new`, `am send`, `am restore`), append the
equivalent `am doctor` command:

```
am new failed. Run 'am doctor' to diagnose, or 'am doctor --capture' to share a report.
```

The diagnostic infrastructure (`am doctor`) already exists — the bridge is one
line of output.

### 2.2 Proactive health check

The entry point checks bash ≥4.4 but nothing proactively verifies: tmux ≥3.2,
fzf, jq, `osascript` (macOS), `notify-send` (Linux), writable `~/.agent-manager`.
Move `am doctor`'s dependency check into an `am health` flag (or run it as part
of `am install`):

```
am health
  tmux 3.4a ✔
  fzf 0.52 ✔
  jq 1.7 ✔
  osascript  (macOS only) ✔
  tmux ≥3.2  ✔  (for -e pane env, display-popup)
```

### 2.3 Config defaults that don't assume "like me"

Current defaults (`auto_restore: true`, `stream_logs: true`, `shell_pane: false`,
`notify: true`, `notify_states: waiting_user`) are personal preferences. For a
wider audience:

- `notify_states` defaulting to `waiting_user,ready` — a finished turn is often
  more useful to know about than a permission dialog
- An `am init` wizard (3–4 yes/no questions at first install) instead of
  dumping config keys into `am config set`
- Document every config key in the README with a short sentence about what it
  does (most are documented, a few are not)

### 2.4 Platform expectations

The project is macOS-first but doesn't state it. Linux runs in CI, but:

- `osascript` — macOS-only notification path
- `notify-send` / `terminal-notifier` / `alerter` — Linux/macOS fallbacks exist
  in code but are undocumented
- Windows is unsupported (no tmux)

Add `docs/platform-support.md` setting correct expectations before someone
invests in the install.

---

## Tier 3: Product Depth for a Public Release

### 3.1 CI badge and contribution infrastructure

- CI status badge in the README
- GitHub issue templates (bug report + feature request)
- Brief `SECURITY.md` with a reporting path

### 3.2 Merge scripts/install.sh into am install

The standalone `scripts/install.sh` adds `am` to PATH and sets up tmux config.
`am install` does the real work (hooks, skills, Go binaries). Two install paths
with different scopes confuse new users. Merge the PATH/shell-rc logic into
`am install`, making the bootstrap either a one-line `curl | bash` wrapper or
deleted.

### 3.3 Highlight the A2A superpower

`am send`, `am wait`, `am peek`, `am done`/`am result` — agent-to-agent
orchestration — is a genuine differentiator that no other agent management tool
provides. It's buried as reference table entries. A single "Agent-to-Agent
Orchestration" section in the README with one real example (a dispatcher
spawning two sessions and collecting results) would make "why am?" much
stronger for power users.

---

## What Would *Not* Change

These opinions are worth preserving:

- The terse, fast CLI voice. Verbose output for new users would annoy the
  primary user (you) daily. The right fix is better diagnostics and
  discoverability (completions, `am doctor` bridge), not rewriting the CLI.
- The Go mirror discipline. It works and is a strength. Contributors need it
  explained (CONTRIBUTING.md does this).
- The state detection code. It's the core IP. No public-facing polish needed.
- The test suite. Thorough, parallel, with summary mode — already ready for
  public scrutiny.

---

## Suggested Priority Order

1. **Shell completions** (`_am` generation, wired into `am install`)
2. **README rewrite** — philosophy to `docs/philosophy.md`, add screenshot, tighten
   quick start
3. **CHANGELOG.md** — entries from commit history
4. **`am init` / config wizard** — interactive first-run setup
5. **`am health` flag** — dependency and environment check
6. **Error diagnostic bridge** — append `am doctor` hint on failure
7. **CONTRIBUTING.md** — contribution guide
8. **A2A section in README** — show the orchestration use case
9. **Platform support doc** — set expectations
10. **CI badge + issue templates**
