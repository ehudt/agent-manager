/**
 * lib/hooks/am-state.ts - agent-manager state detection for pi sessions.
 *
 * Pi twin of lib/hooks/state-hook.sh (Claude/Codex): maps pi lifecycle
 * events to am session states and writes them to $AM_STATE_DIR/<session>.
 * Installed by `am install` as a symlink at ~/.pi/agent/extensions/am-state.ts
 * (auto-discovered by pi) and copied into the sandbox home by sandbox_start.
 *
 * Event mapping:
 *   session_start  -> waiting_input   (fresh session idle at its first
 *                     prompt; also rebinds the .sid sidecar — re-fires on
 *                     /new, /resume and /fork, keeping it authoritative)
 *   agent_start    -> running
 *   agent_settled  -> waiting_input   (pi will not continue on its own: no
 *                     retry, auto-compaction, or queued messages left)
 *
 * The resolver (lib/state.sh) trusts this file UNGATED for pi sessions:
 * the extension is in-process, so the file cannot go silently stale — a
 * dead pi drops the pane to a shell, which the shell-pane check catches.
 *
 * Writes are transition-only so the state file's mtime pins the moment the
 * state was entered (the status bar renders tab ages from it). Every side
 * effect is best-effort: a failure must never break the pi session.
 *
 * No-op unless AM_SESSION_NAME is set (exported into the pane by
 * agent_launch). When the registry file exists, the session must be in it;
 * when it is absent (sandbox container — the host registry is not mounted),
 * AM_SESSION_NAME alone is trusted.
 */
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const sessionName = process.env.AM_SESSION_NAME ?? "";
const stateDir = process.env.AM_STATE_DIR ?? "/tmp/am-state";
const amDir = process.env.AM_DIR ?? join(homedir(), ".agent-manager");
const registryPath = process.env.AM_REGISTRY ?? join(amDir, "sessions.json");
const tmuxSocket = process.env.AM_TMUX_SOCKET ?? "agent-manager";

function sessionRegistered(): boolean {
  if (!existsSync(registryPath)) return true;
  try {
    const reg = JSON.parse(readFileSync(registryPath, "utf8")) as {
      sessions?: Record<string, unknown>;
    };
    return Boolean(reg.sessions && sessionName in reg.sessions);
  } catch {
    return true;
  }
}

function writeState(state: string): void {
  try {
    mkdirSync(stateDir, { recursive: true });
    const file = join(stateDir, sessionName);
    let current = "";
    try {
      current = (readFileSync(file, "utf8").split("\n", 1)[0] ?? "").trim();
    } catch {
      /* no existing state file */
    }
    if (current !== state) writeFileSync(file, state);
  } catch {
    /* best-effort */
  }
  // Invalidate the list cache and the title-scan throttle (all three events
  // are prompt boundaries), then nudge the status bar. Mirrors state-hook.sh.
  try {
    rmSync(join(amDir, ".list_cache"), { force: true });
    rmSync(join(amDir, ".title_scan_last"), { force: true });
  } catch {
    /* best-effort */
  }
  try {
    execFile("tmux", ["-L", tmuxSocket, "refresh-client", "-S"], () => {});
  } catch {
    /* best-effort */
  }
}

function writeSid(sid: string | undefined): void {
  if (!sid || !/^[A-Za-z0-9._-]+$/.test(sid)) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, `${sessionName}.sid`), sid);
  } catch {
    /* best-effort */
  }
}

export default function (pi: ExtensionAPI) {
  if (!sessionName || !sessionRegistered()) return;

  pi.on("session_start", async (_event, ctx) => {
    writeSid(ctx.sessionManager.getSessionId());
    writeState("waiting_input");
  });

  pi.on("agent_start", async () => {
    writeState("running");
  });

  pi.on("agent_settled", async () => {
    writeState("waiting_input");
  });
}
