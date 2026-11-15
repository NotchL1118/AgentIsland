import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import IslandCore
import IslandIntegrations

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
    @Published var compactSessionRevealID = UUID()
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
    @Published private(set) var integrationStatuses: [AgentProvider: IntegrationStatus] = [:]
    let demo: Bool
    private let defaults: UserDefaults
    private let socketPath: String
    private var server: SocketServer?
    private var feedbackTask: Task<Void, Never>?
    var sessions: [SessionState] {
        store.sessions.values.sorted {
            if $0.status.needsAttention != $1.status.needsAttention { return $0.status.needsAttention }
            return $0.lastEventAt > $1.lastEventAt
        }
    }
    var pendingCount: Int { sessions.reduce(0) { $0 + max($1.pendingRequests.count, $1.status.needsAttention ? 1 : 0) } }
    var runningCount: Int { sessions.filter { $0.status == .working }.count }
    var completedCount: Int { sessions.filter { $0.status == .completed }.count }
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
        else {
            startServer()
            // Keep the stable hook forwarder pointing at this copy of the app (only if something is installed).
            // Only a real app bundle may re-point it; dev builds and test runners never touch it.
            let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-island-hook").path
            if Bundle.main.bundleURL.pathExtension == "app", FileManager.default.isExecutableFile(atPath: bundledHelper) {
                let manager = IntegrationManager(IntegrationEnvironment(helperPath: bundledHelper))
                Task.detached(priority: .utility) { manager.refreshShimIfInstalled() }
            }
            refreshIntegrations()
        }
    }
    func startServer() {
        let server = SocketServer(path: socketPath) { [weak self] event, connection in
            // Acknowledge receipt before scheduling UI work. Legacy bridges also
            // receive no decision and can immediately continue in their host.
            connection.reply(BridgeReply(status: "accepted"))
            Task { @MainActor in self?.receive(event) }
        }
        do { try server.start(); self.server = server; serverReady = true; statusMessage = "" }
        catch { statusMessage = error.localizedDescription; serverReady = false }
    }
    private func receive(_ event: AgentEvent) {
        let sessionID = event.sessionKey
        let result = store.apply(event)
        if result.changed && (event.kind == .approvalRequested || event.kind == .questionRequested),
           autoExpand && !menuBarOnly && !showingSettings && !isSettingsWindowVisible && !isEditingText {
            selectedID = sessionID; expanded = true
        }
        if selectedID == nil, store.sessions[sessionID] != nil { selectedID = sessionID }
        if let completed = result.completedSessionID, let session = store.sessions[completed] {
            notifyCompletion(session)
            if autoExpand && !menuBarOnly && !showingSettings && !isSettingsWindowVisible && !isEditingText { selectedID = completed; expanded = true }
        }
    }
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    func removeSession(_ id: String) {
        guard store.removeSession(id) else { return }
        if selectedID == id { selectedID = sessions.first?.id }
    }
    func clearCompletedSessions() {
        let completedIDs = sessions.filter { $0.status == .completed }.map(\.id)
        guard !completedIDs.isEmpty else { return }
        var updatedStore = store
        for id in completedIDs { updatedStore.removeSession(id) }
        store = updatedStore
        if let selectedID, completedIDs.contains(selectedID) {
            self.selectedID = sessions.first?.id
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
    /// The compiled hook runtime: bundled in Contents/Helpers, or next to the binary during `swift run`.
    var hookHelperPath: String? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-island-hook"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agent-island-hook")]
        return candidates.compactMap { $0?.path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var integrationManager: IntegrationManager { IntegrationManager(IntegrationEnvironment(helperPath: hookHelperPath)) }

    func refreshIntegrations() {
        let manager = integrationManager
        Task {
            let statuses = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: AdapterRegistry.all.map { ($0.descriptor.provider, manager.status($0.descriptor.provider)) })
            }.value
            integrationStatuses = statuses
        }
    }
    func install(_ provider: AgentProvider, remove: Bool = false) {
        runIntegration { manager in
            let report = remove ? try manager.uninstall(provider) : try manager.install(provider)
            return [report]
        }
    }
    /// Remove every integration Agent Island ever wrote, then its own support files.
    func uninstallEverything() {
        runIntegration { manager in manager.uninstallEverything() }
    }
    private func runIntegration(_ work: @escaping @Sendable (IntegrationManager) throws -> [IntegrationReport]) {
        guard !integrationBusy, !demo else { return }
        integrationBusy = true; integrationOutput = "正在更新接入配置…"
        let manager = integrationManager
        Task {
            let result = await Task.detached(priority: .utility) { () -> String in
                do {
                    let reports = try work(manager)
                    if reports.isEmpty { return "没有发现需要处理的接入。" }
                    return reports.map { ([$0.path] + $0.lines.map { "  " + $0 }).joined(separator: "\n") }.joined(separator: "\n")
                } catch { return "接入失败：\(error.localizedDescription)" }
            }.value
            integrationOutput = result; integrationBusy = false
            refreshIntegrations()
        }
    }
    func copyLaunchCommand(_ provider: AgentProvider) {
        guard case .sessionExtension(let resource)? = AdapterRegistry.adapter(for: provider)?.descriptor.injection else { return }
        let command = "\(provider.rawValue) -e " + shellQuote(integrationsDirectory.appendingPathComponent(resource).path)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        integrationOutput = "已复制：\(command)\n仅展示进度；审批和回答请在原 Agent 中处理。"
    }
    private func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func loadDemo() {
        store.reset()
        applyDemo(provider: .claude, kind: .turnStarted, message: "修复登录校验")
        applyDemo(provider: .codex, kind: .turnStarted, message: "优化订单查询")
        applyDemo(provider: .pi, kind: .turnStarted, message: "补齐测试用例")
        applyDemo(provider: .claude, kind: .approvalRequested, message: "运行登录模块测试", request: AgentRequest(id: "demo-approval", kind: .approval, title: "允许执行测试命令？", detail: "npm test -- auth.test.ts"))
        applyDemo(provider: .pi, kind: .questionRequested, message: "选择测试数据", request: AgentRequest(id: "demo-question", kind: .question, title: "测试数据采用哪种方案？", options: [RequestOption(id: "mock", label: "沿用现有 mock 数据"), RequestOption(id: "db", label: "使用独立测试数据库")]))
        selectedID = "claude:demo-claude"; statusMessage = ""
    }
    #if DEBUG
    /// Layout-only fixtures: no sockets, hooks, or real Agent requests.
    @discardableResult
    func loadSessionLayoutSnapshot(_ scene: String) -> Bool {
        guard demo, ["sessionList", "sessionDetail", "sessionOverflow"].contains(scene) else { return false }
        feedbackTask?.cancel()
        store.reset()
        selectedID = nil
        statusMessage = ""
        let now = Date().timeIntervalSince1970
        let longSummary = "正在调整会话面板的宽度、卡片边界和信息层级，让同一项目中的多个任务也能清楚区分。\n已完成标题、运行状态和操作按钮的重新排列，接下来检查长文本在不同窗口宽度下的换行与完整展示。\n同时验证完整摘要、待审批请求和较多会话的滚动位置，确保最后一项的内容与按钮都能完整显示。"
        func add(_ id: String, provider: AgentProvider = .codex, title: String,
                 project: String = "CodeLand", kind: EventKind, message: String,
                 age: Double, request: AgentRequest? = nil) {
            _ = store.apply(AgentEvent(id: "snapshot-\(id)", provider: provider, sessionID: id,
                                       turnID: "layout-snapshot", timestamp: now - age, kind: kind,
                                       title: title, cwd: "/projects/\(project)", message: message,
                                       terminal: TerminalTarget(appBundleID: provider == .codex ? "com.openai.codex" : "com.googlecode.iterm2"),
                                       request: request))
        }
        switch scene {
        case "sessionList":
            add("layout-approval", provider: .claude, title: "验证登录流程与权限提示", project: "web-app",
                kind: .approvalRequested, message: "等待允许执行登录模块的回归测试。", age: 10,
                request: AgentRequest(id: "layout-approval-request", kind: .approval,
                                      title: "允许执行登录模块回归测试？",
                                      detail: "npm run test -- --runInBand src/auth/login.test.ts src/auth/permissions.test.ts --coverage"))
            add("layout-working", title: "调整多会话面板的布局、信息层级与长标题展示，覆盖浮条、菜单栏和顶部刘海三种模式",
                kind: .turnStarted, message: longSummary, age: 25)
            add("layout-completed", provider: .pi, title: "补齐订单查询的边界测试", project: "api-server",
                kind: .turnCompleted, message: "已补充分页与空结果测试，所有测试通过。", age: 120)
            add("layout-failed", title: "检查构建与资源打包", kind: .turnFailed,
                message: "构建失败：资源目录缺少应用图标，需要返回会话继续处理。", age: 300)
            add("layout-disconnected", title: "新会话", kind: .sessionEnded,
                message: "Codex 会话已结束", age: 600)
        case "sessionDetail":
            add("layout-working", title: "调整会话面板布局与信息层级", kind: .turnStarted,
                message: "正在检查卡片间距、会话标题和操作按钮的排列。", age: 5)
            add("layout-disconnected", title: "新会话", kind: .sessionEnded,
                message: "Codex 会话已结束", age: 15)
            selectedID = "codex:layout-disconnected"
        case "sessionOverflow":
            let titles = ["调整面板宽度", "整理会话信息层级", "检查长标题显示", "验证审批操作",
                          "检查浮条展开位置", "整理完成状态", "验证卡片边界", "检查列表末项的完整内容与长摘要"]
            for (index, title) in titles.enumerated() {
                add("layout-overflow-\(index)", title: title,
                    kind: index == 5 ? .turnCompleted : .turnStarted,
                    message: index == titles.count - 1 ? longSummary : "正在验证\(title)，保持状态、摘要和操作区域清晰可见。",
                    age: Double(index * 60 + 5))
            }
            selectedID = "codex:layout-overflow-7"
        default: break
        }
        return true
    }
    #endif
    private func applyDemo(provider: AgentProvider, kind: EventKind, message: String, request: AgentRequest? = nil) {
        let event = AgentEvent(id: UUID().uuidString, provider: provider, sessionID: "demo-\(provider.rawValue)", turnID: "demo-turn", timestamp: Date().timeIntervalSince1970, kind: kind, title: provider == .claude ? "修复登录校验" : provider == .codex ? "优化订单查询" : "补齐测试用例", cwd: "/projects/\(provider == .claude ? "web-app" : provider == .codex ? "api-server" : "test-suite")", message: message, request: request)
        _ = store.apply(event)
    }
    func shutdown() {
        feedbackTask?.cancel()
        server?.stop()
    }
}
