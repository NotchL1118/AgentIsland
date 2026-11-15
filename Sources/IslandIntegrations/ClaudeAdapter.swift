import Foundation
import IslandCore

/// Claude Code command hooks only publish observations. Async registrations and
/// neutral output leave all approvals and questions in Claude Code's own UI.
public struct ClaudeAdapter: AgentAdapter {
    public static let eventTimeout: TimeInterval = 0.05

    public init() {}

    public var descriptor: AgentDescriptor {
        AgentDescriptor(
            provider: .claude,
            summary: "被动展示状态、审批及问答提醒；操作仍在 Claude Code 中完成。安装后重启生效。",
            capabilities: AgentCapabilities(),
            injection: .hookConfig(HookConfigTarget(
                defaultPath: { env, home in
                    let directory = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        ?? home.appendingPathComponent(".claude")
                    return directory.appendingPathComponent("settings.json")
                },
                scanPaths: { _, home in
                    // Read-only leftover scan of ~/.claude* config dirs (custom CLAUDE_CONFIG_DIR setups).
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
                    return names.filter { $0.hasPrefix(".claude") }.flatMap { name -> [URL] in
                        let directory = home.appendingPathComponent(name)
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
                        return ["settings.json", "settings.local.json"].map { directory.appendingPathComponent($0) }
                    }
                })),
            hooks: [
                HookSpec("SessionStart"), HookSpec("UserPromptSubmit"),
                HookSpec("PreToolUse"), HookSpec("PostToolUse"), HookSpec("PostToolUseFailure"),
                HookSpec("PermissionRequest"),
                HookSpec("Notification"), HookSpec("Stop"), HookSpec("StopFailure"), HookSpec("SessionEnd"),
            ],
            afterInstall: "重新启动 Claude Code 后生效。")
    }

    public var silentOutput: String? { nil }

    public func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String? {
        // Legacy --wait invocations follow the same passive path. Replies cannot
        // become decisions or rewritten tool input, even from an older app.
        let hook = payload["hook_event_name"] as? String
        if (hook == "PreToolUse" || hook == "PermissionRequest"),
           payload["tool_name"] as? String == "AskUserQuestion" {
            for event in questionEvents(payload, context: context) {
                _ = context.send(event, Self.eventTimeout)
            }
        } else if let event = event(for: payload, context: context) {
            _ = context.send(event, Self.eventTimeout)
        }
        return nil
    }

    func event(for payload: [String: Any], context: HookContext) -> AgentEvent? {
        let hook = payload["hook_event_name"] as? String ?? ""
        let tool = string(payload["tool_name"], limit: 200)
        let mapping: [String: EventKind] = [
            "SessionStart": .sessionStarted, "UserPromptSubmit": .turnStarted,
            "PreToolUse": .toolStarted, "PostToolUse": .toolFinished, "PostToolUseFailure": .toolFinished,
            "Stop": .turnCompleted, "StopFailure": .turnFailed, "SessionEnd": .sessionEnded,
        ]
        if hook == "PermissionRequest" {
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                return base(payload, .questionRequested, context: context, message: "请在 Claude Code 处理：\(tool)")
            }
            // PermissionRequest may lack tool_use_id; the UUID belongs to this exact invocation.
            let request = AgentRequest(id: UUID().uuidString, kind: .approval,
                                       title: "等待在 Claude Code 审批：\(tool.isEmpty ? "工具操作" : tool)", detail: Self.toolDetail(payload))
            return base(payload, .approvalRequested, context: context, message: request.title, request: request)
        }
        if hook == "Notification" {
            let types = ["permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input"]
            guard let type = payload["notification_type"] as? String, types.contains(type) else { return nil }
            return base(payload, .questionRequested, context: context, message: "请在 Claude Code 处理：" + string(payload["message"], limit: 1800))
        }
        guard let kind = mapping[hook] else { return nil }
        var title: String?
        let message: String
        switch hook {
        case "UserPromptSubmit":
            let prompt = string(payload["prompt"]).trimmingCharacters(in: .whitespacesAndNewlines)
            title = String((prompt.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "").prefix(100))
            if title?.isEmpty ?? true { title = "Claude Code" }
            message = "正在处理任务"
        case "SessionStart": message = "会话已连接"
        case "Stop": message = nonEmpty(string(payload["last_assistant_message"], limit: 4000)) ?? "本轮任务已完成"
        case "StopFailure": message = nonEmpty(string(payload["error_details"] ?? payload["error"])) ?? "本轮任务异常结束"
        case "SessionEnd": message = "会话已结束"
        default:
            let prefix = hook == "PostToolUseFailure" ? "工具失败：" : hook == "PreToolUse" ? "正在执行：" : "已执行："
            message = String((prefix + tool + " " + Self.toolDetail(payload)).prefix(2000))
        }
        return base(payload, kind, context: context, title: title, message: message)
    }

    private func base(_ payload: [String: Any], _ kind: EventKind, context: HookContext, title: String? = nil,
                      message: String, request: AgentRequest? = nil) -> AgentEvent? {
        var session = string(payload["session_id"], limit: 500)
        guard !session.isEmpty else { return nil }
        let agent = string(payload["agent_id"], limit: 300)
        if !agent.isEmpty { session += "/" + agent }
        return AgentEvent(provider: .claude, sessionID: session, turnID: nonEmpty(string(payload["prompt_id"], limit: 500)),
                          timestamp: context.now(), kind: kind, title: title, cwd: nonEmpty(string(payload["cwd"], limit: 4000)),
                          message: message, terminal: context.terminal(), request: request)
    }

    static func toolDetail(_ payload: [String: Any]) -> String {
        if let input = payload["tool_input"] as? [String: Any] {
            if let command = nonEmpty(string(input["command"], limit: 16000)) { return command }
            if let path = nonEmpty(string(input["file_path"] ?? input["path"], limit: 4000)) { return path }
            return string(input, limit: 16000)
        }
        return string(payload["tool_input"], limit: 16000)
    }

    private func questionEvents(_ payload: [String: Any], context: HookContext) -> [AgentEvent] {
        guard let input = payload["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else {
            return [base(payload, .questionRequested, context: context,
                         message: "等待在 Claude Code 回答问题")].compactMap { $0 }
        }
        let callID = nonEmpty(string(payload["tool_use_id"], limit: 500)) ?? UUID().uuidString
        return questions.prefix(8).enumerated().compactMap { index, question in
            let title = nonEmpty(string(question["question"])) ?? "等待在 Claude Code 回答问题"
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> RequestOption? in
                guard let label = nonEmpty(string(option["label"], limit: 200)) else { return nil }
                return RequestOption(id: label, label: label)
            }
            let request = AgentRequest(id: "\(callID):question:\(index)", kind: .question, title: title,
                                       detail: "第 \(index + 1)/\(questions.count) 个问题 · 请在 Claude Code 回答", options: options)
            return base(payload, .questionRequested, context: context, message: title, request: request)
        }
    }

}

func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
