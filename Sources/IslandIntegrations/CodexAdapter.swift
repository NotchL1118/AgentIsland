import Foundation
import IslandCore

/// Codex lifecycle hooks, shared by Codex CLI and Codex Desktop (both read
/// `$CODEX_HOME/hooks.json`). Codex always receives a JSON object on stdout;
/// `{}` hands control back to Codex's own approval UI and never approves.
public struct CodexAdapter: AgentAdapter {
    public static let desktopBundleID = "com.openai.codex"
    static let mapping: [String: EventKind] = [
        "SessionStart": .sessionStarted, "UserPromptSubmit": .turnStarted, "PreToolUse": .toolStarted,
        "PostToolUse": .toolFinished, "PermissionRequest": .approvalRequested, "Stop": .turnCompleted,
        "Interrupt": .turnFailed, "SessionEnd": .sessionEnded,
    ]

    public init() {}

    public var descriptor: AgentDescriptor {
        AgentDescriptor(
            provider: .codex,
            summary: "Codex Desktop 与 CLI：状态与审批。安装后需在 Codex 的 hooks 设置中检查并信任。",
            capabilities: AgentCapabilities(approval: true),
            injection: .hookConfig(HookConfigTarget(
                defaultPath: { env, home in
                    let directory = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        ?? home.appendingPathComponent(".codex")
                    return directory.appendingPathComponent("hooks.json")
                },
                trustStore: .codexConfigToml, fallbackPrintsEmptyObject: true)),
            // Subagent lifecycle hooks are not registered: they carry the parent's
            // session id, so their Stop would be misreported as the parent's completion.
            hooks: [
                HookSpec("SessionStart"), HookSpec("UserPromptSubmit"), HookSpec("PreToolUse"), HookSpec("PostToolUse"),
                HookSpec("PermissionRequest", blocking: true, timeout: 125),
                HookSpec("Stop"), HookSpec("Interrupt"), HookSpec("SessionEnd"),
            ],
            afterInstall: "请在 Codex 中打开 hooks 设置（CLI 为 /hooks），检查并信任新增的 Agent Island hooks。安装不会绕过信任。")
    }

    public var silentOutput: String? { "{}" }

    public func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String? {
        jsonLine(run(payload, context: context)) ?? "{}"
    }

    func run(_ payload: [String: Any], context: HookContext) -> [String: Any] {
        guard let event = event(for: payload, context: context) else { return [:] }
        guard event.kind == .approvalRequested, let request = event.request else {
            _ = context.send(event, 0.7)
            return [:]
        }
        let wait = Double(context.environment["AGENT_ISLAND_APPROVAL_TIMEOUT"] ?? "").map { min(120, max(1, $0)) } ?? 120
        let reply = context.send(event, wait)
        if let output = Self.permissionOutput(reply: reply, requestID: request.id) { return output }
        if reply?.status != "duplicate" {
            var cancel = event
            cancel.id = UUID().uuidString; cancel.timestamp = context.now(); cancel.kind = .requestCancelled
            cancel.message = "审批已交回 Codex，请在那里处理。"
            _ = context.send(cancel, 0.35)
        }
        return [:]
    }

    func event(for payload: [String: Any], context: HookContext) -> AgentEvent? {
        guard let name = payload["hook_event_name"] as? String, let kind = Self.mapping[name] else { return nil }
        let session = string(payload["session_id"], limit: 512)
        guard !session.isEmpty, payload["session_id"] is String else { return nil }
        let cwd = (payload["cwd"] as? String).map { String($0.prefix(4096)) }
        let tool = nonEmpty((payload["tool_name"] as? String).map { String($0.prefix(256)) } ?? "") ?? "工具"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        var event = AgentEvent(provider: .codex, sessionID: session,
                               turnID: (payload["turn_id"] as? String).flatMap { nonEmpty(String($0.prefix(512))) },
                               timestamp: context.now(), kind: kind, cwd: cwd.flatMap(nonEmpty), terminal: context.terminal())
        switch name {
        case "SessionStart":
            if payload["source"] as? String == "compact" {
                event.kind = .heartbeat; event.message = "上下文整理完成，继续当前任务"
            } else {
                event.title = cwd.flatMap { nonEmpty(URL(fileURLWithPath: $0).lastPathComponent) } ?? "Codex"
                event.message = "Codex 会话已连接"
            }
        case "UserPromptSubmit":
            let prompt = payload["prompt"] as? String ?? ""
            event.title = String((prompt.split(separator: "\n").first.map(String.init) ?? "Codex 任务").prefix(120))
            event.message = "正在处理请求"
        case "PreToolUse": event.message = nonEmpty(string(input["description"] as? String, limit: 500)) ?? "执行 \(tool)"
        case "PostToolUse": event.message = "\(tool) 已返回结果"
        case "PermissionRequest":
            let detail = nonEmpty(string(input["command"] as? String, limit: 4000)) ?? string(input, limit: 4000)
            let title = nonEmpty(string(input["description"] as? String, limit: 500)) ?? "允许 Codex 执行 \(tool)？"
            event.request = AgentRequest(id: UUID().uuidString, kind: .approval, title: title, detail: detail)
            event.message = "等待你批准工具请求"
        case "Stop": event.message = nonEmpty(string(payload["last_assistant_message"] as? String, limit: 4000)) ?? "本轮任务已完成"
        case "Interrupt": event.message = "本轮任务已被用户中断"
        default: event.message = "Codex 会话已结束"
        }
        return event
    }

    static func permissionOutput(reply: BridgeReply?, requestID: String) -> [String: Any]? {
        guard let reply, reply.status == "resolved", reply.requestID == requestID,
              let decision = reply.decision, decision == "allow" || decision == "deny" else { return nil }
        var output: [String: Any] = ["behavior": decision]
        if decision == "deny" { output["message"] = nonEmpty(String((reply.message ?? "").prefix(1000))) ?? "用户在 Agent Island 中拒绝了本次请求。" }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": output]]
    }
}
