import XCTest
@testable import IslandCore

final class SessionStoreTests: XCTestCase {
    private func event(_ kind: EventKind, at: Double = 1, id: String = UUID().uuidString,
                       provider: AgentProvider = .claude, session: String = "s1", turn: String? = "t1",
                       request: AgentRequest? = nil, message: String? = nil,
                       terminal: TerminalTarget? = nil) -> AgentEvent {
        AgentEvent(id: id, provider: provider, sessionID: session, turnID: turn,
                   timestamp: at, kind: kind, message: message, terminal: terminal, request: request)
    }

    private func approval(_ id: String = "r1") -> AgentRequest {
        AgentRequest(id: id, kind: .approval, title: "Run tests", detail: "npm test")
    }

    private func question(_ id: String = "q1") -> AgentRequest {
        AgentRequest(id: id, kind: .question, title: "Choose fixtures", options: [RequestOption(id: "mock", label: "Use mocks")])
    }

    func testDecodesAdapterEventAndDefaultsProtocolVersion() throws {
        let data = Data(#"{"id":"e1","provider":"pi","sessionID":"/tmp/session.jsonl","timestamp":1720000000.25,"kind":"questionRequested","request":{"id":"q1","kind":"question","title":"Which database?","options":[{"id":"local","label":"Local"}]},"terminal":{"tty":"/dev/ttys003","tmuxPane":"%2"}}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.sessionKey, "pi:/tmp/session.jsonl")
        XCTAssertEqual(decoded.request?.options?.first?.id, "local")
        XCTAssertEqual(decoded.terminal?.tmuxPane, "%2")
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testReplyPreservesExactRequestAndAnswer() throws {
        let reply = BridgeReply(status: "resolved", requestID: "question:3", decision: "answer", answer: "测试数据库 🧪")
        XCTAssertEqual(try JSONDecoder().decode(BridgeReply.self, from: JSONEncoder().encode(reply)), reply)
    }

    func testCancellationWireEventOnlyNeedsRequestID() throws {
        let data = Data(#"{"id":"e2","provider":"codex","sessionID":"s1","timestamp":1720000000,"kind":"requestCancelled","request":{"id":"r1"}}"#.utf8)
        let event = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(event.kind, .requestCancelled)
        XCTAssertEqual(event.request?.id, "r1")
    }

    func testProviderNamespacePreventsSessionCollision() {
        var store = SessionStore()
        store.apply(event(.turnStarted, provider: .claude))
        store.apply(event(.turnStarted, provider: .codex))
        store.apply(event(.approvalRequested, at: 2, provider: .claude, request: approval()))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsApproval)
        XCTAssertEqual(store.sessions["codex:s1"]?.status, .working)
        XCTAssertFalse(store.resolve(sessionID: "codex:s1", requestID: "r1", decision: "allow"))
    }

    func testDuplicateCompletionNotifiesOnlyOnce() {
        var store = SessionStore()
        store.apply(event(.turnStarted))
        let done = event(.turnCompleted, at: 2, id: "done")
        XCTAssertEqual(store.apply(done).completedSessionID, "claude:s1")
        XCTAssertFalse(store.apply(done).changed)
        XCTAssertNil(store.apply(event(.turnCompleted, at: 3)).completedSessionID)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .completed)
    }

    func testLateTurnCannotOverwriteNewTurnEvenWithNewerTimestamp() {
        var store = SessionStore()
        store.apply(event(.turnStarted, at: 1, turn: "old"))
        store.apply(event(.turnStarted, at: 2, turn: "new"))
        XCTAssertFalse(store.apply(event(.turnCompleted, at: 3, turn: "old")).changed)
        XCTAssertFalse(store.apply(event(.turnCompleted, at: 4, turn: "unrecognized")).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.turnID, "new")
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testOlderEventCannotReplaceRecentMessage() {
        var store = SessionStore()
        store.apply(event(.turnStarted, at: 5, message: "New work"))
        XCTAssertFalse(store.apply(event(.toolStarted, at: 3, message: "Old work")).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.message, "New work")
    }

    func testLateToolTelemetryDoesNotReviveCompletedTurn() {
        var store = SessionStore()
        store.apply(event(.turnStarted))
        store.apply(event(.turnCompleted, at: 2, message: "Done"))
        XCTAssertFalse(store.apply(event(.toolFinished, at: 3, message: "Late tool")).changed)
        XCTAssertFalse(store.apply(event(.turnStarted, at: 4)).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.message, "Done")
        store.apply(event(.turnStarted, at: 5, turn: "t2"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
        XCTAssertEqual(store.apply(event(.turnCompleted, at: 6, turn: "t2")).completedSessionID, "claude:s1")
    }

    func testPendingRequestsSurviveToolEventsAndCompletion() {
        var store = SessionStore()
        store.apply(event(.turnStarted))
        store.apply(event(.questionRequested, at: 2, request: question()))
        store.apply(event(.toolStarted, at: 3))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        store.apply(event(.approvalRequested, at: 4, request: approval()))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsApproval)
        XCTAssertNil(store.apply(event(.turnCompleted, at: 5)).completedSessionID)
        XCTAssertEqual(store.sessions["claude:s1"]?.pendingRequests.count, 2)
        XCTAssertTrue(store.resolve(sessionID: "claude:s1", requestID: "r1", decision: "allow"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        XCTAssertTrue(store.resolve(sessionID: "claude:s1", requestID: "q1", decision: "answer", answer: "mock"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .completed)
    }

    func testRequestDeduplicationAndStaleReplayAfterResolution() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, request: approval()))
        store.apply(event(.approvalRequested, at: 2, request: approval()))
        XCTAssertEqual(store.sessions["claude:s1"]?.pendingRequests.count, 1)
        XCTAssertTrue(store.resolve(sessionID: "claude:s1", requestID: "r1", decision: "deny"))
        XCTAssertFalse(store.resolve(sessionID: "claude:s1", requestID: "r1", decision: "allow"))
        XCTAssertFalse(store.apply(event(.approvalRequested, at: 3, request: approval())).changed)
        XCTAssertTrue(store.sessions["claude:s1"]?.pendingRequests.isEmpty == true)
    }

    func testNewTurnClearsOldRequestsWithoutMarkingNewTurnDone() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, request: approval()))
        store.apply(event(.turnStarted, at: 2, turn: "t2"))
        XCTAssertTrue(store.sessions["claude:s1"]?.pendingRequests.isEmpty == true)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
        XCTAssertFalse(store.resolve(sessionID: "claude:s1", requestID: "r1", decision: "allow"))
    }

    func testQuestionRequiresNonemptyAnswerAndCorrectDecision() {
        var store = SessionStore()
        store.apply(event(.questionRequested, request: question()))
        XCTAssertFalse(store.resolve(sessionID: "claude:s1", requestID: "q1", decision: "allow"))
        XCTAssertFalse(store.resolve(sessionID: "claude:s1", requestID: "q1", decision: "answer", answer: " \n "))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        XCTAssertTrue(store.resolve(sessionID: "claude:s1", requestID: "q1", decision: "answer", answer: "Use mock data"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testCancelOnlyRemovesDisconnectedRequestAndNeverApprovesIt() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, at: 1, request: approval("r1")))
        store.apply(event(.approvalRequested, at: 2, request: approval("r2")))
        XCTAssertTrue(store.cancelRequest(sessionID: "claude:s1", requestID: "r1"))
        XCTAssertEqual(store.sessions["claude:s1"]?.pendingRequests.map(\.id), ["r2"])
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsApproval)
        XCTAssertTrue(store.cancelRequest(sessionID: "claude:s1", requestID: "r2"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsApproval)
        XCTAssertFalse(store.cancelRequest(sessionID: "claude:s1", requestID: "r2"))
        store.apply(event(.toolStarted, at: 3))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testSessionEndAndConnectionLossAreNotCompletion() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, request: approval()))
        let result = store.apply(event(.sessionEnded, at: 2))
        XCTAssertNil(result.completedSessionID)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .disconnected)
        XCTAssertTrue(store.sessions["claude:s1"]?.pendingRequests.isEmpty == true)
        store.apply(event(.turnStarted, at: 3, turn: "t2"))
        store.markDisconnected(sessionID: "claude:s1")
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .disconnected)
    }

    func testTerminalIdentityIsMergedWithoutLosingPreciseTarget() {
        var store = SessionStore()
        store.apply(event(.turnStarted, terminal: TerminalTarget(appBundleID: "com.googlecode.iterm2", tty: "/dev/ttys001", paneID: "pane-1")))
        store.apply(event(.toolStarted, at: 2, terminal: TerminalTarget(appBundleID: "com.googlecode.iterm2")))
        XCTAssertEqual(store.sessions["claude:s1"]?.terminal?.tty, "/dev/ttys001")
        XCTAssertEqual(store.sessions["claude:s1"]?.terminal?.paneID, "pane-1")
    }

    func testInvalidProtocolAndMismatchedRequestsDoNotCreateSessions() {
        var store = SessionStore()
        var invalid = event(.turnStarted)
        invalid.version = 2
        XCTAssertFalse(store.apply(invalid).changed)
        invalid.version = 1
        invalid.timestamp = .infinity
        XCTAssertFalse(store.apply(invalid).changed)
        XCTAssertFalse(store.apply(event(.approvalRequested, request: question())).changed)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testObservedPromptWithoutResponseChannelShowsWaitingAndCanResume() {
        var store = SessionStore()
        store.apply(event(.turnStarted, provider: .pi))
        store.apply(event(.questionRequested, at: 2, provider: .pi, message: "Choose an option in Pi"))
        XCTAssertEqual(store.sessions["pi:s1"]?.status, .needsInput)
        XCTAssertTrue(store.sessions["pi:s1"]?.pendingRequests.isEmpty == true)
        store.apply(event(.toolFinished, at: 3, provider: .pi))
        XCTAssertEqual(store.sessions["pi:s1"]?.status, .working)
    }

    func testRequestCancellationEventOnlyRemovesMatchingRequest() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, request: approval("a")))
        store.apply(event(.questionRequested, at: 2, request: question("q")))
        store.apply(event(.requestCancelled, at: 3, request: approval("a")))
        XCTAssertEqual(store.sessions["claude:s1"]?.pendingRequests.map(\.id), ["q"])
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        XCTAssertFalse(store.resolve(sessionID: "claude:s1", requestID: "a", decision: "allow"))
        XCTAssertFalse(store.apply(event(.requestCancelled, at: 4, request: approval("missing"))).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.lastEventAt, 3)
        XCTAssertFalse(store.apply(event(.requestCancelled, at: 5, session: "unknown", request: approval("a"))).changed)
        XCTAssertNil(store.sessions["claude:unknown"])
    }

    func testDisconnectedQuestionRemainsWaitingForHostUntilNewWork() {
        var store = SessionStore()
        store.apply(event(.questionRequested, request: question()))
        XCTAssertTrue(store.cancelRequest(sessionID: "claude:s1", requestID: "q1"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        XCTAssertTrue(store.sessions["claude:s1"]?.pendingRequests.isEmpty == true)
        store.apply(event(.heartbeat, at: 2))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        store.apply(event(.toolFinished, at: 3))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testExplicitCancellationWithoutHostWaitingRestoresActivity() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, request: approval()))
        XCTAssertTrue(store.cancelRequest(sessionID: "claude:s1", requestID: "r1", waitingForHost: false))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testRequestFallbackPreservesCompletedOutcomeAndMessage() {
        var store = SessionStore()
        store.apply(event(.questionRequested, request: question()))
        store.apply(event(.turnCompleted, at: 2, message: "Finished result"))
        XCTAssertTrue(store.cancelRequest(sessionID: "claude:s1", requestID: "q1"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .completed)
        XCTAssertEqual(store.sessions["claude:s1"]?.message, "Finished result")

        store.apply(event(.turnStarted, at: 3, turn: "t2"))
        store.apply(event(.approvalRequested, at: 4, turn: "t2", request: approval("r2")))
        store.apply(event(.turnCompleted, at: 5, turn: "t2", message: "Second result"))
        store.apply(event(.requestCancelled, at: 6, turn: "t2", request: approval("r2"), message: "Return to terminal"))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .completed)
        XCTAssertEqual(store.sessions["claude:s1"]?.message, "Second result")
    }

    func testOutOfOrderCurrentTurnRequestsMergeWithoutRewindingMetadata() {
        var store = SessionStore()
        store.apply(event(.turnStarted, at: 1))
        store.apply(event(.approvalRequested, at: 5, request: approval("later"), message: "Newest message", terminal: TerminalTarget(tty: "/dev/ttys005")))
        XCTAssertTrue(store.apply(event(.questionRequested, at: 3, request: question("earlier"), message: "Older message", terminal: TerminalTarget(tty: "/dev/ttys003"))).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.pendingRequests.map(\.id), ["later", "earlier"])
        XCTAssertEqual(store.sessions["claude:s1"]?.lastEventAt, 5)
        XCTAssertEqual(store.sessions["claude:s1"]?.message, "Newest message")
        XCTAssertEqual(store.sessions["claude:s1"]?.terminal?.tty, "/dev/ttys005")
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsApproval)
    }

    func testOutOfOrderRequestsNeedExplicitMatchingTurnAndCannotReplayResolvedRequest() {
        var store = SessionStore()
        store.apply(event(.turnStarted, at: 1, turn: "old"))
        store.apply(event(.turnStarted, at: 3, turn: "current"))
        store.apply(event(.heartbeat, at: 10, turn: "current"))
        XCTAssertFalse(store.apply(event(.approvalRequested, at: 5, turn: nil, request: approval("missing-turn"))).changed)
        XCTAssertFalse(store.apply(event(.approvalRequested, at: 5, turn: "old", request: approval("old-turn"))).changed)
        XCTAssertFalse(store.apply(event(.approvalRequested, at: 5, turn: "unknown", request: approval("unknown-turn"))).changed)
        XCTAssertTrue(store.apply(event(.approvalRequested, at: 5, turn: "current", request: approval("valid"))).changed)
        XCTAssertTrue(store.resolve(sessionID: "claude:s1", requestID: "valid", decision: "allow"))
        XCTAssertFalse(store.apply(event(.approvalRequested, at: 6, turn: "current", request: approval("valid"))).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.lastEventAt, 10)
    }

    func testOutOfOrderCancellationUsesPendingKindAndPreservesWatermark() {
        var store = SessionStore()
        store.apply(event(.questionRequested, at: 2, request: question()))
        store.apply(event(.heartbeat, at: 10, message: "Still active"))
        // A minimal wire cancellation defaults its decoded kind to approval.
        // The reducer must use the actual pending question's kind instead.
        XCTAssertTrue(store.apply(event(.requestCancelled, at: 3, request: AgentRequest(id: "q1", kind: .approval, title: ""))).changed)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .needsInput)
        XCTAssertTrue(store.sessions["claude:s1"]?.pendingRequests.isEmpty == true)
        XCTAssertEqual(store.sessions["claude:s1"]?.lastEventAt, 10)
        store.apply(event(.toolFinished, at: 11))
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .working)
    }

    func testBoundedDedupHistoryAndReset() {
        var store = SessionStore(historyLimit: 2)
        store.apply(event(.turnStarted, at: 1, id: "start"))
        store.apply(event(.heartbeat, at: 2, id: "h1"))
        store.apply(event(.heartbeat, at: 3, id: "h2"))
        XCTAssertFalse(store.apply(event(.heartbeat, at: 3, id: "h2")).changed)
        // The retired event is no longer in the ID cache, but still cannot rewind time.
        XCTAssertFalse(store.apply(event(.turnStarted, at: 1, id: "start")).changed)
        store.reset()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.apply(event(.turnStarted, id: "start")).changed)
    }
}
