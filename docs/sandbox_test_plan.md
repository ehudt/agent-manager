# Sandbox Test Plan (Functional, Security, UX)

Date: 2026-02-17 (original), 2026-03-03 (revised for am integration)
System under test: `am` CLI sandbox subsystem (`lib/sandbox.sh`), `sandbox/entrypoint.sh`, `sandbox/Dockerfile` runtime behavior

## 0. Current Status

Last audited: 2026-03-03

### How to run

```
uv run --with pytest pytest -q tests/test_sandbox_security_integration.py
```

The suite calls real `sandbox_*` shell functions (sourced from `lib/sandbox.sh`) plus `docker inspect`/`docker exec` assertions. Auto-skips when Docker or required host capabilities are unavailable.

### Test file

`tests/test_sandbox_security_integration.py` — 25 tests total (renamed from former `test_sb_security_integration.py`).

### Architecture context

The standalone `sb` CLI no longer exists. Sandbox functionality is integrated into `am` (agent-manager):

| Old `sb` command | Current equivalent | Layer |
|------------------|--------------------|-------|
| `sb <dir>` | `am new --yolo <dir>` | CLI → `agent_launch()` → `sandbox_start()` |
| `sb <dir> --start` | `sandbox_start(session, dir)` | Function (no direct CLI, called by launch) |
| `sb <dir> --attach` | `sandbox_attach_cmd(session, dir)` | Function (attach via tmux pane) |
| `sb <dir> --status` | `am sandbox status <session>` | CLI → `sandbox_status()` |
| `sb <dir> --stop` | `sandbox_stop(session)` | Function (called by `agent_kill`) |
| `sb <dir> --clean` | `sandbox_remove(session)` | Function (called by `agent_kill`) |
| `sb --list` | `am sandbox ls` | CLI → `sandbox_list()` |
| `sb --prune` | `am sandbox prune` | CLI → `sandbox_prune()` |
| `sb --rebuild` | `am sandbox rebuild` | CLI → `sandbox_build_image()` |
| `sb --rebuild-running` | `am sandbox rebuild --restart` | CLI → `sandbox_rebuild_and_restart()` |
| `sb --init-sb-home` | `am sandbox identity init` | CLI → `sandbox_identity_init()` |

Integration flow: `am new --yolo <dir>` → `agent_launch()` checks `wants_yolo + docker available` → calls `sandbox_start(session_name, dir)` → gets `sandbox_attach_cmd()` → both tmux panes exec into the container → agent runs inside Docker.

Cleanup flow: `agent_kill(session)` → `sandbox_remove(session)` → `tmux_kill_session()` → `registry_remove()`.

Test approach: tests call `sandbox_*` functions directly via `bash -lc` (sourcing `lib/utils.sh` + `lib/sandbox.sh`), not through the `am` CLI entry point. This tests the sandbox layer in isolation. CLI-level integration (e.g., `am new --yolo`) is covered by `tests/test_all.sh`.

### Per-case implementation map

Legend: DONE = pytest test exists and passes, SHELL = covered by shell sub-script called from pytest, MISSING = no automated coverage, STALE = listed as covered in prior status but test no longer present in file.

#### Functional (F-*)

| ID | P | Description | Status | Test function / notes |
|----|---|-------------|--------|-----------------------|
| F-001 | P0 | First-run create + start | DONE | `test_f001_first_run_create_and_start` |
| F-002 | P0 | Reuse existing running sandbox | DONE | `test_f002_reuse_existing_running_sandbox` |
| F-003 | P0 | Label-based session mapping | DONE | `test_f003_label_based_session_mapping` |
| F-004 | P1 | `sandbox_start` idempotency | DONE | `test_f004_sandbox_start_idempotency` |
| F-005 | P1 | Attach failure when container not running | DONE | `test_f005_attach_failure_when_not_running` |
| F-006 | P1 | `sandbox_status` running / not found | DONE | `test_f001_status_output_for_running_and_not_found_states` |
| F-007 | P1 | `sandbox_stop` + resume via `sandbox_start` | DONE | `test_f007_stop_and_resume` |
| F-008 | P1 | `sandbox_remove` cleans up containers | DONE | `test_f008_sandbox_remove_cleanup` |
| F-009 | P1 | `sandbox_list` and `sandbox_prune` | DONE | `test_f009_sandbox_list_and_prune` |
| F-010 | P1 | `sandbox_rebuild_and_restart` restore behavior | MISSING | |
| F-011 | P2 | `sandbox_identity_init` setup quality | DONE | `test_f011_sandbox_identity_init_quality` |
| F-012 | P2 | Mount precedence (`~/.sb/` over host-global) | MISSING | |
| F-013 | P1 | Stale container recreate on config drift | DONE | `test_s006_stale_runtime_settings_trigger_recreate` |
| F-014 | P1 | `sandbox_gc_orphans` removes orphaned containers | DONE | `test_f014_sandbox_gc_orphans` |

#### Security (S-*)

| ID | P | Description | Status | Test function / notes |
|----|---|-------------|--------|-----------------------|
| S-001 | P0 | Hardened defaults present | DONE | `test_s001_hardened_defaults_present` — asserts no-new-privileges, cap-drop ALL, cap-add CHOWN/DAC_OVERRIDE/FOWNER, pids/memory/cpu limits |
| S-002 | P0 | Tailscale privilege gating | DONE | `test_s002_tailscale_privilege_gating` — asserts NET_ADMIN + /dev/net/tun only when SB_ENABLE_TAILSCALE=1 |
| S-003 | P0 | Unsafe mode downgrade explicit | DONE | `test_s003_unsafe_mode_downgrade_is_explicit` — asserts warning text + no-new-privileges absent |
| S-004 | P0 | Sensitive mount modes | DONE | `test_s004_sensitive_mount_modes_enforced` — asserts :ro on auth.json, .ssh, .gitconfig, .zshrc, .vimrc, .tmux.conf, native claude binary/versions; asserts :rw on .claude.json, .claude/, codex/config.toml; write verification via docker exec |
| S-005 | P1 | Read-only rootfs | DONE | `test_s005_read_only_rootfs_mode_enforced` — asserts ReadonlyRootfs=true, write to / rejected, write to /tmp allowed |
| S-006 | P1 | SSH agent forwarding gating | DONE | `test_s007_ssh_agent_forwarding_gated_by_socket_presence` — asserts warning when socket missing, mount present when socket exists |
| S-007 | P1 | Env secret leakage minimization | DONE | `test_s007_environment_secret_leakage` |
| S-008 | P2 | Multi-tenant separation by session | DONE | `test_s008_multi_tenant_separation` |

#### UX (U-*)

| ID | P | Description | Status | Test function / notes |
|----|---|-------------|--------|-----------------------|
| U-001 | P1 | Identity source reporting on start | DONE | `test_u001_start_output_shows_host_global_identity_sources` + `test_u002_start_output_shows_sandbox_identity_sources` |
| U-002 | P1 | Invalid directory error clarity | DONE | `test_u002_invalid_directory_error` |
| U-003 | P1 | Warning usefulness for conflicting envs | DONE | `test_u003_warning_usefulness_conflicting_envs` |
| U-004 | P1 | `am sandbox status` message quality | MISSING | Partially covered by test_f001 (checks Container/Directory/Status/Tailscale fields) |
| U-005 | P2 | Performance envelope | MISSING | |
| U-006 | P2 | `am sandbox` help discoverability | MISSING | |

#### Additional tests (not in original plan)

| Test function | Category | What it covers |
|---------------|----------|----------------|
| `test_f002_shell_runtime_checks_from_sb_suite` | Functional | Runs 3 shell scripts inside a live container: `test_claude_mount.sh` (claude dir writable), `test_codex_permissions.sh` (codex dirs writable), `test_cap_chown.sh` (CHOWN/DAC_OVERRIDE/FOWNER caps in /proc/1/status) |

### Summary counts

- **Plan cases**: 28 total (14 functional, 8 security, 6 UX)
- **DONE in pytest**: 23 (S-001 through S-008, F-001 through F-009, F-011, F-013, F-014, U-001 through U-003)
- **STALE** (claimed covered but test missing): 0
- **MISSING**: 5 (F-010, F-012, U-004, U-005, U-006)
- **Additional tests beyond plan**: 1 (shell runtime checks)

### Priority for next implementation round

All P0 and P1 gaps addressed except:

Remaining gaps:
1. **F-010** — `sandbox_rebuild_and_restart` restore behavior
2. **F-012** — Mount precedence (`~/.sb/` over host-global)
3. **U-004** — `am sandbox status` message quality (partially covered by test_f001)
4. **U-005** — Performance envelope
5. **U-006** — `am sandbox` help discoverability

### Related security plans (docs/)

| Plan | Focus | Test coverage |
|------|-------|---------------|
| `security_plan_02_runtime_hardening.md` | no-new-privileges, cap-drop, resource limits, read-only rootfs, unsafe mode | Covered by S-001 through S-005 |
| `security_plan_03_supply_chain.md` | Pin dependencies, remove curl-pipe-sh, checksum verification | No test coverage (build-time, not runtime) |
| `security_plan_04_ssh_tailscale_controls.md` | SB_ENABLE_TAILSCALE, ENABLE_SSH, TS_ENABLE_SSH flag matrix | Partially covered by S-002, S-006 |
| `security_plan_05_codex_config_sync.md` | Mount codex config :ro, import/export commands | Partially covered by S-004 (mount mode), commands not tested |
| `security_best_practices_report.md` | Audit findings C-01 through M-02 | C-01 done (S-004), C-02 partial (S-001/S-003), C-03/H-01/H-02/M-01/M-02 open |

### Runtime fixes shipped (historical)

1. Read-only-rootfs mode preserves stable in-image home path; writable Codex state at `/home/dev/.codex`; read-only startup avoids rootfs-mutating home remap.
2. Host identity/home alignment in `entrypoint.sh` degrades safely instead of crash-looping under hardened defaults.
3. `sandbox_status` reports `not found` cleanly on a missing sandbox.

## 1. Objectives

1. Verify `am` sandbox subsystem reliably manages sandbox lifecycle and per-session container mapping.
2. Verify runtime hardening and secret-handling controls work as intended.
3. Verify operator experience is clear, fast, and recoverable for common workflows.

## 2. Scope

In scope:
- `am` CLI surface: `am new --yolo`, `am sandbox {ls,prune,rebuild,status,identity init}`.
- `lib/sandbox.sh` functions: `sandbox_start`, `sandbox_attach_cmd`, `sandbox_stop`, `sandbox_remove`, `sandbox_status`, `sandbox_list`, `sandbox_prune`, `sandbox_build_image`, `sandbox_rebuild_and_restart`, `sandbox_gc_orphans`, `sandbox_identity_init`.
- Container naming/labeling (`agent-sandbox=true`, `agent-sandbox.session=<name>`, `agent-sandbox.dir=<path>`) and persistence behavior.
- Host mount precedence (`~/.sb/*` over host-global files).
- Security defaults and mode toggles (`SB_ENABLE_TAILSCALE`, `TS_ENABLE_SSH`, `ENABLE_SSH`, `SB_UNSAFE_ROOT`, `SB_READ_ONLY_ROOTFS`, `SB_FORWARD_SSH_AGENT`).
- UX of output messages, warnings, and recovery actions.
- Integration with `agent_launch()` / `agent_kill()` lifecycle.

Out of scope:
- Tailscale control-plane reliability beyond local command outcomes.
- Docker engine bugs unrelated to sandbox logic.
- tmux session management (covered by `test_all.sh`).

## 3. Test Environment Matrix

1. Host OS: Ubuntu 24.04 (primary), macOS/Linux secondary if supported by team.
2. Docker: current stable daemon with permission to run privileged flags used by sandbox.
3. Network profiles:
- A: online with valid `TS_AUTHKEY`.
- B: online without `TS_AUTHKEY`.
- C: offline/degraded DNS.
4. Identity layouts:
- A: only host-global creds (`~/.ssh`, `~/.codex`, `~/.claude*`).
- B: dedicated sandbox identity (`~/.sb/...`) initialized via `am sandbox identity init`.
5. Runtime modes:
- Hardened default (`SB_UNSAFE_ROOT=0`, `SB_READ_ONLY_ROOTFS=0`).
- Read-only rootfs (`SB_READ_ONLY_ROOTFS=1`).
- Unsafe compatibility (`SB_UNSAFE_ROOT=1`).

## 4. Entry / Exit Criteria

Entry:
1. `am` script executable, Docker daemon healthy, `agent-sandbox:persistent` image built.
2. Clean baseline: no stale test containers for the chosen test sessions.

Exit:
1. All P0/P1 tests pass.
2. No open Critical/High security defects.
3. UX acceptance checks pass or have approved exceptions.

## 5. Requirement Coverage

Functional requirements:
1. Session-based container reuse via `agent-sandbox.session` label.
2. Correct lifecycle semantics for `sandbox_start`/`sandbox_stop`/`sandbox_remove`/`sandbox_list`/`sandbox_prune`.
3. Rebuild behavior (`sandbox_rebuild_and_restart`) preserves intended running set.
4. Mount rules and fallback precedence (`~/.sb` preferred over host-global).
5. Stale container detection and automatic recreate when config drifts.
6. Orphan cleanup via `sandbox_gc_orphans`.

Security requirements:
1. Default hardening: `no-new-privileges`, `cap-drop=ALL`, bounded resources.
2. Conditional privilege additions only when needed (`NET_ADMIN`, `/dev/net/tun`).
3. Read-only mount expectations for sensitive files.
4. Optional read-only rootfs mode with required writable paths only.
5. Unsafe mode clearly gated and warned.
6. SSH agent forwarding gated by socket presence.

UX requirements:
1. Start output reports identity sources being used.
2. Error cases provide remediation (invalid dir, missing running container, unset auth key).
3. Startup path is fast and predictable.
4. `am sandbox status` output is trustworthy and includes key connection info.

## 6. Test Cases

Priority legend: P0 critical, P1 high, P2 medium.

### 6.1 Functional Test Cases

1. `F-001` (P0): First-run create + start
- Steps: call `sandbox_start(session, new_dir)` with no pre-existing container.
- Expected: image auto-build if missing, container created with correct labels (`agent-sandbox=true`, `agent-sandbox.session=<session>`, `agent-sandbox.dir=<dir>`), container reaches running state.

2. `F-002` (P0): Reuse existing running sandbox
- Steps: call `sandbox_start(session, dir)` twice with same session name.
- Expected: second call detects running container, does not create a duplicate, returns success.

3. `F-003` (P0): Label-based session mapping correctness
- Steps: start a sandbox, then `docker inspect` the container.
- Expected: `agent-sandbox=true`, `agent-sandbox.session` matches session name, `agent-sandbox.dir` matches exact absolute path.

4. `F-004` (P1): `sandbox_start` idempotency
- Steps: call `sandbox_start(session, dir)` on an already-running sandbox.
- Expected: no duplicate container creation; success on both calls; same container ID.

5. `F-005` (P1): Attach command failure when container not running
- Steps: stop container via `sandbox_stop(session)`, then call `sandbox_attach_cmd(session, dir)` or attempt docker exec.
- Expected: non-zero exit and clear error text.
- Status: STALE — was listed as automated; needs reimplementation.

6. `F-006` (P1): `sandbox_status` for running and not found states
- Steps: call `sandbox_status(session)` for a running sandbox and a nonexistent session name.
- Expected: running → shows Container, Directory, Status=running, Tailscale field. Not found → shows Container, Status=not found.
- Status: DONE — `test_f001_status_output_for_running_and_not_found_states`.

7. `F-007` (P1): `sandbox_stop` + resume via `sandbox_start`
- Steps: start sandbox, call `sandbox_stop(session)`, then `sandbox_start(session, dir)`.
- Expected: container stops then restarts with same name and state.

8. `F-008` (P1): `sandbox_remove` cleans up container
- Steps: start sandbox, call `sandbox_remove(session)`.
- Expected: container fully removed, `docker ps -a` shows no match.

9. `F-009` (P1): `sandbox_list` and `sandbox_prune`
- Steps: create running + stopped sandbox containers, call `sandbox_list()` then `sandbox_prune()`.
- Expected: list shows only `agent-sandbox`-labeled containers; prune removes stopped ones only; running containers survive.

10. `F-010` (P1): `sandbox_rebuild_and_restart` restore behavior
- Steps: start two sandboxes, call `sandbox_rebuild_and_restart()`.
- Expected: image rebuilt, both containers recreated and running after rebuild.

11. `F-011` (P2): `sandbox_identity_init` setup quality
- Steps: run `sandbox_identity_init()` in a clean `$SB_HOME`.
- Expected: creates `~/.sb/ssh/` with key + config, `~/.sb/claude/`, `~/.sb/claude.json`, `~/.sb/codex/` with config.toml + auth.json; correct permissions (0700 for ssh dir, 0600 for private key).

12. `F-012` (P2): Mount precedence (`~/.sb/` over host-global)
- Steps: initialize `~/.sb/` identity, then start sandbox. Inspect mounts.
- Expected: container mounts `~/.sb/ssh` instead of `~/.ssh`, `~/.sb/claude.json` instead of `~/.claude.json`, etc.

13. `F-013` (P1): Stale container recreate on config drift
- Steps: create a container with intentionally wrong settings (missing caps, wrong mount modes), then call `sandbox_start(session, dir)`.
- Expected: detects config mismatch, removes old container, recreates with correct settings.
- Status: DONE — `test_s006_stale_runtime_settings_trigger_recreate`.

14. `F-014` (P1): `sandbox_gc_orphans` removes orphaned containers
- Steps: create an `agent-sandbox`-labeled container whose session has no matching tmux session, then call `sandbox_gc_orphans()`.
- Expected: orphaned container removed; returns count of removed orphans.

### 6.2 Security Test Cases

1. `S-001` (P0): Hardened defaults present
- Steps: call `sandbox_start(session, dir)` with default env, `docker inspect` the container.
- Expected: `SecurityOpt` contains `no-new-privileges:true`; `CapDrop` includes `ALL`; `CapAdd` includes CHOWN, DAC_OVERRIDE, FOWNER; `PidsLimit`=512; `Memory`=4g; `NanoCpus`=2.0.
- Status: DONE — `test_s001_hardened_defaults_present`.

2. `S-002` (P0): Tailscale privilege gating
- Steps: start sandbox with `SB_ENABLE_TAILSCALE=0`, inspect. Remove, start with `SB_ENABLE_TAILSCALE=1`, inspect.
- Expected: `NET_ADMIN` and `/dev/net/tun` appear only when enabled.
- Status: DONE — `test_s002_tailscale_privilege_gating`.

3. `S-003` (P0): Unsafe mode downgrade is explicit
- Steps: start sandbox with `SB_UNSAFE_ROOT=1`.
- Expected: warning text in output; inspect confirms `no-new-privileges:true` absent from SecurityOpt.
- Status: DONE — `test_s003_unsafe_mode_downgrade_is_explicit`.

4. `S-004` (P0): Sensitive mount modes enforced
- Steps: start sandbox with fake home containing claude/codex/ssh files, inspect mounts, attempt writes via docker exec.
- Expected: `:ro` mounts on auth.json, .ssh, .gitconfig, .zshrc, .vimrc, .tmux.conf, native claude binary/versions; `:rw` on .claude.json, .claude/, codex/config.toml; docker exec writes to ro mounts fail.
- Status: DONE — `test_s004_sensitive_mount_modes_enforced`.

5. `S-005` (P1): Read-only rootfs mode enforcement
- Steps: start sandbox with `SB_READ_ONLY_ROOTFS=1`, attempt writes.
- Expected: `ReadonlyRootfs=true` in inspect; write to `/` rejected; write to `/tmp` allowed.
- Status: DONE — `test_s005_read_only_rootfs_mode_enforced`.

6. `S-006` (P1): SSH agent forwarding gating
- Steps: start with `SB_FORWARD_SSH_AGENT=1` and missing socket path, then with valid socket.
- Expected: warning when socket missing, no `/ssh-agent` mount. With valid socket: mount present and writable at `/ssh-agent`.
- Status: DONE — `test_s007_ssh_agent_forwarding_gated_by_socket_presence`.

7. `S-007` (P1): Environment secret leakage minimization
- Steps: start sandbox, `docker exec env` to list container environment.
- Expected: only intended vars present (HOST_USER, HOST_UID, HOST_GID, HOST_HOME, TARGET_DIR, SB_*, TS_*, ENABLE_SSH, ANTHROPIC_API_KEY if set). No accidental host env spillover (HOME, PATH, etc. should be container-native).

8. `S-008` (P2): Multi-tenant separation by session
- Steps: start two sandboxes for different directories, inspect mounts and labels.
- Expected: no cross-directory project mount leakage; each container only mounts its own target dir.

### 6.3 UX Test Cases

1. `U-001` (P1): Identity source reporting on start
- Steps: start sandbox with host-global identity, check output. Init `~/.sb/`, start again, check output.
- Expected: output clearly lists each identity source path and whether it is host-global or sandbox-specific.
- Status: DONE — `test_u001_start_output_shows_host_global_identity_sources` + `test_u002_start_output_shows_sandbox_identity_sources`.

2. `U-002` (P1): Error clarity for invalid directory
- Steps: call `sandbox_start(session, '/path/does-not-exist')`.
- Expected: explicit error message mentioning invalid/nonexistent directory, non-zero exit.
- Status: STALE — needs reimplementation.

3. `U-003` (P1): Warning usefulness for conflicting envs
- Steps: start sandbox with `SB_ENABLE_TAILSCALE=0` + `TS_ENABLE_SSH=1`; start with `SB_ENABLE_TAILSCALE=1` but no `TS_AUTHKEY`.
- Expected: warnings explain impact and suggested next action.
- Status: STALE — needs reimplementation.

4. `U-004` (P1): `am sandbox status` message quality
- Steps: call `sandbox_status(session)` for a running sandbox.
- Expected: includes container name, directory, status, and Tailscale/SSH info when applicable.

5. `U-005` (P2): Performance envelope
- Steps: measure `sandbox_attach_cmd` + docker exec on a running container.
- Expected target: median attach < 2s on test host.

6. `U-006` (P2): `am sandbox` help discoverability
- Steps: run `am sandbox`, `am sandbox --help`, `am sb`, invalid subcommands.
- Expected: concise usage lines listing available subcommands; clear error on invalid subcommand.

## 7. Automation Strategy

1. Primary suite: `pytest` + subprocess calling `sandbox_*` functions via `bash -lc` (sourcing `lib/utils.sh` + `lib/sandbox.sh`).
   Status: Implemented in `tests/test_sandbox_security_integration.py` (25 tests).
2. Docker inspect helpers: `_inspect`, `_container_mount`, `_normalize_caps`, `_wait_for_running`, `_find_container` cover inspect JSON, mount mode, cap normalization, and lifecycle assertions.
3. Shell sub-scripts (`tests/test_claude_mount.sh`, `tests/test_codex_permissions.sh`, `tests/test_cap_chown.sh`) run inside live containers via `test_f002`.
4. CLI-level tests (e.g., `am new --yolo`, `am sandbox ls`) covered by `tests/test_all.sh`.
5. Test markers:
- `@pytest.mark.integration` + `@pytest.mark.docker` — all sandbox tests.
- `@pytest.mark.security` — `S-*` tests.
- `@pytest.mark.functional` — `F-*` tests.
- `@pytest.mark.ux` — `U-*` tests.
6. Run in CI on self-hosted runner with Docker privileges; gate merges on security + functional.

## 8. Defect Severity Model

1. Critical: privilege boundary failure, secret exposure, wrong-container attach causing data loss.
2. High: command behavior mismatch that blocks normal workflows.
3. Medium: partial failure with workaround or misleading UX.
4. Low: cosmetic output inconsistencies.

## 9. Reporting

For each run, capture:
1. Commit SHA and host environment snapshot.
2. Pass/fail by test ID.
3. `docker inspect` evidence for failed security assertions.
4. Time-to-attach and major UX observations.
