# Security Best Practices Review: agent-sandbox

Date: 2026-02-16  
Scope: `sb`, `entrypoint.sh`, `Dockerfile`, `README.md`, `config_context/*`

## Executive Summary

The sandbox is functional but not yet strongly aligned with the stated goal of running an untrusted coding agent "with more confidence." The current design exposes high-value host credentials directly inside the container, grants elevated container privileges (including `NET_ADMIN` and root escalation), and builds the image using multiple unverified remote install scripts.  

Top priority should be to reduce host-secret exposure and container privileges by default, and make risky features opt-in.

## Critical Findings

### [C-01] Host secrets are directly mounted into the sandbox
Impact: A malicious or compromised agent can exfiltrate host credentials and account tokens, bypassing sandbox trust assumptions.

Evidence:
- `sb:126` mounts `~/.claude.json` read-only.
- `sb:127` mounts `~/.claude/` read-only.
- `sb:131` mounts `~/.codex/auth.json` read-only.
- `sb:132` mounts `~/.ssh/` read-only.

Why this matters:
- Read-only prevents modification, not theft.  
- `~/.ssh` may include private keys; `~/.claude*` and `~/.codex/auth.json` may contain long-lived auth material.

Recommendations:
1. Remove direct mounts of high-value auth material by default.
2. Use short-lived credentials or brokered auth (e.g., host-side command proxy, scoped tokens, dedicated per-sandbox identities).
3. Offer explicit opt-in flags for sensitive mounts (for example: `--mount-ssh`, `--mount-claude-auth`), with warnings.

### [C-02] Container privileges are too high for untrusted-agent execution
Impact: Increased chance of container breakout or host-impacting behavior if agent executes hostile payloads.

Evidence:
- `sb:153` adds `CAP_NET_ADMIN`.
- `sb:154` exposes `/dev/net/tun`.
- `Dockerfile:46` grants `dev` passwordless sudo (`NOPASSWD:ALL`).

Why this matters:
- `NET_ADMIN` + `tun` materially increases kernel attack surface.
- Passwordless root inside container is convenient but unsafe for hostile workloads.

Recommendations:
1. Make Tailscale-related privileges conditional; only add `NET_ADMIN` and `--device /dev/net/tun` when explicitly requested.
2. Drop all other capabilities by default (`--cap-drop=ALL` then add minimum required).
3. Remove `NOPASSWD:ALL` in hardened mode (or gate behind explicit `--unsafe-root`).

### [C-03] Build pipeline trusts unverified remote scripts/binaries
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
- `sb:130` mounts `~/.codex/config.toml` without `:ro`.

Risk:
- Agent can persist hostile settings or alter host-side behavior beyond sandbox lifetime.

Recommendations:
1. Mount this file read-only by default.
2. If writes are required, use a narrow synchronization flow (explicit import/export command) instead of live RW mount.

### [H-02] SSH daemon is always started inside container
Evidence:
- `entrypoint.sh:43` always executes `service ssh start`.

Risk:
- Extra network-reachable service increases attack surface even when remote SSH is not needed.

Recommendations:
1. Start SSH only when explicitly enabled (`ENABLE_SSH=1`).
2. Pair with restrictive network policy and key restrictions.

## Medium Findings

### [M-01] Missing runtime hardening flags on `docker run`
Evidence:
- `sb:147`-`sb:157` starts container without `no-new-privileges`, resource limits, or read-only rootfs.

Risk:
- Greater blast radius for malicious processes and easier privilege abuse post-compromise.

Recommendations:
1. Add `--security-opt no-new-privileges:true`.
2. Consider `--pids-limit`, memory/CPU limits, and seccomp/apparmor hardening.
3. Consider `--read-only` plus dedicated writable tmpfs/volumes where needed.

### [M-02] `HOST_HOME` symlink logic trusts environment path in root context
Evidence:
- `sb:142` passes `HOST_HOME=$HOME`.
- `entrypoint.sh:38`-`entrypoint.sh:40` creates directories/symlink from that value as root.

Risk:
- If `HOST_HOME` is manipulated, entrypoint may create unexpected filesystem paths/symlinks in container rootfs.

Recommendations:
1. Validate `HOST_HOME` against expected pattern (`/home/<user>`).
2. Avoid dynamic root-level path creation from env input where possible.

## Positive Controls Already Present

1. Host project mount is scoped to selected directory (`sb:125`).
2. Several host files are mounted read-only (`sb:126`, `sb:127`, `sb:131`, `sb:132`-`sb:137`).
3. No host Docker socket mount was found.
4. Default Docker bridge networking avoids direct LAN exposure without explicit port publishing.

## Prioritized Remediation Plan

Status update:
1. Done: Remove or gate sensitive host credential mounts ([C-01]).
2. Open: Introduce hardened default mode with reduced privileges ([C-02], [M-01]).
3. Open: Harden build supply chain with pinned/verified dependencies ([C-03]).
4. Open: Make SSH/Tailscale explicit controls while keeping Tailscale default-on ([C-02], [H-02]).
5. Open: Replace live RW host config mount with explicit sync flow ([H-01]).

Plan files:
2. `security_plan_02_runtime_hardening.md`
3. `security_plan_03_supply_chain.md`
4. `security_plan_04_ssh_tailscale_controls.md`
5. `security_plan_05_codex_config_sync.md`

## Residual Risk Statement

If the product goal includes running potentially adversarial code, current defaults are too permissive. After implementing the remediations above, the sandbox will better match the intended trust boundary ("internet + project access, no blanket host access"), but full isolation still depends on Docker/kernel security posture and operational controls (host patching, image provenance, and credential lifecycle).
