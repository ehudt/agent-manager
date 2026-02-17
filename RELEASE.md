# Release Checklist

## 1. Quality gates

- Run tests: `./tests/test_all.sh`
- Run bash syntax checks: `bash -n am lib/*.sh bin/* scripts/*.sh tests/test_all.sh`
- Run local pre-commit checks: `./scripts/precommit-checks.sh`
- Smoke-test installer:
  - `./scripts/install.sh --help`
  - `./scripts/install.sh --yes --no-shell --no-tmux --prefix /tmp/am-install-test`
  - `/tmp/am-install-test/am version`

## 2. Security/public scan

- Scan tracked files: `./scripts/scan-secrets.sh`
- Scan git history: `./scripts/scan-secrets.sh --history`
- Check for machine-specific paths/placeholders:
  - `rg -n "(/home/|your-org|youruser)" README.md DESIGN.md AINAV.md config am lib tests scripts`

## 3. Docs + metadata

- Update `README.md` examples and version references as needed
- Ensure install instructions still match `scripts/install.sh`
- Confirm `config/tmux.conf.example` matches documented keybindings
- Decide license (and add/update `LICENSE`)

## 4. Publish

- Create/verify remote repo visibility and permissions
- Push default branch
- Tag release (for example `v0.1.0`)
- Draft release notes from recent commits
