import XCTest
import Foundation
import IslandCore
@testable import AgentIsland

final class AppModelTests: XCTestCase {
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("State did not update before timeout"); throw SocketTestError.conditionTimedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func makeModel(path: String) -> AppModel {
        let model = AppModel(demo: false, socketPath: path)
        model.autoExpand = false
        model.notificationsEnabled = false
        return model
    }

    @MainActor
    func testApprovalIsHeldUntilUserRespondsAndThenResolved() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        XCTAssertTrue(model.serverReady)
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        let request = AgentRequest(id: "approve-me", kind: .approval, title: "Run npm test?", detail: "npm test")
        try client.send(AgentEvent(provider: .claude, sessionID: "session", turnID: "turn", kind: .approvalRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        let session = try XCTUnwrap(model.store.sessions["claude:session"])
        XCTAssertEqual(session.status, .needsApproval)
        model.respond(session: session, request: request, decision: "allow")
        let reply = try await Task.detached { try client.readReply() }.value
        XCTAssertEqual(reply, BridgeReply(status: "resolved", requestID: "approve-me", decision: "allow"))
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.store.sessions[session.id]?.status, .working)
    }

    @MainActor
    func testQuestionRejectsEmptyAnswerAndSendsMatchingText() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        let request = AgentRequest(id: "question-7", kind: .question, title: "Which database?")
        try client.send(AgentEvent(provider: .claude, sessionID: "question-session", kind: .questionRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        let session = try XCTUnwrap(model.store.sessions["claude:question-session"])
        model.respond(session: session, request: request, decision: "answer", answer: " \n ")
        XCTAssertEqual(model.pendingCount, 1)
        model.respond(session: session, request: request, decision: "answer", answer: "SQLite")
        let reply = try await Task.detached { try client.readReply() }.value
        XCTAssertEqual(reply.status, "resolved")
        XCTAssertEqual(reply.requestID, request.id)
        XCTAssertEqual(reply.decision, "answer")
        XCTAssertEqual(reply.answer, "SQLite")
    }

    @MainActor
    func testDuplicateRequestDoesNotReplaceOriginalConnection() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let first = try TestSocketClient(path: path)
        let duplicate = try TestSocketClient(path: path)
        defer { first.close(); duplicate.close() }
        let request = AgentRequest(id: "same-request", kind: .approval, title: "Run?")
        try first.send(AgentEvent(provider: .codex, sessionID: "same-session", kind: .approvalRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        try duplicate.send(AgentEvent(provider: .codex, sessionID: "same-session", kind: .approvalRequested, request: request))
        let duplicateReply = try await Task.detached { try duplicate.readReply() }.value
        XCTAssertEqual(duplicateReply.status, "duplicate")
        XCTAssertEqual(model.pendingCount, 1)
        let session = try XCTUnwrap(model.store.sessions["codex:same-session"])
        model.respond(session: session, request: request, decision: "deny")
        let originalReply = try await Task.detached { try first.readReply() }.value
        XCTAssertEqual(originalReply.decision, "deny")
        XCTAssertEqual(originalReply.requestID, "same-request")
    }

    @MainActor
    func testDisconnectedRequesterIsRemovedWithoutApproving() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let client = try TestSocketClient(path: path)
        let request = AgentRequest(id: "closed-request", kind: .approval, title: "Run?")
        try client.send(AgentEvent(provider: .pi, sessionID: "closed", kind: .approvalRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        client.close()
        try await waitUntil(timeout: 4) { model.store.sessions["pi:closed"]?.pendingRequests.isEmpty == true }
        XCTAssertEqual(model.store.sessions["pi:closed"]?.status, .needsApproval)
        XCTAssertEqual(model.pendingCount, 1, "Native approval still needs user attention")
        XCTAssertTrue(model.statusMessage.contains("原 Agent"))
    }

    @MainActor
    func testMinimalCancellationRemovesPendingAndReleasesSocket() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let waiting = try TestSocketClient(path: path)
        let cancel = try TestSocketClient(path: path)
        defer { waiting.close(); cancel.close() }
        let request = AgentRequest(id: "cancel-me", kind: .question, title: "Continue?")
        try waiting.send(AgentEvent(provider: .claude, sessionID: "cancelled", kind: .questionRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        let cancellation: [String: Any] = ["version": 1, "id": UUID().uuidString, "provider": "claude", "sessionID": "cancelled", "timestamp": Date().timeIntervalSince1970, "kind": "requestCancelled", "request": ["id": request.id]]
        var packet = try JSONSerialization.data(withJSONObject: cancellation)
        packet.append(0x0a)
        try cancel.send(packet)
        let acknowledgement = try await Task.detached { try cancel.readReply() }.value
        let released = try await Task.detached { try waiting.readReply() }.value
        XCTAssertEqual(acknowledgement.status, "accepted")
        XCTAssertEqual(released.status, "unavailable")
        XCTAssertEqual(released.requestID, request.id)
        XCTAssertNil(released.decision)
        XCTAssertTrue(model.store.sessions["claude:cancelled"]?.pendingRequests.isEmpty == true)
        XCTAssertEqual(model.store.sessions["claude:cancelled"]?.status, .needsInput)
        XCTAssertEqual(model.pendingCount, 1, "The agent's original question still needs an answer")
    }

    @MainActor
    func testHostOnlyQuestionCountsAsAttentionWithoutReplyButtons() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let question = try TestSocketClient(path: path)
        defer { question.close() }
        try question.send(AgentEvent(provider: .pi, sessionID: "host-question", kind: .questionRequested, message: "请在 Pi 终端回答"))
        let ack = try await Task.detached { try question.readReply() }.value
        XCTAssertEqual(ack.status, "accepted")
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.store.sessions["pi:host-question"]?.status, .needsInput)
        XCTAssertTrue(model.store.sessions["pi:host-question"]?.pendingRequests.isEmpty == true)
        let resumed = try TestSocketClient(path: path)
        defer { resumed.close() }
        try resumed.send(AgentEvent(provider: .pi, sessionID: "host-question", kind: .toolStarted))
        _ = try await Task.detached { try resumed.readReply() }.value
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.runningCount, 1)
    }

    @MainActor
    func testShutdownReturnsUnavailableToWaitingClient() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        let request = AgentRequest(id: "shutdown-request", kind: .approval, title: "Run?")
        try client.send(AgentEvent(provider: .pi, sessionID: "shutdown", kind: .approvalRequested, request: request))
        try await waitUntil { model.pendingCount == 1 }
        model.shutdown()
        let reply = try await Task.detached { try client.readReply() }.value
        XCTAssertEqual(reply.status, "unavailable")
        XCTAssertEqual(reply.requestID, request.id)
        XCTAssertNil(reply.decision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
