# Security Best Practices Review: agent-sandbox

Date: 2026-02-16 (updated 2026-03-03)
Scope: `lib/sandbox.sh`, `sandbox/entrypoint.sh`, `sandbox/Dockerfile`

## Executive Summary

The sandbox is functional but not yet strongly aligned with the stated goal of running an untrusted coding agent "with more confidence." The current design exposes host credentials inside the container (mitigated by dedicated sandbox identities), and builds the image using multiple unverified remote install scripts.

Top priority should be to harden the build supply chain and complete codex config sync.

## Critical Findings

### [C-01] Host secrets are directly mounted into the sandbox
Status: **Mitigated** (sandbox identity system)

Impact: A malicious or compromised agent can exfiltrate host credentials and account tokens, bypassing sandbox trust assumptions.

Evidence:
- `lib/sandbox.sh:237` mounts `~/.claude.json` (prefers `~/.sb/claude.json` if present).
- `lib/sandbox.sh:239` mounts `~/.claude/` (prefers `~/.sb/claude` if present).
- `lib/sandbox.sh:247` mounts `~/.codex/auth.json` read-only (prefers `~/.sb/codex/auth.json` if present).
- `lib/sandbox.sh:250` mounts `~/.ssh/` read-only (prefers `~/.sb/ssh` if present).

Mitigations applied:
- `am sandbox identity init` (`lib/sandbox.sh:466`) creates a dedicated per-sandbox identity in `~/.sb/` with its own SSH keypair, Claude auth, and Codex credentials.
- When `~/.sb/` files exist, they are mounted instead of host-global secrets.

Residual risk:
- Users who skip `identity init` still fall back to host-global mounts.

### [C-02] Container privileges are too high for untrusted-agent execution
Status: **Mitigated** (runtime hardening)

Evidence:
- `lib/sandbox.sh:308` adds `CAP_NET_ADMIN` and `/dev/net/tun` only when `SB_ENABLE_TAILSCALE=1`.
- `entrypoint.sh:134-146` grants passwordless sudo only when `SB_UNSAFE_ROOT=1`.

Mitigations applied:
- `lib/sandbox.sh:297` drops all capabilities by default (`--cap-drop=ALL`), adding back only `CHOWN`, `DAC_OVERRIDE`, `FOWNER` (lines 298-300).
- `lib/sandbox.sh:303` adds `--security-opt no-new-privileges:true` by default (disabled only when `SB_UNSAFE_ROOT=1`).
- `lib/sandbox.sh:294-296` enforces `--pids-limit`, `--memory`, and `--cpus` limits.
- Tailscale privileges (`NET_ADMIN`, `/dev/net/tun`) are conditional on `SB_ENABLE_TAILSCALE=1` (line 307-309).

### [C-03] Build pipeline trusts unverified remote scripts/binaries
Status: **Open**

Impact: Supply-chain compromise of an upstream installer can silently compromise every sandbox build.

Evidence:
- `Dockerfile:31` `curl ... | sh` for Tailscale.
- `Dockerfile:56` `curl ... | bash` for NodeSource.
- `Dockerfile:76` `curl ... | sh` for `uv`.
- `Dockerfile:85` `curl ... | bash` for Claude installer.
- `Dockerfile:65` globally installs `@openai/codex` without version pin.
- `Dockerfile:51` clones `pure` from GitHub without pinning commit.

Recommendations:
1. Pin versions and verify checksums/signatures for downloaded artifacts.
2. Prefer distro packages or verified release assets over script pipes.
3. Pin npm and git dependencies to immutable versions/commits.

## High Findings

### [H-01] Host config is writable from the sandbox (`~/.codex/config.toml`)
Evidence:
- `lib/sandbox.sh:244` mounts `~/.codex/config.toml` without `:ro` (prefers `~/.sb/codex/config.toml` if present).

Risk:
- Agent can persist hostile settings or alter host-side behavior beyond sandbox lifetime.

Recommendations:
1. Mount this file read-only by default.
2. If writes are required, use a narrow synchronization flow (explicit import/export command) instead of live RW mount.

### [H-02] SSH daemon is always started inside container
Status: **Mitigated**

Evidence:
- `entrypoint.sh:148-162` starts SSH only when `ENABLE_SSH=1` (default: `0`).
- `lib/sandbox.sh:227` passes `ENABLE_SSH` from env (default `0`).

Mitigations applied:
- SSH is off by default; must be explicitly enabled.
- Tailscale SSH (`TS_ENABLE_SSH`) is a separate control (entrypoint.sh:172-173).

## Medium Findings

### [M-01] Missing runtime hardening flags on `docker run`
Status: **Mitigated**

Evidence:
- `lib/sandbox.sh:290-321` now starts containers with `--cap-drop=ALL`, `no-new-privileges`, resource limits, and optional `--read-only` rootfs.

Mitigations applied:
- `--cap-drop=ALL` with minimal add-back (lines 297-300).
- `--security-opt no-new-privileges:true` by default (line 303).
- `--pids-limit`, `--memory`, `--cpus` resource limits (lines 294-296).
- `--read-only` rootfs with dedicated tmpfs mounts when `SB_READ_ONLY_ROOTFS=1` (lines 310-321).

### [M-02] `HOST_HOME` symlink logic trusts environment path in root context
Evidence:
- `lib/sandbox.sh:263` passes `HOST_HOME=$HOME`.
- `entrypoint.sh:57-61` moves user home directory based on that value as root.

Risk:
- If `HOST_HOME` is manipulated, entrypoint may create unexpected filesystem paths/symlinks in container rootfs.

Recommendations:
1. Validate `HOST_HOME` against expected pattern (`/home/<user>`).
2. Avoid dynamic root-level path creation from env input where possible.

## Positive Controls Already Present

1. Host project mount is scoped to selected directory (`lib/sandbox.sh:235`).
2. Host files use read-only mounts where possible (`lib/sandbox.sh:247`, `lib/sandbox.sh:250-255`).
3. Dedicated sandbox identity (`~/.sb/`) preferred over host-global secrets when available.
4. No host Docker socket mount.
5. Default Docker bridge networking avoids direct LAN exposure without explicit port publishing.
6. `--init` flag ensures zombie process reaping (`lib/sandbox.sh:293`).

## Prioritized Remediation Plan

1. **Done**: Remove or gate sensitive host credential mounts ([C-01]). Sandbox identity system via `am sandbox identity init`.
2. **Done** (2026-03-03): Introduce hardened default mode with reduced privileges ([C-02], [M-01]). Cap-drop-all, no-new-privileges, resource limits, optional read-only rootfs.
3. **Open**: Harden build supply chain with pinned/verified dependencies ([C-03]).
4. **Done** (2026-03-03): Make SSH/Tailscale explicit controls while keeping Tailscale default-on ([C-02], [H-02]). SSH off by default, Tailscale capabilities conditional.
5. **Open** (partially implemented): Replace live RW host config mount with explicit sync flow ([H-01]). Sandbox identity covers auth files; `~/.codex/config.toml` still mounted RW.

Plan files:
2. `security_plan_02_runtime_hardening.md`
3. `security_plan_03_supply_chain.md`
4. `security_plan_04_ssh_tailscale_controls.md`
5. `security_plan_05_codex_config_sync.md`

## Residual Risk Statement

After implementing plans 1, 2, and 4 the sandbox significantly better matches the intended trust boundary. The primary remaining risks are supply-chain integrity (plan 3) and the RW codex config mount (plan 5). Full isolation still depends on Docker/kernel security posture and operational controls (host patching, image provenance, and credential lifecycle).
