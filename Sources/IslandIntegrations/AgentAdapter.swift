import Foundation
import IslandCore

/// Observation capabilities. Providers never approve operations or answer questions.
public struct AgentCapabilities: Sendable, Equatable {
    public var status = true
    public var approval = false
    public var question = false
    public init(status: Bool = true, approval: Bool = false, question: Bool = false) {
        self.status = status; self.approval = approval; self.question = question
    }
}

/// One passive hook registration. Some provider lifecycle events require a
/// synchronous invocation, but no hook waits for the app or a user decision.
public struct HookSpec: Sendable, Equatable {
    public var event: String
    public var matcher: String?
    public var timeout: Int
    public var asynchronous: Bool
    public init(_ event: String, matcher: String? = nil, timeout: Int = 5,
                asynchronous: Bool = true) {
        self.event = event; self.matcher = matcher; self.timeout = timeout
        self.asynchronous = asynchronous
    }
}

/// Where and how an agent's persistent hook configuration lives.
public struct HookConfigTarget: Sendable {
    /// Default file, resolved from the environment the way the agent resolves it.
    public var defaultPath: @Sendable (_ environment: [String: String], _ home: URL) -> URL
    /// Additional read-only locations scanned for leftovers (never written unless recorded in the ledger).
    public var scanPaths: @Sendable (_ environment: [String: String], _ home: URL) -> [URL]
    /// The agent records hook trust elsewhere (Codex: config.toml `hooks.state`).
    public var trustStore: TrustStoreKind
    /// Whether the fallback (Agent Island missing) must still print `{}`.
    public var fallbackPrintsEmptyObject: Bool
    public init(defaultPath: @escaping @Sendable ([String: String], URL) -> URL,
                scanPaths: @escaping @Sendable ([String: String], URL) -> [URL] = { _, _ in [] },
                trustStore: TrustStoreKind = .none, fallbackPrintsEmptyObject: Bool = false) {
        self.defaultPath = defaultPath; self.scanPaths = scanPaths
        self.trustStore = trustStore; self.fallbackPrintsEmptyObject = fallbackPrintsEmptyObject
    }
}

public enum TrustStoreKind: Sendable, Equatable { case none, codexConfigToml }

public enum Injection: Sendable {
    /// Persistent hooks merged into the agent's JSON config (`hooks.<Event>[]`).
    case hookConfig(HookConfigTarget)
    /// Loaded per session by the agent itself (e.g. `pi -e extension.ts`); nothing to install.
    case sessionExtension(resource: String)
}

public struct AgentDescriptor: Sendable {
    public var provider: AgentProvider
    public var summary: String
    public var capabilities: AgentCapabilities
    public var injection: Injection
    public var hooks: [HookSpec]
    public var afterInstall: String?
}

/// Everything a hook invocation may touch. Tests replace the transport and
/// environment; production uses the real socket and process environment.
public struct HookContext {
    public var environment: [String: String]
    public var send: (AgentEvent, TimeInterval) -> BridgeReply?
    public var terminal: () -> TerminalTarget?
    public var now: () -> Double

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                send: @escaping (AgentEvent, TimeInterval) -> BridgeReply?,
                terminal: (() -> TerminalTarget?)? = nil,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.environment = environment
        self.send = send
        self.terminal = terminal ?? { TerminalProbe.current(environment: environment) }
        self.now = now
    }
}

public protocol AgentAdapter: Sendable {
    var descriptor: AgentDescriptor { get }
    /// Observe one hook payload. `waiting` is ignored for legacy --wait callers.
    /// Output is always neutral: nil or an empty JSON object, never a decision.
    func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String?
    /// Output when the payload cannot be processed or the app is unreachable.
    var silentOutput: String? { get }
}

public enum AdapterRegistry {
    /// Adding an agent: implement `AgentAdapter` and list it here. The app, UI,
    /// installer, ledger and uninstaller pick it up from its descriptor.
    public static let all: [any AgentAdapter] = [ClaudeAdapter(), CodexAdapter(), PiAdapter()]

    public static func adapter(for provider: AgentProvider) -> (any AgentAdapter)? {
        all.first { $0.descriptor.provider == provider }
    }
}

// MARK: Helpers shared by adapters

func string(_ value: Any?, limit: Int = 2000) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let text = value as? String { return String(text.prefix(limit)) }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) { return String(text.prefix(limit)) }
    return String(String(describing: value).prefix(limit))
}

func jsonLine(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
}

public struct PiAdapter: AgentAdapter {
    public init() {}
    public var descriptor: AgentDescriptor {
        AgentDescriptor(provider: .pi, summary: "通过扩展被动展示任务进度，不接管工具审批。",
                        capabilities: AgentCapabilities(), injection: .sessionExtension(resource: "pi-extension.ts"),
                        hooks: [], afterInstall: nil)
    }
    public var silentOutput: String? { nil }
    public func handle(_ payload: [String: Any], waiting: Bool, context: HookContext) -> String? { nil }
}
