import XCTest
@testable import IslandCore

final class MenuBarActivityTests: XCTestCase {
    private func event(_ kind: EventKind, session: String = "first", at: Double,
                       turn: String = "turn-1", request: AgentRequest? = nil) -> AgentEvent {
        AgentEvent(provider: .codex, sessionID: session, turnID: turn,
                   timestamp: at, kind: kind, request: request)
    }

    private func activity(_ store: SessionStore) -> MenuBarActivity {
        MenuBarActivity(sessions: store.sessions.values)
    }

    func testRemainsRunningUntilTheLastAgentCompletes() {
        var store = SessionStore()
        XCTAssertEqual(activity(store), .idle)
        store.apply(event(.sessionStarted, at: 1))
        XCTAssertEqual(activity(store), .idle)

        store.apply(event(.turnStarted, at: 2))
        store.apply(event(.turnStarted, session: "second", at: 3))
        XCTAssertEqual(activity(store), .running)
        store.apply(event(.turnCompleted, at: 4))
        XCTAssertEqual(activity(store), .running)
        store.apply(event(.turnCompleted, session: "second", at: 5))
        XCTAssertEqual(activity(store), .completed)
    }

    func testWaitingStopsActivityUntilWorkResumes() {
        for requestKind in [RequestKind.approval, .question] {
            var store = SessionStore()
            store.apply(event(.turnStarted, at: 1))
            let request = AgentRequest(id: "request", kind: requestKind, title: "Private request")
            store.apply(event(requestKind == .approval ? .approvalRequested : .questionRequested,
                              at: 2, request: request))
            XCTAssertEqual(activity(store), .needsAttention)

            store.apply(event(.turnStarted, session: "second", at: 3))
            XCTAssertEqual(activity(store), .running)
            store.apply(event(.turnCompleted, session: "second", at: 4))
            XCTAssertEqual(activity(store), .needsAttention)

            store.apply(event(.toolStarted, at: 5))
            XCTAssertEqual(activity(store), .running)
            store.apply(event(.turnCompleted, at: 6))
            XCTAssertEqual(activity(store), .completed)
        }
    }

    func testWaitingWithoutRequestDetailsAndRestoredPendingRequestsStillNeedAttention() {
        var store = SessionStore()
        store.apply(event(.approvalRequested, at: 1))
        XCTAssertEqual(activity(store), .needsAttention)
        store.apply(event(.toolFinished, at: 2))
        XCTAssertEqual(activity(store), .running)

        let restored = SessionState(provider: .pi, sessionID: "restored", status: .idle,
                                    pendingRequests: [AgentRequest(id: "pending", kind: .question, title: "Private question")])
        XCTAssertEqual(MenuBarActivity(sessions: [restored]), .needsAttention)
    }

    func testFailureAndUnknownOutcomeCannotAppearAsSuccess() {
        var store = SessionStore()
        store.apply(event(.turnCompleted, session: "successful", at: 1))
        store.apply(event(.turnStarted, at: 2))
        store.apply(event(.sessionEnded, at: 3))
        XCTAssertEqual(activity(store), .disconnected)

        store.apply(event(.turnStarted, session: "failed", at: 4))
        XCTAssertEqual(activity(store), .running)
        store.apply(event(.turnFailed, session: "failed", at: 5))
        XCTAssertEqual(activity(store), .failed)
        store.apply(event(.questionRequested, session: "waiting", at: 6))
        XCTAssertEqual(activity(store), .needsAttention)

        store.removeSession("codex:waiting")
        XCTAssertEqual(activity(store), .failed)
        store.removeSession("codex:failed")
        XCTAssertEqual(activity(store), .disconnected)
        store.removeSession("codex:first")
        XCTAssertEqual(activity(store), .completed)
    }

    func testClearingCompletedRecordsRestoresIdleWithoutHidingActiveWork() {
        var store = SessionStore()
        store.apply(event(.turnCompleted, at: 1))
        store.apply(event(.turnStarted, session: "second", at: 2))
        store.removeSession("codex:first")
        XCTAssertEqual(activity(store), .running)
        store.apply(event(.turnCompleted, session: "second", at: 3))
        XCTAssertEqual(activity(store), .completed)
        store.removeSession("codex:second")
        XCTAssertEqual(activity(store), .idle)
    }

    func testNewTurnResumesRunningAndLateEventsCannotUndoItsOutcome() {
        var store = SessionStore()
        store.apply(event(.turnStarted, at: 1))
        let completed = event(.turnCompleted, at: 2)
        store.apply(completed)
        XCTAssertEqual(activity(store), .completed)
        store.apply(event(.toolFinished, at: 3))
        XCTAssertEqual(activity(store), .completed)

        store.apply(event(.turnStarted, at: 4, turn: "turn-2"))
        XCTAssertEqual(activity(store), .running)
        store.apply(completed)
        store.apply(event(.turnCompleted, at: 5))
        XCTAssertEqual(activity(store), .running)
        store.apply(event(.turnCompleted, at: 6, turn: "turn-2"))
        XCTAssertEqual(activity(store), .completed)
    }

    func testPriorityDoesNotDependOnSessionIterationOrder() {
        let states = SessionStatus.allCases.enumerated().map { index, status in
            SessionState(provider: .codex, sessionID: "session-\(index)", status: status)
        }
        XCTAssertEqual(MenuBarActivity(sessions: states), .running)
        XCTAssertEqual(MenuBarActivity(sessions: states.reversed()), .running)
        let stopped = states.filter { $0.status != .working }
        XCTAssertEqual(MenuBarActivity(sessions: stopped), .needsAttention)
        XCTAssertEqual(MenuBarActivity(sessions: stopped.reversed()), .needsAttention)
        let outcomes = stopped.filter { !$0.status.needsAttention }
        XCTAssertEqual(MenuBarActivity(sessions: outcomes), .failed)
        XCTAssertEqual(MenuBarActivity(sessions: outcomes.reversed()), .failed)
    }
}
