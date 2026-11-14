import Foundation

/// A synchronous reducer. The app owns serialization and transport; the reducer
/// performs no I/O, asks for no permissions, and never executes agent commands.
public struct SessionStore: Sendable {
    public private(set) var sessions: [String: SessionState]

    private var activity: [String: SessionStatus] = [:]
    private var retiredTurns: [String: [String]] = [:]
    private var resolvedRequests: Set<String> = []
    private var resolvedRequestOrder: [String] = []
    private var seenEvents: Set<String> = []
    private var eventOrder: [String] = []
    private let historyLimit: Int

    public init(sessions: [String: SessionState] = [:], historyLimit: Int = 2048) {
        self.sessions = Dictionary(sessions.values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.historyLimit = max(1, historyLimit)
        for session in self.sessions.values {
            activity[session.id] = session.status.needsAttention ? .working : session.status
        }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ApplyResult {
        guard event.version == 1, !event.id.isEmpty, !event.sessionID.isEmpty,
              event.timestamp.isFinite, event.timestamp >= 0 else {
            return ApplyResult(changed: false)
        }
        if (event.kind == .approvalRequested || event.kind == .questionRequested), let request = event.request {
            guard !request.id.isEmpty,
                  request.kind == (event.kind == .approvalRequested ? .approval : .question) else {
                return ApplyResult(changed: false)
            }
        }
        if event.kind == .requestCancelled, event.request?.id.isEmpty != false {
            return ApplyResult(changed: false)
        }

        let key = event.sessionKey
        let eventKey = "\(key)|\(event.id)"
        guard !seenEvents.contains(eventKey) else { return ApplyResult(changed: false) }
        rememberEvent(eventKey)

        let previous = sessions[key]
        if event.kind == .requestCancelled,
           previous?.pendingRequests.contains(where: { $0.id == event.request?.id }) != true {
            return ApplyResult(changed: false)
        }
        let isOlder = event.timestamp < (previous?.lastEventAt ?? 0)
        let isNewCurrentTurnRequest = (event.kind == .approvalRequested || event.kind == .questionRequested)
            && event.turnID != nil && event.turnID == previous?.turnID
            && event.request != nil
            && previous?.pendingRequests.contains(where: { $0.id == event.request?.id }) == false
        // Independent hooks can reach the socket out of order. A new request
        // with an explicit current turn ID can be merged without rewinding the
        // session. Cancellation identifies an existing request rather than work.
        guard !isOlder || isNewCurrentTurnRequest || event.kind == .requestCancelled else {
            return ApplyResult(changed: false)
        }
        if let incomingTurn = event.turnID,
           retiredTurns[key, default: []].contains(incomingTurn) {
            return ApplyResult(changed: false)
        }

        var session = previous ?? SessionState(provider: event.provider, sessionID: event.sessionID)
        var underlying = activity[key] ?? .idle
        let changesTurn = event.turnID != nil && event.turnID != session.turnID

        // An explicit start is the authority for replacing an established turn.
        // A late result carrying a different ID cannot replace the current task.
        if changesTurn && session.turnID != nil && event.kind != .turnStarted {
            return ApplyResult(changed: false)
        }
        if event.kind == .turnStarted {
            if let currentTurn = session.turnID, event.turnID == currentTurn,
               underlying == .completed || underlying == .failed {
                return ApplyResult(changed: false)
            }
            if changesTurn || event.turnID == nil {
                if let oldTurn = session.turnID { retire(oldTurn, for: key) }
                for request in session.pendingRequests { rememberResolved(request.id, session: key) }
                session.pendingRequests.removeAll()
                session.turnID = event.turnID
            }
            underlying = .working
        } else if changesTurn {
            session.turnID = event.turnID
        }

        // Tool telemetry received after a terminal outcome must not revive that
        // turn. Only a subsequent turnStarted event can begin work again.
        if (event.kind == .toolStarted || event.kind == .toolFinished),
           [.completed, .failed, .disconnected].contains(underlying) {
            return ApplyResult(changed: false)
        }
        if let request = event.request,
           (event.kind == .approvalRequested || event.kind == .questionRequested),
           resolvedRequests.contains(requestKey(request.id, session: key)) {
            return ApplyResult(changed: false)
        }

        if !isOlder && event.kind != .requestCancelled {
            if let title = event.title, !title.isEmpty { session.title = title }
            if let cwd = event.cwd { session.cwd = cwd }
            if let message = event.message { session.message = message }
            if let terminal = event.terminal {
                session.terminal = session.terminal?.merging(terminal) ?? terminal
            }
        }
        session.lastEventAt = max(session.lastEventAt, event.timestamp)

        switch event.kind {
        case .sessionStarted:
            if previous == nil || underlying == .disconnected { underlying = .idle }
        case .turnStarted, .toolStarted, .toolFinished:
            underlying = .working
        case .approvalRequested, .questionRequested:
            if let request = event.request {
                if let index = session.pendingRequests.firstIndex(where: { $0.id == request.id }) {
                    session.pendingRequests[index] = request
                } else {
                    session.pendingRequests.append(request)
                }
                if underlying == .idle || underlying == .disconnected { underlying = .working }
            } else {
                // A source may observe a prompt without owning its response
                // channel. Show the wait state; the UI must route to the host.
                underlying = event.kind == .approvalRequested ? .needsApproval : .needsInput
            }
        case .requestCancelled:
            if let requestID = event.request?.id,
               let index = session.pendingRequests.firstIndex(where: { $0.id == requestID }) {
                let cancelled = session.pendingRequests.remove(at: index)
                rememberResolved(requestID, session: key)
                if !isTerminal(underlying) {
                    underlying = hostWaitingStatus(for: cancelled.kind, underlying: underlying)
                    session.message = event.message ?? "请求已交回原 Agent，请返回原会话处理"
                }
            }
        case .turnCompleted:
            underlying = .completed
        case .turnFailed:
            underlying = .failed
            invalidatePending(&session)
        case .sessionEnded:
            underlying = .disconnected
            invalidatePending(&session)
        case .heartbeat:
            break
        }

        activity[key] = underlying
        session.status = visibleStatus(for: session, underlying: underlying)
        sessions[key] = session
        let didComplete = event.kind == .turnCompleted
            && session.status == .completed
            && previous?.status != .completed
        return ApplyResult(changed: previous != session, completedSessionID: didComplete ? key : nil)
    }

    /// sessionID is the namespaced SessionState.id, not the agent's raw ID.
    /// The caller must deliver the reply through its original live connection.
    @discardableResult
    public mutating func resolve(sessionID: String, requestID: String, decision: String, answer: String? = nil) -> Bool {
        guard var session = sessions[sessionID],
              let index = session.pendingRequests.firstIndex(where: { $0.id == requestID }) else {
            return false
        }
        let request = session.pendingRequests[index]
        switch request.kind {
        case .approval:
            guard decision == "allow" || decision == "deny" else { return false }
        case .question:
            guard decision == "answer", let answer,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }

        session.pendingRequests.remove(at: index)
        rememberResolved(requestID, session: sessionID)
        let underlying = activity[sessionID] ?? .working
        session.status = visibleStatus(for: session, underlying: underlying)
        if underlying != .completed && underlying != .failed {
            session.message = decision == "answer" ? "已回答：\(answer ?? "")"
                : decision == "allow" ? "已允许请求，等待 Agent 继续" : "已拒绝请求，等待 Agent 继续"
        }
        sessions[sessionID] = session
        return true
    }

    /// Removes only the request whose response channel expired or disconnected.
    /// A lost response channel is never interpreted as approval or task success.
    @discardableResult
    public mutating func cancelRequest(sessionID: String, requestID: String, waitingForHost: Bool = true) -> Bool {
        guard var session = sessions[sessionID],
              let index = session.pendingRequests.firstIndex(where: { $0.id == requestID }) else {
            return false
        }
        let cancelled = session.pendingRequests.remove(at: index)
        rememberResolved(requestID, session: sessionID)
        var underlying = activity[sessionID] ?? .working
        if !isTerminal(underlying) {
            if waitingForHost { underlying = hostWaitingStatus(for: cancelled.kind, underlying: underlying) }
            session.message = waitingForHost ? "请求已交回原 Agent，请返回原会话处理" : "请求已取消"
        }
        activity[sessionID] = underlying
        session.status = visibleStatus(for: session, underlying: underlying)
        sessions[sessionID] = session
        return true
    }

    public mutating func markDisconnected(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        invalidatePending(&session)
        activity[sessionID] = .disconnected
        session.status = .disconnected
        session.message = "连接已断开，任务结果未知"
        sessions[sessionID] = session
    }

    public mutating func reset() {
        sessions.removeAll()
        activity.removeAll()
        retiredTurns.removeAll()
        resolvedRequests.removeAll()
        resolvedRequestOrder.removeAll()
        seenEvents.removeAll()
        eventOrder.removeAll()
    }

    private func visibleStatus(for session: SessionState, underlying: SessionStatus) -> SessionStatus {
        if session.pendingRequests.contains(where: { $0.kind == .approval }) { return .needsApproval }
        if session.pendingRequests.contains(where: { $0.kind == .question }) { return .needsInput }
        return underlying
    }

    private func requestKey(_ requestID: String, session: String) -> String {
        "\(session)|\(requestID)"
    }

    private func isTerminal(_ status: SessionStatus) -> Bool {
        status == .completed || status == .failed || status == .disconnected
    }

    private func hostWaitingStatus(for kind: RequestKind, underlying: SessionStatus) -> SessionStatus {
        // Do not forget an approval already handed back to the host when a
        // second question connection is lost before the agent resumes.
        kind == .approval || underlying == .needsApproval ? .needsApproval : .needsInput
    }

    private mutating func invalidatePending(_ session: inout SessionState) {
        for request in session.pendingRequests { rememberResolved(request.id, session: session.id) }
        session.pendingRequests.removeAll()
    }

    private mutating func retire(_ turn: String, for session: String) {
        var turns = retiredTurns[session, default: []]
        if !turns.contains(turn) { turns.append(turn) }
        if turns.count > 64 { turns.removeFirst(turns.count - 64) }
        retiredTurns[session] = turns
    }

    private mutating func rememberEvent(_ key: String) {
        seenEvents.insert(key)
        eventOrder.append(key)
        if eventOrder.count > historyLimit {
            let expired = eventOrder.removeFirst()
            seenEvents.remove(expired)
        }
    }

    private mutating func rememberResolved(_ requestID: String, session: String) {
        let key = requestKey(requestID, session: session)
        guard resolvedRequests.insert(key).inserted else { return }
        resolvedRequestOrder.append(key)
        if resolvedRequestOrder.count > historyLimit {
            resolvedRequests.remove(resolvedRequestOrder.removeFirst())
        }
    }
}
