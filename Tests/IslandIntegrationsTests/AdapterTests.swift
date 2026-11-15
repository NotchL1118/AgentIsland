import XCTest
import IslandCore
@testable import IslandIntegrations

/// Synthetic hook payloads only; no sockets, models or user configuration.
final class ClaudeAdapterTests: XCTestCase {
    var sent: [(AgentEvent, TimeInterval)] = []
    var reply: (AgentEvent) -> BridgeReply? = { _ in BridgeReply(status: "accepted") }

    func context() -> HookContext {
        HookContext(environment: [:], send: { [unowned self] event, timeout in
            sent.append((event, timeout)); return reply(event)
        }, terminal: { nil }, now: { 1 })
    }

    func payload(_ hook: String = "PreToolUse", _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "session-1", "cwd": "/example/project", "hook_event_name": hook,
         "tool_name": "Bash", "tool_input": ["command": "npm test"]].merging(extra) { $1 }
    }

    let adapter = ClaudeAdapter()

    func testNormalToolOnlyPublishesStatus() {
        XCTAssertNil(adapter.handle(payload(), waiting: false, context: context()))
        XCTAssertEqual(sent.first?.0.kind, .toolStarted)
        XCTAssertNil(sent.first?.0.request)
    }

    func testLifecycleAndSubagentIdentity() {
        let first = adapter.event(for: payload("UserPromptSubmit", ["prompt": "Fix auth\nMore", "prompt_id": "turn-7"]), context: context())
        XCTAssertEqual(first?.title, "Fix auth")
        XCTAssertEqual(first?.turnID, "turn-7")
        XCTAssertEqual(adapter.event(for: payload("Stop"), context: context())?.kind, .turnCompleted)
        XCTAssertEqual(adapter.event(for: payload("PreToolUse", ["agent_id": "worker-2"]), context: context())?.sessionID, "session-1/worker-2")
    }

    func testToolFailureIsNotTurnFailure() {
        XCTAssertEqual(adapter.event(for: payload("PostToolUseFailure"), context: context())?.kind, .toolFinished)
        XCTAssertEqual(adapter.event(for: payload("StopFailure"), context: context())?.kind, .turnFailed)
    }

    func testLegacyWaitAndAppRepliesCannotApproveOrDeny() {
        for waiting in [false, true] {
            for decision in ["allow", "deny", "answer"] {
                sent = []
                reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: decision, answer: "A") }
                XCTAssertNil(adapter.handle(payload("PermissionRequest"), waiting: waiting, context: context()))
                XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested])
                XCTAssertEqual(sent.first?.0.request?.detail, "npm test")
                XCTAssertEqual(sent.first?.1, 0.05, "Permission observations use the same short send deadline as status")
            }
        }
    }

    func testUnavailableObserverLeavesNativeApprovalUntouched() {
        reply = { _ in nil }
        XCTAssertNil(adapter.handle(payload("PermissionRequest"), waiting: true, context: context()))
        XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested], "No cancellation or replacement approval is injected")
    }

    func questionPayload(_ questions: [[String: Any]]) -> [String: Any] {
        payload("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "call-1",
                               "tool_input": ["questions": questions, "metadata": ["keep": true]]])
    }

    func testQuestionsRemainReadOnlyIncludingMultiSelectAndLegacyWait() {
        let input = questionPayload([
            ["question": "Which DB?", "options": [["label": "Mock"]]],
            ["question": "Pick", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]]
        ])
        for waiting in [false, true] {
            sent = []
            reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: "answer", answer: "Mock") }
            XCTAssertNil(adapter.handle(input, waiting: waiting, context: context()), "Never return updatedInput or permissionDecision")
            XCTAssertEqual(sent.map(\.0.kind), [.questionRequested, .questionRequested])
            XCTAssertEqual(sent.map { $0.0.request?.id }, ["call-1:question:0", "call-1:question:1"])
            XCTAssertEqual(sent.first?.0.request?.title, "Which DB?")
            XCTAssertEqual(sent.first?.0.request?.options?.map(\.label), ["Mock"])
            XCTAssertEqual(sent.last?.0.request?.options?.map(\.label), ["A", "B"])
            XCTAssertTrue(sent.allSatisfy { $0.1 == 0.05 })
        }
    }

    func testInteractivePermissionNotificationsNeverAnswer() {
        reply = { _ in BridgeReply(status: "resolved", requestID: "x", decision: "allow") }
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            XCTAssertNil(adapter.handle(payload("PermissionRequest", ["tool_name": tool]), waiting: true, context: context()))
        }
        XCTAssertTrue(sent.allSatisfy { $0.0.kind == .questionRequested })
    }

    func testMissingIdentityIsIgnored() {
        XCTAssertNil(adapter.handle(["hook_event_name": "Stop"], waiting: false, context: context()))
        XCTAssertTrue(sent.isEmpty)
    }
}

final class CodexAdapterTests: XCTestCase {
    var sent: [(AgentEvent, TimeInterval)] = []
    var reply: (AgentEvent) -> BridgeReply? = { _ in BridgeReply(status: "accepted") }
    func context(_ env: [String: String] = [:]) -> HookContext {
        HookContext(environment: env, send: { [unowned self] event, timeout in
            sent.append((event, timeout)); return reply(event)
        }, terminal: { nil }, now: { 1 })
    }
    let adapter = CodexAdapter()

    func payload(_ hook: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": hook, "session_id": "s",
         "transcript_path": "/nonexistent/example/session.jsonl"].merging(extra) { $1 }
    }

    func testLifecycleMappingAndCompaction() {
        for (hook, kind) in CodexAdapter.mapping {
            XCTAssertEqual(adapter.event(for: payload(hook), context: context())?.kind, kind)
        }
        let compact = adapter.event(for: payload("SessionStart", ["source": "compact"]), context: context())
        XCTAssertEqual(compact?.kind, .heartbeat)
        XCTAssertNil(compact?.title)
        XCTAssertNil(adapter.event(for: payload("SubagentStop"), context: context()))
        var missingIdentity = payload("Stop")
        missingIdentity.removeValue(forKey: "session_id")
        XCTAssertNil(adapter.event(for: missingIdentity, context: context()))
    }

    func testEveryLifecycleHookWithoutTranscriptIsSilentlyIgnored() {
        let invalidPaths: [Any?] = [nil, NSNull(), "", " \n\t ", 42, true,
                                   ["/example/session.jsonl"], ["path": "/example/session.jsonl"]]
        for hook in CodexAdapter.mapping.keys {
            for invalidPath in invalidPaths {
                var input = payload(hook, ["prompt": "推送到远程吧", "last_assistant_message": "推送到远程吧"])
                if let invalidPath { input["transcript_path"] = invalidPath }
                else { input.removeValue(forKey: "transcript_path") }
                XCTAssertNil(adapter.event(for: input, context: context()), hook)
                for waiting in [false, true] {
                    XCTAssertEqual(adapter.handle(input, waiting: waiting, context: context()), "{}", hook)
                    XCTAssertTrue(sent.isEmpty, "\(hook) must not publish a background observation")
                }
            }
        }
    }

    func testSubmittedRecommendationTextWithTranscriptRemainsARealTask() {
        // Metadata distinguishes real submissions; the wording and local file
        // existence must not decide whether a task is observed.
        XCTAssertEqual(adapter.handle(payload("UserPromptSubmit", ["prompt": "推送到远程吧", "turn_id": "turn-7"]),
                                      waiting: false, context: context()), "{}")
        XCTAssertEqual(sent.map(\.0.kind), [.turnStarted])
        XCTAssertEqual(sent.first?.0.title, "推送到远程吧")
        XCTAssertEqual(sent.first?.0.turnID, "turn-7")
    }

    func testRecommendationHooksCannotChangeAnActiveOrCompletedSession() {
        var store = SessionStore()
        let context = HookContext(environment: [:], send: { event, _ in
            store.apply(event)
            return nil
        }, terminal: { nil }, now: { 1 })
        XCTAssertEqual(adapter.handle(payload("UserPromptSubmit", ["prompt": "Actual task"]),
                                      waiting: false, context: context), "{}")
        XCTAssertEqual(store.sessions["codex:s"]?.status, .working)
        let active = store.sessions["codex:s"]
        for hook in ["UserPromptSubmit", "Stop"] {
            var background = payload(hook, ["prompt": "推送到远程吧", "last_assistant_message": "推送到远程吧"])
            background.removeValue(forKey: "transcript_path")
            XCTAssertEqual(adapter.handle(background, waiting: false, context: context), "{}")
            XCTAssertEqual(store.sessions["codex:s"], active)
        }

        XCTAssertEqual(adapter.handle(payload("Stop", ["last_assistant_message": "Actual result"]),
                                      waiting: false, context: context), "{}")
        XCTAssertEqual(store.sessions["codex:s"]?.status, .completed)
        let completed = store.sessions["codex:s"]
        for hook in ["UserPromptSubmit", "Stop"] {
            let background = payload(hook, ["transcript_path": "", "prompt": "推送到远程吧",
                                            "last_assistant_message": "推送到远程吧"])
            XCTAssertEqual(adapter.handle(background, waiting: false, context: context), "{}")
            XCTAssertEqual(store.sessions["codex:s"], completed)
        }
    }

    func testStatusHookAlwaysPrintsEmptyObject() {
        reply = { _ in BridgeReply(status: "resolved", decision: "allow") }
        XCTAssertEqual(adapter.handle(payload("Stop"), waiting: false, context: context()), "{}")
        XCTAssertEqual(sent.map(\.0.kind), [.turnCompleted])
    }

    func testLegacyApprovalSettingsAndAppRepliesCannotDecide() {
        for waiting in [false, true] {
            for decision in ["allow", "deny", "answer"] {
                sent = []
                reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: decision, answer: "A") }
                XCTAssertEqual(adapter.handle(payload("PermissionRequest", ["tool_input": ["command": "npm test"]]), waiting: waiting,
                                              context: context(["AGENT_ISLAND_APPROVAL_TIMEOUT": "120"])), "{}")
                XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested])
                XCTAssertEqual(sent.first?.0.request?.detail, "npm test")
                XCTAssertEqual(sent.first?.1, 0.05)
            }
        }
    }

    func testUnavailableObserverLeavesNativeApprovalUntouched() {
        reply = { _ in nil }
        XCTAssertEqual(adapter.handle(payload("PermissionRequest"), waiting: true, context: context()), "{}")
        XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested])
    }
}

final class TerminalProbeTests: XCTestCase {
    func testNothingIsInvented() {
        XCTAssertNil(TerminalProbe.current(environment: [:], controllingTTY: { nil }))
        XCTAssertNil(TerminalProbe.current(environment: [:], controllingTTY: { "/dev/tty" }))
    }

    func testKnownSources() {
        let target = TerminalProbe.current(environment: ["TERM_PROGRAM": "Apple_Terminal", "TMUX_PANE": "%3"], controllingTTY: { "/dev/ttys004" })
        XCTAssertEqual(target?.appBundleID, "com.apple.Terminal")
        XCTAssertEqual(target?.tty, "/dev/ttys004")
        XCTAssertEqual(target?.tmuxPane, "%3")
        // Codex Desktop runs hooks from its own process; it is identified by bundle id.
        XCTAssertEqual(TerminalProbe.current(environment: ["__CFBundleIdentifier": CodexAdapter.desktopBundleID, "TERM_PROGRAM": "ghostty"],
                                             controllingTTY: { nil })?.appBundleID, CodexAdapter.desktopBundleID)
    }
}

final class ProviderTests: XCTestCase {
    func testEveryProviderIsObservationOnly() {
        for adapter in AdapterRegistry.all {
            XCTAssertTrue(adapter.descriptor.capabilities.status)
            XCTAssertFalse(adapter.descriptor.capabilities.approval)
            XCTAssertFalse(adapter.descriptor.capabilities.question)
        }
    }

    func testUnknownProvidersDecode() throws {
        let json = #"{"version":1,"id":"e","provider":"newagent","sessionID":"s","timestamp":1,"kind":"turnStarted"}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.provider.rawValue, "newagent")
        XCTAssertEqual(event.provider.displayName, "Newagent")
    }
}
