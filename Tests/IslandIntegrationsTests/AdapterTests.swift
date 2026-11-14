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

    func testNormalToolNeverGrantsPermission() {
        XCTAssertNil(adapter.decide(payload(), waiting: false, context: context()))
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

    func testExplicitAllowOnly() throws {
        reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: "allow") }
        let output = try XCTUnwrap(adapter.decide(payload("PermissionRequest"), waiting: true, context: context()))
        XCTAssertEqual(sent.first?.1, 120)
        let decision = (output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
    }

    func testDenyAddsNoPersistentPermission() throws {
        let output = try XCTUnwrap(ClaudeAdapter.permissionOutput(requestID: "r", reply: BridgeReply(status: "resolved", requestID: "r", decision: "deny")))
        let decision = (output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertNil(decision?["updatedPermissions"])
    }

    func testUnmatchedOrUnresolvedRepliesNeverApprove() {
        for candidate: BridgeReply? in [nil, BridgeReply(status: "resolved", decision: "allow"),
                                        BridgeReply(status: "resolved", requestID: "wrong", decision: "allow"),
                                        BridgeReply(status: "accepted", requestID: "r", decision: "allow"),
                                        BridgeReply(status: "resolved", requestID: "r", decision: "always")] {
            XCTAssertNil(ClaudeAdapter.permissionOutput(requestID: "r", reply: candidate))
        }
    }

    func testUnavailableCancelsCardButDuplicateDoesNot() {
        reply = { _ in nil }
        XCTAssertNil(adapter.decide(payload("PermissionRequest"), waiting: true, context: context()))
        XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested, .requestCancelled])
        sent = []
        reply = { BridgeReply(status: "duplicate", requestID: $0.request?.id) }
        XCTAssertNil(adapter.decide(payload("PermissionRequest"), waiting: true, context: context()))
        XCTAssertEqual(sent.map(\.0.kind), [.approvalRequested])
    }

    func questionPayload(_ questions: [[String: Any]]) -> [String: Any] {
        payload("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "call-1",
                               "tool_input": ["questions": questions, "metadata": ["keep": true]]])
    }

    func testQuestionAnswersPreserveEntireToolInput() throws {
        reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: "answer", answer: " Mock ") }
        let output = try XCTUnwrap(adapter.decide(questionPayload([["question": "Which DB?", "options": [["label": "Mock"]]]]), waiting: true, context: context()))
        let specific = output["hookSpecificOutput"] as? [String: Any]
        let updated = specific?["updatedInput"] as? [String: Any]
        XCTAssertEqual(specific?["permissionDecision"] as? String, "allow")
        XCTAssertEqual((updated?["answers"] as? [String: String])?["Which DB?"], "Mock")
        XCTAssertEqual((updated?["metadata"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(sent.first?.0.request?.options?.map(\.label), ["Mock"])
    }

    func testAsyncRegistrationNeverAnswersQuestions() {
        XCTAssertNil(adapter.decide(questionPayload([["question": "Which DB?"]]), waiting: false, context: context()))
        XCTAssertTrue(sent.isEmpty)
    }

    func testPartialQuestionFailureDoesNotRewriteInput() {
        var calls = 0
        reply = { event in
            calls += 1
            return calls == 1 ? BridgeReply(status: "resolved", requestID: event.request?.id, decision: "answer", answer: "A") : nil
        }
        XCTAssertNil(adapter.decide(questionPayload([["question": "One?"], ["question": "Two?"]]), waiting: true, context: context()))
        XCTAssertEqual(sent.last?.0.kind, .requestCancelled)
    }

    func testMultiSelectUsesOriginalUI() {
        XCTAssertNil(adapter.decide(questionPayload([["question": "Pick", "multiSelect": true]]), waiting: true, context: context()))
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent[0].0.request)
    }

    func testInteractiveToolsDoNotReceiveBareAllow() {
        reply = { _ in BridgeReply(status: "resolved", requestID: "x", decision: "allow") }
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            XCTAssertNil(adapter.decide(payload("PermissionRequest", ["tool_name": tool]), waiting: true, context: context()))
        }
        XCTAssertTrue(sent.allSatisfy { $0.0.kind == .questionRequested && $0.0.request == nil })
    }

    func testMissingIdentityIsIgnored() {
        XCTAssertNil(adapter.decide(["hook_event_name": "Stop"], waiting: false, context: context()))
        XCTAssertTrue(sent.isEmpty)
    }
}

final class CodexAdapterTests: XCTestCase {
    var sent: [AgentEvent] = []
    var reply: (AgentEvent) -> BridgeReply? = { _ in BridgeReply(status: "accepted") }
    func context(_ env: [String: String] = [:]) -> HookContext {
        HookContext(environment: env, send: { [unowned self] event, _ in sent.append(event); return reply(event) }, terminal: { nil }, now: { 1 })
    }
    let adapter = CodexAdapter()

    func testLifecycleMappingAndCompaction() {
        for (hook, kind) in CodexAdapter.mapping where hook != "PermissionRequest" {
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

    func testAllowUsesDocumentedShapeAndDenyStaysDeny() throws {
        reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: "allow") }
        let allow = adapter.run(["hook_event_name": "PermissionRequest", "session_id": "s"], context: context())
        XCTAssertEqual(((allow["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        reply = { BridgeReply(status: "resolved", requestID: $0.request?.id, decision: "deny") }
        let deny = adapter.run(["hook_event_name": "PermissionRequest", "session_id": "s"], context: context())
        XCTAssertEqual(((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    func testTimeoutReturnsControlToCodexAndCancelsCard() {
        reply = { _ in nil }
        XCTAssertEqual(adapter.handle(["hook_event_name": "PermissionRequest", "session_id": "s"], waiting: true, context: context()), "{}")
        XCTAssertEqual(sent.map(\.kind), [.approvalRequested, .requestCancelled])
        XCTAssertEqual(sent[0].request?.id, sent[1].request?.id)
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
    func testUnknownProvidersDecode() throws {
        let json = #"{"version":1,"id":"e","provider":"newagent","sessionID":"s","timestamp":1,"kind":"turnStarted"}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.provider.rawValue, "newagent")
        XCTAssertEqual(event.provider.displayName, "Newagent")
    }
}
