# Adding a New Agent Integration

How to make `am` support a new coding agent end to end: launch, state
detection, pane title, transcript/identity, restore, `am install`, `am doctor`,
tests, and a live lab.

The codebase is deliberately **manifest-first**. Almost every agent-specific
fact lives in one file, `internal/sessions/agents.manifest` (symlinked as
`lib/agents.manifest`), and the bash and Go sides branch on the manifest
*fields*, never on the agent's name. Start by adding a block there; add code
only for the seams a new family genuinely introduces. The opencode
integration was added this way and is the worked example throughout.

> **Read first:** the manifest header comments
> (`internal/sessions/agents.manifest`, lines 1–40) and the “State Detection”
> section of [`AGENTS.md`](../AGENTS.md). This guide is the procedural
> companion to those references.

---

## The model in one paragraph

A session is a tmux pane running an agent command plus a registry row. `am`
launches the agent, watches a **state file** (and, for some agents, a pane
title) to derive one of eight lifecycle states, and records conversation
identity in **sidecar files** so the tab can be titled and the session
restored. Everything an adapter must supply is expressed as manifest fields;
the resolver, titler, restore scan, and doctor read those fields. The only
places you write agent-specific code are the ones where the agent's *external
contract* differs: how its lifecycle events arrive, how its transcript is
stored, and how its pane title is shaped.

## Decide what you can reuse

Answer these before writing anything. If your agent matches an existing family
on all three, the integration is **manifest-only** (plus tests/docs).

| Question | Existing answers | Where it lives |
|---|---|---|
| How does the initial prompt reach it? | `stdin`, `argv`, `argv:<flags>` | `lib/agents.sh` `_agent_prompt_mode` |
| How do lifecycle signals arrive? | Claude/Codex `state-hook.sh` (CamelCase events), Cursor `state-hook.sh` (camelCase), pi in-process extension, opencode in-process plugin | `lib/hooks/*`, `hook_family` |
| Where is the transcript? | `claude`, `cursor`, `pi`, `opencode`, `none` | `internal/sessions/{sessions,identity,titles}.go` |
| What does the pane title look like? | `claude`, `cursor`, `pi`, `opencode` | `internal/sessions/titles.go` |
| Resume form? | `--resume {id}`, `--session {id}`, `resume {id}` | `resume` |

A new agent that reuses one of each (say, Claude-style panels + a `none`
transcript + Cursor-style title suffixes) needs only a manifest block and test
updates. Anything genuinely new needs code at the exact seam below.

---

## Step 1 — Add the manifest block

Append a block to `internal/sessions/agents.manifest`. One fact per line,
`<type>.<field> <value>`; `-` means “none”. The first line for a type declares
it, and **type order is file order** (it drives `AM_AGENT_TYPES`, the form
selector, and doctor iteration), so put the new agent where you want it.

```text
myagent.command        myagent
myagent.aliases        -
myagent.prompt         stdin
myagent.resume         --resume {id}
myagent.store          none
myagent.title          claude
myagent.title_state    none
myagent.turn_boundary  gated
myagent.hook_family    claude
myagent.preflight      id
myagent.version_bin    myagent
myagent.lab            tests/live_lab/run_myagent.sh
```

Field reference (full text in the manifest header):

| Field | Values | Meaning |
|---|---|---|
| `command` | binary name | Launched by `agent_launch`; also the install-time presence probe (`command -v`). |
| `aliases` | space-separated | Extra names `am new -t` / config accept; normalize to the type. |
| `prompt` | `stdin` \| `argv` \| `argv:<flags>` | `argv` appends the task as the last positional; `argv:<flags>` inserts `<flags>` first (opencode uses `argv:--prompt`). |
| `resume` | template with `{id}`, or `-` | Enables restore + kill-time snapshot. |
| `store` | `claude` \| `cursor` \| `pi` \| `opencode` \| `none` | Transcript layout: existence check + first-message reader. `none` = id-only (Codex). |
| `title` | `claude` \| `cursor` \| `pi` \| `opencode` | Pane-title parser. |
| `title_state` | `glyph` \| `suffix` \| `none` | Does the title itself carry state? |
| `turn_boundary` | `reliable` \| `gated` | Reliable = real turn-boundary events exist → read the hook file ungated. Gated = 180s running-staleness gate. |
| `hook_family` | `claude` \| `cursor` \| `pi` \| `opencode` | Event namespace, used by `state-hook.sh` to reject foreign agents nested in a pane. |
| `preflight` | `transcript` \| `id` | Restore preflight: must the transcript exist, or is a well-formed id enough? |
| `version_bin` | binary name | `am doctor` `--version` probe and `tests/live_lab/VERIFIED` key. |
| `lab` | path or `-` | Live lab that verifies state detection. |

Nothing else wires the type: launching, the interactive form, presets,
`am config set agent`, the status bar `[type]` label, and the restore gate all
derive from `AGENT_COMMANDS` / `AM_AGENT_TYPES`, which are built from this
file (`lib/agents.sh` `_agents_commands_init`, `internal/sessions/agents.go`
`parseAgentManifest`).

### Prompt delivery (`argv:<flags>`)

`agent_launch` (`lib/agents.sh`) reads the mode via `_agent_prompt_mode` and
`_agent_prompt_as_arg`. `stdin` pipes a temp file (buffered, no tty overflow);
`argv` appends the quoted task; `argv:<flags>` splits `<flags>` on whitespace
and appends each before the task. Use `argv:<flags>` when the agent needs a
flag (`opencode --prompt "text"`) rather than a bare positional.

---

## Step 2 — State detection

This is the hard part; get it empirically right (see the live lab, Step 10).

### The state-file contract

Every mechanism writes the same three things:

1. **`$AM_STATE_DIR/<session>`** — one word: `running`, `ready`,
   `waiting_user`, `background` (canonical names; the pre-0.12
   `waiting_*` aliases are accepted on read but never written). Write on
   **transitions only** — the file's mtime is the state-entry timestamp that
   the status bar renders as tab age.
2. **`$AM_STATE_DIR/<session>.sid`** (+ durable copy under
   `$AM_IDENTITY_DIR`) — the conversation id, when the agent exposes one.
3. Optionally `$AM_STATE_DIR/<session>.cwd` (working directory for the tab
   label), `.dirty` (touch on tool activity so the review pane re-measures),
   and `.transcript` (absolute path to a transcript, for `store` layouts that
   report one — Cursor and opencode).

Also: after a write, remove `$AM_DIR/.list_cache`, `.title_scan_last`, and
`.restore_scan_last` and run `tmux -L <socket> refresh-client -S` so the tab
redraws immediately. A dead agent drops the pane to a shell, which the
resolver's shell-pane check catches, so an in-process mechanism never needs a
staleness gate.

Writes are gated on **positive pane identification**: the hook must see
`AM_SESSION_NAME` (seeded into every am pane at creation) and the registry row
for that session must have the matching `agent_type`. A directory is shared, so
never infer the session from cwd.

### Choose a mechanism

- **Reuse `lib/hooks/state-hook.sh`** (`hook_family=claude` or `cursor`) if the
  agent can run shell commands on lifecycle events with a payload close enough
  to Claude's or Cursor's. Cursor is the template for a new camelCase family:
  extend the event→state mapping and family inference in `state-hook.sh`, add
  an installer in `scripts/install.sh`, and add the family to
  `_AM_HOOK_FAMILY_FALLBACK` (Step: inline table).
- **Write a sibling in-process extension** (like `lib/hooks/am-state.ts` for pi
  or `lib/hooks/opencode-state.js` for opencode) if the agent has a plugin
  API. This is the strongest signal and the recommended path when available.
  Model the file on `lib/hooks/opencode-state.js`: module-scope config from
  `process.env`, a registry gate, transition-only `writeState`, sidecar
  writers, and best-effort error handling throughout.
- **Title-only or gated hooks** (`title_state`/`turn_boundary`): if the agent
  exposes neither turn-boundary events nor a plugin, use `turn_boundary=gated`
  so `running` falls to `unknown` after 180s of silence, and a `title_state`
  signal if its title is stable enough.

### Pick the manifest values

- `hook_family` — the namespace your events arrive in. If you add a brand-new
  mechanism, introduce a new family name (e.g. `opencode`). `state-hook.sh`
  uses the family to reject a foreign agent nested inside a pane.
- `turn_boundary` — `reliable` only if you have genuine turn-boundary events
  (a stop/settled/idle event, or an in-process plugin). Otherwise `gated`.
- `title_state` — `none` unless the pane title itself encodes busy/waiting
  (`glyph` for Claude's spinners/`✳`, `suffix` for Cursor's `✅/⏳/❓`).

### Inline family table (parity test)

`lib/hooks/state-hook.sh` carries `_AM_HOOK_FAMILY_FALLBACK` for the
out-of-repo byte copy Cursor runs. `tests/test_agents.sh`
(`test_agent_manifest`) asserts **every manifest type has an entry** mapping to
its `hook_family`. Add yours even if the agent never calls `state-hook.sh`
(opencode is listed as `opencode=opencode` solely to satisfy this parity
check and to reject cross-family events).

---

## Step 3 — Transcript store (only for a new layout)

Reuse `store=none` (id-only) if the agent has no addressable local transcript.
If it keeps transcripts in a location `am` can address, decide the shape:

- **Deterministic path from `home` + `dir` + `sid`** (Claude, pi): implement
  `xxxJSONLExists` and `xxxFirstUserMessage` in
  `internal/sessions/sessions.go` / `titles.go`, add a `case` to
  `storeJSONLExists` and `FirstMessage` in `internal/sessions/identity.go`,
  and a `case` to `_doc_transcript` in `lib/doctor.sh`. Test overrides are
  environment variables (`AM_PI_SESSIONS_DIR`, `AM_CURSOR_PROJECTS_DIR`).
- **Hook-reported path** (Cursor, opencode): the agent's hook writes an
  absolute path to `<session>.transcript`; `AgentSpec.SidecarTranscriptStore()`
  returns true for these. `DetectID`, `refreshedTitle`, `RestoreScan`, and
  `agent_kill` already consult the sidecar for those stores. As with Cursor,
  persist the path into the sessions log (`transcript_path`) so restore can
  verify it after the sidecar is cleaned up. opencode’s real store is SQLite,
  which am can’t read, so its plugin mirrors the first user message to
  `$AM_DIR/opencode/<sid>.jsonl` and points `.transcript` at it — that mirror
  is the addressable copy.

`preflight` is `transcript` if that check can succeed, else `id`.

---

## Step 4 — Pane title parser

If `title` is a new shape, add a function in `internal/sessions/titles.go`
(e.g. `opencodeTitleExtract`) and a `case` in `refreshedTitle`. Rules:

- Return `""` for the agent’s bare boot placeholder (`OpenCode`, `pi`, …) so
  the first-user-message fallback can name the tab.
- Strip only the agent-owned decoration (`OC | `, ` - ✅ Ready`, `pi - X - base`).
- `titleValid` (`titles.go`) rejects empty/newline/over-long and the literal
  `Claude Code`; the scan applies hysteresis, so an invalid title never
  replaces an existing task.

The scan is `am-core titles` (Go `RefreshTitles`); `lib/registry.sh`
`auto_title_scan` is a one-line wrapper.

---

## Step 5 — Restore and resume

Set `resume` to the template that takes a conversation id, and `preflight`
appropriately. `agent_resume_args` (bash) and `AgentSpec.ResumeArgs` (Go)
expand `{id}`; `agent_restorable` / `Restorable` gate whether the session is
logged at launch and snapshotted at kill. No other restore code is needed
unless the agent’s store/preflight semantics are unusual.

---

## Step 6 — Install wiring

If the mechanism needs an artifact in the agent’s config, wire it in **three**
places:

1. `scripts/install.sh` — add an `_install_<agent>_*` function and invoke it
   guarded by `command -v <command>`. Symlink from the checkout where possible
   (`_install_pi_extension`, `_install_opencode_plugin`) so it stays fresh.
2. `am` `_install_inputs()` — add the artifact’s source path to the install
   fingerprint so a browser launch refreshes after it changes.
3. `am` `_install_refresh()` — refresh the symlink when the checkout moved or
   the artifact changed (see the Cursor hook-copy and opencode plugin blocks).

If the agent needs a config feature flag (like Codex’s `hooks = true`), add an
idempotent `_enable_*` helper alongside the installer.

---

## Step 7 — Doctor

- `lib/doctor.sh` `_doc_hooks_installed` — add a check that the hook/plugin is
  installed and current (`_doc_hooks_check` for shell hooks, a bespoke
  `_doc_opencode_plugin`-style function for plugins). Report “CLI not
  installed” rather than a warning when `command -v` fails.
- `_doc_required_keys` — if your agent uses `state-hook.sh`, list the payload
  fields the hook reads, keyed by `<agent>.*` / `<agent>.<Event>`. In-process
  plugins don’t write `$AM_DIR/hook-schema/`, so nothing is needed there.
- `_doc_transcript` — add your `store` case (path resolution + first-message
  reader + the “missing transcript” warning list).
- `version_bin` and `lab` drive the version-drift canary automatically.
- Add a live-lab pin so doctor reports “verified” instead of nagging (Step 10).

---

## Step 8 — Tests

Several tests hard-code the agent set; update them or the suite fails:

- `internal/sessions/agents_test.go` — `TestAgentManifestTypes` (ordered
  `want`), `TestAgentManifestFacts` (command/prompt/store/family/resume), and
  `TestStoreDispatch` if you add a store.
- `tests/test_agents.sh` — `test_agents` (command/prompt/resume assertions),
  `test_agent_manifest` (the `AM_AGENT_TYPES` string appears twice, the
  `AGENT_COMMANDS` count, and the fallback-table parity check). Add an
  integration prompt-injection case if your prompt mode is new.
- `tests/test_helpers.sh` — `setup_integration_env`: symlink the new command
  name to `tests/stub_agent` under `$TEST_STUB_BIN` and add
  `AGENT_COMMANDS[<type>]`.
- `tests/test_form.sh` — the directory-launcher `launch_agents` list.
- Add focused Go tests for a new `store`/title parser
  (`titles_test.go`, `agents_test.go`).

Run `./tests/test_all.sh --summary` (it builds the Go binaries first) plus
`bash -n lib/*.sh am` and `go vet ./... && go test ./...`.

---

## Step 9 — Live lab and verified pin

State detection rests on empirical agent behavior, so it needs ground truth.
Copy an existing runner (`tests/live_lab/run_pi.sh` or `run_opencode.sh`) to
`tests/live_lab/run_<agent>.sh` and drive the agent through: fresh idle,
prompt round-trip (running → ready), a long quiet tool call (>180s for the
gated case), a dialog if the agent has one, and quit → shell. The lab runs in
an isolated tmux/state/registry sandbox, records `report.txt` +
`timeline.tsv` + pane snapshots at 1s resolution, and prints the installed
version at the end.

After the report agrees, add a line to `tests/live_lab/VERIFIED`
(`<binary> <version> <date> <lab> <note…>`) and extend
`tests/live_lab/README.md`. `am doctor` warns when the installed version is
newer than its pin.

---

## Step 10 — Docs and version

- `README.md` — the intro tagline, the supported-agents install table, the
  `am new -t` examples, the restore/resume paragraph, the state-detection
  paragraph, the auto-titling paragraph, the Agent Types table, and the
  `am restore` command row.
- `AGENTS.md` — the manifest field list, the Key Files table, the Data Flow
  block, the State Detection section (add a `<agent> sessions:` paragraph),
  and the Extension Points table.
- `docs/concepts.md` and `skills/agent-manager-dispatch/SKILL.md` mention the
  agent set.
- Bump `AM_VERSION` in `am` (new user-facing capability → MINOR) in the same
  commit, and mention the bump in the commit body.

---

## Gotchas

- **Never branch on the agent name** in production code; branch on manifest
  fields. The exceptions are the few places that already switch on `store` /
  `title`.
- **State writes are transition-only.** Rewriting the same state resets the tab
  age and flaps the UI.
- **No pane-content scraping for state.** The one exception is Cursor’s
  structural footer task counter. Use the agent’s own events/titles.
- **Beware synthetic user messages.** opencode emits a post-turn
  title-generation user message *after* `session.idle`; treating user messages
  as turn starts pinned it at `running`. Drive `running` from the busy status,
  not from a user message.
- **Identity comes only from the session’s own sidecar.** Never pick the
  newest transcript in a shared directory.
- **`sed -E`, not `sed -r`**; libs are sourced (no shebang, no `set -euo
  pipefail`); log to stderr; prefix functions by module.
- **`$AM_DIR/opencode`** (or your store’s mirror dir) is on the persistent side;
  the state dir is ephemeral and shared across AM_DIRs.

---

## Reference: the opencode integration

The commit that added opencode (`opencode: full agent support — state plugin,
store, title, restore, live lab; 0.34.0`) is the most complete recent example.
Read it in this order:

1. `internal/sessions/agents.manifest` — the block.
2. `lib/hooks/opencode-state.js` — the in-process plugin.
3. `internal/sessions/{identity,sessions,titles}.go` — store, first-message
   mirror, title parser, and the generalized `.transcript` sidecar handling.
4. `scripts/install.sh` + `am` `_install_inputs`/`_install_refresh` — install.
5. `lib/doctor.sh` — plugin check + transcript case.
6. `lib/agents.sh` — `argv:<flags>` prompt delivery and kill-time transcript.
7. `tests/test_agents.sh`, `tests/test_helpers.sh`, `internal/sessions/*_test.go`
   — test updates.
8. `tests/live_lab/run_opencode.sh`, `tests/live_lab/VERIFIED` — ground truth.
