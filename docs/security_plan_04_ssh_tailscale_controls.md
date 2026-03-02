# Plan 04: SSH and Tailscale Controls (Tailscale Default-On)

Related findings: [C-02], [H-02]  
Status: Open

## Goal
Keep Tailscale enabled by default while removing unnecessary SSH daemon exposure.

## Scope
- `entrypoint.sh`
- `sb`
- `README.md`

## Implementation Steps
1. Define explicit runtime defaults and flag precedence:
   - `SB_ENABLE_TAILSCALE=1` by default.
   - `ENABLE_SSH=0` by default.
   - `TS_ENABLE_SSH=1` by default.
   - if `SB_ENABLE_TAILSCALE=1` and `TS_AUTHKEY` is unset, print a warning and continue without failing container startup.
2. Keep Tailscale default-on behavior in runtime config:
   - retain `NET_ADMIN` and `/dev/net/tun` defaults in `sb` while Tailscale default-on is in effect.
   - in `entrypoint.sh`, start Tailscale when `SB_ENABLE_TAILSCALE=1` and `TS_AUTHKEY` is present.
3. Gate SSH daemon startup in `entrypoint.sh`:
   - start SSH only if `ENABLE_SSH=1`
   - do not start `sshd` by default.
4. Gate Tailscale SSH feature:
   - use `tailscale up --ssh` by default (`TS_ENABLE_SSH=1`).
   - if explicitly disabled (`TS_ENABLE_SSH=0`), run `tailscale up` without SSH option.
   - if `TS_ENABLE_SSH=1` while `SB_ENABLE_TAILSCALE=0`, print configuration warning and ignore `TS_ENABLE_SSH`.
5. Expose explicit runtime controls in `sb`:
   - pass through/document `SB_ENABLE_TAILSCALE`, `ENABLE_SSH`, and `TS_ENABLE_SSH`.
   - print a startup summary of effective modes (Tailscale on/off, SSH daemon on/off, Tailscale SSH on/off).
6. Update documentation with a behavior matrix:
   - local shell only (`SB_ENABLE_TAILSCALE=0`, `ENABLE_SSH=0`)
   - Tailscale + Tailscale SSH (default)
   - Tailscale networking only (`TS_ENABLE_SSH=0`)
   - Tailscale + SSH daemon
   - all SSH modes enabled explicitly.

## Validation
1. Default start (`SB_ENABLE_TAILSCALE=1`, no explicit SSH flags):
   - confirm no `sshd` process
   - confirm startup summary reports Tailscale on, SSH daemon off, Tailscale SSH on.
2. `ENABLE_SSH=1`:
   - confirm `sshd` is running and configured as expected.
3. `TS_ENABLE_SSH=1` with Tailscale enabled:
   - confirm Tailscale is started with SSH enabled.
4. `SB_ENABLE_TAILSCALE=0`:
   - confirm Tailscale is not started
   - confirm warning is emitted if `TS_ENABLE_SSH=1`.

## Acceptance Criteria
- SSH daemon is not started unless explicitly enabled.
- Tailscale remains default-on (`SB_ENABLE_TAILSCALE=1` default).
- Tailscale SSH is enabled by default and documented.
- OpenSSH daemon exposure is opt-in and documented.
