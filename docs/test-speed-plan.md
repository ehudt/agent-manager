# Test Suite Speed Plan: Getting Under 10 Seconds

## Current Baseline

**Total runtime: ~59 seconds** (490 tests, all passing)

### Time Breakdown by Test Group

| Group                        | Time    | Tests | Key Bottleneck                          |
|------------------------------|---------|-------|-----------------------------------------|
| run_sandbox_tests            | 17.08s  | 14    | Pytest Docker integration (16.6s alone) |
| run_agents_tests             | 7.59s   | 57    | 15 agent_launch + worktree git ops      |
| run_state_tests              | 6.88s   | 27    | Polling loop (up to 4s) + am CLI calls  |
| run_cli_tests                | 6.95s   | 47    | 24 am CLI invocations + polling loops   |
| run_bin_helpers_tests        | 4.96s   | 19    | 3 agent_launch + 1.3s fixed sleeps      |
| run_standalone_scripts_tests | 4.95s   | 43    | 4 agent_launch + status-right (2.5s)    |
| run_registry_tests           | 2.40s   | 80    | GC test (0.5s) + auto_title_scan (1.2s) |
| run_tmux_tests               | 0.83s   | 20    | 2 agent_launch + teardown               |
| run_install_tests            | 0.44s   | 21    | install.sh subprocess (2x)              |
| run_fzf_tests                | 0.19s   | 12    | Fast (pure functions)                   |
| run_config_tests             | 0.18s   | 22    | Fast (pure functions)                   |
| run_form_tests               | 0.17s   | 100   | Fast (pure functions)                   |
| run_utils_tests              | 0.15s   | 28    | Fast (pure functions)                   |

## Optimizations

### OPT-1: Separate sandbox pytest into slow tier (17s)
Move `test_sandbox_pytest_integration` behind `--include-slow` flag. The bash-level sandbox tests (0.1s, 13 tests) stay in the fast suite.

### OPT-2: Tighten polling loops and sleeps (4s)
Replace `for _i in $(seq 1 20); sleep 0.2` patterns with `seq 1 10; sleep 0.1`. Reduce fixed `sleep 0.5` to `sleep 0.1` where waiting for tmux readiness.

### OPT-3: Share integration environment across test groups (4s)
Single `suite_integration_setup()` instead of 15 per-test setup/teardown cycles. Each test creates/kills its own sessions but shares stub symlinks, AM_DIR, and tmux server env.

### OPT-4: Batch agent_launch calls (2.5s)
In test_worktree and test_agents, combine sequential launch+kill+launch+kill into launch+test+launch+test+kill_all. Reuse sessions for read-only checks.

### OPT-5: Reduce CLI subprocess overhead (1.5s)
Convert most `am` subprocess invocations in test_cli to direct function calls. Keep 2-3 end-to-end CLI tests.

### OPT-6: Skip worktree wait in test mode (0.5s)
The background worktree polling in agent_launch is useless with stub agents. Add test-mode bypass.

### OPT-7: Source libs once at suite startup (0.5s)
Source all libs once in test_helpers.sh instead of per-test re-sourcing.

### OPT-8: Parallelize test groups (15-20s)
Run independent test groups in parallel subshells with separate AM_TMUX_SOCKET and AM_DIR. Aggregate results after.

## Implementation Plan

### Batch 1 — 3 parallel agents, zero file conflicts

| Agent | Opts | Files | Savings |
|-------|------|-------|---------|
| A | OPT-1 (sandbox → slow tier) | `test_all.sh`, `test_sandbox.sh` | 17s |
| B | OPT-6 (skip worktree wait) | `lib/agents.sh` | 0.5s |
| C | OPT-2 + OPT-5 (polling + CLI reduction) | `test_cli.sh`, `test_state.sh`, `test_bin_helpers.sh`, `test_standalone_scripts.sh` | 5.5s |

**Measure** → ~36s expected

### Batch 2 — 1 agent, touches many files

| Agent | Opts | Files | Savings |
|-------|------|-------|---------|
| D | OPT-3 + OPT-4 + OPT-7 (shared env + batch launches + source once) | `test_helpers.sh`, `test_agents.sh`, integration test setup/teardown | 5s |

**Measure** → ~31s expected

### Batch 3 — 1 agent, the big one

| Agent | Opts | Files | Savings |
|-------|------|-------|---------|
| E | OPT-8 (parallel test groups) | `test_all.sh` restructure | 15-20s |

**Measure** → ~12s expected, tune to <10s

### Shortcut path

Skip batch 2, go straight from batch 1 to batch 3 (parallelization). Faster to implement, fewer moving parts. Gets to ~16s, then tune from there.
