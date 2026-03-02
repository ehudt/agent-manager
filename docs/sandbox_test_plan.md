# SB Test Plan (Functional, Security, UX)

Date: 2026-02-17  
System under test: `sb` CLI, `entrypoint.sh`, `Dockerfile` runtime behavior

## 0. Current Status

Implemented and validated in this session:
1. Added `pytest` integration coverage for:
- `S-001` hardened defaults present
- `S-002` Tailscale privilege gating
- `S-003` unsafe-mode downgrade behavior
- `S-004` sensitive mount mode enforcement
- `S-005` read-only rootfs mode enforcement
- `S-006` SSH agent forwarding gating
- `U-002` invalid directory error clarity
- `U-003` warning usefulness for conflicting envs / missing Tailscale auth
- `F-005` attach failure semantics
- `F-006` status output for running / not found states
2. Validation result as of 2026-02-28:
- `uv run --with pytest pytest -q tests/test_sb_security_integration.py`
- `9 passed, 1 skipped`
3. Runtime fixes shipped to support `S-005`:
- read-only-rootfs mode now preserves the stable in-image home path
- writable Codex state is mounted at `/home/dev/.codex`
- read-only startup avoids rootfs-mutating home remap operations
4. Additional runtime fixes shipped in this session:
- host identity/home alignment in `entrypoint.sh` now degrades safely instead of crash-looping under hardened defaults
- `sb --status` now reports `not found` cleanly on a missing sandbox instead of emitting a malformed multi-line state

How to run the current integration coverage:
- `uv run --with pytest pytest -q tests/test_sb_security_integration.py`
- The suite uses the real `sb` CLI plus `docker inspect` / `docker exec` assertions and auto-skips when Docker or required host capabilities are unavailable.

## 1. Objectives

1. Verify `sb` reliably manages sandbox lifecycle and per-directory container mapping.
2. Verify runtime hardening and secret-handling controls work as intended.
3. Verify operator experience is clear, fast, and recoverable for common workflows.

## 2. Scope

In scope:
- CLI commands: `--start`, `--attach`, `--status`, `--stop`, `--clean`, `--list`, `--prune`, `--rebuild`, `--rebuild-running`, `--init-sb-home`.
- Container naming/labeling and persistence behavior.
- Host mount precedence (`~/.sb/*` over host-global files).
- Security defaults and mode toggles (`SB_ENABLE_TAILSCALE`, `TS_ENABLE_SSH`, `ENABLE_SSH`, `SB_UNSAFE_ROOT`, `SB_READ_ONLY_ROOTFS`).
- UX of output messages, warnings, and recovery actions.

Out of scope:
- Tailscale control-plane reliability beyond local command outcomes.
- Docker engine bugs unrelated to `sb` logic.

## 3. Test Environment Matrix

1. Host OS: Ubuntu 24.04 (primary), macOS/Linux secondary if supported by team.
2. Docker: current stable daemon with permission to run privileged flags used by `sb`.
3. Network profiles:
- A: online with valid `TS_AUTHKEY`.
- B: online without `TS_AUTHKEY`.
- C: offline/degraded DNS.
4. Identity layouts:
- A: only host-global creds (`~/.ssh`, `~/.codex`, `~/.claude*`).
- B: dedicated sandbox identity (`~/.sb/...`) initialized.
5. Runtime modes:
- Hardened default (`SB_UNSAFE_ROOT=0`, `SB_READ_ONLY_ROOTFS=0`).
- Read-only rootfs (`SB_READ_ONLY_ROOTFS=1`).
- Unsafe compatibility (`SB_UNSAFE_ROOT=1`).

## 4. Entry / Exit Criteria

Entry:
1. `sb` script executable, Docker daemon healthy.
2. Clean baseline: no stale test containers for the chosen test directories.

Exit:
1. All P0/P1 tests pass.
2. No open Critical/High security defects.
3. UX acceptance checks pass or have approved exceptions.

## 5. Requirement Coverage

Functional requirements:
1. Directory-based container reuse via `agent-sandbox.dir` label.
2. Correct lifecycle semantics for create/start/attach/stop/clean/prune/list.
3. Rebuild behavior (`--rebuild`, `--rebuild-running`) preserves intended running set.
4. Mount rules and fallback precedence (`~/.sb` preferred).
5. Correct attach fallback when host user/path is unavailable in container.

Security requirements:
1. Default hardening: `no-new-privileges`, `cap-drop=ALL`, bounded resources.
2. Conditional privilege additions only when needed (`NET_ADMIN`, `/dev/net/tun`).
3. Read-only mount expectations for sensitive files.
4. Optional read-only rootfs mode with required writable paths only.
5. Unsafe mode clearly gated and warned.

UX requirements:
1. Command outputs are clear, actionable, and consistent.
2. Error cases provide remediation (invalid dir, missing running container, unset auth key).
3. Startup/attach path is fast and predictable.
4. Status output is trustworthy and includes key connection info.

## 6. Test Cases

Priority legend: P0 critical, P1 high, P2 medium.

### 6.1 Functional Test Cases

1. `F-001` (P0): First-run create + attach
- Steps: `sb <new_dir>`
- Expected: image auto-build if missing, container created with label, shell attaches.

2. `F-002` (P0): Reuse existing running sandbox
- Steps: run `sb <same_dir>` twice.
- Expected: second run reports already running and attaches to same container name.

3. `F-003` (P0): Label-based mapping correctness
- Steps: inspect labels for container.
- Expected: `agent-sandbox=true` and exact absolute path in `agent-sandbox.dir`.

4. `F-004` (P1): `--start` idempotency
- Steps: `sb <dir> --start` twice.
- Expected: no duplicate container creation; success both times.

5. `F-005` (P1): `--attach` failure semantics
- Steps: stop container, run `sb <dir> --attach`.
- Expected: non-zero exit and clear error text.
- Status: Automated and passing.

6. `F-006` (P1): `--status` for running and not found states
- Steps: run against existing and fresh directory.
- Expected: accurate status and directory/container display.
- Status: Automated and passing.

7. `F-007` (P1): `--stop` + resume
- Steps: `sb <dir> --stop`, then `sb <dir>`.
- Expected: stopped then resumed/reattached with same container.

8. `F-008` (P1): `--clean` removes all mapped containers for directory
- Steps: create duplicates intentionally, run clean.
- Expected: no remaining containers with matching label/path.

9. `F-009` (P1): Global `--list` and `--prune`
- Steps: create running + stopped sb containers, run commands.
- Expected: list only sb-labeled containers; prune removes stopped sb containers only.

10. `F-010` (P1): `--rebuild-running` restore behavior
- Steps: keep two sandboxes running, run `--rebuild-running`.
- Expected: both restored and running after rebuild.

11. `F-011` (P2): `--init-sb-home` setup quality
- Steps: run init in clean home.
- Expected: creates expected files/permissions and SSH key/config.

12. `F-012` (P2): Mount precedence
- Steps: provide both `~/.sb/*` and fallback files.
- Expected: container mounts `~/.sb` variants when present.

### 6.2 Security Test Cases

1. `S-001` (P0): Hardened defaults present
- Steps: start default sandbox, run `docker inspect`.
- Expected: `SecurityOpt` contains `no-new-privileges:true`; `CapDrop` includes `ALL`; resource limits match defaults.

2. `S-002` (P0): Tailscale privilege gating
- Steps: run with `SB_ENABLE_TAILSCALE=0` then `1`.
- Expected: `NET_ADMIN` and `/dev/net/tun` appear only when enabled.
- Status: Automated and passing.

3. `S-003` (P0): Unsafe mode downgrade is explicit
- Steps: run with `SB_UNSAFE_ROOT=1`.
- Expected: warning printed; inspect confirms no-new-privileges disabled.
- Status: Automated and passing.

4. `S-004` (P0): Sensitive mount modes
- Steps: inspect mounts and attempt writes from container.
- Expected: configured `:ro` mounts reject writes (`~/.ssh`, auth files, dotfiles that are ro by design).
- Status: Automated and passing.

5. `S-005` (P1): Read-only rootfs mode enforcement
- Steps: run with `SB_READ_ONLY_ROOTFS=1`, attempt write to `/etc` and `/`.
- Expected: writes denied except allowed tmpfs/volumes.
- Status: Automated and passing.

6. `S-006` (P1): SSH agent forwarding gating
- Steps: set `SB_FORWARD_SSH_AGENT=1` with and without valid `SSH_AUTH_SOCK`.
- Expected: mount only when socket exists; warning when missing.
- Status: Automated and passing.

7. `S-007` (P1): Environment secret leakage minimization
- Steps: inspect container env and process list.
- Expected: only intended vars present; no accidental host env spillover.

8. `S-008` (P2): Multi-tenant separation by directory
- Steps: launch two directories, compare mounts and labels.
- Expected: no cross-directory project mount leakage.

### 6.3 UX Test Cases

1. `U-001` (P0): Help discoverability
- Steps: run `sb`, `sb --help`, invalid flags.
- Expected: concise usage lines and clear command options.

2. `U-002` (P1): Error clarity for invalid directory
- Steps: `sb /path/does-not-exist`.
- Expected: explicit “not a valid directory” and non-zero exit.
- Status: Automated and passing.

3. `U-003` (P1): Warning usefulness
- Steps: run with conflicting envs (`SB_ENABLE_TAILSCALE=0`, `TS_ENABLE_SSH=1`; missing `TS_AUTHKEY`).
- Expected: warnings explain impact and next action.
- Status: Automated and passing.

4. `U-004` (P1): Status message quality
- Steps: `sb <dir> --status`.
- Expected: includes container name, directory, status, and SSH hint when applicable.

5. `U-005` (P2): Performance envelope
- Steps: measure attach path on running container.
- Expected target: median attach < 2s on test host.

6. `U-006` (P2): Recovery workflow
- Steps: force broken state then run documented recovery commands.
- Expected: user can recover with documented commands and minimal ambiguity.

## 7. Suggested Automation Strategy

1. Build a shell-based integration suite (Bats or `pytest` + subprocess) that creates temporary directories and runs real `sb` commands.
   Status: Started with `pytest` integration coverage in `tests/test_sb_security_integration.py`.
2. Add helpers to parse `docker inspect` JSON and assert security/mount invariants.
   Status: Implemented for the current `S-001`, `S-002`, and `S-005` checks.
3. Mark tests:
- `smoke`: `F-001`, `F-002`, `F-006`, `S-001`.
- `security`: all `S-*`.
- `ux`: `U-*` (string assertions + timing).
4. Run in CI on self-hosted runner with Docker privileges; gate merges on smoke + security.

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
