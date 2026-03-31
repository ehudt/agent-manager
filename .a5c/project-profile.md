# Project Profile: agent-manager

Bash CLI tool for managing AI coding agent sessions via tmux, fzf, and Docker sandboxes

> Last updated: 2026-03-30T15:10:00.000Z | Version: 1

## Goals

- **testing** [high]: Automated testing workflows for bash CLI with tmux/fzf/Docker dependencies (planned)
- **development** [high]: Feature development orchestration for multi-step features across agent sessions (planned)
- **quality** [medium]: Code review and refactoring workflows with quality convergence gates (planned)
- **testing** [high]: Automated UI/visual testing for terminal-based interfaces (tmux panes, fzf, tput forms) (planned)

## Tech Stack

### Languages

- Bash v4.0+ (Primary language for CLI and all modules)
- Python v3.11+ (Integration tests (pytest))

### Frameworks

- tmux v>=3.0 [Session persistence and multiplexing]
- fzf v>=0.40 [Interactive selection UI]
- pytest [Python test framework]

### Infrastructure

- Docker [Sandbox container runtime]
- tinyproxy [HTTP proxy for sandbox network filtering]
- jq [JSON processing]
- git [Version control with worktree support]

## Architecture

**Pattern:** modular-cli
**Data flow:** am loads lib/* modules. fzf_main() for interactive, cmd_* for direct. Registry JSON <-> tmux <-> pane JSONL.

### Modules

| Module | Path | Description |
|--------|------|-------------|
| agents | `lib/agents.sh` | Agent lifecycle management |
| registry | `lib/registry.sh` | Session metadata persistence |
| tmux | `lib/tmux.sh` | tmux wrapper functions |
| fzf | `lib/fzf.sh` | Interactive UI and main loop |
| form | `lib/form.sh` | tput-based new session form |
| state | `lib/state.sh` | Session state detection |
| config | `lib/config.sh` | User configuration |
| sandbox | `lib/sandbox.sh` | Docker sandbox lifecycle |
| utils | `lib/utils.sh` | Shared utilities |

**Entry points:** `am`

## Team

- **Ehud Tamir** (Sole developer): All development, Architecture, Testing, Operations
- **Claude (AI)** (AI contributor): Feature PRs, Documentation, Bug fixes
- **Codex (AI)** (AI contributor): Feature PRs

## Workflows

### development

Trunk-based: direct commits to main, PRs for AI changes
**Triggers:** manual

1. Edit code
2. bash -n syntax check
3. tests/test_all.sh
4. Commit to main

### testing

Parallel bash test execution with tmux isolation
**Triggers:** manual, CI

1. test_all.sh parallel workers
2. pytest integration/security/docker
3. perf_test.sh standalone

### ci-pipeline

GitHub Actions on push/PR
**Triggers:** push to main, pull requests

1. syntax check
2. docs sync
3. test suite
4. perf benchmark
5. secrets scan

## CI/CD

**Provider:** GitHub Actions
**Config files:** `.github/workflows/ci.yml`, `.github/workflows/secrets.yml`

### Pipelines

- **CI** (trigger: push/PR)
  Stages: syntax-check -> docs-sync -> test-suite -> perf-test
- **Secrets Scan** (trigger: push/PR)
  Stages: scan-tracked -> scan-history

## Pain Points

- **high** [architecture]: Sandbox subsystem required continuous rework (66 commits, 21%)
  - Remediation: Better test coverage for sandbox lifecycle
- **medium** [quality]: 21.5% of commits are fixes, insufficient pre-commit quality gates
  - Remediation: Automated testing before commit
- **high** [testing]: Manual testing loops for sandbox and form changes are slow and error-prone
  - Remediation: Automated integration and regression testing
- **high** [testing]: UI/visual testing (timing, visual changes) is manual, slow, unreliable, hard to reproduce
  - Remediation: Terminal capture testing, tmux pane content assertion framework

## Bottlenecks

- Sandbox has highest churn with multiple architecture redesigns at lib/sandbox.sh, sandbox/Dockerfile (Continuous)
  Impact: Major time sink
- Tests leaked into real tmux sessions and user config at tests/ (Periodic)
  Impact: Developer environment pollution

## Conventions

### Naming

- **functions:** module_prefix (registry_add, tmux_create_session)
- **files:** No shebang in lib/*, shebang in am and bin/*
- **sessions:** am-<6-char-hash>

### Git

- **commitStyle:** Imperative mood, verb-first
- **branchStrategy:** Trunk-based, PRs for AI only
- **mergeStrategy:** Direct push, merge for PRs

**Testing:** tests/test_*.sh sourced by test_all.sh, pytest markers for integration/security/docker

### Additional Rules

- Use sed -E for portability
- SCRIPT_DIR overwritten when sourcing lib/agents.sh
- Sandbox containers run as ubuntu user

## CLAUDE.md Instructions

- Use TDD with iterative-convergence for new features
- Run /babysitter:call for orchestrated workflows
- Project profile at .a5c/project-profile.json

## Installed Extensions

- Skills: cli-e2e-test-harness, cli-snapshot-tester, bats-test-scaffolder, shellcheck-config-generator, posix-shell-validator, bash-script-template
- Agents: cli-testing-architect, cli-ux-architect, shell-portability-expert, shell-security-auditor
- Processes: cli-unit-integration-testing, shell-script-development, interactive-form-implementation, error-handling-user-feedback
