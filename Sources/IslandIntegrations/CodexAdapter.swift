import Foundation
import IslandCore

/// Codex lifecycle hooks, shared by Codex CLI and Codex Desktop (both read
/// `$CODEX_HOME/hooks.json`). Codex always receives a JSON object on stdout;
/// `{}` leaves Codex's own approval flow untouched, regardless of app replies.
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
            summary: "Codex Desktop 与 CLI：被动展示状态和审批提醒。安装后需在 Codex 的 hooks 设置中检查并信任。",
            capabilities: AgentCapabilities(),
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
                HookSpec("PermissionRequest"),
                HookSpec("Stop"),
                // Codex caps these lifecycle hooks at 3 seconds and runs SessionEnd synchronously.
                HookSpec("Interrupt", timeout: 3),
                HookSpec("SessionEnd", timeout: 3, asynchronous: false),
            ],
            afterInstall: "请在 Codex 中打开 hooks 设置（CLI 为 /hooks），检查并信任新增的 Agent Island hooks。安装不会绕过信任。")
    }

    public var silentOutput: String? { "{}" }

    public func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String? {
        if let event = event(for: payload, context: context) {
            _ = context.send(event, 0.05)
        }
        // Ignore old --wait arguments and any reply from the observer.
        return "{}"
    }

    func event(for payload: [String: Any], context: HookContext) -> AgentEvent? {
        guard let name = payload["hook_event_name"] as? String, let kind = Self.mapping[name] else { return nil }
        // Observe persisted conversations only. Ephemeral work such as suggested
        // replies must not create tasks or overwrite a real turn's state.
        // Check metadata without reading the transcript file.
        guard let transcript = payload["transcript_path"] as? String,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
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
            let title = nonEmpty(string(input["description"] as? String, limit: 500)) ?? "等待在 Codex 审批：\(tool)"
            event.request = AgentRequest(id: UUID().uuidString, kind: .approval, title: title, detail: detail)
            event.message = "等待在 Codex 处理工具审批"
        case "Stop": event.message = nonEmpty(string(payload["last_assistant_message"] as? String, limit: 4000)) ?? "本轮任务已完成"
        case "Interrupt": event.message = "本轮任务已被用户中断"
        default: event.message = "Codex 会话已结束"
        }
        return event
    }

}
