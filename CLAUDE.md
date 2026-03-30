# Agent Manager

All architecture, code style, commands, and key functions: @AGENTS.md

## Babysitter

Use `/babysitter:call` to orchestrate complex, multi-step workflows for this project.

**Methodology**: TDD with iterative-convergence. Write tests first, implement until they pass, refine iteratively.

**Recommended processes**:
- `cli-unit-integration-testing` -- unit and integration tests for CLI commands
- `shell-script-development` -- structured shell script implementation
- `interactive-form-implementation` -- tput/fzf form features
- `error-handling-user-feedback` -- user-facing error paths and messages

**Recommended skills**:
- `cli-e2e-test-harness` -- end-to-end test runner scaffolding
- `cli-snapshot-tester` -- snapshot-based output testing
- `bats-test-scaffolder` -- generate BATS test files
- `shellcheck-config-generator` -- ShellCheck config for this project's style
- `posix-shell-validator` -- portability validation

**Recommended agents**:
- `cli-testing-architect` -- test strategy and coverage
- `cli-ux-architect` -- CLI user experience design
- `shell-portability-expert` -- cross-platform shell compatibility
- `shell-security-auditor` -- security review for shell code

**Project profile**: `.a5c/project-profile.json`
