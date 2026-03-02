# Plan 03: Build Supply-Chain Hardening

Related findings: [C-03]  
Status: Open

## Goal
Reduce compromise risk from unverified upstream installers and mutable dependencies.

## Scope
- `Dockerfile`
- version/checksum metadata file (to add)
- `README.md`

## Implementation Steps
1. Replace `curl | sh/bash` installer patterns with pinned and verifiable fetch/install flows where possible.
2. Pin dependency versions:
   - npm global package `@openai/codex` to exact version
   - `pure` prompt source to fixed commit SHA
   - all installer targets (Node/Tailscale/uv/Claude) to explicit versions/releases.
3. Add integrity verification:
   - checksums/signatures for downloaded binaries/archives
   - fail build on mismatch.
4. Add centralized metadata file for all pinned versions/checksums.
5. Document maintenance workflow for secure version bumps.

## Validation
1. Build succeeds with expected pinned versions.
2. Intentionally tampered checksum causes build failure.
3. Produce a build manifest summary of installed versions.

## Acceptance Criteria
- No remaining unpinned high-risk external dependency fetches.
- Downloaded artifacts are integrity-checked.
- Build fails closed on verification failure.
