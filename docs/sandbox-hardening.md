# Sandbox Hardening

Security audit and mitigations for the agent sandbox.

## 1. SSH key isolation

**Problem:** `~/.ssh/` was mounted read-only, exposing all host private keys.

**Solution:** `sandbox_identity_init` auto-runs on first sandbox launch if `~/.sb/ssh/` is missing. Generates a dedicated ed25519 keypair with `IdentitiesOnly yes`. Host `~/.ssh/` is never mounted.

- Config: `am config set sb_host_ssh true` to opt out (mounts host `~/.ssh/:ro` with a warning)
- The public key is printed on init — add it as a deploy key to relevant repos

## 2. Claude credential isolation

**Problem:** `~/.claude.json` and `~/.claude/` were mounted read-write, exposing auth tokens.

**Solution:** `sandbox_identity_init` copies these to `~/.sb/claude.json` and `~/.sb/claude/`. The sandbox mounts the `~/.sb/` copies (read-write for Claude to function). Host-global files are never exposed.

- Token refresh writes go to the sandbox copy. If the snapshot token expires, re-run `am sandbox init-identity` to re-copy from host.
- Sensitive mount sources log a warning when falling back to host-global.

## 3. Codex credential isolation

**Problem:** `~/.codex/config.toml` mounted read-write, `~/.codex/auth.json` readable.

**Solution:** Same `~/.sb/` pattern. Copies live at `~/.sb/codex/config.toml` and `~/.sb/codex/auth.json`.

## 4. Network egress restriction

**Problem:** Containers had full outbound internet access — any mounted credential could be exfiltrated.

**Solution:** Per-session tinyproxy sidecar with domain allowlist.

- A Docker network `<session>-net` isolates the sandbox container
- A tinyproxy container (`<session>-proxy`) is the only outbound path, connected to both the session network and bridge
- `HTTP_PROXY`/`HTTPS_PROXY` env vars route all traffic through the proxy
- Proxy enforces `FilterDefaultDeny` with a regex allowlist (`sandbox/tinyproxy-filter.txt`)

Default allowed domains: `api.anthropic.com`, `api.openai.com`, `github.com`, `*.githubusercontent.com`, `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `crates.io`, `static.crates.io`

Config:
- `am config set sb_network_restrict false` — disable (full internet access)
- `am config set sb_allowed_hosts "extra.example.com,another.com"` — add domains to allowlist

Note: network restriction disables Tailscale (logged as warning). Proxy + network are cleaned up on `sandbox_remove`.

## Config summary

| Key | Default | Purpose |
|-----|---------|---------|
| `sb_host_ssh` | `false` | Mount host `~/.ssh/` instead of sandbox keys |
| `sb_network_restrict` | `true` | Restrict outbound via tinyproxy allowlist |
| `sb_allowed_hosts` | `""` | Extra domains to allow (comma-separated) |
