import Foundation

/// Open set of agent identities. Unknown providers decode instead of failing,
/// so a new adapter never requires the app to learn a new enum case first.
public struct AgentProvider: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard !value.isEmpty, value.count <= 64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid provider"))
        }
        rawValue = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claude: AgentProvider = "claude"
    public static let codex: AgentProvider = "codex"
    public static let pi: AgentProvider = "pi"

    /// Display metadata lives with the identity; unknown agents still render.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "Pi"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    public var glyph: String {
        switch self {
        case .claude: return "✳"
        case .codex: return ">_"
        case .pi: return "π"
        default: return String(displayName.prefix(1))
        }
    }
}

public enum EventKind: String, Codable, Sendable {
    case sessionStarted
    case turnStarted
    case toolStarted
    case toolFinished
    case approvalRequested
    case questionRequested
    case requestCancelled
    case turnCompleted
    case turnFailed
    case sessionEnded
    case heartbeat
}

public enum RequestKind: String, Codable, Sendable {
    case approval, question
}

public struct RequestOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct AgentRequest: Codable, Equatable, Identifiable, Sendable {
    public typealias Kind = RequestKind

    public var id: String
    public var kind: RequestKind
    public var title: String
    public var detail: String?
    public var options: [RequestOption]?

    public init(id: String, kind: RequestKind, title: String, detail: String? = nil, options: [RequestOption]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.options = options
    }
}

public struct TerminalTarget: Codable, Equatable, Sendable {
    public var appBundleID: String?
    public var tty: String?
    public var windowID: String?
    public var tabID: String?
    public var paneID: String?
    public var tmuxPane: String?

    public init(appBundleID: String? = nil, tty: String? = nil, windowID: String? = nil, tabID: String? = nil, paneID: String? = nil, tmuxPane: String? = nil) {
        self.appBundleID = appBundleID
        self.tty = tty
        self.windowID = windowID
        self.tabID = tabID
        self.paneID = paneID
        self.tmuxPane = tmuxPane
    }

    /// Event sources may only know part of the terminal identity. Keep previously
    /// observed IDs when a later event omits them.
    public func merging(_ newer: TerminalTarget) -> TerminalTarget {
        TerminalTarget(
            appBundleID: newer.appBundleID ?? appBundleID,
            tty: newer.tty ?? tty,
            windowID: newer.windowID ?? windowID,
            tabID: newer.tabID ?? tabID,
            paneID: newer.paneID ?? paneID,
            tmuxPane: newer.tmuxPane ?? tmuxPane
        )
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var provider: AgentProvider
    public var sessionID: String
    public var turnID: String?
    public var timestamp: Double
    public var kind: EventKind
    public var title: String?
    public var cwd: String?
    public var message: String?
    public var terminal: TerminalTarget?
    public var request: AgentRequest?

    public var sessionKey: String { "\(provider.rawValue):\(sessionID)" }

    public init(version: Int = 1, id: String = UUID().uuidString, provider: AgentProvider, sessionID: String, turnID: String? = nil, timestamp: Double = Date().timeIntervalSince1970, kind: EventKind, title: String? = nil, cwd: String? = nil, message: String? = nil, terminal: TerminalTarget? = nil, request: AgentRequest? = nil) {
        self.version = version
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.message = message
        self.terminal = terminal
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, provider, sessionID, turnID, timestamp, kind, title, cwd, message, terminal, request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        kind = try container.decode(EventKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        terminal = try container.decodeIfPresent(TerminalTarget.self, forKey: .terminal)
        if kind == .requestCancelled {
            let cancellation = try container.decodeIfPresent(CancellationRequest.self, forKey: .request)
            request = cancellation.map {
                AgentRequest(id: $0.id, kind: $0.kind ?? .approval, title: $0.title ?? "", detail: $0.detail, options: $0.options)
            }
        } else {
            request = try container.decodeIfPresent(AgentRequest.self, forKey: .request)
        }
    }

    private struct CancellationRequest: Decodable {
        var id: String
        var kind: RequestKind?
        var title: String?
        var detail: String?
        var options: [RequestOption]?
    }
}

public struct BridgeReply: Codable, Equatable, Sendable {
    public var status: String
    public var requestID: String?
    public var decision: String?
    public var answer: String?
    public var message: String?

    public init(status: String, requestID: String? = nil, decision: String? = nil, answer: String? = nil, message: String? = nil) {
        self.status = status
        self.requestID = requestID
        self.decision = decision
        self.answer = answer
        self.message = message
    }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case idle, working, needsApproval, needsInput, completed, failed, disconnected

    public var displayName: String {
        switch self {
        case .idle: return "就绪"
        case .working: return "运行中"
        case .needsApproval: return "待审批"
        case .needsInput: return "待回答"
        case .completed: return "已完成"
        case .failed: return "异常"
        case .disconnected: return "已断开"
        }
    }

    public var needsAttention: Bool { self == .needsApproval || self == .needsInput }
}

public struct SessionState: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue):\(sessionID)" }
    public var provider: AgentProvider
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var message: String
    public var status: SessionStatus
    public var turnID: String?
    public var lastEventAt: Double
    public var terminal: TerminalTarget?
    public var pendingRequests: [AgentRequest]

    public init(provider: AgentProvider, sessionID: String, title: String = "", cwd: String = "", message: String = "", status: SessionStatus = .idle, turnID: String? = nil, lastEventAt: Double = 0, terminal: TerminalTarget? = nil, pendingRequests: [AgentRequest] = []) {
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.message = message
        self.status = status
        self.turnID = turnID
        self.lastEventAt = lastEventAt
        self.terminal = terminal
        self.pendingRequests = pendingRequests
    }
}

public struct ApplyResult: Equatable, Sendable {
    public var changed: Bool
    public var completedSessionID: String?

    public init(changed: Bool, completedSessionID: String? = nil) {
        self.changed = changed
        self.completedSessionID = completedSessionID
    }
}
