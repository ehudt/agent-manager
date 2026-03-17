# Sandbox Hardening Plan

Current audit of sandbox security and proposed mitigations.

## Issues

### 1. SSH: all host private keys visible

`~/.ssh/` is mounted read-only, exposing every private key on the host — even keys unrelated to the project (personal, corporate, other services).

**Solution: require sandbox identity initialization.**

The `~/.sb/` system (`sandbox_identity_init`) already generates a dedicated ed25519 keypair with `IdentitiesOnly yes`. The fix is to:

- Make `sandbox_identity_init` run automatically on first `am new --yolo` if `~/.sb/ssh/` doesn't exist, instead of requiring manual setup.
- Once `~/.sb/` exists, only `~/.sb/ssh/` is mounted — host `~/.ssh/` is never exposed.
- Print the public key on init so the user can add it as a deploy key to relevant repos.
- **Fallback**: if the user explicitly opts out (`am config set sb_host_ssh true`), mount `~/.ssh/:ro` as today. Log a warning.

### 2. Claude credentials: `~/.claude.json` and `~/.claude/` mounted read-write

The agent has full read-write access to Claude auth tokens and the entire Claude data directory. A compromised agent could exfiltrate tokens or tamper with settings/session history of other sessions.

**Solution: isolate via `~/.sb/` copies with scoped write access.**

- On `sandbox_identity_init`, copy `~/.claude.json` → `~/.sb/claude.json` and `~/.claude/` → `~/.sb/claude/` (this already happens).
- Mount `~/.sb/claude.json` and `~/.sb/claude/` read-write into the container. The host-global files are never mounted.
- Claude still gets the write access it needs for token refresh and session JSONL writes, but writes go to the sandbox-scoped copies.
- **Token sync**: add a post-session hook that copies `~/.sb/claude.json` back to `~/.claude.json` only if the OAuth token field changed (so refreshed tokens propagate). This avoids the agent needing direct write access to host credentials while keeping tokens working across sessions.
- **Alternative (simpler)**: if token refresh is infrequent, accept that sandbox sessions use a snapshot of the token. When it expires, re-run `sandbox_identity_init` to re-copy. Document this trade-off.
- User: I prefer the alternative.

### 3. Codex credentials: `~/.codex/config.toml` rw, `~/.codex/auth.json` ro

Same class of issue as Claude: config is mounted read-write, auth tokens are readable.

**Solution: same `~/.sb/` isolation pattern.**

- On `sandbox_identity_init`, copy `~/.codex/config.toml` → `~/.sb/codex/config.toml` and `~/.codex/auth.json` → `~/.sb/codex/auth.json` (this already happens).
- Mount `~/.sb/codex/config.toml` read-write and `~/.sb/codex/auth.json` read-only.
- Codex gets write access to its own scoped config copy. Host codex config is never exposed.
- Same token-sync hook approach as Claude if auth.json needs refresh propagation.

### 4. Unrestricted outbound network

The container has full outbound internet access. A compromised agent can exfiltrate any mounted credential to an arbitrary endpoint.

**Solution: DNS-based egress allowlist via Docker network config.**

Phased approach:

**Phase 1 — audit mode (log only):**
- Run a transparent DNS proxy (e.g., `dnsmasq` in a sidecar or on the host) that logs all DNS queries from sandbox containers.
- Expose a command `am sandbox dns-log <session>` to review what hosts were contacted.
- This builds confidence in what the allowlist should contain before enforcing.

**Phase 2 — allowlist enforcement:**
- Create a dedicated Docker network (`am-sandbox-net`) with a DNS proxy that resolves only allowed domains.
- Default allowlist: `api.anthropic.com`, `api.openai.com`, `github.com`, `*.githubusercontent.com`, `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `crates.io`, `static.crates.io`, package mirrors.
- Per-project overrides via `am config set sb_allowed_hosts "extra.example.com,..."`.
- Blocked queries return NXDOMAIN. The agent gets a clear DNS failure, not a hang.
- `--network am-sandbox-net` replaces the default bridge network in docker run.

**Phase 3 — IP-level enforcement:**
- Add iptables/nftables rules on the Docker network to block direct IP connections (bypassing DNS).
- Allow only the resolved IPs from the allowlist proxy.
- User: Not needed, as far as I understand.

**Simpler alternative if phased approach is too heavy:**
- Use `--network none` and provide a configured proxy (squid/tinyproxy) as the only outbound path. The proxy enforces the allowlist. Set `HTTP_PROXY`/`HTTPS_PROXY` env vars in the container. Downside: some tools don't respect proxy env vars (e.g., raw socket connections).
- User: the above lightweight solution is the preferred approach right now.

## Implementation Priority

| # | Issue | Effort | Impact | Priority |
|---|-------|--------|--------|----------|
| 1 | SSH key isolation | Low — mostly wiring existing `~/.sb/` | High — stops key leakage | **P0** |
| 2 | Claude credential isolation | Medium — token sync hook | High — stops token exfil | **P0** |
| 3 | Codex credential isolation | Low — same pattern as #2 | Medium | **P1** |
| 4 | Network egress restriction | High — DNS proxy infra | High — blocks exfiltration | **P1** |

## What `~/.sb/` Already Provides

The `sandbox_identity_init` function (lib/sandbox.sh) already:
- Creates `~/.sb/ssh/` with a dedicated ed25519 keypair and `IdentitiesOnly yes`
- Copies `~/.claude.json` → `~/.sb/claude.json`
- Copies `~/.claude/` → `~/.sb/claude/`
- Copies `~/.codex/config.toml` → `~/.sb/codex/config.toml`
- Copies `~/.codex/auth.json` → `~/.sb/codex/auth.json`
- Mount resolution already prefers `~/.sb/` paths when they exist

The main gaps are:
1. `sandbox_identity_init` is not auto-triggered — users must run it manually.
2. No token-sync mechanism for refreshed OAuth tokens.
3. No network restrictions at all.
