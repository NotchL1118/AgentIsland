import Foundation
import IslandCore

/// Claude Code command hooks. Status hooks are registered `async`, so they never
/// block the agent loop. Only PermissionRequest and AskUserQuestion wait, and
/// they write a decision only after a matching, explicit reply from the app.
public struct ClaudeAdapter: AgentAdapter {
    public static let eventTimeout: TimeInterval = 0.8
    public static let requestTimeout: TimeInterval = 120

    public init() {}

    public var descriptor: AgentDescriptor {
        AgentDescriptor(
            provider: .claude,
            summary: "状态、单次审批、单选或文本问答。安装后重启 Claude Code 生效。",
            capabilities: AgentCapabilities(approval: true, question: true),
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
                HookSpec("PreToolUse", matcher: "AskUserQuestion", blocking: true, timeout: 125),
                HookSpec("PreToolUse"), HookSpec("PostToolUse"), HookSpec("PostToolUseFailure"),
                HookSpec("PermissionRequest", blocking: true, timeout: 125),
                HookSpec("Notification"), HookSpec("Stop"), HookSpec("StopFailure"), HookSpec("SessionEnd"),
            ],
            afterInstall: "重新启动 Claude Code 后生效。")
    }

    public var silentOutput: String? { nil }

    public func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String? {
        decide(payload, waiting: waiting, context: context).flatMap(jsonLine)
    }

    /// `waiting` is true for the blocking registrations (`--wait`).
    public func decide(_ payload: [String: Any], waiting: Bool, context: HookContext) -> [String: Any]? {
        let hook = payload["hook_event_name"] as? String
        let tool = string(payload["tool_name"], limit: 200)
        if hook == "PreToolUse" && tool == "AskUserQuestion" {
            // The async PreToolUse registration also sees this call; only the waiting one answers.
            return waiting ? answerQuestions(payload, context: context) : nil
        }
        guard let event = event(for: payload, context: context) else { return nil }
        guard event.kind == .approvalRequested, let request = event.request else {
            _ = context.send(event, Self.eventTimeout)
            return nil
        }
        let reply = context.send(event, Self.requestTimeout)
        let output = Self.permissionOutput(requestID: request.id, reply: reply)
        if output == nil && reply?.status != "duplicate" {
            _ = context.send(cancellation(payload, request: request, message: "请在 Claude Code 处理原生审批。", context: context), Self.eventTimeout)
        }
        return output
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
                                       title: "允许 \(tool.isEmpty ? "工具操作" : tool)？", detail: Self.toolDetail(payload))
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

    private func cancellation(_ payload: [String: Any], request: AgentRequest, message: String, context: HookContext) -> AgentEvent {
        base(payload, .requestCancelled, context: context, message: message, request: request)!
    }

    static func toolDetail(_ payload: [String: Any]) -> String {
        if let input = payload["tool_input"] as? [String: Any] {
            if let command = nonEmpty(string(input["command"], limit: 16000)) { return command }
            if let path = nonEmpty(string(input["file_path"] ?? input["path"], limit: 4000)) { return path }
            return string(input, limit: 16000)
        }
        return string(payload["tool_input"], limit: 16000)
    }

    static func permissionOutput(requestID: String, reply: BridgeReply?) -> [String: Any]? {
        guard let reply, reply.status == "resolved", reply.requestID == requestID,
              let decision = reply.decision, decision == "allow" || decision == "deny" else { return nil }
        var result: [String: Any] = ["behavior": decision]
        if decision == "deny" { result["message"] = "用户在 Agent Island 拒绝了本次请求。" }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
    }

    func answerQuestions(_ payload: [String: Any], context: HookContext) -> [String: Any]? {
        guard let original = payload["tool_input"] as? [String: Any],
              let questions = original["questions"] as? [Any], !questions.isEmpty, questions.count <= 8 else { return nil }
        // Never partially rewrite the input: one unsupported question returns the whole tool to Claude's UI.
        let supported = questions.allSatisfy { item in
            guard let question = item as? [String: Any], question["question"] is String else { return false }
            return (question["multiSelect"] as? Bool) != true
        }
        guard supported else {
            if let event = base(payload, .questionRequested, context: context, message: "此问题需要在 Claude Code 终端回答（包含多选或不支持的题型）。") {
                _ = context.send(event, Self.eventTimeout)
            }
            return nil
        }
        var answers = original["answers"] as? [String: Any] ?? [:]
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        let callID = nonEmpty(string(payload["tool_use_id"], limit: 500)) ?? UUID().uuidString
        for (index, item) in questions.enumerated() {
            let question = item as! [String: Any]
            let text = question["question"] as! String
            if answers[text] != nil { continue }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let options = (question["options"] as? [Any] ?? []).compactMap { option -> RequestOption? in
                guard let option = option as? [String: Any], let label = nonEmpty(string(option["label"], limit: 200)) else { return nil }
                return RequestOption(id: label, label: label)
            }
            let request = AgentRequest(id: "\(callID):question:\(index)", kind: .question, title: String(text.prefix(2000)),
                                       detail: "第 \(index + 1)/\(questions.count) 个问题", options: options)
            guard let event = base(payload, .questionRequested, context: context, message: String(text.prefix(2000)), request: request) else { return nil }
            let reply = context.send(event, remaining)
            guard let reply, reply.status == "resolved", reply.requestID == request.id, reply.decision == "answer",
                  let answer = reply.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                if reply?.status != "duplicate" {
                    _ = context.send(cancellation(payload, request: request, message: "请在 Claude Code 终端回答。", context: context), Self.eventTimeout)
                }
                return nil
            }
            answers[text] = String(answer.prefix(16000))
        }
        var updated = original
        updated["answers"] = answers
        return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
    }
}

func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
