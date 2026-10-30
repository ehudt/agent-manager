# Sandboxed sessions

am can start a session's agent inside a sandbox: a container (Docker
Sandboxes' `sbx`), a namespace jail (bubblewrap, firejail), a macOS
`sandbox-exec` profile, a VM. am knows none of them. It talks to one
configured **sandbox provider**, a command you write or pick, the same way
it talks to the `dir_provider` for `@spec` directories.

```bash
am config set sandbox_provider <am checkout>/scripts/sandbox/sbx
am new --sandbox ~/project        # one session
am config set sandbox true        # every new session (--no-sandbox opts out)
am preset save boxed --sandbox @  # a preset that always sandboxes
```

The tab shows `[claude·sandbox]`; everything else (the browser, `am send`,
`am peek`, the review pane, notifications) works as for a host session.

## The provider contract

am runs the provider as `bash -c '<provider> "$@"' _ <verb> <args...>`, so
the configured value may carry its own arguments or environment
(`AM_SBX_CREATE_ARGS="--memory 8g" /path/to/sbx`). Three verbs:

| Verb | When, where | Must |
|---|---|---|
| `prepare <session> <dir> <agent>` | On the host, before am creates the tmux session. | Create or check the sandbox. Exit non-zero to refuse the launch (tool missing, agent unsupported): nothing has been created yet. Progress and errors go to stderr (the user sees them; a background launch keeps them in its log). stdout is `key=value` lines; am reads `hooks=1` (see below). May be slow: a browser launch of a sandboxed session runs in the background. |
| `run <session> <dir> <agent> -- <agent argv...>` | Typed into the agent pane, interactive, on the pane's tty. | Start the agent from the argv after `--` inside the sandbox, attached to the terminal, and stay in the foreground until it exits (`exec` is the simplest). argv[0] is the host's agent binary name; a sandbox that brings its own may drop it. The rest are the agent's arguments: resume flags, model flags, an argv prompt. When stdin is not a tty it carries the first prompt for a stdin-prompt agent (Claude): hand it on (a host-side wrapper just execs; `scripts/sandbox/sbx` turns it into the agent's prompt argument). |
| `stop <session>` | On the host, detached, after the session is killed. | Stop or remove the sandbox. Best effort; a failure is one `sandbox.stop_fail` line in `events.log`. |

Every verb runs with these in its environment (`agent_sandbox_env`); the
pane's environment carries them too, so `run` sees them:

| Variable | Meaning |
|---|---|
| `AM_SESSION_NAME`, `AM_AGENT_TYPE` | The session and its agent type (`AM_AGENT_TYPE` is not set for `stop`). |
| `AM_SANDBOX` | `1`. |
| `AM_DIR`, `AM_STATE_DIR` | Where am and its hook write. |
| `AM_HOOKS_DIR` | am's `lib/hooks` (state-hook.sh, spool-hook.sh, hook-relay). |
| `AM_HOOK_SPOOL` | This session's hook spool directory (`$AM_STATE_DIR/<session>.spool`); created by the provider when it uses one, removed by am on kill and by GC. |

## State detection

am's state comes from the agent's lifecycle hooks writing
`$AM_STATE_DIR/<session>` (see AGENTS.md, State Detection). A host-side
wrapper (bubblewrap, sandbox-exec) that leaves the state dir writable needs
nothing: the agent's hooks run as installed by `am install`. Print
`hooks=1` from `prepare`.

A container cannot see the host's hooks, state dir or registry. For that
case am ships a relay:

- `lib/hooks/spool-hook.sh` runs **inside** the sandbox as the agent's hook.
  It needs only `sh`, `date`, `cat` and `mv`, and writes each payload as a
  `.json` file in the directory it lives in.
- `lib/hooks/hook-relay --spool <dir> --pid <pid>` runs **on the host** and
  feeds each spooled payload, in arrival order, to `state-hook.sh` with the
  pane's `AM_SESSION_NAME`. It exits after a final drain when `<pid>` is
  gone. Start it from `run` with your own `$$` just before you `exec` the
  sandbox client.

So a container provider mounts `$AM_HOOK_SPOOL` read-write into the sandbox,
copies `spool-hook.sh` into it, registers it as the agent's hook for the
events am uses (for Claude: Stop, UserPromptSubmit, PostToolUse and
Notification `idle_prompt` / `permission_prompt` / `elicitation_dialog`), and
prints `hooks=1`. The spool is the only host directory the sandbox gets to
write besides the workspace. What arrives through it is untrusted: the relay
takes the session from its own environment, never from a payload, and drops
symlinks and payloads over `AM_HOOK_RELAY_MAX` bytes (default 8MB).

When `prepare` does not print `hooks=1`, am writes
`$AM_STATE_DIR/<session>.nohooks`. Without it, Claude's `✳` title with no
hook file would read as "fresh session, ready" for the whole life of the
session. With it the session reads `unknown` until a hook file appears.

Limits of a relayed hook:

- It is asynchronous, so a `PreToolUse` cannot deny a call. The relocation
  fence of a restored session (AGENTS.md) does not reach a sandboxed agent.
- Payload paths are the sandbox's. `cwd` matches the host path only if the
  sandbox mounts the workspace at the same absolute path (sbx does).
  `transcript_path` points inside the sandbox.

## Restore and reboot recovery

The registry and the sessions log record `sandbox: "1"`. `am restore` and
reboot recovery start the session in the sandbox again (`--sandbox`), and
start a host session on the host whatever the `sandbox` default is
(`--no-sandbox`). Both still need what they need for any session: a
conversation id bound by a hook and a transcript am can find from the host.
A container that keeps its transcripts inside is therefore not restorable,
unless the provider makes them visible on the host.

## Security note

A sandbox that bind-mounts the workspace lets the agent write anything in
it, `.git/config` and `.gitattributes` included. am runs git in the session
directory on the host (the review checkpoints, branch labels, `am diff`), as
does any IDE or shell that opens the repository. A hostile repository
configuration (`core.fsmonitor`, a filter driver) runs on the host the next
time git does. Sandbox providers that need to contain an untrusted agent
should mount a copy or a clone (`sbx run --clone`) rather than the real
checkout.

## Reference: `scripts/sandbox/sbx`

Docker Sandboxes. `prepare` creates the sandbox named after the session
with the launch directory and the hook spool as workspaces, and for Claude
registers `spool-hook.sh` in the sandbox's `~/.claude/settings.json`
(idempotent: the entries carry the `# am-state-hook` marker). `run` starts
the relay and `exec`s `sbx run --name <session> -- <agent args>`. `stop`
runs `sbx stop`, or `sbx rm --force` with `AM_SBX_ON_KILL=rm`. Other agents
(codex, cursor, opencode) run without hooks. `AM_SBX_CREATE_ARGS` adds
`sbx create` arguments (`--memory 8g`, an extra `path:ro` workspace).

## Writing a provider

A host-side wrapper is a few lines (a sketch: the binds an agent needs vary):

```bash
#!/usr/bin/env bash
# bubblewrap: read-only system, writable workspace and am state dir
case "$1" in
    prepare) command -v bwrap >/dev/null || { echo "error: bwrap missing" >&2; exit 1; }
             echo hooks=1 ;;
    run)     dir="$3"; shift 4; [[ "$1" == -- ]] && shift
             exec bwrap --ro-bind / / --dev /dev --proc /proc \
                 --bind "$dir" "$dir" --bind "$AM_STATE_DIR" "$AM_STATE_DIR" \
                 --bind "$AM_DIR" "$AM_DIR" --bind "$HOME/.claude" "$HOME/.claude" \
                 --chdir "$dir" "$@" ;;
    stop)    : ;;
esac
```

Test doubles: `tests/fake_sandbox_provider` (logs every call, execs `run`'s
argv), and `tests/test_agents.sh` `test_sandbox_provider` for the contract
am holds up its end of.
