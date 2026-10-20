/**
 * lib/hooks/opencode-state.js - agent-manager state detection for opencode.
 *
 * opencode twin of lib/hooks/state-hook.sh (Claude/Codex/Cursor) and
 * lib/hooks/am-state.ts (pi). Installed by `am install` as a symlink at
 * ~/.config/opencode/plugins/am-state.js, which opencode auto-discovers.
 * opencode loads plugins in-process and hands every server event to the
 * plugin, so the file cannot go silently stale the way an external shell hook
 * can: a dead opencode drops the pane back to a shell, which the resolver's
 * shell-pane check catches. The resolver reads the file UNGATED for opencode
 * (turn_boundary=reliable).
 *
 * Two APIs, one file (the plugin default export carries both entrypoints):
 *
 *   OpenCode 2 (setup) - plugins live in the shared background service, not
 *   in the TUI process, so the pane environment (AM_SESSION_NAME) describes
 *   whichever pane happened to start the service. A session belongs to a
 *   LOCATION (directory) in V2, so each opencode session is bound to the one
 *   live am session registered for that directory. Events for a session no
 *   live am session owns are dropped (hook.drop in events.log), never guessed.
 *   Event mapping (opencode 2.1, see tests/live_lab/run_opencode.sh):
 *     session.created                                 -> ready
 *     session.inbox.enqueued (item.type=user)         -> running + first message
 *     session.execution.started                       -> running
 *     session.execution.succeeded|failed|interrupted  -> ready
 *     session.idle, session.status idle               -> ready
 *     session.status busy|retry                       -> running
 *     permission.asked, form.created                  -> waiting_user
 *     permission.replied|rejected, form.replied       -> running
 *
 *   OpenCode 1 (server) - the TUI hosts the server, so the pane environment
 *   names the am session directly. Event mapping (opencode 1.18):
 *     session.created, session.status idle, session.idle  -> ready
 *     session.status busy|retry                           -> running
 *     permission(.v2).asked, question(.v2).asked          -> waiting_user
 *     permission(.v2).replied, question.v2.*replied       -> running
 *
 * Side effects (mirroring the other hooks), per am session:
 *   .sid         the opencode session id (ephemeral + durable identity)
 *   .transcript  absolute path of the first-user-message mirror
 *   mirror       $AM_DIR/opencode/<sid>.jsonl, one {"role":"user","text":…}
 *                line: opencode stores conversations in SQLite, which am
 *                cannot address, so the plugin keeps the addressable copy
 *   .cwd         the session directory (tab label; title-scan unthrottle)
 *   .dirty       touched on tool/message activity (review pane re-measure)
 *
 * No-op unless the session resolves to a live am session whose registry row
 * says agent_type opencode. Every side effect is best-effort: a failure must
 * never break the opencode session.
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const envSessionName = process.env.AM_SESSION_NAME ?? "";
const registeredAgentType = process.env.AM_AGENT_TYPE ?? "";
const stateDir = process.env.AM_STATE_DIR ?? "/tmp/am-state";
const identityDir =
  process.env.AM_IDENTITY_DIR ??
  join(process.env.AM_DIR ?? join(homedir(), ".agent-manager"), "identities");
const amDir =
  process.env.AM_DIR ??
  (process.env.AM_IDENTITY_DIR ? dirname(process.env.AM_IDENTITY_DIR) : join(homedir(), ".agent-manager"));
const registryPath = process.env.AM_REGISTRY ?? join(amDir, "sessions.json");
const tmuxSocket = process.env.AM_TMUX_SOCKET ?? "agent-manager";

function readFirstLine(file) {
  try {
    return (readFileSync(file, "utf8").split("\n", 1)[0] ?? "").trim();
  } catch {
    return "";
  }
}

function readRegistry() {
  try {
    const reg = JSON.parse(readFileSync(registryPath, "utf8"));
    return reg && typeof reg.sessions === "object" && reg.sessions ? reg.sessions : {};
  } catch {
    return {};
  }
}

function sessionRegistered(session = envSessionName) {
  if (!session) return false;
  if (!existsSync(registryPath)) return registeredAgentType === "opencode";
  const row = readRegistry()[session];
  const type = row?.agent_type;
  return type === "opencode" && (!registeredAgentType || registeredAgentType === "opencode");
}

// Invalidate the list cache and title-scan throttle, then nudge the status
// bar. Mirrors state-hook.sh / am-state.ts.
function nudge() {
  try {
    rmSync(join(amDir, ".list_cache"), { force: true });
    rmSync(join(amDir, ".title_scan_last"), { force: true });
    rmSync(join(amDir, ".restore_scan_last"), { force: true });
  } catch {
    /* best-effort */
  }
  try {
    execFile("tmux", ["-L", tmuxSocket, "refresh-client", "-S"], () => {});
  } catch {
    /* best-effort */
  }
}

// One TSV line in $AM_DIR/events.log, shaped like am's am_event: rare
// lifecycle/failure only (a session no live am session owns), never the
// success path.
function event(what, session, detail) {
  try {
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const line = `${now}\tplugin:${process.pid}\t${what}\t${session || "-"}\t${detail ?? ""}\n`;
    appendFileSync(join(amDir, "events.log"), line);
  } catch {
    /* best-effort */
  }
}

function writeState(session, state) {
  if (!session) return;
  let changed = false;
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, session);
    if (readFirstLine(file) !== state) {
      writeFileSync(file, state);
      changed = true;
    }
  } catch {
    /* best-effort */
  }
  // Repeated same-state writes are the norm (every plugin location instance
  // sees the whole server event stream), so nudge only on a transition.
  if (changed) nudge();
}

// Write a sidecar both ephemerally (state dir) and durably (identity dir).
// The durable copy is only overwritten when it is empty, unchanged, or a
// .rebind marker permits it (a resumed conversation re-pins identity).
function writeSidecar(session, suffix, value) {
  if (!session || !value) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, `${session}${suffix}`), value);
    mkdirSync(identityDir, { recursive: true });
    const durable = join(identityDir, `${session}${suffix}`);
    const rebind = join(identityDir, `${session}.rebind`);
    const current = readFirstLine(durable);
    if (!current || current === value || existsSync(rebind)) {
      writeFileSync(durable, value);
      rmSync(rebind, { force: true });
    }
  } catch {
    /* best-effort */
  }
}

function mirrorPath(sid) {
  return join(amDir, "opencode", `${sid}.jsonl`);
}

function bindIdentity(session, sid) {
  if (!session || !sid || !/^[A-Za-z0-9._-]+$/.test(sid)) return;
  const file = join(stateDir, `${session}.sid`);
  if (readFirstLine(file) === sid) return;
  writeSidecar(session, ".sid", sid);
  try {
    const p = mirrorPath(sid);
    mkdirSync(dirname(p), { recursive: true });
    if (!existsSync(p)) writeFileSync(p, ""); // marker: this session exists
    writeSidecar(session, ".transcript", p);
  } catch {
    /* best-effort */
  }
}

function writeCwd(session, dir) {
  if (!session || !dir) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, `${session}.cwd`);
    if (readFirstLine(file) !== dir) {
      writeFileSync(file, dir);
      rmSync(join(amDir, ".title_scan_last"), { force: true });
    }
  } catch {
    /* best-effort */
  }
}

function touchDirty(session) {
  if (!session) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    appendFileSync(join(stateDir, `${session}.dirty`), "");
  } catch {
    /* best-effort */
  }
}

function writeMirrorText(session, text) {
  if (!session || typeof text !== "string" || !text) return;
  const sid = readFirstLine(join(stateDir, `${session}.sid`));
  if (!sid) return;
  // opencode can hand back the raw input with its surrounding quotes intact;
  // strip one matching pair so the mirror/preview reads as typed.
  let body = text;
  if (body.length >= 2 && body.startsWith('"') && body.endsWith('"')) body = body.slice(1, -1);
  try {
    const p = mirrorPath(sid);
    mkdirSync(dirname(p), { recursive: true });
    if (!existsSync(p)) writeFileSync(p, "");
    appendFileSync(p, JSON.stringify({ role: "user", text: body }) + "\n");
  } catch {
    /* best-effort */
  }
}

function mirrorHasMessage(session) {
  try {
    const p = mirrorPath(readFirstLine(join(stateDir, `${session}.sid`)));
    return existsSync(p) && statSync(p).size > 0;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// OpenCode 1: pane environment names the am session.
// ---------------------------------------------------------------------------

let v1BoundSid = "";
let v1FirstMessageWritten = false;
const v1UserMessageIDs = new Set();
let v1PendingPermission = false;

function bindV1(sid) {
  if (!sid || v1BoundSid === sid) return;
  v1BoundSid = sid;
  bindIdentity(envSessionName, sid);
}

function handleV1Part(p) {
  const part = p.part;
  if (!part || part.type !== "text" || !part.text) return;
  if (v1FirstMessageWritten || !v1BoundSid) return;
  if (!v1UserMessageIDs.has(part.messageID)) return;
  v1FirstMessageWritten = true;
  writeMirrorText(envSessionName, part.text);
}

async function onV1Event({ event }) {
  const session = envSessionName;
  const p = event.properties ?? event.data ?? {};
  const sid = p.sessionID ?? p.info?.id ?? p.info?.sessionID;
  if (sid) bindV1(sid);

  switch (event.type) {
    case "session.created":
      if (p.info?.directory) writeCwd(session, p.info.directory);
      writeState(session, "ready");
      break;
    case "session.updated":
      if (p.info?.directory) writeCwd(session, p.info.directory);
      break;
    case "session.status": {
      const status = p.status?.type;
      if (v1PendingPermission && status !== "idle") break;
      if (status === "busy" || status === "retry") writeState(session, "running");
      else if (status === "idle") writeState(session, "ready");
      break;
    }
    case "session.idle":
      if (!v1PendingPermission) writeState(session, "ready");
      break;
    case "message.updated":
      // Track user message ids (for the first-message mirror) but do NOT
      // treat every user message as a turn start: opencode emits a synthetic
      // user message for post-turn title generation *after* session.idle, so
      // that would pin the session at running. `session.status busy` is the
      // turn-start signal.
      if (p.info?.role === "user" && p.info.id) v1UserMessageIDs.add(p.info.id);
      break;
    case "message.part.updated":
      handleV1Part(p);
      touchDirty(session);
      break;
    case "permission.asked":
    case "permission.v2.asked":
    case "question.asked":
    case "question.v2.asked":
      v1PendingPermission = true;
      writeState(session, "waiting_user");
      break;
    case "permission.replied":
    case "permission.v2.replied":
    case "question.v2.replied":
    case "question.v2.rejected":
      v1PendingPermission = false;
      writeState(session, "running");
      break;
    default:
      break;
  }
}

// ---------------------------------------------------------------------------
// OpenCode 2: a session belongs to a location; bind it to the live am
// session registered for that directory (the service process carries the
// environment of whichever pane started it, never this pane's).
// ---------------------------------------------------------------------------

const liveSessionsCache = { at: 0, names: new Set() };

function liveTmuxSessions() {
  if (Date.now() - liveSessionsCache.at < 2000) return Promise.resolve(liveSessionsCache.names);
  return new Promise((resolve) => {
    try {
      execFile("tmux", ["-L", tmuxSocket, "list-sessions", "-F", "#{session_name}"], { timeout: 1500 }, (err, stdout) => {
        if (err) return resolve(liveSessionsCache.names);
        liveSessionsCache.names = new Set(String(stdout).split("\n").filter(Boolean));
        liveSessionsCache.at = Date.now();
        resolve(liveSessionsCache.names);
      });
    } catch {
      resolve(liveSessionsCache.names);
    }
  });
}

const ownerCache = new Map(); // opencode session id -> { owner, dir, child }
const dropLogged = new Map();

// opencode reports its location with symlinks resolved (/private/var/... on
// macOS) while a registry row keeps the path the pane was launched with
// (/var/...); compare canonical paths.
const realDirCache = new Map();

function realDir(p) {
  if (!p) return "";
  const hit = realDirCache.get(p);
  if (hit !== undefined) return hit;
  let out = p;
  try {
    out = realpathSync(p);
  } catch {
    /* keep the path as given */
  }
  realDirCache.set(p, out);
  return out;
}

function drop(reason, sid, dir, extra = "") {
  const key = `${reason}:${sid}`;
  const now = Date.now();
  if (now - (dropLogged.get(key) ?? 0) < 60000) return;
  dropLogged.set(key, now);
  event("hook.drop", "-", `reason=${reason} sid=${sid} dir=${dir}${extra ? " " + extra : ""}`);
}

async function resolveOwner(ctx, sid, locationDir) {
  const cached = ownerCache.get(sid);
  if (cached && (cached.owner || cached.child || Date.now() - cached.at < 30000)) return cached;
  // One lookup per session: it carries the session's location and whether it
  // is a subagent's child (whose execution events must not move the parent's
  // state).
  let info = null;
  try {
    info = await ctx.session.get({ sessionID: sid });
  } catch {
    /* fall back to the event's location */
  }
  const dir = info?.location?.directory ?? info?.directory ?? locationDir ?? "";
  if (info?.parentID) {
    const child = { owner: "", dir, child: true, at: Date.now() };
    ownerCache.set(sid, child);
    return child;
  }
  const live = await liveTmuxSessions();
  const rows = readRegistry();
  const wantDir = realDir(dir);
  const matches = [];
  for (const [name, row] of Object.entries(rows)) {
    if (row?.agent_type !== "opencode") continue;
    if (!live.has(name)) continue;
    const effective = row.workdir || row.directory || "";
    if (effective && realDir(effective) === wantDir) matches.push(name);
  }
  let owner = "";
  if (matches.length === 1) owner = matches[0];
  // A positive binding is permanent (a session never changes location); an
  // unowned answer is retried, an am session may appear in that directory.
  const resolved = { owner, dir, at: Date.now() };
  ownerCache.set(sid, resolved);
  if (!owner) {
    drop(matches.length ? "unowned_ambiguous" : "unowned", sid, dir, matches.length ? `candidates=${matches.join(",")}` : "");
  }
  return resolved;
}

const pendingPermission = new Set();

async function onV2Event(ctx, event) {
  const type = event?.type ?? "";
  const p = event?.data ?? event?.properties ?? {};
  const sid = p.sessionID ?? p.id ?? p.info?.id;
  if (!sid) return;
  const locationDir = event?.location?.directory ?? p.location?.directory ?? "";

  // Skip events that provably belong to another location (this plugin
  // instance runs once per location; every instance sees the whole stream).
  if (locationDir && ctx.location?.directory && locationDir !== ctx.location.directory) return;

  const { owner: session, dir } = await resolveOwner(ctx, sid, locationDir);
  if (!session) return;
  bindIdentity(session, sid);
  writeCwd(session, dir);

  switch (type) {
    case "session.created":
      writeState(session, "ready");
      break;
    case "session.updated":
    case "session.metadata.updated":
      break;
    case "session.inbox.enqueued": {
      const item = p.item ?? {};
      if (item.type !== "user") break;
      if (!mirrorHasMessage(session)) writeMirrorText(session, item.payload?.text ?? "");
      pendingPermission.delete(sid);
      writeState(session, "running");
      break;
    }
    case "session.execution.started":
      pendingPermission.delete(sid);
      writeState(session, "running");
      break;
    case "session.execution.succeeded":
    case "session.execution.failed":
    case "session.execution.interrupted":
    case "session.idle":
      if (!pendingPermission.has(sid)) writeState(session, "ready");
      break;
    case "session.status": {
      const status = p.status?.type;
      if (pendingPermission.has(sid) && status !== "idle") break;
      if (status === "busy" || status === "retry") writeState(session, "running");
      else if (status === "idle") writeState(session, "ready");
      break;
    }
    case "permission.asked":
    case "permission.v2.asked":
    case "form.created":
      pendingPermission.add(sid);
      writeState(session, "waiting_user");
      break;
    case "permission.replied":
    case "permission.v2.replied":
    case "permission.rejected":
    case "form.replied":
    case "form.cancelled":
      pendingPermission.delete(sid);
      writeState(session, "running");
      break;
    case "session.deleted":
      ownerCache.delete(sid);
      pendingPermission.delete(sid);
      break;
    default:
      // Tool, step, text, reasoning and message traffic: review re-measure
      // and title-scan nudges only (an untracked write on every delta would
      // be noise; execution.started already marked the turn running).
      if (
        type.startsWith("session.tool.") ||
        type.startsWith("session.step.") ||
        type.startsWith("session.text.") ||
        type.startsWith("session.reasoning.") ||
        type === "session.message.content.updated"
      ) {
        touchDirty(session);
      }
      break;
  }
}

export default {
  id: "am.state",

  async setup(ctx) {
    // A fresh TUI creates its session lazily (no session.created until the
    // first prompt) and resumes are equally idle, so plugin init is
    // opencode's session_start equivalent: the pane booted into an idle
    // prompt. Only the location's sole live am session gets it.
    try {
      const live = await liveTmuxSessions();
      const dir = realDir(ctx?.location?.directory ?? "");
      const matches = Object.entries(readRegistry()).filter(
        ([name, row]) =>
          row?.agent_type === "opencode" &&
          live.has(name) &&
          realDir(row.workdir || row.directory || "") === dir,
      );
      if (matches.length === 1) writeState(matches[0][0], "ready");
    } catch {
      /* best-effort */
    }

    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try {
            await onV2Event(ctx, event);
          } catch {
            /* best-effort */
          }
        }
      } catch {
        /* subscription ended (plugin unloaded) */
      }
    })();
    return () => controller.abort();
  },

  // OpenCode 1 entrypoint (the pane environment names the am session).
  async server() {
    if (!envSessionName || !sessionRegistered()) return {};

    // Same fresh-TUI reasoning as setup above.
    writeState(envSessionName, "ready");

    return {
      event: onV1Event,
      "tool.execute.before": async () => {
        touchDirty(envSessionName);
      },
      "tool.execute.after": async () => {
        touchDirty(envSessionName);
      },
    };
  },
};
