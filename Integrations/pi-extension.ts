/**
 * Pi 1.3+ local integration. Run with `pi -e /path/to/pi-extension.ts`.
 * Monitoring is passive. `--island-approve-tools` explicitly adds approval for
 * bash/write/edit; failure falls back to Pi's confirmation UI, never approval.
 */
import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Reply = { status: string; requestID?: string; decision?: string; answer?: string };
type Event = Record<string, unknown>;
const maximumBytes = 1024 * 1024;

export function islandSocketPath(): string {
  return process.env.AGENT_ISLAND_SOCKET || join(process.env.TMPDIR || tmpdir(), `agent-island-${process.getuid?.() ?? 0}.sock`);
}

export function sendEvent(event: Event, timeout = 800, signal?: AbortSignal): Promise<Reply> {
  return new Promise(resolve => {
    if (signal?.aborted) { resolve({ status: "unavailable" }); return; }
    const packet = JSON.stringify(event) + "\n";
    if (Buffer.byteLength(packet) > maximumBytes) { resolve({ status: "error" }); return; }
    const socket = createConnection(islandSocketPath());
    let finished = false;
    let bytes = Buffer.alloc(0);
    const done = (reply: Reply) => {
      if (finished) return;
      finished = true;
      signal?.removeEventListener("abort", aborted);
      socket.destroy();
      resolve(reply);
    };
    const aborted = () => done({ status: "unavailable" });
    signal?.addEventListener("abort", aborted, { once: true });
    socket.setTimeout(Math.min(timeout, 800));
    socket.on("connect", () => { socket.setTimeout(timeout); socket.write(packet); });
    socket.on("timeout", () => done({ status: "unavailable" }));
    socket.on("error", () => done({ status: "unavailable" }));
    socket.on("end", () => done({ status: "unavailable" }));
    socket.on("data", chunk => {
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length > maximumBytes) { done({ status: "error" }); return; }
      const newline = bytes.indexOf(10);
      if (newline < 0) return;
      try {
        const reply = JSON.parse(bytes.subarray(0, newline).toString("utf8"));
        done(reply && typeof reply.status === "string" ? reply : { status: "unavailable" });
      } catch { done({ status: "unavailable" }); }
    });
  });
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
  let tty = env.AGENT_ISLAND_TTY || env.TTY;
  if (!tty && process.stdin.isTTY) {
    try {
      const value = execFileSync("/bin/ps", ["-o", "tty=", "-p", String(process.pid)], { encoding: "utf8", timeout: 300, stdio: ["ignore", "pipe", "ignore"] }).trim();
      if (value && value !== "??" && value !== "?") tty = value.startsWith("/dev/") ? value : `/dev/${value}`;
    } catch { /* App activation remains available without exact TTY. */ }
  }
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
  let ownConfirmation = false;
  pi.registerFlag("island-approve-tools", { description: "Ask Agent Island before bash/write/edit; falls back to Pi confirmation", type: "boolean", default: false });

  function event(ctx: ExtensionContext, kind: string, fields: Event = {}): Event {
    return { version: 1, id: randomUUID(), provider: "pi", sessionID: ctx.sessionManager.getSessionId(), turnID,
      timestamp: Date.now() / 1000, kind, title, cwd: ctx.cwd, terminal, ...fields };
  }
  const notify = async (ctx: ExtensionContext, kind: string, fields: Event = {}) => { await sendEvent(event(ctx, kind, fields)); };

  pi.on("session_start", async (_event, ctx) => {
    active = false; turnID = undefined; finalText = ""; failed = false;
    title = ctx.sessionManager.getSessionName() || "Pi";
    await notify(ctx, "sessionStarted", { message: "Pi 会话已连接" });
  });
  pi.on("before_agent_start", async (input, _ctx) => {
    if (input.messageType === "user") title = input.prompt.trim().split("\n")[0].slice(0, 100) || "Pi";
  });
  pi.on("agent_start", async (_event, ctx) => {
    if (!active) { turnID = randomUUID(); active = true; failed = false; finalText = ""; }
    await notify(ctx, "turnStarted", { message: "正在处理任务" });
  });
  pi.on("tool_execution_start", async (input, ctx) => {
    await notify(ctx, "toolStarted", { message: `正在执行：${input.toolName}` });
  });
  pi.on("tool_execution_end", async (input, ctx) => {
    await notify(ctx, "toolFinished", { message: `${input.isError ? "工具失败" : "已执行"}：${input.toolName}` });
  });
  pi.on("tool_call", async (input, ctx) => {
    if (!pi.getFlag("island-approve-tools") || !["bash", "write", "edit"].includes(input.toolName)) return;
    const requestID = `pi:${ctx.sessionManager.getSessionId()}:${input.toolCallId}`;
    const args = input.input as Record<string, unknown>;
    const detail = String(args.command || args.path || JSON.stringify(args)).slice(0, 16000);
    const reply = await sendEvent(event(ctx, "approvalRequested", { message: `等待批准 ${input.toolName}`,
      request: { id: requestID, kind: "approval", title: `允许 ${input.toolName}？`, detail } }), 120000, ctx.signal);
    if (reply.status === "resolved" && reply.requestID === requestID) {
      if (reply.decision === "allow") return;
      if (reply.decision === "deny") return { block: true, reason: "用户在 Agent Island 拒绝了本次操作。" };
    }
    if (reply.status !== "duplicate") {
      await notify(ctx, "requestCancelled", { request: { id: requestID }, message: "面板审批已结束，请在 Pi 处理确认。" });
    }
    if (ctx.signal?.aborted) return { block: true, reason: "操作已取消。" };
    if (!ctx.hasUI) return { block: true, reason: "Agent Island 不可用，当前模式无法显示备用确认；操作未执行。" };
    ownConfirmation = true;
    try {
      const allowed = await ctx.ui.confirm("Agent Island 不可用", `是否允许 ${input.toolName}？\n${detail}`, { timeout: 120000 });
      if (!allowed) return { block: true, reason: "用户未批准本次操作。" };
    } finally { ownConfirmation = false; }
  });
  pi.on("ui_prompt_start", async (input, ctx) => {
    if (!ownConfirmation) await notify(ctx, "questionRequested", { message: `请在 Pi 终端处理：${input.title || input.kind}` });
  });
  pi.on("ui_prompt_end", async (_input, ctx) => {
    if (!ownConfirmation) await notify(ctx, "toolFinished", { message: "Pi 已收到输入" });
  });
  pi.on("agent_end", async (input, _ctx) => {
    const assistant = [...input.messages].reverse().find(message => message.role === "assistant");
    if (assistant?.role === "assistant") {
      failed = assistant.stopReason === "error";
      finalText = assistant.content.filter(part => part.type === "text").map(part => part.text).join("\n").slice(0, 4000);
    }
  });
  pi.on("agent_settled", async (input, ctx) => {
    if (!active) return;
    await notify(ctx, input.aborted || failed ? "turnFailed" : "turnCompleted", {
      message: input.aborted ? "本轮任务已中断" : failed ? "本轮任务异常结束" : finalText || "本轮任务已完成",
    });
    active = false;
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    await notify(ctx, "sessionEnded", { message: "Pi 会话已结束" });
    active = false;
  });
}
