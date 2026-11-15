/// A content-free summary of all observed sessions for the menu bar indicator.
public enum MenuBarActivity: Equatable, Sendable, CaseIterable {
    case idle, running, needsAttention, failed, disconnected, completed

    public init(sessions: some Sequence<SessionState>) {
        var needsAttention = false
        var hasFailure = false
        var hasDisconnected = false
        var hasCompleted = false
        for session in sessions {
            // Another session ending or waiting must never hide ongoing work.
            if session.status == .working {
                self = .running
                return
            }
            needsAttention = needsAttention || session.status.needsAttention || !session.pendingRequests.isEmpty
            hasFailure = hasFailure || session.status == .failed
            hasDisconnected = hasDisconnected || session.status == .disconnected
            hasCompleted = hasCompleted || session.status == .completed
        }
        if needsAttention { self = .needsAttention }
        else if hasFailure { self = .failed }
        else if hasDisconnected { self = .disconnected }
        else if hasCompleted { self = .completed }
        else { self = .idle }
    }

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "等待 Agent"
        case .running: return "Agent 运行中"
        case .needsAttention: return "Agent 等待处理"
        case .failed: return "Agent 运行异常"
        case .disconnected: return "Agent 已断开，结果未知"
        case .completed: return "Agent 已完成"
        }
    }
}
