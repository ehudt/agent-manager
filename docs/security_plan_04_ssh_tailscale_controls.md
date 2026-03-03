# Plan 04: SSH and Tailscale Controls (Tailscale Default-On)

Related findings: [C-02], [H-02]
Status: Done (2026-03-03)

## Goal
Keep Tailscale enabled by default while removing unnecessary SSH daemon exposure.

## Scope
- `lib/sandbox.sh` (host-side sandbox lifecycle, runtime defaults, environment passthrough)
- `sandbox/entrypoint.sh` (container-side SSH/Tailscale initialization)

## Implementation

### Runtime defaults (`lib/sandbox.sh` `sandbox_start()`)
- `SB_ENABLE_TAILSCALE=1` by default.
- `ENABLE_SSH=0` by default.
- `TS_ENABLE_SSH=1` by default.
- `NET_ADMIN` capability and `/dev/net/tun` added only when `SB_ENABLE_TAILSCALE=1`.
- Missing `TS_AUTHKEY` prints a warning without failing container startup.
- `TS_ENABLE_SSH=1` with `SB_ENABLE_TAILSCALE=0` prints a configuration warning.
- Startup summary logged: `tailscale=, tailscale_ssh=, sshd=, ...`

### Container-side gating (`sandbox/entrypoint.sh`)
- SSH daemon started only when `ENABLE_SSH=1`.
- Tailscale started with `--ssh` when `TS_ENABLE_SSH=1`; without it when `TS_ENABLE_SSH=0`.
- `TS_ENABLE_SSH=1` ignored (with warning) when `SB_ENABLE_TAILSCALE=0`.

### CLI surface
- `am new --yolo` launches sandbox sessions (calls `sandbox_start()`).
- `am sandbox {ls,prune,rebuild,status,identity init}` for fleet management.
- Environment variables (`SB_ENABLE_TAILSCALE`, `ENABLE_SSH`, `TS_ENABLE_SSH`) set via `~/.agent-manager/sandbox.env` or exported before invocation.

## Behavior Matrix

| SB_ENABLE_TAILSCALE | ENABLE_SSH | TS_ENABLE_SSH | Result |
|---|---|---|---|
| 0 | 0 | (ignored) | Local shell only |
| 1 | 0 | 1 | Tailscale + Tailscale SSH (default) |
| 1 | 0 | 0 | Tailscale networking only |
| 1 | 1 | 0 | Tailscale + SSH daemon |
| 1 | 1 | 1 | Tailscale + Tailscale SSH + SSH daemon |

## Acceptance Criteria
- SSH daemon is not started unless explicitly enabled (`ENABLE_SSH=1`).
- Tailscale remains default-on (`SB_ENABLE_TAILSCALE=1`).
- Tailscale SSH is enabled by default and documented.
- OpenSSH daemon exposure is opt-in.
