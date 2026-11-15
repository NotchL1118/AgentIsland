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

    func testLifecycleMappingAndCompaction() {
        for (hook, kind) in CodexAdapter.mapping {
            XCTAssertEqual(adapter.event(for: ["hook_event_name": hook, "session_id": "s"], context: context())?.kind, kind)
        }
        let compact = adapter.event(for: ["hook_event_name": "SessionStart", "session_id": "s", "source": "compact"], context: context())
        XCTAssertEqual(compact?.kind, .heartbeat)
        XCTAssertNil(compact?.title)
        XCTAssertNil(adapter.event(for: ["hook_event_name": "SubagentStop", "session_id": "s"], context: context()))
        XCTAssertNil(adapter.event(for: ["hook_event_name": "Stop"], context: context()))
    }

    func testStatusHookAlwaysPrintsEmptyObject() {
        reply = { _ in BridgeReply(status: "resolved", decision: "allow") }
        XCTAssertEqual(adapter.handle(["hook_event_name": "Stop", "session_id": "s"], waiting: false, context: context()), "{}")
    }

    func testLegacyApprovalSettingsAndAppRepliesCannotDecide() {
        for waiting in [false, true] {
            for decision in ["allow", "deny", "answer"] {
                sent = []
                reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: decision, answer: "A") }
                XCTAssertEqual(adapter.handle(["hook_event_name": "PermissionRequest", "session_id": "s",
                                               "tool_input": ["command": "npm test"]], waiting: waiting,
                                              context: context(["AGENT_ISLAND_APPROVAL_TIMEOUT": "120"])), "{}")
                XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested])
                XCTAssertEqual(sent.first?.0.request?.detail, "npm test")
                XCTAssertEqual(sent.first?.1, 0.05)
            }
        }
    }

    func testUnavailableObserverLeavesNativeApprovalUntouched() {
        reply = { _ in nil }
        XCTAssertEqual(adapter.handle(["hook_event_name": "PermissionRequest", "session_id": "s"], waiting: true, context: context()), "{}")
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
