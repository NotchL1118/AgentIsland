/**
 * Pi 1.3+ local integration. Run with `pi -e /path/to/pi-extension.ts`.
 * Monitoring is always passive. Notifications never wait for the panel or
 * participate in tool approval, including when the legacy approval flag is set.
 */
import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Event = Record<string, unknown>;
const maximumBytes = 1024 * 1024;

export function islandSocketPath(): string {
  return process.env.AGENT_ISLAND_SOCKET || join(process.env.TMPDIR || tmpdir(), `agent-island-${process.getuid?.() ?? 0}.sock`);
}

/** Best-effort delivery only. Replies cannot affect the agent's execution. */
export function sendEvent(event: Event): void {
  try {
    const packet = JSON.stringify(event) + "\n";
    if (Buffer.byteLength(packet) > maximumBytes) return;
    const socket = createConnection(islandSocketPath());
    // Neither a stalled connection nor its cleanup timer should keep Pi alive.
    socket.unref();
    const deadline = setTimeout(() => socket.destroy(), 800);
    deadline.unref();
    socket.once("close", () => clearTimeout(deadline));
    socket.once("error", () => socket.destroy());
    socket.once("connect", () => {
      // Close once the event has been written; do not read or await a reply.
      socket.end(packet, () => socket.destroy());
    });
  } catch { /* Observation failures never escape into Pi's handlers. */ }
}

function terminalMetadata(): Record<string, string> {
  const env = process.env;
  const result: Record<string, string> = {};
  const bundleIDs: Record<string, string> = {
    Apple_Terminal: "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
    ghostty: "com.mitchellh.ghostty", WezTerm: "com.github.wez.wezterm",
    vscode: "com.microsoft.VSCode", WarpTerminal: "dev.warp.Warp-Stable",
  };
  const bundleID = env.AGENT_ISLAND_TERMINAL_BUNDLE_ID || bundleIDs[env.TERM_PROGRAM || ""];
  if (bundleID) result.appBundleID = bundleID;
  const tty = env.AGENT_ISLAND_TTY || env.TTY;
  if (tty?.startsWith("/dev/") && tty !== "/dev/tty") result.tty = tty;
  if (env.TMUX_PANE) result.tmuxPane = env.TMUX_PANE;
  if (env.ITERM_SESSION_ID) result.paneID = env.ITERM_SESSION_ID;
  if (env.TERM_SESSION_ID) result.tabID = env.TERM_SESSION_ID;
  return result;
}

export default function agentIsland(pi: ExtensionAPI) {
  const terminal = terminalMetadata();
  let turnID: string | undefined;
  let active = false;
  let title = "Pi";
  let finalText = "";
  let failed = false;
  // Accept old launch commands without restoring their former approval behavior.
  pi.registerFlag("island-approve-tools", { description: "Deprecated; Agent Island only observes and never requests approval", type: "boolean", default: false });

  function event(ctx: ExtensionContext, kind: string, fields: Event = {}): Event {
    return { version: 1, id: randomUUID(), provider: "pi", sessionID: ctx.sessionManager.getSessionId(), turnID,
      timestamp: Date.now() / 1000, kind, title, cwd: ctx.cwd, terminal, ...fields };
  }
  const notify = (ctx: ExtensionContext, kind: string, fields: Event = {}): void => {
    try { sendEvent(event(ctx, kind, fields)); }
    catch { /* Missing host metadata must not interrupt the agent either. */ }
  };

  pi.on("session_start", (_event, ctx) => {
    active = false; turnID = undefined; finalText = ""; failed = false;
    title = ctx.sessionManager.getSessionName() || "Pi";
    notify(ctx, "sessionStarted", { message: "Pi 会话已连接" });
  });
  pi.on("before_agent_start", (input, _ctx) => {
    if (input.messageType === "user") title = input.prompt.trim().split("\n")[0].slice(0, 100) || "Pi";
  });
  pi.on("agent_start", (_event, ctx) => {
    if (!active) { turnID = randomUUID(); active = true; failed = false; finalText = ""; }
    notify(ctx, "turnStarted", { message: "正在处理任务" });
  });
  pi.on("tool_execution_start", (input, ctx) => {
    notify(ctx, "toolStarted", { message: `正在执行：${input.toolName}` });
  });
  pi.on("tool_execution_end", (input, ctx) => {
    notify(ctx, "toolFinished", { message: `${input.isError ? "工具失败" : "已执行"}：${input.toolName}` });
  });
  pi.on("ui_prompt_start", (input, ctx) => {
    notify(ctx, "questionRequested", { message: `请在 Pi 终端处理：${input.title || input.kind}` });
  });
  pi.on("ui_prompt_end", (_input, ctx) => {
    notify(ctx, "toolFinished", { message: "Pi 已收到输入" });
  });
  pi.on("agent_end", (input, _ctx) => {
    const assistant = [...input.messages].reverse().find(message => message.role === "assistant");
    if (assistant?.role === "assistant") {
      failed = assistant.stopReason === "error";
      finalText = assistant.content.filter(part => part.type === "text").map(part => part.text).join("\n").slice(0, 4000);
    }
  });
  pi.on("agent_settled", (input, ctx) => {
    if (!active) return;
    notify(ctx, input.aborted || failed ? "turnFailed" : "turnCompleted", {
      message: input.aborted ? "本轮任务已中断" : failed ? "本轮任务异常结束" : finalText || "本轮任务已完成",
    });
    active = false;
  });
  pi.on("session_shutdown", (_event, ctx) => {
    notify(ctx, "sessionEnded", { message: "Pi 会话已结束" });
    active = false;
  });
}
