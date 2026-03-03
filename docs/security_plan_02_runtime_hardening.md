# Plan 02: Runtime Hardening Defaults

Related findings: [C-02], [M-01]
Status: Done (2026-03-03). All items implemented in `lib/sandbox.sh`, `sandbox/entrypoint.sh`, and `sandbox/Dockerfile`.

## Goal
Reduce runtime privilege and blast radius while preserving default Tailscale functionality.

## Scope
- `lib/sandbox.sh` (`sandbox_start` builds the `docker run` flags)
- `sandbox/entrypoint.sh`
- `sandbox/Dockerfile`

## Implementation Steps
1. Default `docker run` flags in `sandbox_start()` (`lib/sandbox.sh`):
   - `--cap-drop=ALL`
   - `--cap-add=CHOWN`, `DAC_OVERRIDE`, `FOWNER` (entrypoint user-alignment)
   - `--cap-add=NET_ADMIN` + `--device /dev/net/tun` when `SB_ENABLE_TAILSCALE=1`
   - `--security-opt no-new-privileges:true` (omitted when `SB_UNSAFE_ROOT=1`)
2. Default resource guardrails in `sandbox_start()` with env overrides:
   - `--pids-limit` (default 512, override `SB_PIDS_LIMIT`)
   - `--memory` (default `4g`, override `SB_MEMORY_LIMIT`)
   - `--cpus` (default `2.0`, override `SB_CPUS_LIMIT`)
3. Read-only root filesystem mode (`SB_READ_ONLY_ROOTFS=1`):
   - `--read-only`
   - `--tmpfs /tmp:rw,noexec,nosuid,nodev`
   - `--tmpfs /run:rw,nosuid,nodev`
   - `--tmpfs /var/run:rw,nosuid,nodev`
   - `-v ${session}-codex-home:/home/dev/.codex`
   - `-v ${session}-tailscale-state:/var/lib/tailscale` (when Tailscale enabled)
4. Hardened vs unsafe mode (`SB_UNSAFE_ROOT`):
   - Default (`SB_UNSAFE_ROOT=0`): no NOPASSWD sudoers, `no-new-privileges` active
   - Unsafe (`SB_UNSAFE_ROOT=1`): passwordless sudo via drop-in, `no-new-privileges` disabled, startup warning logged
5. Privilege escalation path:
   - Dockerfile has no `NOPASSWD:ALL`; `dev` is only in the `sudo` group
   - `entrypoint.sh` writes/removes `/etc/sudoers.d/90-sb-unsafe-root` based on `SB_UNSAFE_ROOT`

## CLI surface
- `am new --yolo <dir>` -- launches agent in sandbox (calls `sandbox_start`)
- `am sandbox ls|prune|rebuild|status|identity init` -- fleet management

## Validation
1. Start sandbox in default mode and verify:
   - Interactive shell works
   - Tailscale starts and can obtain an IP
   - `docker inspect` shows `no-new-privileges:true`, `CapDrop=ALL`, correct `CapAdd`, resource limits
2. Attempt privileged operations and confirm denial:
   - `sudo -n id` fails in hardened mode
   - Writing to `/` fails when `SB_READ_ONLY_ROOTFS=1`
3. Compatibility mode (`SB_UNSAFE_ROOT=1`):
   - `sudo -n id` succeeds
   - `no-new-privileges` absent from inspect output

## Remaining gaps
- No seccomp or AppArmor profile applied (Docker default seccomp is in effect).
- Read-only rootfs is opt-in (`SB_READ_ONLY_ROOTFS=0` by default) rather than default-on; some workflows break with read-only root.
