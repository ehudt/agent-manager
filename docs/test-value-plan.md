# Test Suite Value Plan: Removing Tests That Guard Nothing

Companion to `test-speed-plan.md`. That document is about wall time; this one
is about which tests earn their place. The two overlap only where a slow test
is also a redundant one.

## 1. Baseline

**257 tests, 1617 assertions, ~75s wall** (`./tests/test_all.sh`, 8 parallel
workers; worker 5 runs `tests/test_cli.sh` alone at ~50s and sets the floor).

| | Count |
|---|---|
| Bash test files (`tests/*.sh`, excluding the runner and helpers) | 19 |
| Go test files (`*_test.go`) | 16 |
| Tests (bash `test_*` functions, Go `Test*`, lab cases, perf drivers) | 257 |
| Assertions | 1617 |

### Category distribution (survey, per test)

| Category | Tests | Meaning |
|---|---|---|
| contract | 147 | Pins a documented behavior of one function or command |
| regression-guard | 59 | Added with or after a fix; names the breakage it catches |
| invariant | 22 | Cross-cutting rule (manifest completeness, lock discipline, env hand-off) |
| duplicate-in-file | 13 | Same assertion as another test in the same file |
| smoke | 7 | Runs the path, asserts little |
| implementation-pin | 5 | Asserts wording, ordering, or a help line rather than an outcome |
| tautology | 2 | Cannot fail without a nonsensical edit |
| perf | 2 | Wall-clock budget |

### Cost distribution (survey, per test)

| Tier | Tests | Typical shape |
|---|---|---|
| trivial | 93 | Pure function, no subprocess |
| cheap | 108 | jq / git / one subprocess |
| moderate | 40 | Real tmux or several `am` invocations |
| expensive | 16 | `agent_launch`, polling loops, fixed sleeps |

### Slowest files (direct run, seconds)

| File | s | What dominates |
|---|---|---|
| `tests/test_cli.sh` | 49.8 | `am wait --state idle --timeout 20` for the 5s `starting` window (L332, 1019-1020) |
| `tests/test_agents.sh` | 21.1 | `test_review_pane` 11.3s, of which a 6s busy-wait at 513-515 |
| `tests/test_recovery.sh` | 17.1 | three tmux tests 11.6s (`test_recovery_agent_start_stability` 5.3s) |
| `tests/test_standalone_scripts.sh` | 16.7 | `test_standalone_status_bar` 9.0s + `_layout` 6.4s |
| `tests/test_state_hooks.sh` | 12.7 | `test_state_hooks` 5.4s (~100 hook subprocesses, each forking jq) |
| `internal/sessions/review_test.go` | 11.2 | real git per case |
| `tests/test_registry.sh` | 9.9 | `test_auto_title_scan` 2.0s, `test_registry_tmp_guard` 1.7s |
| `tests/test_state.sh` | 6.7 | two integration tests, 3.2s + 3.5s |

Everything else is under 5.3s; the 15 Go files other than `review_test.go`
total about 7.1s (0.83 + 1.1 + 0.26 + 1.02 + 0.28 + 0.18 + 0.17 + 0.27 + 0.18
+ 0.26 + 0.87 + 0.35 + 0.2 + 0.72 + 0.42), most of it test-binary link time.

### How the verdicts were produced

| Stage | Input | Output |
|---|---|---|
| Survey | every test, one agent per file | 257 verdicts: keep 181, simplify 48, merge 13, remove 15 |
| History | 518 commits (2026-02-04..10-05), 150 CI runs | test-only commit ratios, fix-born tests, flaky and never-failed signals |
| Redundancy | all files | 24 cross-file clusters, each with a named survivor |
| Skeptic | 90 candidates (29 remove, 48 simplify, 13 merge; the 15 survey removes plus 14 cluster non-survivors the redundancy pass added) | per candidate: a concrete regression only it would catch, or none |
| Mutation | the 42 candidates the skeptic could not defend | up to 3 breakages applied in a worktree, suite run with and without the candidate |
| Final | | **remove 14, simplify 6, merge 3, keep 67** |

Every remove, simplify and merge in 3a/3b is mutation-confirmed. The 48
candidates the skeptic defended on argument alone were never mutated and all
stay. Line-level drops the skeptic cleared *inside* kept tests are collected
in 3d; they are not mutation-confirmed and need their own check before they
are applied.

## 2. What makes a test worth keeping here

A test earns its place when at least one of these holds:

- **Sole guard.** Some plausible edit to production code is caught by this
  test and no other. "Plausible" means the kind of change a refactor or a
  cleanup makes: an argument swap, a dropped guard clause, a reintroduced
  directory guess, a loosened version compare.
- **Boundary crossing.** It is the only test that drives a path across a
  process or language boundary: bash → `am-core` env hand-off, the JSON keys
  bash and Go both read, the CLI wiring in `am` over a lib function, the hook
  writer against the resolver reader.
- **Fix-born.** It arrived in a commit whose subject names a bug (70 of 284
  test functions ever added; ~25% of assertion labels). These are the suite's
  record of what has broken before.
- **Cell coverage.** It exercises a combination no other test does (empty live
  set and more than one registry row; a real `agent_set_workdir` with
  `effective_directory` ≠ `project_directory`).

A test does not earn its place by asserting a Go zero value, by re-asserting
what a stricter test in the same file already asserts, or by re-running a Go
behavior matrix through a one-line bash wrapper when the wrapper's own
contract (the env hand-off) is covered by one scenario already.

### Removal rule

1. **Remove** only when the mutation check confirms redundancy or tautology:
   every breakage applied was caught by a named surviving test.
2. **Simplify** implementation pins: keep the test, drop the lines that pin
   wording, field order, or a help line, unless the pin itself is the point
   (`TestHelpText`'s Ctrl-R line is the only thing that notices the help text
   drifting from the key map).
3. **Keep** anything that is the sole guard of a plausible regression, even
   when it looks like a duplicate, costs seconds, or has never failed.
4. When in doubt, keep.

The asymmetry behind rule 4: a kept redundant test costs a fraction of a
second per run and a few lines of upkeep when a schema moves. A lost guard
costs an incident, a bisect, and a fix commit, and this repository's history
has several of each (the Obsidian-terminal session that drove another tab's
state; the GC that wiped every hook file on each suite run; the title that
mixed two same-directory sessions). Removal must be verified; keeping needs
no justification.

## 3. Verified lists

Checked by: **M** = mutation check in a worktree, up to 3 breakages each,
suite run with the candidate enabled and disabled; **A** = skeptic's argument
only (no mutation run).

### 3a. Remove (14, all M)

| File | Test | Line | Why | What still guards it |
|---|---|---|---|---|
| `tests/test_registry.sh` | `test_auto_title_session` | 642 | One assertion: `registry_update` + `registry_get_field` round trip | `test_registry` L29-30; `test_registry_concurrency` L1091-1099; `test_registry_get_fields` L210, 226-227 (`registry_get_fields: updated field (5th field)`, `registry_update: changes field`, `concurrency: no parallel registry_update lost (lost=12 of 12)`) |
| `tests/test_registry.sh` | `test_registry_gc_extras` | 377 | 16 assertions re-running the Go extras half through `am-core`; Go `TestGCExtras` says in its own comment that it mirrors this test and is a strict superset | `internal/sessions/maintenance_test.go::TestGCExtras` (sessions log names; `sid-gone.txt` exists), `TestGCHalvesAndGrace`, `TestIsLogCapTemp`; `tests/test_standalone_scripts.sh::test_standalone_status_bar` (`tick prunes a sessions-log entry whose transcript is gone`, `tick sweeps a leaked .sessions-log temp`, `tick stamps .gc_extras_last`); `test_registry_gc` keeps the bash → `am-core gc` plumbing (`test_registry_tmp_guard` was listed here too, but the Batch 2 re-run showed it does not notice a disabled temp sweep: it tests the writer's own signal guard, not GC) |
| `tests/test_state_hooks.sh` | `test_state_from_hook_reads_file` | 747 | Reads `_state_hook_read` through the test-only shim `_state_from_hook` (`test_helpers.sh:186-190`) | `tests/test_state.sh::test_state` (`_state_hook_read: waiting_user`, `_state_hook_read: background`); `test_state_integration` (`agent_get_state: reads hook file when pane is not shell`) |
| `tests/test_state_hooks.sh` | `test_state_from_hook_missing_file` | 759 | Same shim | `test_state` (`_state_hook_read: missing file`) |
| `tests/test_state_hooks.sh` | `test_state_from_hook_stale_file` | 770 | Same shim, 2 assertions | `test_state` (`stale running drops`, `stale file + stale activity drops`, `stale file + empty activity drops`) |
| `tests/test_state_hooks.sh` | `test_state_from_hook_invalid_state` | 799 | Same shim | `test_state` (`_state_hook_read: invalid state rejected`) |
| `internal/sessions/sessions_test.go` | `TestFormatRestorableDisplayBase` | 67 | One-row formatter check | `TestRestorableEntriesFromLog` (sessions_test.go:276), `TestRestoreNote` |
| `internal/sessions/sessions_test.go` | `TestReadRegistryValid` | 90 | Subsumed by the round-trip test in the same file | `TestRegistryRoundTripPreservesKnownAndFutureMetadata`; every `TestReapOrphans*`, `TestRefreshTitles*`, `TestRestoreScan*` reads a registry; `tests/test_cli.sh::test_cli_extended` L187-189 (`am list-internal`) |
| `internal/sessions/titles_test.go` | `TestClaudeFirstUserMessage` | 93 | The id-pinned reader is tested harder by its siblings | `TestClaudeFirstUserMessageDisambiguatesBySessionID`, `TestClaudeFirstUserMessageRequiresBoundID`, `TestClaudeFirstUserMessageFollowsRelocatedTranscript`, `TestRefreshTitlesTitleSources` (eight Go tests failed with the candidate skipped; `tests/test_utils.sh` passed under the same mutation, so the bash test is not a guard here) |
| `internal/sessions/titles_test.go` | `TestClaudeFirstUserMessageSkipsShort` | 141 | The length gate is one function, `titleWorthy` | `TestFirstUserMessageLengthGateCountsRunes`; `tests/test_utils.sh` L104-109 (`skips XML-only messages`) |
| `cmd/am-browse/browse_test.go` | `TestOutputProtocol` | 157 | Tautology: `newModel` never assigns `output`, so it asserts a zero value | `cmd/am-browse/newform_test.go::TestBrowserCtrlNOpensFormAndEscReturns` (:662, :673) for the two breakages applied; the submit hand-off itself (`main.go:297`) is guarded by `TestBrowserFormSubmitQuitsWithLine` (:677), see 3c |
| `tests/state_lab/cases/13-background-wait.sh` (steps 3-7 only; steps 1-2 kept, see the decision below) | via `tests/test_state_lab.sh::test_state_lab_cases` | — | 9 `lab_assert`s on the ✳ × background decision rows, 6 of them resolver-only rows fed by `printf` | `tests/test_state.sh::test_state_title_glyph` (`resolve: ✳ + background -> background (hook read)`, `✳ + fresh running -> running`, `✳ + stale running + stale activity -> running`, `✳ + no hook file + ephemeral/durable .sid -> unknown`, `busy + background -> running (wrap-up turn live)`); `tests/test_state_hooks.sh::test_state_hooks` (`Stop re-fire keeps background`, `Stop re-fire over background: mtime pinned`, `Stop + running subagent/shell/monitor/owned/orphaned shell: writes background`) |
| `tests/state_lab/cases/04-hook-stop-then-tool-race.sh` | via `test_state_lab_cases` | — | 6 `lab_assert`s on the Stop → PostToolUse grace window | `test_state_hooks` (`PostToolUse: flips aged ready to running (resumed turn)`, `PostToolUse: does not clobber fresh ready`), `test_state_hook_notify`, `test_state_hook_events` |
| `tests/state_lab/cases/09-dup-cwd-resolution.sh` | via `test_state_lab_cases` | — | 5 `lab_assert`s: two rows share a cwd, `AM_SESSION_NAME` picks one, no pane signal writes nothing | `test_state_hooks` (`AM_SESSION_NAME: targeted session updated` / `first session untouched`, `No pane signal: no state file written`, the `stranger:` block), `test_state_hook_cwd_sidecar` (`hook: unmanaged process in the launch dir writes no state` / `no sidecar`) |

Notes on the lab rows. Case 09 was rewritten in 5f7bd47 for the live
Obsidian-terminal incident, and the history pass said "keep if the lab
stays"; the mutation pass is what makes it removable: all three breakages
applied to the hook's session resolution were caught by `test_state_hooks`.
Case `12-unknown-state.sh` stays (3c: sole guard of the non-bulk
`display-message` failure path), so the wrapper `test_state_lab_cases` and
`tests/state_lab/` stay for case 12 alone. The skeptic's separate argument for
the wrapper (3c, argued: hook writer ↔ resolver reader vocabulary drift)
located that guard in case 13 steps 2-3, "the only assertions in the repo
where the real hook writes the file the real `_state_resolve` reads"; the
mutation pass on case 13 found every breakage applied caught elsewhere, and
the drift the skeptic describes is a two-sided edit (hook output changes,
`test_state_hooks` updated, `lib/state.sh` not) that no single mutation
samples. Decided 2026-10-06 (Batch 3): case 13 keeps the two steps where
the real hook writes and the real resolver reads (steps 1-2 of the file:
Stop with a running `background_tasks` entry → `background`, the re-fired
Stop with an empty array → `ready`); the five resolver-only rows it also
carried (busy glyph, non-Claude agent, hook silent with and without a glyph,
stale running) are deleted as duplicates of `test_state_title_glyph`. The
wrapper is kept for cases 12 and 13, and the header at
`tests/test_state_lab.sh:9-10` (which listed three cases while four existed)
names the two that remain.

### 3b. Simplify and merge (9, all M)

| File | Test | Line | Verdict | drop_lines | Why / into what |
|---|---|---|---|---|---|
| `tests/test_agents.sh` | `test_agents` | 4 | simplify | 14, 15, 25, 27, 28, 35, 36, 39, 40, 41, 42, 43, 46, 47, 48, 51, 52, 57, 58, 59, 60, 61, 62 | Hand-copied manifest facts (command, prompt mode, resume templates per type); every breakage caught by `internal/sessions/agents_test.go::TestAgentManifestFacts` (also `TestAgentAliasesAndUnknown`, `TestAgentManifestSharedWithBash`, `test_agent_manifest`). Keep the bash-reader assertions |
| `tests/test_install.sh` | `test_install_pi_extension` | 830 | simplify | 841, 842, 843, 844, 845 | The uninstall half; caught by `uninstall: pi extension link removed` in `test_installer_uninstall_reverses_install` |
| `tests/test_registry.sh` | `test_registry` | 4 | simplify | 18 (loosen, not delete) | Exact field-order pin on `registry_add`'s JSON. Rewrite to compare sorted `keys`: the field *set* is still guarded (a dropped `created_at` also defeats the GC grace window, `reap.go:66`, caught by `test_registry_gc`'s `row younger than the grace window is not reaped`) |
| `tests/test_registry.sh` | `test_auto_title_scan` | 672 | simplify | 736, 737, 738, 739, 740, 743, 744, 745, 746, 747 | The recorded lines are Tests 5 and 6 (first title for an untitled row; no rewrite when the pane title equals the task), the am-5 / am-6 rows of `TestRefreshTitlesTitleSources`; the "hysteresis and sidecar-only" wording below names the mutations the pipeline ran, caught by `TestRefreshTitlesTitleSources` (maintenance_test.go:382, am-6), `TestRestoreScanBindsIDFromSidecarOnly` (:177, :180), `TestResolveSessionIDSidecarOnly` (titles_test.go:459), and this file's `pi detect id: sidecar without a transcript → empty, no substitute` |
| `tests/test_state.sh` | `test_state_integration` | 94 | simplify | 196 (201 kept, see Batch 4) | `am wait` output; caught by `tests/test_cli.sh::test_cli_dispatch` (`am wait: single-session output is just the state`). Line 201 is `am interrupt` against a live session, not `am list --json --state` as this row first said; nothing else runs `am interrupt` on a session (`test_cli` covers only its flag parsing), so it stays |
| `internal/sessions/agents_test.go` | `TestAgentManifestTypes` | 10 | simplify | 30, 31, 32 | The every-type-restorable loop (not the `want` type list); caught by `TestRestorableRawLines`, `TestRestorableEntriesIncludeCodexExactID`, `tests/test_agents.sh::test_agent_manifest` (`no type is missing a load-bearing field`), `cmd/am-browse::TestFormOptionsNavigation` |
| `tests/test_bin_helpers.sh` | `test_symlinked_kill_and_switch` | 80 | merge | — | One assertion through the stub tmux; fold into `test_kill_and_switch_switches_client_before_kill` (every breakage caught by the `kill-and-switch:` stub assertions, e.g. `switch happens before kill`, `still kills target when no alternate exists`, `legacy one-arg form still works`) |
| `tests/test_recovery.sh` | `test_recovery_branch_guard_integration` | 668 | merge | — | 3.5s, two `agent_launch` + `recovery_run`; both breakages caught by `test_recovery_preflight_matrix` (`recovery preflight: re-allocated checkout: actionable reason`) and `test_recovery_sidecar_mirror` (`sidecar mirror: launch records the launch-directory branch`). Fold the one live-launch step into `test_recovery_reboot_integration`, which already launches |
| `internal/sessions/titles_test.go` | `TestClaudeFirstUserMessageMissingDir` | 207 | merge | — | One assertion; add the missing-directory case to `TestClaudeFirstUserMessageDisambiguatesBySessionID`. Both breakages caught by `TestStoreDispatch` (bare HOME, claude `JSONLExists`), `TestClaudeFirstUserMessageFollowsRelocatedTranscript`, `TestStoreDirAndTranscriptPath`, `TestRestorableEntriesFollowRelocatedClaudeTranscript`, `TestResolveSessionIDSidecarOnly` |

### 3c. Keep despite the proposal (67)

These looked low-value to the survey or the redundancy pass and are not. Each
deserves a one-line comment in the test file naming the regression, so the
next audit does not re-propose it.

**Mutation-confirmed sole guards (19).** The breakage named is one that only
this test caught when applied. Where the pipeline recorded a second breakage
it is listed too, so a re-run can find every mutation that justified the keep.

| File::test | Line | Proposed | Breakage(s) only this test caught |
|---|---|---|---|
| `tests/test_agents.sh::test_agents_extended` | 69 | merge | `agent_type_supported` accepting any non-empty type (`\|\| [[ -n "$agent_type" ]]`) |
| `tests/test_agents.sh::test_integration_lifecycle` | 101 | simplify | M2: `agent_kill` skipping `recovery_desired_remove`. M1 is not named in the evidence (it was also run against `tests/test_standalone_scripts.sh`) |
| `tests/test_doctor.sh::test_doctor_versions_minimums` | 100 | simplify | `lib/doctor.sh:69` `am_version_ge` argument order; `:65` `am_dep_min` for `bash` instead of `$tool` |
| `tests/test_doctor.sh::test_doctor_drift` | 123 | simplify | `lib/doctor.sh:292` manifest field rename (`lab` → `live_lab`) missed; `:298` `_doc_ver_newer` args swapped |
| `tests/test_fzf.sh::test_annotated_directories` | 4 | simplify | `_list_directories` ignoring `annotate` (`lib/fzf.sh:94`, `:102`); `_am_branch_batch` running `cat` instead of `am-core branch-batch` |
| `tests/test_install.sh::test_install_refresh_stamp` | 852 | simplify | M1: inverted `cmp` in `_install_refresh`'s Cursor hook copy refresh (fails `reports the Cursor hook copy refresh`, `Cursor hook copy matches the source again`). M2: `_install_is_stale` never true (fails `install stamp: a different stamp is stale`) |
| `tests/test_recovery.sh::test_recovery_native_adapters` | 545 | simplify | Resume args dropped for pi and codex only |
| `tests/test_registry.sh::test_titler_log_gated` | 530 | simplify | `am_core` running the binary with `env -u AM_TITLER_DEBUG` (the export never arrives); the Go twin cannot see this. A second mutation was run (full suite, candidate disabled) but is not named in the evidence |
| `tests/test_standalone_scripts.sh::test_standalone_status_bar` | 180 | simplify | M1: `SessionsLogGC`/`SnapshotGC`/`sweepTemps` moved from the extras half into the rows half of `GC` (`maintenance.go`), fails lines 235 and 237. M2: `Tick` dropping `e.GC(force)`, fails `tick stamps .gc_extras_last` (234), 235, 237 |
| `tests/test_state_hooks.sh::test_state_hook_cwd_sidecar` | 872 | simplify | Deleting `rm -f $AM_DIR/.title_scan_last` after the `.cwd` write (hook line 686) |
| `tests/test_tmux.sh::test_tmux_listing` | 48 | simplify | `tmux_count_am_sessions` counting an empty server as 1; `tmux_list_am_sessions` with `head -n 1` |
| `tests/test_utils.sh::test_git_head_branch` | 235 | simplify | `findGitDir` walk terminating on `cur == "/"` (a relative path outside a repo spins at `.`; `am-core branch sub` hit a 3s timeout) |
| `tests/perf_test.sh::run_perf_test "am list-internal"` | 129 | remove | A 3-attempt retry with 250ms sleeps around `tmux list-sessions` in `ListTmuxSessions`: P50 822ms / P95 1698ms reported as REGRESSION |
| `internal/sessions/review_test.go::TestReviewRebaseSuggestion` | 309 | simplify | Deleting the tree-dedup loop at `review.go:691-695` (the suggestion no longer disappears once its tree is in the chain) |
| `internal/sessions/maintenance_test.go::TestRestoreScanBindsIDFromSidecarOnly` | 113 | simplify | M1: `RestoreScan` falling back to the newest `*.jsonl` in `StoreDir` (the pre-fe7709a directory guess). M2: log branch read from the workdir (`meta.Workdir`) instead of the launch directory |
| `internal/sessions/maintenance_test.go::TestRefreshTitlesTitleSources` | 336 | simplify | Removing the `leadingNonAlnum` strip (`titles.go:222`) |
| `cmd/am-browse/browse_test.go::TestHelpText` | 125 | simplify | Deleting the `Ctrl-R Refresh session list` line from `helpText` while `case tea.KeyCtrlR` still works |
| `tests/test_cli.sh::test_cli_diff` | 1037 | remove | `_review_show` dropping `--record` from the `am-core review-stat` call (registry `review_*` never recorded) |
| `tests/state_lab/cases/12-unknown-state.sh` (via `test_state_lab_cases`) | — | remove | `lib/state.sh` non-bulk fetch: a failed `display-message` short-circuiting to `echo idle` (3/3 lab asserts fail; the full suite with the case removed stays green) |

What "sole guard under mutation" proves for a *simplify* candidate. The
pipeline's "candidate disabled" run skipped the whole test (the evidence says
"candidate skipped" / "candidate disabled"), so the result proves the test
must stay. It does not by itself prove the proposed `drop_lines` must stay,
and for nine of these the evidence attributes the catch to lines the proposal
would have kept:

| Test | drop_lines proposed | Where the evidence puts the catch |
|---|---|---|
| `test_doctor_versions_minimums` | 111 | "lines 112-114, 119, retained" |
| `test_doctor_drift` | 143 | line 144, same `$out`, whose expected text contains `pi` |
| `test_install_refresh_stamp` | 890 | "lines 879 and 887 of the same test imply line 890" |
| `test_titler_log_gated` | 547, 548 | "kept assertions l.546 and l.553" |
| `test_git_head_branch` | 313, 315, 317, 321, 323, 327 | "kept asserts, lines 311 and 319" |
| `TestReviewRebaseSuggestion` | 374 | first half, lines 310-352 (dedup at 350); `TestReviewSyncRebase` with the audit's one-line check appended |
| `TestRestoreScanBindsIDFromSidecarOnly` | 194, 195, 196 | the am-stale assertion at line 161, "identical fixture and outcome" |
| `TestRefreshTitlesTitleSources` | 377, 388, 389, 390, 391 | its own retained assertions 376 and 395 |
| `TestHelpText` | 127, 128, 129, 136, 137, 138, 139, 140 | "the kept loop at lines 131-135 subsumes the h==\"\" check" |

For these nine the drop_lines remain *candidates*: a line-level re-run
(remove only the drop_lines, re-apply the same breakages) decides them. Until
then they stay (rule 4). The opposite case is `test_standalone_status_bar`:
both breakages failed at lines 235 and 237, which are two of its four
drop_lines (235, 237, 280, 285), so that simplify is refuted at line level
for those two; 280 and 285 were not attributed either way.

**Argued sole guards (48, not mutated).** The skeptic named a concrete
regression only this test would catch; the pipeline did not apply it.

| File::test | Line | Proposed | Regression named |
|---|---|---|---|
| `tests/test_agents.sh::test_send_prompt_delay` | 319 | simplify | Deleting `sleep 0.1` at `lib/agents.sh:670`; only assertions 351-352 observe the pause |
| `tests/test_agents.sh::test_review_pane` | 422 | simplify | Dropping the review-pane exclusion from `tmux_shell_pane_state` (`lib/tmux.sh:508`); `.{top-left}` → `.{top}` in `lib/state.sh:328` |
| `tests/test_bin_helpers.sh::test_standalone_switch_last_errors` | 202 | remove | A path-resolution preamble in `bin/switch-last` (lines 6-13) that works only when symlinked; the direct path is the production binding. See section 8: the survey calls this test a tautology (asserts only rc==0) |
| `tests/test_cli.sh::test_cli` | 4 | simplify | L63-64 static grep for `BASH_VERSINFO[1] < 4`: the 4.4 minor clause of the gate at `am:7` (f3fd196 shipped the gate major-only); L33-34 the only unknown-*command* test (`am:2920-2928`) |
| `tests/test_cli.sh::test_cli_extended` | 123 | simplify | L175 and L178 are the only pins on the `directory` and `task` columns of the bash list row (`lib/fzf.sh:279`, `:305`) |
| `tests/test_cli.sh::test_cli_workspace_and_id` | 470 | simplify | L514: `cmd_new`'s `-*)` arm (`am:873-876`) losing the flag name in `Unknown option: $1` |
| `tests/test_completions.sh::test_completions_print` | 31 | simplify | Line 42 is the only read of the `completions` error text (`am:209-211`) |
| `tests/test_completions.sh::test_completions_bash` | 53 | simplify | The `_am_types` pipeline (`am:204-205`) dropping the last manifest type (`opencode`), line 86 |
| `tests/test_config.sh::test_config` | 4 | simplify | `am_notify_enabled`'s `has("notify")` read replaced by `am_config_get` (JSON `false` becomes empty), line 36; boolean coercion of `yes` (47→54); read-path alias canonicalization (51→52) |
| `tests/test_install.sh::test_am_install_dry_run_creates_nothing` | 139 | simplify | The only test running `am install --dry-run`; 155-157 and 164 have no other guard; 162 is the only check that the plan names the Claude settings file when it does not yet exist |
| `tests/test_install.sh::test_installer_points_at_am_install` | 316 | merge | The `scripts/install.sh` trailer (693-699) losing the hint that names `am install`; the wording-independent negative at line 331 is only possible on a direct run |
| `tests/test_install.sh::test_install` | 338 | simplify | L350: `am_version_ge` returning false when actual equals required; every other compare uses unequal pairs |
| `tests/test_install.sh::test_install_hooks_idempotent` | 664 | merge | The marker-filter step of `_install_claude_hooks` (`install.sh:169-176`); the only test that runs the installer twice and counts hook entries |
| `tests/test_install.sh::test_enable_codex_hooks_feature_new_file` | 737 | merge | The merge premise was wrong: the idempotent test's runs 2-3 take the awk branch (`install.sh:212-245`), which repairs a wrong first write before the asserts run |
| `tests/test_presets.sh::test_presets` | 5 | simplify | The `--` sentinel leaking into stored args (`_preset_from_flags`, `lib/presets.sh:100`); L32-35 |
| `tests/test_recovery.sh::test_recovery_coordinator` | 262 | simplify | Deleting the second `recovery_desired_is_open` re-check (`lib/recovery.sh:647-651`), lines 327-337; the exited-agent `recovery_error` text, 323-325 |
| `tests/test_registry.sh::test_registry_extended` | 49 | simplify | 176-177: the only drive of `jsonl-exists` with a Cursor sid whose hook-reported transcript has a different filename stem |
| `tests/test_standalone_scripts.sh::test_standalone_preview` | 4 | simplify | `lib/preview` regaining a directory-based guess after the `.sid` loop (line 50), caught by line 71; a wrong sidecar path (`preview:44-45`), caught by line 78 |
| `tests/test_standalone_scripts.sh::test_standalone_status_bar_layout` | 496 | simplify | Deleting the second ladder rung `"full:both:true:short:full"` at `lib/status-bar:401`, caught by line 622 |
| `tests/test_state_hooks.sh::test_state_hooks` | 4 | simplify | Re-adding a directory guess for Cursor payloads (`workspace_roots[0]`, removed in 5f7bd47), caught by line 568 |
| `tests/test_state_hooks.sh::test_state_hook_notify_osascript_utf8` | 1012 | simplify | Inline interpolation replacing `on run argv` in the osascript call (`state-hook.sh:213-215`); line 1018-1019 is the only assertion that fails |
| `tests/test_state_hooks.sh::test_state_hook_fence` | 1216 | simplify | A per-occurrence `${rest#*…}` loop in `_fence_hit` (`state-hook.sh:645-648`): 27-33s per hook run, caught only by the timing assertion at 1308 |
| `tests/test_state_lab.sh::test_state_lab_cases` | 12 | remove | Hook writer (`state-hook.sh:477-499`, `:104-109`, `:780`) ↔ resolver reader state-vocabulary contract. The skeptic located this in case 13's hook-written steps; Batch 3 keeps those two steps, so the wrapper is kept for both case 12 (mutation-confirmed sole guard) and this argument |
| `tests/test_state.sh::test_state` | 4 | simplify | Dropping the activity term from `_state_hook_read` (`lib/state.sh:239-242`), line 58; `background` dropped from the persistent case (`:236`), line 32 |
| `tests/test_state.sh::test_agent_wait_state_stable_idle` | 555 | merge | The reset branch of the stable-polls arm (`lib/state.sh:586-592`) no longer re-recording `last_match_activity` |
| `tests/test_tmux.sh::test_tmux_binding_snippets` | 98 | simplify | Dropping the index from `command-alias[100]` (`lib/tmux.sh:106`), line 127 |
| `tests/test_tmux.sh::test_tmux_config_refreshes_stale_helpers` | 141 | merge | Swapping `#{client_name} #{session_name}` in the `prefix x` binding (`lib/tmux.sh:94`), line 166 |
| `tests/test_utils.sh::test_utils_extended` | 40 | merge | Lines 45, 46, 51, 56 are the only guards of their `lib/utils.sh` branches (`_format_seconds` negative guard, verbose days, `truncate` boundary), verified by overriding each function |
| `tests/test_utils.sh::test_claude_first_user_message` | 79 | simplify | Deleting the tag strip in `cleanContent` (`titles.go:544`), caught only by 104-109 |
| `tests/test_utils.sh::test_first_user_message_char_length` | 337 | simplify | `titleWorthy` replaced by `len(text) > 10` in the pi/cursor readers (`titles.go:629`, `:446`), lines 383 and 393 |
| `tests/test_utils.sh::test_file_mtime_and_log_cap` | 403 | simplify | Moving `_am_stat_flavor_init` into the `$(...)` helpers (`lib/utils.sh:368`, `:378`), caught only by line 428 |
| `tests/test_utils.sh::test_utils_dep_minimums` | 452 | simplify | Lowering or dropping the jq minimum (`lib/utils.sh:148`); only `:458` notices |
| `tests/test_registry.sh::test_auto_title_scan_workdir` | 1140 | remove | Drift in the JSON key for `Session.Workdir` (`sessions.go:34`) that `RefreshTitles` writes (`titles.go:117`) and bash reads |
| `tests/test_registry.sh::test_registry_gc` | 247 | remove | Bash-written `created_at` parsed as RFC3339 by the Go reaper (`reap.go:66`); a parse failure means no grace window (280-283, 353-360); also 327-332, the extras sweep under a fresh `.gc_last` |
| `tests/test_utils.sh::test_pi_first_user_message` | 144 | remove | `pi_first_user_message: block content` (:170-175) against `piFirstUserMessage`'s inline record struct (`titles.go:615-621`) |
| `tests/test_recovery.sh::test_recovery_batch_partial_success` | 864 | remove | Dropping identity-less desired rows from `recovery_desired_candidates` (`lib/recovery.sh:679-686`) |
| `tests/test_recovery.sh::test_recovery_sidecar_mirror` | 479 | remove | `recovery_sync_live_sidecars` (`lib/recovery.sh:355-361`) not refreshing `branch` when only the branch changed, line 523 |
| `tests/test_recovery.sh::test_recovery_reboot_integration` | 598 | remove | The only run of `recovery_restore_one` with a real `agent_set_workdir` and `effective_directory` ≠ `project_directory` (652-655) |
| `internal/sessions/reap_test.go::TestReapOrphansAllDeadEmptiesRegistry` | 189 | remove | The only test of the cell "empty live set and more than one registry row" |
| `internal/sessions/review_test.go::TestRefreshTitlesReviewCount` | 465 | simplify | The `.dirty` gate in `refreshedReview` (`titles.go:196-198`): `<=` vs `<`, or the `dirtyAt == 0` short-circuit (490-494, 504-511) |
| `internal/sessions/sessions_test.go::TestFormatDisplayDefaults` | 56 | merge | The four empty-field branches of `FormatDisplayBase` (`sessions.go:241-270`) |
| `internal/sessions/sessions_test.go::TestReadRegistryBadJSON` | 168 | merge | `ReadRegistry`'s Unmarshal-error branch returning the pre-allocated registry (`sessions.go:228`) |
| `internal/sessions/sessions_test.go::TestEnvOr` | 392 | remove | `EnvOr` losing its default branch (`sessions.go:325-330`); the suite exports every `LoadEnv` key, so nothing else reaches the default |
| `internal/sessions/agents_test.go::TestAgentManifestFacts` | 36 | remove | `pi.hook_family` / `opencode.hook_family` edited away from its own family (`agents.manifest:91`, `:103`) |
| `cmd/am-browse/browse_test.go::TestWordPrefix` | 62 | merge | Off-by-one on `wordPrefix`'s loop bound (`main.go:539`); lines 67, 69, 70 have the query at end of text |
| `cmd/am-browse/newform_test.go::TestFormFieldsAndAgents` | 74 | simplify | A change to the *set* of agent select options (`newform.go:150`), e.g. aliases appended; lines 83 and 86 |
| `cmd/am-browse/newform_test.go::TestFormView` | 624 | simplify | Line 629: unifying the two hint rows (`newform.go:626-627`) into one width-fitted row; the `f.agent` interpolation in `Enter: launch <agent>` |
| `cmd/am-browse/newform_test.go::TestBrowserFormSubmitQuitsWithLine` | 677 | remove | Deleting `m.output = f.output` in `model.Update`'s `case formSubmit:` (`main.go:297`); also the standalone-cancel branch (`main.go:299-303`) and `openForm`'s prefill plumbing (`main.go:167-172`). The pipeline's candidate record names this test `TestFormSubmitOutput` (evidence line 0); no test of that name exists in the file — the skeptic's reasoning identifies the real one |

### 3d. Partial drops cleared on argument inside kept tests (A, not mutated)

The skeptic examined each kept test's proposed `drop_lines` and, for the lines
below, found no breakage they alone would catch. None of these was mutated.
They are listed so the owner can act on them; each needs a line-level
mutation check before it is applied (batch 5), because the removal rule
applies to lines as much as to tests.

| File::test | Lines cleared | Keep | Condition / why |
|---|---|---|---|
| `tests/test_cli.sh::test_cli` | 19-23, 30-31, 42, 53-62, 73-74, 85-87, 92-93 | 33-34, 63-64 | Absence pins on removed flags and one-line help; 53-62 is a strict subset of `test_standalone_bash_version_gate` L128-136; 86-87 pin an accidental omission of `--history`/`--grep` from the peek sub-help |
| `tests/test_cli.sh::test_cli_extended` | 165-182 | — | Only after adding `.[0].directory == "$test_dir"` and `.[0].task == "cli test"` to the JSON block at L152-157 (closes the `fzf_list_json` index gap, `lib/fzf.sh:375-376`, and replaces L175/L178) |
| `tests/test_cli.sh::test_cli_extended` | 199-200 | — | Absence pin on removed config keys; the config side is `test_config` L62-75 |
| `tests/test_cli.sh::test_cli_extended` | 300-301 | — | `AM_DEFAULT_AGENT` through the CLI; `cmd_config`'s get arm is a bare call to `am_default_agent`, already routed by L290-292 and tested directly by `test_config` L58-60 (cluster, high confidence) |
| `tests/test_cli.sh::test_cli_workspace_and_id` | 512-514 | — | Only after moving L514's `Unknown option: -W` message check into `test_cli` as one `assert_contains` on the `--sandbox` call's stderr (the message text is pinned nowhere else) |
| `tests/test_cli.sh::test_cli_diff` | 1163-1166 and the in-process `registry_remove` call | the rest | `registry_remove` is a jq rewrite that never knows the repository; the assertion detects a strict subset of `test_launch_review_checkpoint` L398-401, which asserts the same ref survives `agent_kill` (cluster, high confidence) |
| `tests/test_completions.sh::test_completions_print` | — | 42; strengthen 44 | Line 44 (no shell argument, rc only) passes the `"${2:-}"` → `"$2"` regression it exists for (`set -u` exits 1 either way); add the `bash\|zsh` message check to it instead of dropping it |
| `tests/test_completions.sh::test_completions_bash` | 65, 69, 76, 78 | 86 and the rest | 69 is implied by 71; 65 and 76 are second members of static strings; 78 fails only when the `wait` token is deleted from `am.bash:62` |
| `tests/test_config.sh::test_config` | 19, 74, 75, 77 | 36, 47-54, 51-52 | None of the three unique guards live in these lines; the yolo/sandbox prune asserts (21, 64-77) should go together with `_AM_CONFIG_OBSOLETE_KEYS` at `lib/config.sh:12`, not before (history pass) |
| `tests/test_install.sh::test_install` | 346-349, 483 | 350 | 348/349 restate `test_utils_dep_minimums`' strict cases; 483 (`tmux` anywhere in the output) is always satisfied by `Refreshing tmux config...` (`am:2796`). Dropping 346-350 also removes the hidden order dependency on `test_install_refresh_stamp` sourcing `utils.sh`; keep 350 by moving it where `utils.sh` is sourced |
| `tests/test_presets.sh::test_presets` | 28, 39, 51 | 32-35, 45, 56-59, 65-69, 76 | 39 is a confirmed tautology; 51 is a strict substring of 52; 28 guards only the save success message |
| `tests/test_recovery.sh::test_recovery_coordinator` | 296-297 | 298, 323-325, 327-337 | `assert_contains` is a glob substring match; 298's exact equality on line 2 of the capture implies 296 |
| `tests/test_registry.sh::test_registry_extended` | 90-92 | 176-177 | `registry_add` → `registry_count` after multiple adds is asserted at L16-34 and by `test_registry_concurrency` L1082-1087 |
| `tests/test_standalone_scripts.sh::test_standalone_preview` | 84 | 71, 78 | The "corrupted transcript" run repeats line 43's code path: `AM_STATE_DIR` is always exported in the suite, so no sidecar is found and the transcript branch is skipped |
| `tests/test_state_hooks.sh::test_state_hooks` | 235, 290, 319, 363, 420, 517, 518, 566, 572, 574, 722 | 568 | Each covered by a named sibling assertion (`test_state_hook_notify` 991-994 for 319; 296 for 290; 368 for 363; 100/106-112 for 420; 520-525 for 517-518; 665-689 for 572/574/722). 566 (pi untouched) is weak even against the Cursor-guess regression because the family gate skips the pi row |
| `tests/test_state_hooks.sh::test_state_hook_notify_osascript_utf8` | 1024; loosen 1018 | 1016-1017, 1021-1025 | 1024 is a platform canary (osascript decodes argv as UTF-8) that cannot fail on an am change; 1018-1019 over-pins the phrase — loosen to `grep -q 'on run argv'`, which keeps the guard |
| `tests/test_tmux.sh::test_tmux_binding_snippets` | 123 | 125, 127 | 123's needle is a strict suffix of 125's and also appears in the alias line; despite its label it never checked `bind s` |
| `tests/test_utils.sh::test_utils_extended` | 65 | 45, 46, 51, 56 | Same `generate_hash` determinism check as `test_utils` line 28 with a different literal |
| `tests/test_utils.sh::test_claude_first_user_message` | 96 | 102-136 | `empty when no JSONL` takes the identical Go path as line 127 (`empty for an unknown id`) with a weaker fixture; also passes when `bin/am-core` is missing |
| `tests/test_utils.sh::test_first_user_message_char_length` | 358 | 383, 393 | Fixture tautology: runs bash on the fixture string with no production code on the path |
| `tests/test_utils.sh::test_utils_dep_minimums` | 456, 457, 459 | 458 | tmux 3.2 and fzf 0.40 are pinned by `test_doctor_versions_minimums` lines 112-113 and `test_cli_missing_dependency_points_at_install` line 118; go 1.19 by `test_install` line 487 |
| `tests/test_agents.sh::test_review_pane` | 453, 454 | the rest | The same `git show-ref --verify refs/am/<s>/baseline` right after `agent_launch` is `test_launch_review_checkpoint` lines 392-393, which runs even when `bin/am-review` is not built |
| `tests/test_agents.sh::test_send_prompt_delay` | 353, 354 | 351, 352 | Exact `"0.1"` pins; the one breakage they alone catch (a malformed interval after the pause becomes a variable) needs an intermediate refactor, and they also fail on a legitimate retune. Cleared with that caveat |
| `internal/sessions/review_test.go::TestRefreshTitlesReviewCount` | 523, 524, 525 | 490-494, 504-511, 526-528 | `ReviewAck` on a launch-only chain is the same state as `TestReviewLaunchAckAndStat:92` and `TestReviewAdoptAndDrop:426`; 526-528 do not depend on the ack |

Rule 2 (simplify implementation pins) is applied through this table, not 3b:
of the five implementation-pin tests, `test_cli` and `test_utils_dep_minimums`
have their pin lines cleared above with the one sole-guard line each kept;
`TestHelpText` is in the line-level re-run list (its catch is attributed to
the kept loop); `TestFormView` line 629 and `test_installer_points_at_am_install`
are sole guards and stay whole.

## 4. Structural findings

### Bash ↔ Go twins

Since the am-core move (fe7709a, 5e3ad28, 2026-09-07) `auto_title_scan`,
`registry_gc`, `sessions_log_*`, `_sessions_log_detect_id_for_session`,
`_sessions_log_jsonl_exists`, `git_head_branch` and the `*_first_user_message`
functions are one-line `am_core` execs. Their bash tests re-run a behavior
matrix that `internal/sessions` tests cover assertion for assertion. The
mutation pass shows what the bash copy still owns:

| Behavior | Bash test | Go twin | Result |
|---|---|---|---|
| GC extras half | `test_registry_gc_extras` | `TestGCExtras` | bash removable (3a) |
| Title + restore scan | `test_auto_title_scan` | `TestRestoreScanBindsIDFromSidecarOnly`, `TestRefreshTitlesTitleSources` | bash trimmed (3b); the rest is the env hand-off |
| GC rows half | `test_registry_gc` | `TestGCHalvesAndGrace` | bash kept: `created_at` RFC3339 contract across the boundary (3c, argued); the cluster's ask to add the marker-independence case to `TestGCHalvesAndGrace` still stands as an addition |
| Workdir / branch refresh | `test_auto_title_scan_workdir` | `TestRefreshTitlesWorkdirAndBranch` | bash kept: the `workdir` JSON key contract (3c, argued) |
| Titler trace gate | `test_titler_log_gated` | `TestTitlerLogGatedAndCapped` | bash kept: the `env -u` mutation was caught only there (3c, M) |
| `GitHeadBranch` | `test_git_head_branch` | `TestGitHeadBranch` | bash kept: relative-path walk caught only there (3c, M); the cluster's port (three relative cases with `t.Chdir`) would move that guard to Go — section 8 |
| Claude first message | `test_claude_first_user_message` | three Go tests | the duplication is *inside Go*: two Go tests removable (3a), one merged (3b); bash kept for the tag strip (3c, argued) |
| Length gate | `test_first_user_message_char_length` | `TestFirstUserMessageLengthGateCountsRunes` | bash kept (3c, argued): the pi and cursor readers' short-message rejection (lines 383, 393) exists only in bash until `TestPiFirstUserMessage` / `TestCursorFirstUserMessage` get a short first line |
| pi reader | `test_pi_first_user_message` | `TestPiFirstUserMessage` | bash kept (3c, argued): block content (170-175); the cluster's port (second-file and array cases into the Go test) ends that uniqueness — section 8 |
| cursor reader | `test_cursor_first_user_message` | `TestCursorFirstUserMessage` | never a candidate (survey verdict keep, no skeptic entry). Cluster, low confidence: the bash standard-layout fallback (220-222) and missing-session asserts are the only tests of `cursorStandardTranscriptPath` / `cursorTranscriptsDir` (`titles.go:414-418`); port them into the Go test first, then the bash test becomes a one-line-wrapper check — section 8 |

Rule that follows: the Go test owns the behavior matrix; one bash scenario
per `am-core` subcommand owns the plumbing (explicit env hand-off in
`am_core`, exported-only vars `HOME` / `AM_TITLER_DEBUG` / `AM_GC_GRACE_SECS`,
the JSON keys both sides read, a real tmux server where the Go test fakes
one). Bash-only logic with no Go twin stays whole: `test_registry_concurrency`
(perl flock on macOS), `test_registry_tmp_guard`.

### CLI ↔ lib

| Behavior | Survivor | Duplicate | Result |
|---|---|---|---|
| `AM_DEFAULT_AGENT` overrides saved default | `tests/test_config.sh::test_config` L58-60 | `test_cli_extended` L300-301 | cleared on argument (3d); not mutated |
| bash < 4.4 gate | `test_standalone_bash_version_gate` L128-136 | `test_cli` L50-62 | `test_cli` kept for L63-64 (3c); L53-62 cleared (3d) |
| Review refs outlive the registry row | `test_launch_review_checkpoint` L398-401 | `test_cli_diff` L1163-1166 | `test_cli_diff` kept for the `--record` wiring (3c, M); L1163-1166 and the in-process `registry_remove` call cleared (3d) |
| `am wait <s>` prints the state alone | `test_cli_dispatch` L951-952 | `test_state_integration` L193-196 | simplify confirmed (3b, line 196) |
| `cmd_new` unknown option | `test_cli` L25-31 | `test_cli_workspace_and_id` L510-514 | kept: the message text is pinned only at L514 (3c); move it, then 512-514 go (3d) |
| `_state_hook_read` cases | `test_state` | four `test_state_from_hook_*` | remove confirmed (3a) |
| Claude glyph × hook table | `test_state_title_glyph` | lab cases 12, 13 | 13 removable, 12 sole guard |
| Hook event map, race guard | `test_state_hooks` | lab case 04 | remove confirmed |
| Hook session resolution | `test_state_hooks` | lab case 09 | remove confirmed |
| Native resume adapters | `test_recovery_coordinator` | `test_recovery_native_adapters`, `test_agents`, `TestAgentManifestFacts` | `test_agents` trimmed (3b: its resume-template lines 57-62 are among the drop_lines, caught by `TestAgentManifestFacts`); `test_recovery_native_adapters` kept (3c, M: a pi/codex-only mutation was caught only there); `TestAgentManifestFacts` kept (3c, argued: `hook_family` pins) |
| Branch-guard preflight | `test_recovery_preflight_matrix` | `test_recovery_branch_guard_integration` | merge confirmed (3b) |
| Codex hooks feature flag | `test_enable_codex_hooks_feature_idempotent` | `_new_file` | kept: the premise was wrong (3c) |
| Form output line | `TestBrowserCtrlNOpensFormAndEscReturns` (prefix, separators, cancel → empty) and `TestBrowserFormSubmitQuitsWithLine` (the `m.output = f.output` hand-off, `main.go:297`) | `TestOutputProtocol` | tautology removed (3a); the cluster's third member `TestFormSubmitOutput` does not exist in `newform_test.go` — the test meant is `TestBrowserFormSubmitQuitsWithLine` (:677), kept (3c) |
| Non-git workdir blanks branch | `test_auto_title_scan_workdir` step 5 (1195-1202) | `TestRefreshTitlesNonGitWorkdirBlanksBranch` | not verified; here the *Go* test is the deletable one (the bash test stays for the `workdir` key contract); the better move is to fold it into `TestRefreshTitlesWorkdirAndBranch` (titles_test.go:493) |

### Files where setup dominates

| File | Setup pattern | Observation |
|---|---|---|
| `tests/test_cli.sh` (49.8s, worker 5 alone) | three integration functions each `setup_integration_env` + 4-15 stub launches; `am wait --state idle --timeout 20` waits out the 5s `starting` window | Seven aggregate functions, so every verdict is per block; the file's high-value core (send/queue/background, restore-relocation/fence/owner, `cmd_cd`, doctor smoke) was not proposed and must not be touched |
| `tests/test_agents.sh` (21.1s) | 8 of 11 tests `setup_integration_env` + at least one `agent_launch` | `test_review_pane` lines 513-515 busy-wait until the session is 6s old so `am send` exits 2 instead of 4; `cmd/am-review/note_test.go` covers both exit codes (`TestSendNoteRefusedWithoutAgent`, `TestSendNoteQueuedWhenBusy`), so the check could accept either and drop the wait (~6s). `test_integration_lifecycle` 166-179 repeats what 158-159 asserts (~1s), but the test is a mutation-confirmed sole guard: trim, do not remove |
| `tests/test_recovery.sh` (17.1s) | every test re-sources four libs; stubbing tests `unset -f` production functions at the end | `test_recovery_agent_start_stability` must exhaust a 30×0.1s window (5.3s); the `unset -f` pattern broke later tests once (2a457b2) |
| `tests/test_standalone_scripts.sh` (16.7s) | three status-bar tests each re-source five libs and run setup/teardown | `test_standalone_status_bar` lines 259-292 have been a permanent `skip_test` since c15c4e7 (the `""` at line 264 becomes `sleep ''`); deleting that `""` revives the block and saves ~3s |
| `tests/test_state_hooks.sh` (12.7s) | one 730-line function, ~100 hook subprocesses each forking jq, three `sleep 0.4` | A failure reports only the label; splitting by theme (exit-0 robustness, event map, guards, background_tasks, identity, resolution, stranger) helps more than any assertion drop |
| `tests/test_bin_helpers.sh` (4.5s) | tests 1-5 share a stub tmux (cheap); tests 6-7 each run a real tmux cycle | Tests 6-7 are nearly all of the 4.5s; one of them is the tautology the skeptic kept (section 8) |
| `tests/test_state.sh` (6.7s) | two integration tests pay `setup_integration_env` + launches (3.2s + 3.5s); four unit tests total 0.5s | — |

Hub functions that cannot be judged or removed as units (history pass):
`test_state_hooks` (743 lines, 100 assertions, 25 hunk-touches),
`test_cli_workspace_and_id` (376; named for a `-W` flag removed five days
after it was added), `test_cli_extended` (347; 30 hunk-touches, the most
touched function in the suite), `test_auto_title_scan` (324). They absorb
every feature change; the right move is a split by theme, not a verdict.

## 5. Expected effect

**Tests removed:** 11 named tests + 3 lab cases (3a) + 3 merged away (3b)
= 17 of 257 (6.6%).

**Assertions removed:** 3a removes 52 (bash 22: `test_auto_title_session` 1,
`test_registry_gc_extras` 16, the four `test_state_from_hook_*` 5; Go 10
checks; 20 `lab_assert`s: 9 + 6 + 5). 3b lists 44 drop_lines, of which line
18 of `test_registry` is rewritten rather than deleted (43 deleted), and
roughly 10-15 of the 44 are assertions; the three merges fold 1 + 6 + 1 = 8
assertions into other tests without losing them. Net: about 65 of 1617
assertions (4%), plus the test-only shim `_state_from_hook`
(`test_helpers.sh:186-190`) and `_ensure_state_lib_sourced`
(`test_state_hooks.sh:736-745`). 3d, if every line survives its check, is
another ~75 lines, mostly absence pins in `test_cli.sh`.

**Seconds saved:** about 5s of CPU, no change to wall time. Workers per
`WORKER_PLAN` in `tests/test_all.sh:185-194`.

| Item | s | Worker |
|---|---|---|
| `test_recovery_branch_guard_integration` (merge) | 3.5 | 2 |
| lab cases 04, 09, 13 (of `run.sh`'s 1.19s for four cases) | ~0.9 | 4 |
| `test_auto_title_session`, `test_registry_gc_extras` | 0.15 | 2 |
| four `test_state_from_hook_*` | ~0.2 | 1 |
| `test_symlinked_kill_and_switch` | <0.1 | 6 |
| `test_install_pi_extension` lines, Go tests, other trimmed lines | <0.3 | 1, 8 |

Wall time is set by worker 5 (`test_cli.sh`), which this plan does not
shorten. The wall-relevant findings of this audit are both "keep the guard,
fix the test": the 6s busy-wait in `test_review_pane` (`test_agents.sh`,
worker 3) and the dead skip block in `test_standalone_status_bar`
(`test_standalone_scripts.sh`, worker 7). They belong in the speed plan.

**Maintenance churn removed:** small. Only 28 of 518 commits (5%) touch
tests without a production change, and no test file exceeds a 0.19 test-only
ratio except the runner. The tests removed here have near-zero churn:
`sessions_test.go` 0 of 12 commits test-only (8 of 18 tests untouched since
they were added), `titles_test.go` 0 of 13, `browse_test.go` 0 of 9,
`test_state_hooks.sh` 1 of 36, `test_registry.sh` 3 of 28 (one a flake fix on
`test_registry_gc_go_path`, kept), `test_bin_helpers.sh` 1 of 7 (the 4b79401
bulk-add), the lab wrapper 2 of 2. What is removed is dead weight, not
upkeep. The upkeep that exists lives in the hub functions this plan keeps.
One concrete saving: adding an agent today means editing the manifest,
`TestAgentManifestTypes`' want, `TestAgentManifestFacts`' cases,
`tests/test_agents.sh:810` / `:861` (in `test_agent_manifest`), and the
per-type pins in `test_agents` (lines 14-62: command, prompt mode, resume
template for all five types). The 3b `test_agents` drop removes that last
site. The other four stay: the `TestAgentManifestTypes` drop (30-32) removes
the restorable loop, not the want list, and no 3b row touches
`test_agent_manifest`. Folding `TestAgentManifestTypes` into
`TestAgentManifestFacts` as one table-driven test (the file note's option)
would remove one more; it is not in this plan.

## 6. Execution plan

One commit per batch. Each batch is verified by (a) `./tests/test_all.sh`
green and `go test ./...` green, and (b) re-applying, in a scratch worktree,
the mutations that justified the batch and checking that the named surviving
assertions fail. Each batch also adds the one-line keep-comment (3c) to the
kept tests in the files it touches. Where the evidence records the catchers
but not the edit, the verify step says so; the re-run applies an edit of the
same shape.

### Batch 1 — dead and tautologies

| File | Change |
|---|---|
| `cmd/am-browse/browse_test.go` | delete `TestOutputProtocol` (157) |
| `tests/test_state_hooks.sh` | delete `test_state_from_hook_reads_file` (747), `_missing_file` (759), `_stale_file` (770), `_invalid_state` (799) and `_ensure_state_lib_sourced` (736-745); drop them from the file's runner list |
| `tests/test_helpers.sh` | delete the shim `_state_from_hook` (186-190) |
| `tests/test_registry.sh` | delete `test_auto_title_session` (642) |

**Verify** → mutate `_state_hook_read` in `lib/state.sh` (return the raw
value without the 180s gate; accept an invalid value) and expect
`tests/test_state.sh::test_state`'s `_state_hook_read: stale running drops`,
`stale file + stale activity drops`, `stale file + empty activity drops` and
`_state_hook_read: invalid state rejected` to fail. Mutate `registry_update`
(write the wrong field) and expect `registry_update: changes field`,
`registry_get_fields: updated field (5th field)` and `concurrency: no parallel
registry_update lost (lost=12 of 12)` to fail. For `TestOutputProtocol`,
re-apply the two recorded breakages (the evidence names only their catchers)
and expect `TestBrowserCtrlNOpensFormAndEscReturns` to fail at
`newform_test.go:662` and `:673`. Separately, as a check that the hand-off
guard is still in place: delete `m.output = f.output` at `main.go:297` and
expect `TestBrowserFormSubmitQuitsWithLine` (:677) to fail;
`TestBrowserCtrlNOpensFormAndEscReturns` never submits and will not.

Re-run result (2026-10-05, before the Batch 1 commit): 6 of 7 mutations
reproduced. The "accept an invalid value" mutation (drop the
`_state_normalize` call) is an equivalent mutant: the `case` in
`_state_hook_read` has arms only for the valid states, so a bogus value falls
through to empty either way and no test can distinguish the two. The removed
`test_state_from_hook_invalid_state` asserted exactly what `test_state`'s
`_state_hook_read: invalid state rejected` asserts, on the same function, so
the removal stands on duplication, not on that mutation.

### Batch 2 — confirmed duplicates, Go and bash ↔ Go

| File | Change |
|---|---|
| `tests/test_registry.sh` | delete `test_registry_gc_extras` (377) |
| `internal/sessions/sessions_test.go` | delete `TestFormatRestorableDisplayBase` (67), `TestReadRegistryValid` (90) |
| `internal/sessions/titles_test.go` | delete `TestClaudeFirstUserMessage` (93), `TestClaudeFirstUserMessageSkipsShort` (141); move `TestClaudeFirstUserMessageMissingDir` (207) into `TestClaudeFirstUserMessageDisambiguatesBySessionID` |

**Verify** → three breakages in the extras half of `GC` (the evidence records
the catchers: the `SessionsLogGC` rule → `TestGCExtras`'s sessions-log names
and `sid-gone.txt exists`; the leaked-temp sweep → `TestIsLogCapTemp`,
`TestGCExtras`, `test_standalone_status_bar`'s `tick sweeps a leaked
.sessions-log temp`; the extras stamp → `test_standalone_status_bar`'s
`tick stamps .gc_extras_last` and `tick prunes a sessions-log entry whose
transcript is gone`). Mutate `ReadRegistry` / `FormatRestorableDisplayBase`
and expect `TestRegistryRoundTripPreservesKnownAndFutureMetadata` /
`TestRestorableEntriesFromLog` and `TestRestoreNote` to fail. Mutate
`claudeFirstUserMessage` (the bound-id read) and `titleWorthy` and expect
`TestClaudeFirstUserMessageDisambiguatesBySessionID`,
`TestClaudeFirstUserMessageRequiresBoundID`,
`TestFirstUserMessageLengthGateCountsRunes` to fail (the recorded run also
failed `TestRestoreScanClaudeTranscriptSidecar` and `TestPiFirstUserMessage`;
`tests/test_utils.sh` stayed green and is not expected to fail). For the
`TestClaudeFirstUserMessageMissingDir` merge, break the missing-directory
path (`claudeTranscriptPath`'s store-wide search when the project directory
is gone) and expect `TestStoreDispatch` (bare HOME, claude `JSONLExists`),
`TestClaudeFirstUserMessageFollowsRelocatedTranscript`,
`TestStoreDirAndTranscriptPath`,
`TestRestorableEntriesFollowRelocatedClaudeTranscript` and
`TestResolveSessionIDSidecarOnly` to fail, plus the merged case itself.

Re-run result (2026-10-05, before the Batch 2 commit): all nine mutations
(the three GC breakages, `isLogCapTemp`, `ReadRegistry`,
`FormatRestorableDisplayBase`, `extractContent`'s string branch, the
`titleWorthy` gate, `claudeStoreSearch` panicking on a missing store root)
were caught by the named Go tests and status-bar assertions. Two
attributions were wrong: `test_registry_tmp_guard` stays green with the temp
sweep disabled (corrected in 3a), and `TestGCHalvesAndGrace` does not notice
a missing extras stamp (`TestGCExtras` does). The merged missing-directory
case first stayed green under the store-root panic because the merged test
had already created a store under its HOME; the case now runs under a fresh
HOME with no store root, which the panic mutation fails. Of the four other
tests expected to fail under that mutation, only `TestStoreDispatch` and
`TestStoreDirAndTranscriptPath` did; the relocation tests all have a store
root. Bash tests run from a worktree must get `AM_LIB_DIR=<worktree>/lib`,
or they exec the main checkout's `bin/am-core` and every bash mutation
result is a false green.

### Batch 3 — state lab

| File | Change |
|---|---|
| `tests/state_lab/cases/` | delete `04-hook-stop-then-tool-race.sh`, `09-dup-cwd-resolution.sh`; trim `13-background-wait.sh` to its two hook-written steps (decision above) |
| `tests/test_state_lab.sh` | fix the header (9-10): cases 12 and 13; keep-comment on the wrapper |
| `tests/state_lab/` | the lab stays as the opt-in repro harness: `README.md` rewritten for the hook + resolver harness (it still described the JSONL and pane drivers removed in 476d563), the dead helpers `lab_xfail`, `probe_agent_get_state`, `probe_resolve_bulk` removed from `lab.sh`, `run.sh`'s usage example updated |

The optional port-and-delete (case 12's assertions into `tests/test_state.sh`,
then drop the wrapper, the lab, and `run_state_lab_tests` from worker 4) is
not taken: with case 13 kept the lab holds an integration check that has no
home in `tests/test_state.sh`.

**Verify** → (1) mutate `lib/hooks/state-hook.sh`'s Stop → PostToolUse grace
window; expect `test_state_hooks`' `PostToolUse: flips aged ready to running
(resumed turn)` and `PostToolUse: does not clobber fresh ready` to fail. (2)
Drop the `AM_SESSION_NAME` requirement in the hook's session resolution (three
breakages were recorded); expect `No pane signal: no state file written`, the
`stranger:` block, `AM_SESSION_NAME: targeted session updated` / `first
session untouched` and `test_state_hook_cwd_sidecar`'s `hook: unmanaged
process in the launch dir writes no state` / `no sidecar` to fail. (3) Two
sides, two mutations: ignore `background_tasks` on Stop in the hook and expect
`test_state_hooks`' `Stop + running subagent/shell/monitor/owned/orphaned
shell: writes background` and `Stop re-fire keeps background` to fail — not
anything in `tests/test_state.sh`, which writes its hook files with `printf`
and never runs the hook; then break the ✳ + background pass-through in
`_state_resolve` (`lib/state.sh`) and expect `test_state_title_glyph`'s
`resolve: ✳ + background -> background (hook read)` and `busy + background ->
running (wrap-up turn live)` to fail. Case 09 is the guard for a live
incident and only the mutation result makes it removable; re-run (2) before
committing.

Re-run result (2026-10-06, before the Batch 3 commit): every mutation was
caught. (1) The disabled grace window fails only `PostToolUse: does not
clobber fresh ready` — the `flips aged ready` assertion cannot fail under a
mutation that only makes flipping easier. (2) All three session-resolution
breakages (AM_SESSION_NAME overridden by a cwd match; the no-pane-signal
exit falling back to a cwd match; that exit writing only a `.sid` sidecar)
fail the named `test_state_hooks` assertions; the sidecar-only variant is
caught by the `stranger: sid sidecar untouched` assertion, not by
`test_state_hook_cwd_sidecar`'s `writes no sidecar` (which checks the
`.cwd` sidecar). (3) Ignoring `background_tasks` on Stop fails seven
`test_state_hooks` assertions and both of case 13's hook-written steps;
breaking the ✳ + background pass-through fails `test_state_title_glyph`'s
`✳ + background -> background` and case 13's `passes through`. The
two-sided drift the kept case exists for was also run: the hook writing `bg`
instead of `background` with every expected `background` in
`test_state_hooks.sh` renamed to match, `lib/state.sh` untouched —
`test_state.sh` and `test_standalone_scripts.sh` stayed green and only case
13 failed on its own terms (`hook file background` got `bg`; `passes
through` got `ready`, the resolver not recognising the word).

### Batch 4 — simplifications and merges

| File | Change |
|---|---|
| `tests/test_agents.sh` | `test_agents`: drop lines 14, 15, 25, 27, 28, 35, 36, 39, 40, 41, 42, 43, 46, 47, 48, 51, 52, 57, 58, 59, 60, 61, 62 |
| `tests/test_install.sh` | `test_install_pi_extension`: drop 841-845 |
| `tests/test_registry.sh` | `test_registry`: line 18 compares sorted `keys` instead of the exact order; `test_auto_title_scan`: drop 736-740, 743-747 |
| `tests/test_state.sh` | `test_state_integration`: drop 196 (the `am wait` block); 201 is the only live `am interrupt` run and stays |
| `internal/sessions/agents_test.go` | `TestAgentManifestTypes`: drop 30-32 |
| `tests/test_bin_helpers.sh` | fold `test_symlinked_kill_and_switch` (80) into `test_kill_and_switch_switches_client_before_kill` |
| `tests/test_recovery.sh` | fold `test_recovery_branch_guard_integration` (668) into `test_recovery_reboot_integration`; the preflight outcome stays with `test_recovery_preflight_matrix` |

**Verify** → change a resume template or alias in the manifest and expect
`TestAgentManifestFacts` / `TestAgentAliasesAndUnknown` to fail (the
`test_agents` drop). Make one manifest type non-restorable (blank its
`resume`) and expect `TestRestorableRawLines`,
`TestRestorableEntriesIncludeCodexExactID`, `test_agent_manifest`'s `no type
is missing a load-bearing field` and `cmd/am-browse::TestFormOptionsNavigation`
to fail (the `TestAgentManifestTypes` drop; run the bash side with
`AM_LIB_DIR` pointed at the worktree, see section 8). Drop a `registry_add`
field and expect the sorted-keys assertion and `test_registry_gc`'s `row
younger than the grace window is not reaped` to fail. Break hysteresis and
the sidecar-only binding and expect `TestRefreshTitlesTitleSources` (am-6),
`TestRestoreScanBindsIDFromSidecarOnly` (:177, :180),
`TestResolveSessionIDSidecarOnly` (:459) and `pi detect id: sidecar without a
transcript → empty, no substitute` to fail. Change `am wait`'s single-session
output and `am list --json --state` and expect `test_cli_dispatch`'s `am wait:
single-session output is just the state` and `am list --json --state: filters
the array` to fail. Break `bin/kill-and-switch`'s switch-before-kill order and
expect `kill-and-switch: switch happens before kill` to fail. Break the
branch preflight (two breakages recorded) and expect `recovery preflight:
re-allocated checkout: actionable reason` and `sidecar mirror: launch records
the launch-directory branch` to fail. Break the pi extension uninstall and
expect `uninstall: pi extension link removed` to fail.

Re-run result (2026-10-06, before the Batch 4 commit): twelve mutations,
every one caught. Two attributions were wrong. A non-restorable pi (blank
`pi.resume`) is caught by `TestAgentManifestFacts`,
`TestRestorableEntriesIncludePi` and `test_agent_manifest`'s `no type is
missing a load-bearing field` — not by `TestRestorableRawLines`,
`TestRestorableEntriesIncludeCodexExactID` or `TestFormOptionsNavigation`,
none of which depends on pi's resume template. The hysteresis rule (an
invalid pane title must not replace an existing task) is guarded by
`TestRefreshTitlesTitleSources` alone; the bash scan test never checked it
(its dropped Test 6 covered the title-equals-task case). The folded
`test_recovery_branch_guard_integration` assertions hold: an unrecorded
branch fails `sidecar mirror: launch records the launch-directory branch`
and the new `reboot recovery: launch records the checkout's branch`; a
preflight that ignores the branch fails `recovery preflight: re-allocated
checkout: actionable reason`. The folded symlink test holds: a helper that
no longer resolves its symlink fails every `kill-and-switch:` stub assertion.

### Batch 5 — argued partial drops (optional; each line needs its own check)

Apply the 3d table one test at a time. For each: remove only the cleared
lines, re-apply the breakage the skeptic named for the test's *kept* lines
(3c) to confirm it still fails, then apply a breakage aimed at what the
cleared lines asserted and confirm the named sibling assertion fails (for
example: delete `test_cli_extended` L165-182 only after the two new JSON
asserts are in; mutate `fzf_list_json`'s `task` index at `lib/fzf.sh:375-376`
and expect `.[0].task == "cli test"` to fail). Preconditions in the table
(move L514's message check first; add the two JSON asserts first; strengthen
`test_completions_print` L44 rather than drop it; loosen osascript L1018) are
part of the same commit. The nine line-level re-run candidates from 3c
(`test_doctor_versions_minimums` 111, `test_doctor_drift` 143,
`test_install_refresh_stamp` 890, `test_titler_log_gated` 547-548,
`test_git_head_branch` 313-327, `TestReviewRebaseSuggestion` 374,
`TestRestoreScanBindsIDFromSidecarOnly` 194-196, `TestRefreshTitlesTitleSources`
377/388-391, `TestHelpText` 127-129/136-140) go here too, each re-run with the
same breakages 3c records and only the drop_lines removed.

Applied (2026-10-06). Every 3d row and every 3c line-level candidate was
taken, with these deviations from the table (survey-time line numbers):

| Row | What was done instead |
|---|---|
| `test_config` 19 | Kept. Line 19 opens the three-line key-set assertion whose label line (21) the same row says must stay with `_AM_CONFIG_OBSOLETE_KEYS`; the two readings conflict, so the statement stays (rule 4) |
| `test_cli` 25-28 | Rewritten, not dropped: the `--sandbox` run now captures stderr and carries the `Unknown option: <flag>` message check moved from `test_cli_workspace_and_id` L514 (the flag is `--sandbox`, no longer `-W`) |
| `test_cli_diff` 1163 | The in-process `registry_remove test-am-diff1` moved to the cleanup lines rather than deleted |
| `test_install` 346-350 | The whole block went (`_install_version_ge` is a one-line wrapper over `am_version_ge`); the equal-pair compare lives in `test_utils_dep_minimums` as `version_ge: 0.40 >= 0.40 (equal)` |
| `test_completions_bash` 78 | Line 77 (the `am wait` completion run that fed only 78) went with it |
| `test_standalone_preview` 84 | Lines 80-83 (the corrupted-JSONL run that fed only 84) went with it |
| `test_state_hooks` (11 lines) | Each dropped assertion's own hook run went with it where nothing else read its result (Cursor stop → ready, PostToolUse over fresh background, UserPromptSubmit over ready, Stop + monitor over no state, idle_prompt over ready, the AM_SESSION_NAME targeted write, the Claude no-pane-signal Stop in the family block, the no-pane-signal Stop at 722). The dup-cwd registry fixture stays for the bogus-name run; the osascript argv round trip (platform canary) went with 1024 and the phrase grep is now `on run argv` |
| `test_utils_extended` 65 | The `h2` hash lines went with it |
| `test_claude_first_user_message` 96 | The no-JSONL run went; `local result` stays |
| `test_git_head_branch` 313-327 | The Go-parity comment (325-326) went with 327 |
| `TestRestoreScanBindsIDFromSidecarOnly` 194-196 | The `am-shared` registry row and its log/pane entries went with the assertion |
| `TestRefreshTitlesTitleSources` 377, 388-391 | The `am-9` row and the proj9 transcript went with the want entry; the throttle check went (guarded by `TestRestoreScanThrottleIndependentOfTitleMarker`), the `setTitle` stays for the forced-scan check |
| `TestReviewRebaseSuggestion` 374 | The kind check became a bare `ReviewSync` call; `TestReviewSyncRebase` owns the kind |
| `TestRefreshTitlesReviewCount` 523-525 | The `ReviewAck` call went; the zero-stat `ReviewRecord` check stays |
| `test_send_prompt_delay` 353-354 | Dropped as cleared; the caveat (a retune would have failed it) is the reason |

Full suite after the batch: 1493 assertions (1571 before), one skip.

Re-run result (2026-10-06, before the Batch 5 commit): forty mutations in
three groups — the 3c breakages against each test's kept lines (19), the
breakages aimed at what the cleared lines asserted against the named sibling
(10), and the nine line-level candidates with their 3c breakages (11) — and
no surviving mutation concerns a dropped line. Three records need
correcting. `test_doctor_drift`: the manifest field is `lab`, so the
breakage is doctor reading a renamed field, not the manifest renaming one
(the test fails either way). `test_state_hooks` Cursor no-pane: the kept
assertion catches only a family-aware directory fallback; a family-blind
one writes the pi row first and is caught by the stranger and
unmanaged-process assertions instead. `test_git_head_branch`: the
`findGitDir` `cur == "/"` mutation is caught only as a suite hang —
`_ghb_bounded` kills its subshell but the orphan `am-core` keeps the
command-substitution pipe open, so the `TIMEOUT` branch never reports —
and the Go `TestGitHeadBranch` has no relative-name case; the dropped lines
(313-327) were not the guard, so the drop stands, and the watchdog is
listed in section 8. Two gaps outside this batch: `TestStoreDispatch`
cannot tell codex reading the claude store from codex having no store (both
return the empty string in an empty `TempDir`), and the bash "empty for an
unknown id" lines of `test_claude_first_user_message` do not catch a
newest-jsonl fallback that `TestClaudeFirstUserMessageDisambiguatesBySessionID`
does (the dropped line 96 was the same path). Two breakages fail more than
their record names: the rebase tree-dedup loop also fails
`TestReviewSyncRebaseNoOwnCommits`; `ReviewAdopt` leaving the old refs
behind also fails `TestReviewAdoptAndDrop`.

### Order and stopping

Batches 1 → 2 → 3 → 4 → 5. Stop at any batch whose mutation re-run does not
reproduce the recorded result: a mutation that the surviving tests no longer
catch means the record was wrong or the suite moved, and the candidate stays.

## 7. Keeping the suite from regrowing

A PR that adds a test states, in the test's comment or the PR body:

1. **The regression it guards**, as a concrete edit to production code
   (`catches: _state_hook_read losing the activity term, lib/state.sh:239`),
   not a restatement of the assertion. A test whose author cannot name one is
   a contract test and must say which function's contract and why no existing
   test already pins it.
2. **One guard per behavior.** Before adding, grep for the function or
   message under test; if a test already asserts it, extend that test. The
   same behavior in two files is allowed only across a boundary (bash wrapper
   over Go, CLI over lib), and then the second test asserts the boundary (env
   hand-off, JSON key, exit code, message wiring), not the behavior again.
3. **Prefer the Go test when the bash side is a one-line wrapper.** New
   behavior in `internal/sessions` gets its matrix in Go; the bash file gets
   at most one scenario per `am-core` subcommand, and only when the plumbing
   is new.
4. **No implementation pins** (field order, exact help text, exact wording)
   unless the pin is the point, and then the comment says so.
5. **Expensive tests** (`agent_launch`, real tmux, sleeps) name what the
   cheap layer cannot reach. A bash integration test that re-asserts a Go
   unit test's outcome through a stub agent is the pattern 3a removes.

Run a mutation check when: a PR removes or merges a test, or drops assertion
lines from one (the removal must name the surviving guard and the breakage it
caught); a PR adds a test to a file that already has a twin on the other side
of a boundary; or a hub function is split. The check is cheap: apply the
breakage in a worktree, run the file and its twins, confirm the named
assertion fails, revert. When the candidate is a set of lines, disable only
those lines — a whole-test skip proves the test must stay, not that the lines
must (the nine cases in 3c).

## 8. Open questions and what was not done

**The mutation agents.** The first attempt to run the 42 mutation checks
failed before any agent started (the worktrees were requested from a working
directory outside the repository); all 42 were re-run from the repository
root and completed, each in its own disposable worktree, with no errors. The
batch plan re-runs every mutation before its commit, which is the check that
matters; until then treat every 3a/3b result as provisional. Nothing in
3a/3b is removed on argument alone.

**Candidates not mutated (48).** The skeptic defended them and the pipeline
stopped there. A mutation run could still show some removable; a wrong keep
is the cheap error, so they stay. The one worth revisiting is
`tests/test_bin_helpers.sh::test_standalone_switch_last_errors` (202): the
survey calls it a tautology (asserts only rc==0 at line 230, and
`bin/switch-last` exits 0 on every path: `|| exit 0` line 18, `|| true`
lines 24, 27, 28) that costs most of the file's 4.5s; the skeptic kept it as
the only direct-path invocation of the script. Both can be true. The fix is
a rewrite that checks the attached client moved (`display-message -p -c
<client> '#{session_name}'`), not a keep as is.

**Weak guards found by the Batch 5 re-run (not fixed).** `_ghb_bounded` in
`tests/test_utils.sh::test_git_head_branch` kills only its subshell, so a
spinning `am-core branch` hangs the suite instead of printing `TIMEOUT`; it
should run the call in its own process group and kill the group. Go
`TestGitHeadBranch` has no relative-name case, so the bash test is the only
guard of the `findGitDir` termination. `TestStoreDispatch`'s codex line
cannot distinguish "no store" from "the claude store" in an empty `HOME`;
a claude transcript planted under the codex directory would.

**Limits of the method.**

- Mutation sampled at most 3 breakages per test. A test can still be the sole
  guard of a breakage nobody tried. The removal batches name the breakages
  that were tried; a reviewer who can name a fourth should apply it first.
- For simplify candidates the "disabled" run skipped the whole test, so the
  result decides the test, not its drop_lines (3c, nine cases).
- Environment caveats recorded with the mutation runs: `TestAgentManifestTypes`'
  bash twin held only with `AM_LIB_DIR` pointed at the worktree (the inherited
  variable pointed at the main checkout); two `test_cli.sh` assertions that
  caught the `test_state_integration` mutation were noted as "appears flaky"
  (`test_cli` passed 316/316 on a later run); `TestFormatRestorableDisplayBase`'s
  catch list includes `TestRepoScanCached`, marked unrelated; the
  `09-dup-cwd-resolution` run's catch list includes `tmux_create_session:
  initial shell inherits env arg (probably unrelated flake)`;
  `test_state_from_hook_stale_file`'s second mutation was run only with the
  candidate disabled; `perf_test.sh` was measured with no tmux server.
- Line numbers are as of the audit (2026-10-05, `main` at 4edbb14) and move
  with every edit; apply the batches by test name, with the line numbers as a
  check.

**Survey coverage.** All 35 test files were surveyed (19 bash including
`tests/perf_test.sh`, `tests/test_perf_session_switch.sh` and
`tests/test_state_lab.sh`; 16 Go). None was dropped. `tests/test_all.sh` and
`tests/test_helpers.sh` are runner infrastructure and were not surveyed as
tests.

**Not decided.**

- Case `13-background-wait.sh` and `tests/state_lab/` as a whole: decided
  2026-10-06, see 3a and Batch 3 — case 13 keeps its two hook-written
  steps as the one place the real hook writes the file the real
  `_state_resolve` reads, and the lab stays (README rewritten, dead helpers
  removed) rather than being ported and deleted.
- `test_cursor_first_user_message` (`tests/test_utils.sh`): cluster, low
  confidence — port the standard-layout (220-222, `AM_CURSOR_PROJECTS_DIR`
  with a dotted project name) and missing-session cases into
  `TestCursorFirstUserMessage`, then delete the bash test. Not surveyed as a
  candidate, not skeptic-reviewed, not mutated.
- `test_pi_first_user_message`: cluster, medium — port the second-file and
  array cases into `TestPiFirstUserMessage`; the skeptic agrees the bash
  test's uniqueness (block content, 170-175) ends with that port.
- `test_git_head_branch`: cluster, medium — port three relative-path cases
  (bare name outside a repo, `.` in a dir holding `.git`, relative walk stops
  at the cwd) with `t.Chdir` into `TestGitHeadBranch`; the mutation pass found
  the relative-path walk guarded only in bash today, so the port must land
  before any drop.
- `tests/test_perf_session_switch.sh` (1500ms budget, never failed, untouched
  since 4497d8a): flagged by the history pass, never proposed by the survey,
  not mutated. A load-independent form (time N=2 vs N=10, assert the ratio)
  would remove the flake shape without losing the guard.
- `tests/perf_test.sh`: kept because the one mutation tried (a retry loop in
  `ListTmuxSessions`) was reported as REGRESSION, but its thresholds
  (500/1000/2000ms) are ~15x the current latency and predate the Go port.
- `TestRefreshTitlesNonGitWorkdirBlanksBranch`: the redundancy pass names
  the Go test as the deletable twin of `test_auto_title_scan_workdir` step 5;
  not verified; folding it into `TestRefreshTitlesWorkdirAndBranch` loses
  nothing.
- `test_config`'s yolo/sandbox prune asserts and `lib/config.sh:12`
  `_AM_CONFIG_OBSOLETE_KEYS`; `test_recovery`'s legacy sandbox/worktree-field
  guard (241-246); `sessions_test.go:152-157`'s dead field names in a
  "future metadata" fixture: migration guards whose production counterpart
  still exists. Remove code and asserts together or not at all.
- Test hygiene outside this plan's scope, from the survey: `test_install`
  lines 347-350 depend on `test_install_refresh_stamp` having sourced
  `utils.sh` first; `test_install_refresh_stamp` leaks a deleted `AM_DIR` into
  every later test in worker 1; `test_standalone_preview` and
  `test_claude_first_user_message` write under the real
  `$HOME/.claude/projects`; `test_cli_missing_dependency_points_at_install`
  touches `~/.agent-manager/config.json` on a direct run;
  `STUB_TMUX_NO_SWITCH` in `test_bin_helpers.sh` never changes an exit code;
  `tests/test_state_lab.sh:9-10` lists three cases while four exist.
