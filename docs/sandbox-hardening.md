# Sandbox Hardening

Security notes and mitigations for the current sandbox design.

## 1. Default credential isolation

**Problem:** older sandbox revisions bind-mounted host credentials directly into the container.

**Current design:** a sandbox starts with only two default mounts:

- The project directory, bind-mounted at the same absolute path
- The persistent `am-state` Docker volume, mounted at `~/.am-state`

Host credentials are not mounted by default. If a sandbox needs access to secrets or dotfiles, they must be added explicitly with either:

- `am sb map ...` to copy data into the persistent sandbox-owned state volume
- `am new --share ...` for a one-off live bind mount

That makes credential exposure opt-in instead of automatic.

## 2. Manifest-driven state hydration

**Problem:** ad hoc bind mounts are brittle, hard to audit, and can overexpose the host.

**Current design:** `am sb map` writes selected host files or directories into `~/.am-state/data/<mapping-name>` and records metadata in `~/.am-state/mappings.json`.

At container startup, the entrypoint:

- reads `mappings.json`
- expands `~` in each target path
- replaces the target with a symlink to `~/.am-state/data/<source>`
- applies an optional mode such as `0700`

This keeps the mounted surface small while preserving stable in-container paths like `~/.ssh` or `~/.claude.json`.

## 3. Explicit live sharing

**Problem:** some workflows still need direct access to a host path.

**Current design:** `--share` allows a narrow, session-scoped bind mount:

```bash
am new --sandbox --share ~/.ssh:~/.ssh:ro ~/project
```

Share syntax is `<host-path>[:container-path][:ro|rw]`. Omitted mode defaults to `ro`.

For persistent-but-reviewed access, prefer `am sb map` over `--share`.

## 4. Network egress restriction

**Problem:** unrestricted outbound networking increases exfiltration risk if credentials are present.

**Current design:** when `sb_network_restrict=true` (default), each sandbox gets:

- a per-session Docker network
- a tinyproxy sidecar as the only outbound path
- `HTTP_PROXY` / `HTTPS_PROXY` environment variables pointing at that proxy
- a default-deny allowlist from `sandbox/tinyproxy-filter.txt`, plus `sb_allowed_hosts`

Config:

- `am config set sb-network-restrict false` to disable the proxy and allow direct internet access
- `am config set sb-allowed-hosts "extra.example.com,another.com"` to extend the allowlist

## 5. Runtime hardening

By default, sandbox containers run with:

- `--cap-drop=ALL`, then only `CHOWN`, `DAC_OVERRIDE`, and `FOWNER` added back
- `--security-opt no-new-privileges:true` unless `SB_UNSAFE_ROOT=1`
- resource limits from `SB_PIDS_LIMIT`, `SB_MEMORY_LIMIT`, and `SB_CPUS_LIMIT`

Optional environment flags in `~/.agent-manager/sandbox.env`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SB_UNSAFE_ROOT` | `0` | Allow passwordless sudo inside the container |

Other runtime behavior that is part of the current design:

- The image has a single built-in user, `dev`, which is not in the `sudo` group by default.
- The entrypoint restores default `.zshrc` and `.vimrc` only if they do not already exist.
- User-space tools (Claude Code, Rust/cargo, `uv`, `ipython`) are installed as `dev`, not root.
- The image includes Node.js, Codex CLI, Claude Code, `uv`, one managed Python, `ipython`, and Playwright Chromium.

## 6. Remaining limits

This sandbox is still not a security boundary.

- The project directory is bind-mounted read-write.
- Docker access remains root-equivalent on the host.
- A deliberate attacker inside the container should be treated as potentially able to escape.

Use the sandbox to reduce accidental damage and narrow secret exposure, not to contain malicious code.
