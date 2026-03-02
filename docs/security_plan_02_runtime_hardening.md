# Plan 02: Runtime Hardening Defaults

Related findings: [C-02], [M-01]  
Status: Open

## Goal
Reduce runtime privilege and blast radius while preserving default Tailscale functionality.

## Scope
- `sb`
- `entrypoint.sh`
- `Dockerfile`
- `README.md`

## Implementation Steps
1. Update default `docker run` flags in `sb`:
   - add `--security-opt no-new-privileges:true`
   - add `--cap-drop=ALL`
   - add `--cap-add=NET_ADMIN` (required for default Tailscale)
   - keep `--device /dev/net/tun` (required for default Tailscale)
2. Add default resource guardrails in `sb` with env overrides:
   - `--pids-limit` (default 512)
   - `--memory` (default `4g`, override with `SB_MEMORY_LIMIT`)
   - `--cpus` (default `2.0`, override with `SB_CPUS_LIMIT`)
3. Add optional read-only root filesystem mode:
   - `SB_READ_ONLY_ROOTFS=1` enables `--read-only`
   - mount writable tmpfs/volumes for required runtime paths:
     - `--tmpfs /tmp:rw,noexec,nosuid,nodev`
     - `--tmpfs /run:rw,nosuid,nodev`
     - `--tmpfs /var/run:rw,nosuid,nodev`
     - `-v sb-tailscale-state:/var/lib/tailscale`
     - `-v sb-home-codex:/home/dev/.codex/tmp`
4. Define explicit hardened vs unsafe mode behavior:
   - hardened default (`SB_UNSAFE_ROOT=0`):
     - no `NOPASSWD:ALL`
     - `--security-opt no-new-privileges:true` remains enabled
   - unsafe compatibility mode (`SB_UNSAFE_ROOT=1`):
     - allow passwordless sudo for legacy workflows
     - disable `no-new-privileges` for that run so sudo elevation can function
     - print a startup warning that unsafe mode weakens isolation
5. Harden privilege escalation path:
   - remove default `NOPASSWD:ALL` from `Dockerfile`
   - add runtime toggle in `entrypoint.sh` to enable/disable a dedicated sudoers drop-in file based on `SB_UNSAFE_ROOT`
6. Update docs:
   - document defaults, env override knobs, and exact hardened/unsafe behavior
   - include read-only-rootfs requirements and known compatibility caveats.

## Validation
1. Start sandbox in default mode and verify:
   - interactive shell works
   - Tailscale starts and can obtain an IP
   - `docker inspect` shows:
     - `HostConfig.SecurityOpt` includes `no-new-privileges:true`
     - `HostConfig.CapDrop` contains `ALL`
     - `HostConfig.CapAdd` contains only `NET_ADMIN`
     - `HostConfig.Memory`, `HostConfig.NanoCpus`, `HostConfig.PidsLimit` match defaults
2. Attempt privileged operations in sandbox and confirm expected denial.
   - `sudo -n id` fails in hardened mode
   - writing to `/` fails when `SB_READ_ONLY_ROOTFS=1`
3. Start sandbox with compatibility mode and verify legacy workflows still function:
   - `SB_UNSAFE_ROOT=1 sudo -n id` succeeds
   - `docker inspect` does not include `no-new-privileges:true` in unsafe mode.

## Acceptance Criteria
- Default container drops all capabilities except required Tailscale capability.
- `no-new-privileges` is enabled by default.
- Default resource limits are active (`pids=512`, `memory=4g`, `cpus=2.0`) unless overridden.
- Passwordless sudo is not enabled in hardened default mode.
- Read-only rootfs mode functions with documented writable mount set.
