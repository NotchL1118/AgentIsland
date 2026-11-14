import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import IslandCore

enum SettingsSection: String, CaseIterable {
    case general
    case agents

    var title: String { self == .general ? "通用" : "Agent 接入" }
    var symbol: String { self == .general ? "slider.horizontal.3" : "terminal" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published var expanded = true
    @Published var showingSettings = false
    @Published var settingsWindowSection: SettingsSection = .agents
    @Published var settingsWindowRequestID = UUID()
    @Published var isSettingsWindowVisible = false
    @Published var selectedID: String?
    @Published var statusMessage = ""
    @Published var serverReady = false
    @Published var notificationsEnabled: Bool
    @Published var autoExpand: Bool
    @Published private(set) var collapseDelay: TimeInterval
    @Published var presentation: IslandPresentation
    @Published var positionResetID = UUID()
    @Published var launchAtLogin = false
    @Published var integrationBusy = false
    @Published var integrationOutput = ""
    let demo: Bool
    private let defaults: UserDefaults
    private let socketPath: String
    private var server: SocketServer?
    private var pending: [String: Pending] = [:]
    private var cleanup: Timer?
    private var demoTasks: [Task<Void, Never>] = []
    private var feedbackTask: Task<Void, Never>?
    private struct Pending { let sessionID: String; let requestID: String; let connection: EventConnection }
    var sessions: [SessionState] {
        store.sessions.values.sorted {
            if $0.status.needsAttention != $1.status.needsAttention { return $0.status.needsAttention }
            return $0.lastEventAt > $1.lastEventAt
        }
    }
    var pendingCount: Int { sessions.reduce(0) { $0 + max($1.pendingRequests.count, $1.status.needsAttention ? 1 : 0) } }
    var runningCount: Int { sessions.filter { $0.status == .working }.count }
    var summary: String {
        if pendingCount > 0 { return "\(pendingCount) 待处理 · \(runningCount) 运行" }
        if runningCount > 0 { return "\(runningCount) 个任务运行中" }
        return sessions.isEmpty ? "等待 Agent" : "\(sessions.count) 个会话"
    }
    var floating: Bool { presentation == .floating }
    var menuBarOnly: Bool { presentation == .menuBar }

    init(demo: Bool, socketPath: String = SocketServer.defaultPath, defaults: UserDefaults = .standard) {
        self.demo = demo
        self.socketPath = socketPath
        self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        autoExpand = defaults.object(forKey: "autoExpand") as? Bool ?? true
        collapseDelay = Self.normalizedCollapseDelay(defaults.object(forKey: "collapseDelay") as? Double ?? 0.3)
        presentation = IslandPresentation.restored(rawValue: defaults.string(forKey: "presentationMode"), legacyFloating: defaults.bool(forKey: "floating"))
        if !demo && Bundle.main.bundleIdentifier == "dev.codeland.agentisland" {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if demo { loadDemo() }
        else { startServer() }
        cleanup = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expirePending() }
        }
    }
    func startServer() {
        let server = SocketServer(path: socketPath) { [weak self] event, connection in
            Task { @MainActor in self?.receive(event, connection: connection) }
        }
        do { try server.start(); self.server = server; serverReady = true; statusMessage = "" }
        catch { statusMessage = error.localizedDescription; serverReady = false }
    }
    private func requestKey(_ session: String, _ request: String) -> String { session + "\u{0}" + request }
    private func receive(_ event: AgentEvent, connection: EventConnection) {
        let sessionID = event.provider.rawValue + ":" + event.sessionID
        let needsReply = (event.kind == .approvalRequested || event.kind == .questionRequested) && event.request != nil
        if needsReply {
            guard let request = event.request, !request.id.isEmpty,
                  (event.kind == .approvalRequested && request.kind == .approval) || (event.kind == .questionRequested && request.kind == .question) else {
                connection.reply(BridgeReply(status: "error", message: "Missing or inconsistent request")); return
            }
            if pending[requestKey(sessionID, request.id)] != nil {
                connection.reply(BridgeReply(status: "duplicate", requestID: request.id, message: "Request already pending; do not cancel the original")); return
            }
        }
        let result = store.apply(event)
        if needsReply, let request = event.request {
            guard result.changed, store.sessions[sessionID]?.pendingRequests.contains(where: { $0.id == request.id }) == true else {
                connection.reply(BridgeReply(status: "unavailable", requestID: request.id, message: "Stale request")); return
            }
            pending[requestKey(sessionID, request.id)] = Pending(sessionID: sessionID, requestID: request.id, connection: connection)
            if autoExpand && !menuBarOnly && !showingSettings && !isSettingsWindowVisible && !isEditingText { selectedID = sessionID; expanded = true }
        } else {
            connection.reply(BridgeReply(status: "accepted"))
            if result.changed && (event.kind == .approvalRequested || event.kind == .questionRequested),
               autoExpand && !menuBarOnly && !showingSettings && !isSettingsWindowVisible && !isEditingText {
                selectedID = sessionID; expanded = true
            }
        }
        reconcilePending()
        if selectedID == nil { selectedID = sessionID }
        if let completed = result.completedSessionID, let session = store.sessions[completed] {
            notifyCompletion(session)
            if autoExpand && !menuBarOnly && !showingSettings && !isSettingsWindowVisible && !isEditingText { selectedID = completed; expanded = true }
        }
    }
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    private func reconcilePending() {
        for (key, waiting) in Array(pending) {
            if store.sessions[waiting.sessionID]?.pendingRequests.contains(where: { $0.id == waiting.requestID }) != true {
                waiting.connection.reply(BridgeReply(status: "unavailable", requestID: waiting.requestID, message: "Request no longer active"))
                pending.removeValue(forKey: key)
            }
        }
    }
    private func expirePending() {
        for (key, waiting) in Array(pending) {
            if !waiting.connection.isConnected || Date().timeIntervalSince(waiting.connection.createdAt) > 120 {
                waiting.connection.reply(BridgeReply(status: "unavailable", requestID: waiting.requestID, message: "Return to the agent to continue"))
                _ = store.cancelRequest(sessionID: waiting.sessionID, requestID: waiting.requestID)
                pending.removeValue(forKey: key)
                statusMessage = "请求已回到原 Agent 处理"
            }
        }
    }
    func respond(session: SessionState, request: AgentRequest, decision: String, answer: String? = nil) {
        guard (request.kind == .approval && ["allow", "deny"].contains(decision)) ||
              (request.kind == .question && decision == "answer" && !(answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) else { return }
        let key = requestKey(session.id, request.id)
        guard demo || pending[key]?.connection.isConnected == true else {
            _ = store.cancelRequest(sessionID: session.id, requestID: request.id)
            pending.removeValue(forKey: key)
            statusMessage = "请求已失效，请回到原 Agent。"; return
        }
        guard store.sessions[session.id]?.pendingRequests.contains(where: { $0.id == request.id }) == true else { return }
        if !demo {
            guard let waiting = pending.removeValue(forKey: key),
                  waiting.connection.reply(BridgeReply(status: "resolved", requestID: request.id, decision: decision, answer: answer)) else {
                _ = store.cancelRequest(sessionID: session.id, requestID: request.id)
                statusMessage = "回传失败，请在原 Agent 中处理。"; return
            }
        }
        guard store.resolve(sessionID: session.id, requestID: request.id, decision: decision, answer: answer) else { return }
        showTransientStatus(decision == "deny" ? "已拒绝请求" : decision == "answer" ? "回答已发送" : "已允许本次请求")
        if demo && decision != "deny" {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.applyDemo(provider: session.provider, kind: .turnCompleted, message: "任务已完成，测试全部通过。")
            }
            demoTasks.append(task)
        }
    }
    func jump(_ session: SessionState) {
        if demo { showTransientStatus("演示：将返回 \(session.provider.displayName) 对应终端"); return }
        Task { @MainActor in
            let outcome = await TerminalNavigator.jump(to: session)
            statusMessage = outcome.precise ? "" : outcome.message
            if outcome.precise { expanded = false }
        }
    }
    private func showTransientStatus(_ message: String) {
        feedbackTask?.cancel()
        statusMessage = message
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.statusMessage == message else { return }
            self.statusMessage = ""
        }
    }
    func savePreferences() {
        guard !demo else { return }
        defaults.set(autoExpand, forKey: "autoExpand")
        defaults.set(presentation.rawValue, forKey: "presentationMode")
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(collapseDelay, forKey: "collapseDelay")
    }
    func setCollapseDelay(_ delay: TimeInterval) {
        collapseDelay = Self.normalizedCollapseDelay(delay)
        guard !demo else { return }
        defaults.set(collapseDelay, forKey: "collapseDelay")
    }
    private static func normalizedCollapseDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return 0.3 }
        return (min(2, max(0, delay)) * 10).rounded() / 10
    }
    func setPresentation(_ presentation: IslandPresentation) {
        self.presentation = presentation
        guard !demo else { return }
        defaults.set(presentation.rawValue, forKey: "presentationMode")
    }
    func resetFloatingPosition() {
        positionResetID = UUID()
    }
    func requestSettingsWindow(_ section: SettingsSection = .agents) {
        settingsWindowSection = section
        showingSettings = false
        expanded = false
        settingsWindowRequestID = UUID()
    }
    func enableNotifications(_ enabled: Bool) {
        guard enabled else { notificationsEnabled = false; savePreferences(); return }
        guard Bundle.main.bundleIdentifier != nil else { statusMessage = "请运行打包后的 .app 来启用系统通知。"; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                self?.statusMessage = granted ? "" : (error?.localizedDescription ?? "通知未获允许，可在系统设置中开启。")
                self?.savePreferences()
            }
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !demo && Bundle.main.bundleIdentifier == "dev.codeland.agentisland" else {
            statusMessage = "请在正式应用模式中设置开机启动。"; return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                statusMessage = "请在系统设置的登录项中允许 Agent Island。"
                SMAppService.openSystemSettingsLoginItems()
            } else { statusMessage = "" }
        } catch { statusMessage = "开机启动设置失败：\(error.localizedDescription)" }
    }
    private func notifyCompletion(_ session: SessionState) {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.provider.displayName) 已完成"
        content.body = "\(session.title) · 点击返回会话"
        content.sound = .default
        content.userInfo = ["sessionID": session.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func revealFromNotification(_ id: String) { selectedID = id; showingSettings = false; expanded = true }
    var integrationsDirectory: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Integrations")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Integrations")
    }
    func install(_ provider: AgentProvider, remove: Bool = false) {
        guard !integrationBusy else { return }
        if provider == .pi {
            let command = "pi -e " + shellQuote(integrationsDirectory.appendingPathComponent("pi-extension.ts").path)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            integrationOutput = "已复制 Pi 启动命令。可在终端粘贴执行。\n工具审批为可选参数 --island-approve-tools。"
            return
        }
        let script = integrationsDirectory.appendingPathComponent(provider == .claude ? "bridge.py" : "codex/codex_bridge.py")
        guard FileManager.default.fileExists(atPath: script.path) else { integrationOutput = "找不到接入脚本，请运行打包后的应用。"; return }
        let command = provider == .claude ? (remove ? "uninstall-claude" : "install-claude") : (remove ? "uninstall" : "install")
        integrationBusy = true; integrationOutput = "正在更新接入配置…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> String in
                let process = Process(); let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", script.path, command]
                process.standardOutput = output; process.standardError = output
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    return (process.terminationStatus == 0 ? "" : "接入失败：\n") + text
                } catch { return "接入失败：\(error.localizedDescription)" }
            }.value
            integrationOutput = result; integrationBusy = false
        }
    }
    func copyLaunchCommand(_ provider: AgentProvider) {
        let base = integrationsDirectory
        let command: String
        switch provider {
        case .pi: command = "pi -e " + shellQuote(base.appendingPathComponent("pi-extension.ts").path)
        case .codex: command = "python3 " + shellQuote(base.appendingPathComponent("codex/codex_bridge.py").path) + " launch"
        case .claude: command = "claude"
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        integrationOutput = "已复制：\(command)"
    }
    private func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func loadDemo() {
        demoTasks.forEach { $0.cancel() }; demoTasks.removeAll(); store.reset()
        applyDemo(provider: .claude, kind: .turnStarted, message: "修复登录校验")
        applyDemo(provider: .codex, kind: .turnStarted, message: "优化订单查询")
        applyDemo(provider: .pi, kind: .turnStarted, message: "补齐测试用例")
        applyDemo(provider: .claude, kind: .approvalRequested, message: "运行登录模块测试", request: AgentRequest(id: "demo-approval", kind: .approval, title: "允许执行测试命令？", detail: "npm test -- auth.test.ts"))
        applyDemo(provider: .pi, kind: .questionRequested, message: "选择测试数据", request: AgentRequest(id: "demo-question", kind: .question, title: "测试数据采用哪种方案？", options: [RequestOption(id: "mock", label: "沿用现有 mock 数据"), RequestOption(id: "db", label: "使用独立测试数据库")]))
        selectedID = "claude:demo-claude"; statusMessage = ""
    }
    private func applyDemo(provider: AgentProvider, kind: EventKind, message: String, request: AgentRequest? = nil) {
        let event = AgentEvent(id: UUID().uuidString, provider: provider, sessionID: "demo-\(provider.rawValue)", turnID: "demo-turn", timestamp: Date().timeIntervalSince1970, kind: kind, title: provider == .claude ? "修复登录校验" : provider == .codex ? "优化订单查询" : "补齐测试用例", cwd: "/projects/\(provider == .claude ? "web-app" : provider == .codex ? "api-server" : "test-suite")", message: message, request: request)
        _ = store.apply(event)
    }
    func shutdown() {
        cleanup?.invalidate(); demoTasks.forEach { $0.cancel() }; feedbackTask?.cancel()
        for waiting in pending.values { waiting.connection.reply(BridgeReply(status: "unavailable", requestID: waiting.requestID, message: "Agent Island is closing")) }
        pending.removeAll(); server?.stop()
    }
}
