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

    private func publish(_ event: AgentEvent, to path: String) throws {
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        try client.send(event)
        XCTAssertEqual(try client.readReply(), BridgeReply(status: "accepted"))
    }

    @MainActor
    func testClearingCompletedRecordsPreservesEveryOtherStatusAndUpdatesSelection() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let fixtures: [(String, EventKind)] = [
            ("done-a", .turnCompleted), ("done-b", .turnCompleted),
            ("working", .turnStarted), ("failed", .turnFailed),
            ("disconnected", .sessionEnded), ("idle", .sessionStarted),
            ("approval", .approvalRequested), ("question", .questionRequested)
        ]
        for (id, kind) in fixtures {
            try publish(AgentEvent(provider: .codex, sessionID: id, kind: kind), to: path)
        }
        try await waitUntil { model.sessions.count == fixtures.count }
        let remaining = model.sessions.filter { $0.status != .completed }
        XCTAssertEqual(Set(remaining.map(\.status)), Set(SessionStatus.allCases.filter { $0 != .completed }))
        XCTAssertEqual(model.completedCount, 2)
        model.selectedID = "codex:done-a"

        model.clearCompletedSessions()

        XCTAssertEqual(model.sessions, remaining)
        XCTAssertEqual(model.selectedID, remaining.first?.id)
        XCTAssertEqual(model.completedCount, 0)
        XCTAssertEqual(model.pendingCount, 2)
        XCTAssertEqual(model.runningCount, 1)
        XCTAssertTrue(model.expanded)
    }

    @MainActor
    func testClearingCompletedRecordsPreservesActiveSelectionAndNoOp() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        try publish(AgentEvent(provider: .claude, sessionID: "active", kind: .turnStarted), to: path)
        try publish(AgentEvent(provider: .claude, sessionID: "done", kind: .turnCompleted), to: path)
        try await waitUntil { model.sessions.count == 2 }
        model.selectedID = "claude:active"
        model.expanded = false
        let active = try XCTUnwrap(model.store.sessions["claude:active"])

        model.clearCompletedSessions()

        XCTAssertEqual(model.sessions, [active])
        XCTAssertEqual(model.selectedID, active.id)
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(model.completedCount, 0)

        model.clearCompletedSessions()
        XCTAssertEqual(model.sessions, [active])
        XCTAssertEqual(model.selectedID, active.id)
        model.selectedID = nil
        model.clearCompletedSessions()
        XCTAssertNil(model.selectedID)
    }

    @MainActor
    func testClearingOnlyCompletedRecordsLeavesAnEmptyPanel() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        for provider in [AgentProvider.claude, .codex] {
            try publish(AgentEvent(provider: provider, sessionID: "done", kind: .turnCompleted), to: path)
        }
        try await waitUntil { model.completedCount == 2 }
        model.selectedID = "codex:done"

        model.clearCompletedSessions()
        model.clearCompletedSessions()

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.completedCount, 0)
        XCTAssertEqual(model.summary, "等待 Agent")
    }

    @MainActor
    func testRemovingSelectedRecordUpdatesSelectionAndCounts() throws {
        let model = AppModel(demo: true)
        let selectedID = try XCTUnwrap(model.selectedID)
        let remaining = model.sessions.filter { $0.id != selectedID }
        XCTAssertEqual(model.pendingCount, 2)

        model.removeSession(selectedID)

        XCTAssertNil(model.store.sessions[selectedID])
        XCTAssertEqual(model.sessions, remaining)
        XCTAssertEqual(model.selectedID, remaining.first?.id)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.runningCount, 1)
        XCTAssertTrue(model.expanded)

        for session in remaining { model.removeSession(session.id) }
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.runningCount, 0)
        XCTAssertEqual(model.summary, "等待 Agent")
    }

    @MainActor
    func testRemovingAnotherOrMissingRecordPreservesSelection() throws {
        let model = AppModel(demo: true)
        let selectedID = try XCTUnwrap(model.selectedID)
        let other = try XCTUnwrap(model.sessions.first { $0.id != selectedID })
        let selected = model.store.sessions[selectedID]

        model.removeSession(other.id)
        model.removeSession("missing")

        XCTAssertEqual(model.selectedID, selectedID)
        XCTAssertEqual(model.store.sessions[selectedID], selected)
        XCTAssertEqual(model.sessions.count, 2)
    }

    @MainActor
    func testApprovalAndQuestionAreAcknowledgedWithoutUIOrDecision() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        XCTAssertTrue(model.serverReady)
        for kind in [RequestKind.approval, .question] {
            let client = try TestSocketClient(path: path)
            defer { client.close() }
            let request = AgentRequest(id: kind.rawValue, kind: kind, title: "Continue in the host?")
            try client.send(AgentEvent(provider: .claude, sessionID: kind.rawValue, turnID: "turn",
                                       kind: kind == .approval ? .approvalRequested : .questionRequested, request: request))
            // Intentionally occupy the main actor: receipt must be acknowledged
            // by the socket queue even while UI processing is unavailable.
            let reply = try client.readReply()
            XCTAssertEqual(reply, BridgeReply(status: "accepted"))
            try await waitUntil { model.store.sessions["claude:\(kind.rawValue)"] != nil }
            let session = try XCTUnwrap(model.store.sessions["claude:\(kind.rawValue)"])
            XCTAssertEqual(session.status, kind == .approval ? .needsApproval : .needsInput)
            XCTAssertEqual(session.pendingRequests, [request])
        }
        XCTAssertEqual(model.pendingCount, 2)
    }

    @MainActor
    func testDuplicateAndStaleRequestsReceiveNeutralAcknowledgements() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let now = Date().timeIntervalSince1970
        let request = AgentRequest(id: "same-request", kind: .approval, title: "Run?")
        let event = AgentEvent(provider: .codex, sessionID: "same-session", turnID: "turn",
                               timestamp: now - 2, kind: .approvalRequested, request: request)
        for _ in 0..<2 {
            let client = try TestSocketClient(path: path)
            defer { client.close() }
            try client.send(event)
            XCTAssertEqual(try client.readReply(), BridgeReply(status: "accepted"))
        }
        try await waitUntil { model.pendingCount == 1 }
        let resumed = try TestSocketClient(path: path)
        defer { resumed.close() }
        try resumed.send(AgentEvent(provider: .codex, sessionID: "same-session", turnID: "turn",
                                    timestamp: now, kind: .toolFinished))
        XCTAssertEqual(try resumed.readReply().status, "accepted")
        try await waitUntil { model.runningCount == 1 }
        let stale = try TestSocketClient(path: path)
        defer { stale.close() }
        var replay = event
        replay.id = UUID().uuidString
        try stale.send(replay)
        XCTAssertEqual(try stale.readReply(), BridgeReply(status: "accepted"))
        // Drain the queued UI update before checking it did not restore the wait.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.store.sessions["codex:same-session"]?.status, .working)
    }

    @MainActor
    func testObserverDisconnectDoesNotEraseHostRequest() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let client = try TestSocketClient(path: path)
        let request = AgentRequest(id: "closed-request", kind: .approval, title: "Run?")
        try client.send(AgentEvent(provider: .pi, sessionID: "closed", kind: .approvalRequested, request: request))
        XCTAssertEqual(try client.readReply().status, "accepted")
        client.close()
        try await waitUntil { model.pendingCount == 1 }
        // Exceeds the old connection-expiry polling interval.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(model.store.sessions["pi:closed"]?.pendingRequests, [request])
        XCTAssertEqual(model.store.sessions["pi:closed"]?.status, .needsApproval)
        XCTAssertEqual(model.pendingCount, 1)
    }

    @MainActor
    func testLegacyCancellationOnlyUpdatesObservation() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let observed = try TestSocketClient(path: path)
        let cancel = try TestSocketClient(path: path)
        defer { observed.close(); cancel.close() }
        let request = AgentRequest(id: "cancel-me", kind: .question, title: "Continue?")
        try observed.send(AgentEvent(provider: .claude, sessionID: "cancelled", kind: .questionRequested, request: request))
        XCTAssertEqual(try observed.readReply(), BridgeReply(status: "accepted"))
        try await waitUntil { model.pendingCount == 1 }
        let cancellation: [String: Any] = ["version": 1, "id": UUID().uuidString, "provider": "claude", "sessionID": "cancelled", "timestamp": Date().timeIntervalSince1970, "kind": "requestCancelled", "request": ["id": request.id]]
        var packet = try JSONSerialization.data(withJSONObject: cancellation)
        packet.append(0x0a)
        try cancel.send(packet)
        XCTAssertEqual(try cancel.readReply(), BridgeReply(status: "accepted"))
        try await waitUntil { model.store.sessions["claude:cancelled"]?.pendingRequests.isEmpty == true }
        XCTAssertEqual(model.store.sessions["claude:cancelled"]?.status, .needsInput)
        XCTAssertEqual(model.pendingCount, 1, "The agent's original question still needs an answer")
    }

    @MainActor
    func testHostOnlyQuestionCountsAsAttentionAndResumesWithProgress() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let question = try TestSocketClient(path: path)
        defer { question.close() }
        try question.send(AgentEvent(provider: .pi, sessionID: "host-question", kind: .questionRequested, message: "请在 Pi 终端回答"))
        XCTAssertEqual(try question.readReply(), BridgeReply(status: "accepted"))
        try await waitUntil { model.pendingCount == 1 }
        XCTAssertEqual(model.store.sessions["pi:host-question"]?.status, .needsInput)
        XCTAssertTrue(model.store.sessions["pi:host-question"]?.pendingRequests.isEmpty == true)
        let resumed = try TestSocketClient(path: path)
        defer { resumed.close() }
        try resumed.send(AgentEvent(provider: .pi, sessionID: "host-question", kind: .toolStarted))
        XCTAssertEqual(try resumed.readReply().status, "accepted")
        try await waitUntil { model.runningCount == 1 }
        XCTAssertEqual(model.pendingCount, 0)
    }

    @MainActor
    func testShutdownHasNoWaitingClientOrDecisionToSend() async throws {
        let path = testSocketPath()
        let model = makeModel(path: path)
        defer { model.shutdown() }
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        let request = AgentRequest(id: "shutdown-request", kind: .approval, title: "Run?")
        try client.send(AgentEvent(provider: .pi, sessionID: "shutdown", kind: .approvalRequested, request: request))
        XCTAssertEqual(try client.readReply(), BridgeReply(status: "accepted"))
        try await waitUntil { model.pendingCount == 1 }
        model.shutdown()
        XCTAssertEqual(model.store.sessions["pi:shutdown"]?.pendingRequests, [request])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
