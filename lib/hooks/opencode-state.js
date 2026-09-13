/**
 * lib/hooks/opencode-state.js - agent-manager state detection for opencode.
 *
 * opencode twin of lib/hooks/state-hook.sh (Claude/Codex/Cursor) and
 * lib/hooks/am-state.ts (pi). Installed by `am install` as a symlink at
 * ~/.config/opencode/plugins/am-state.js, which opencode auto-discovers.
 * opencode loads plugins in-process and hands every server event to the
 * `event` hook and every tool run to the tool hooks, so the file cannot go
 * silently stale the way an external shell hook can: a dead opencode drops
 * the pane back to a shell, which the resolver's shell-pane check catches.
 * The resolver reads the file UNGATED for opencode (turn_boundary=reliable).
 *
 * Event mapping (opencode 1.18, see tests/live_lab/run_opencode.sh):
 *   session.created, session.status idle, session.idle  -> ready
 *   session.status busy|retry                           -> running
 *   permission(.v2).asked, question(.v2).asked          -> waiting_user
 *   permission(.v2).replied, question.v2.*replied       -> running
 *
 * Side effects (mirroring the other hooks):
 *   .sid         the opencode session id (ephemeral + durable identity)
 *   .transcript  absolute path of the first-user-message mirror
 *   mirror       $AM_DIR/opencode/<sid>.jsonl, one {"role":"user","text":…}
 *                line: opencode stores conversations in SQLite, which am
 *                cannot address, so the plugin keeps the addressable copy
 *   .cwd         the session directory (tab label; title-scan unthrottle)
 *   .dirty       touched on tool/message activity (review pane re-measure)
 *
 * No-op unless AM_SESSION_NAME is set and the registry row says agent_type
 * opencode. Every side effect is best-effort: a failure must never break the
 * opencode session.
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const sessionName = process.env.AM_SESSION_NAME ?? "";
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

function sessionRegistered() {
  if (!existsSync(registryPath)) return registeredAgentType === "opencode";
  try {
    const reg = JSON.parse(readFileSync(registryPath, "utf8"));
    const registryType = reg.sessions?.[sessionName]?.agent_type;
    return registryType === "opencode" && (!registeredAgentType || registeredAgentType === "opencode");
  } catch {
    return registeredAgentType === "opencode";
  }
}

function readFirstLine(file) {
  try {
    return (readFileSync(file, "utf8").split("\n", 1)[0] ?? "").trim();
  } catch {
    return "";
  }
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

function writeState(state) {
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, sessionName);
    if (readFirstLine(file) !== state) writeFileSync(file, state);
  } catch {
    /* best-effort */
  }
  nudge();
}

// Write a sidecar both ephemerally (state dir) and durably (identity dir).
// The durable copy is only overwritten when it is empty, unchanged, or a
// .rebind marker permits it (a resumed conversation re-pins identity).
function writeSidecar(suffix, value) {
  if (!value) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, `${sessionName}${suffix}`), value);
    mkdirSync(identityDir, { recursive: true });
    const durable = join(identityDir, `${sessionName}${suffix}`);
    const rebind = join(identityDir, `${sessionName}.rebind`);
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

let boundSid = "";
let firstMessageWritten = false;
const userMessageIDs = new Set();
let pendingPermission = false;

function bind(sid) {
  if (!sid || !/^[A-Za-z0-9._-]+$/.test(sid) || sid === boundSid) return;
  boundSid = sid;
  writeSidecar(".sid", sid);
  try {
    const p = mirrorPath(sid);
    mkdirSync(dirname(p), { recursive: true });
    if (!existsSync(p)) writeFileSync(p, ""); // marker: this session exists
    writeSidecar(".transcript", p);
  } catch {
    /* best-effort */
  }
}

function writeCwd(dir) {
  if (!dir) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, `${sessionName}.cwd`);
    if (readFirstLine(file) !== dir) {
      writeFileSync(file, dir);
      rmSync(join(amDir, ".title_scan_last"), { force: true });
    }
  } catch {
    /* best-effort */
  }
}

function touchDirty() {
  try {
    mkdirSync(stateDir, { recursive: true });
    appendFileSync(join(stateDir, `${sessionName}.dirty`), "");
  } catch {
    /* best-effort */
  }
}

function handlePart(p) {
  const part = p.part;
  if (!part || part.type !== "text" || !part.text) return;
  if (firstMessageWritten || !boundSid) return;
  if (!userMessageIDs.has(part.messageID)) return;
  firstMessageWritten = true;
  // opencode can hand back the raw input with its surrounding quotes intact;
  // strip one matching pair so the mirror/preview reads as typed.
  let text = part.text;
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.slice(1, -1);
  }
  try {
    appendFileSync(mirrorPath(boundSid), JSON.stringify({ role: "user", text }) + "\n");
  } catch {
    /* best-effort */
  }
}

async function onEvent({ event }) {
  const p = event.properties ?? event.data ?? {};
  const sid = p.sessionID ?? p.info?.id ?? p.info?.sessionID;
  if (sid) bind(sid);

  switch (event.type) {
    case "session.created":
      if (p.info?.directory) writeCwd(p.info.directory);
      writeState("ready");
      break;
    case "session.updated":
      if (p.info?.directory) writeCwd(p.info.directory);
      break;
    case "session.status": {
      const status = p.status?.type;
      if (pendingPermission && status !== "idle") break;
      if (status === "busy" || status === "retry") writeState("running");
      else if (status === "idle") writeState("ready");
      break;
    }
    case "session.idle":
      if (!pendingPermission) writeState("ready");
      break;
    case "message.updated":
      // Track user message ids (for the first-message mirror) but do NOT
      // treat every user message as a turn start: opencode emits a synthetic
      // user message for post-turn title generation *after* session.idle, so
      // that would pin the session at running. `session.status busy` is the
      // turn-start signal.
      if (p.info?.role === "user" && p.info.id) userMessageIDs.add(p.info.id);
      break;
    case "message.part.updated":
      handlePart(p);
      touchDirty();
      break;
    case "permission.asked":
    case "permission.v2.asked":
    case "question.asked":
    case "question.v2.asked":
      pendingPermission = true;
      writeState("waiting_user");
      break;
    case "permission.replied":
    case "permission.v2.replied":
    case "question.v2.replied":
    case "question.v2.rejected":
      pendingPermission = false;
      writeState("running");
      break;
    default:
      break;
  }
}

export const AmState = async () => {
  if (!sessionName || !sessionRegistered()) return {};

  // A fresh TUI creates its session lazily (no session.created until the first
  // prompt) and resumes are equally idle, so plugin init is opencode's
  // session_start equivalent: the pane booted into an idle prompt.
  writeState("ready");

  return {
    event: onEvent,
    "tool.execute.before": async () => {
      touchDirty();
    },
    "tool.execute.after": async () => {
      touchDirty();
    },
  };
};
