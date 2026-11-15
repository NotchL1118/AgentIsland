import SwiftUI
import AppKit
import IslandCore

private let islandBackground = Color(red: 0.045, green: 0.05, blue: 0.055)
private let surface = Color(red: 0.12, green: 0.135, blue: 0.145)
private let accent = Color(red: 0.68, green: 0.84, blue: 0.73)
private let separator = Color.white.opacity(0.075)

struct IslandView: View {
    nonisolated static let expandedWidth: CGFloat = 1040
    private static let sessionSpacing: CGFloat = 12
    @ObservedObject var model: AppModel
    var width: CGFloat
    var height: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var progress: CGFloat = 1

    /// The AppKit surface animates its mask, while this layout keeps its final width.
    var body: some View {
        VStack(spacing: 0) {
            if !model.menuBarOnly { compactBar }
            VStack(spacing: 0) {
                heading.modifier(IslandReveal(progress: progress, index: 0, menuBar: model.menuBarOnly))
                if !model.statusMessage.isEmpty {
                    feedback.modifier(IslandReveal(progress: progress, index: 0, menuBar: model.menuBarOnly))
                }
                if model.showingSettings {
                    QuickSettingsView(model: model)
                        .modifier(IslandReveal(progress: progress, index: 1, menuBar: model.menuBarOnly))
                } else {
                    sessions
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(model.expanded && progress > (model.menuBarOnly ? 0.92 : 0.7))
            .disabled(!model.expanded)
            .accessibilityHidden(!model.expanded || model.menuBarOnly && progress <= 0.92)
        }
        .frame(width: width, height: height, alignment: .top)
        .foregroundStyle(Color(white: 0.94))
        .preferredColorScheme(.dark)
        .onExitCommand {
            if model.showingSettings { model.showingSettings = false }
            else { model.expanded = false }
        }
    }

    @MainActor static func contentHeight(for model: AppModel, notchHeight: CGFloat, width: CGFloat = expandedWidth) -> CGFloat {
        let top: CGFloat = model.menuBarOnly ? 0 : max(notchHeight, 36)
        let feedback: CGFloat = model.statusMessage.isEmpty ? 0 : 40
        if model.showingSettings { return top + QuickSettingsView.contentHeight(for: model) + feedback }
        if model.sessions.isEmpty { return top + 220 + feedback }
        let visibleSessions = model.sessions.prefix(5)
        let cardsHeight = visibleSessions.reduce(CGFloat.zero) {
            $0 + SessionCard.contentHeight(for: $1, cardWidth: width - 48)
        }
        return top + 42 + 16 + 4 + cardsHeight
            + CGFloat(max(0, visibleSessions.count - 1)) * sessionSpacing + feedback
    }

    @ViewBuilder private var compactBar: some View {
        if model.floating {
            floatingBar
        } else {
            fixedCompactBar
        }
    }

    private var fixedCompactBar: some View {
        Button { model.expanded.toggle() } label: {
            HStack(spacing: 0) {
                if notchWidth > 0 {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                    // The physical camera remains empty throughout the animation.
                    Color.clear.frame(width: notchWidth, height: max(notchHeight, 36))
                    HStack(spacing: 5) {
                        Circle().fill(model.pendingCount > 0 ? .orange : accent).frame(width: 4, height: 4)
                        Text(model.pendingCount > 0 ? "\(model.pendingCount) 待处理" : "\(model.runningCount) 运行")
                    }.font(.system(size: 10, weight: .medium)).frame(maxWidth: .infinity)
                } else {
                    Image(systemName: "waveform").foregroundStyle(accent)
                    Text("Agent Island").fontWeight(.medium).padding(.leading, 8)
                    Spacer(minLength: 8)
                    Circle().fill(model.pendingCount > 0 ? .orange : accent).frame(width: 4, height: 4)
                    Text(model.pendingCount > 0 ? "\(model.pendingCount) 待处理" : "\(model.runningCount) 运行")
                        .foregroundStyle(.secondary).padding(.leading, 5)
                    Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).padding(.leading, 8)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, notchWidth > 0 ? 0 : 20)
            .frame(width: min(width - 40, notchWidth > 0 ? max(360, notchWidth + 160) : 300), height: max(notchHeight, 36))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.expanded ? "收起 Agent Island" : "展开 Agent Island")
        .accessibilityLabel(model.expanded ? "收起 Agent Island" : "展开 Agent Island")
        .frame(maxWidth: .infinity)
    }

    private var floatingBar: some View {
        let bar = FloatingBarLayout(sessions: model.sessions, maximumWidth: width - 40)
        return FloatingDragHandle(
            onClick: { model.expanded.toggle() },
            onClickAt: { point in
                if let item = bar.items.first(where: { $0.frame.contains(point) }) {
                    revealFloatingSession(item.sessionID)
                } else if bar.overflowFrame?.contains(point) == true {
                    revealFloatingSessions()
                } else {
                    model.expanded.toggle()
                }
            },
            onDoubleClick: { model.resetFloatingPosition() },
            regions: floatingRegions(for: bar)
        )
        .frame(width: bar.width, height: 36)
        .overlay {
            ZStack(alignment: .topLeading) {
                if let frame = bar.brandFrame {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(accent)
                        Text("Agent Island").fontWeight(.medium)
                    }
                    .font(.system(size: 11))
                    .frame(width: frame.width, height: 36)
                    .position(x: frame.midX, y: 18)
                }
                ForEach(bar.items) { item in
                    HStack(spacing: 6) {
                        Text(item.provider.glyph)
                            .font(.system(size: item.provider.glyph.count > 1 ? 11 : 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(floatingProviderColor(item.provider))
                            .frame(width: 18)
                        if !bar.iconsOnly {
                            Text(item.label).font(.system(size: 11, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Circle().fill(floatingStatusColor(item.status)).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, bar.iconsOnly ? 0 : 6)
                    .frame(width: item.frame.width, height: 36)
                    .position(x: item.frame.midX, y: 18)
                }
                if let frame = bar.overflowFrame {
                    Text("+\(bar.overflowCount)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: frame.width, height: 36)
                        .position(x: frame.midX, y: 18)
                }
                Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: bar.chevronFrame.width, height: 36)
                    .position(x: bar.chevronFrame.midX, y: 18)
            }
            .frame(width: bar.width, height: 36)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private func floatingRegions(for bar: FloatingBarLayout) -> [FloatingDragRegion] {
        var regions = bar.items.map { item in
            FloatingDragRegion(frame: item.frame, label: item.tooltip) { revealFloatingSession(item.sessionID) }
        }
        if let frame = bar.brandFrame {
            regions.append(FloatingDragRegion(frame: frame, label: "Agent Island · 等待 Agent 接入；双击归位") { model.expanded.toggle() })
        }
        if let frame = bar.overflowFrame {
            regions.append(FloatingDragRegion(frame: frame, label: "查看其余 \(bar.overflowCount) 个 Agent") { revealFloatingSessions() })
        }
        regions.append(FloatingDragRegion(frame: bar.chevronFrame, label: model.expanded ? "收起任务；双击归位" : "展开任务；双击归位") { model.expanded.toggle() })
        return regions
    }

    private func revealFloatingSession(_ id: String) {
        guard model.sessions.contains(where: { $0.id == id }) else { return }
        model.showingSettings = false
        model.selectedID = id
        model.expanded = true
        model.compactSessionRevealID = UUID()
    }

    private func revealFloatingSessions() {
        model.showingSettings = false
        model.selectedID = nil
        model.expanded = true
        model.compactSessionRevealID = UUID()
    }

    private func floatingProviderColor(_ provider: AgentProvider) -> Color {
        switch provider {
        case .claude: return Color(red: 0.93, green: 0.75, blue: 0.66)
        case .codex: return Color(red: 0.69, green: 0.78, blue: 0.96)
        default: return accent
        }
    }

    private func floatingStatusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .needsApproval, .needsInput: return .orange
        case .failed: return .red
        case .idle, .disconnected: return .gray
        default: return accent
        }
    }

    private var heading: some View {
        HStack(spacing: 9) {
            if model.sessions.isEmpty { Text("Agent Island").font(.system(size: 12, weight: .medium)) }
            Text(model.demo ? "演示 · \(model.sessions.count) 个会话" : "\(model.sessions.count) 个会话")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(model.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if !model.showingSettings {
                Button { model.clearCompletedSessions() } label: {
                    Label("清空已完成", systemImage: "trash")
                }
                .buttonStyle(IslandActionStyle())
                .fixedSize()
                .disabled(model.completedCount == 0)
                .opacity(model.completedCount == 0 ? 0.4 : 1)
                .help(model.completedCount == 0 ? "暂无已完成记录" : "清空 \(model.completedCount) 条已完成记录")
                .accessibilityLabel("清空已完成记录")
            }
            Button { model.showingSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 26)
            }.help("快捷设置")
            Button { model.expanded = false } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 26)
            }.help("收起面板")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .frame(height: 42)
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "terminal").font(.system(size: 29)).foregroundStyle(accent)
                    Text("让你的 Agent 出现在这里").font(.system(size: 16, weight: .medium))
                    Text(model.serverReady || model.demo ? "先在设置中接入工具，再从终端开始任务。" : "暂时无法接收任务，请检查接入设置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("设置接入") { model.requestSettingsWindow(.agents) }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .modifier(IslandReveal(progress: progress, index: 1, menuBar: model.menuBarOnly))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Self.sessionSpacing) {
                            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionCard(model: model, session: session, selected: model.selectedID == session.id)
                                    .modifier(IslandReveal(progress: progress, index: min(index + 1, 4), menuBar: model.menuBarOnly))
                                    .id(session.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: model.compactSessionRevealID) { _, _ in
                        if let id = model.selectedID ?? model.sessions.first?.id {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                    .onAppear {
                        if let id = model.selectedID { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
    }

    private var feedback: some View {
        HStack(spacing: 8) {
            Text(model.statusMessage).lineLimit(2).help(model.statusMessage)
            Spacer(minLength: 8)
            Button { model.statusMessage = "" } label: {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .frame(height: 40)
    }
}

private struct IslandReveal: ViewModifier {
    let progress: CGFloat
    let index: Int
    let menuBar: Bool
    private var amount: CGFloat {
        if menuBar { return MenuBarCollapse.contentVisibility(progress: progress, index: index) }
        let start = 0.12 + CGFloat(index) * 0.085
        let value = min(1, max(0, (pow(min(1, max(0, progress)), 1.06) - start) / (0.72 - start)))
        return value * value * (3 - 2 * value)
    }
    func body(content: Content) -> some View {
        content.opacity(Double(amount)).offset(y: -(menuBar ? 6 : 7) * (1 - amount))
    }
}

struct SessionCard: View {
    @ObservedObject var model: AppModel
    let session: SessionState
    let selected: Bool
    @State private var hovered = false

    private static func messageSummary(for session: SessionState) -> String {
        session.message.trimmingCharacters(in: .whitespacesAndNewlines)
            == session.title.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : session.message
    }
    /// Estimate the natural card height for window placement. The card itself
    /// has no height cap; all overflow scrolls with the session list.
    static func contentHeight(for session: SessionState, cardWidth: CGFloat) -> CGFloat {
        let textWidth = cardWidth - 272 // Padding, avatar, actions and gaps.
        let title = session.title.isEmpty ? "新会话" : session.title
        var textHeight = 20 + 8 + SessionTextLayout.height(title, width: textWidth, size: 13, weight: .medium)
        let summary = messageSummary(for: session)
        if !summary.isEmpty {
            textHeight += 8 + SessionTextLayout.height(summary, width: textWidth, size: 12, lineSpacing: 4)
        }
        var height = 32 + max(72, textHeight)
        if !session.pendingRequests.isEmpty {
            height += 1 + 32 + session.pendingRequests.reduce(CGFloat.zero) {
                $0 + RequestView.contentHeight(for: $1, width: cardWidth - 32)
            } + CGFloat(session.pendingRequests.count - 1) * 14
        }
        if !session.cwd.isEmpty {
            height += max(36, 20 + SessionTextLayout.height(session.cwd, width: cardWidth - 51, size: 10))
        }
        return height
    }
    private var color: Color {
        switch session.provider {
        case .claude: return Color(red: 0.93, green: 0.75, blue: 0.66)
        case .codex: return Color(red: 0.69, green: 0.78, blue: 0.96)
        default: return accent
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .needsApproval, .needsInput: return Color(red: 0.96, green: 0.76, blue: 0.43)
        case .failed: return Color(red: 0.98, green: 0.58, blue: 0.56)
        case .working: return Color(red: 0.69, green: 0.78, blue: 0.96)
        case .idle, .disconnected: return Color(white: 0.60)
        case .completed: return accent
        }
    }
    private var statusSymbol: String {
        switch session.status {
        case .needsApproval: return "exclamationmark.circle"
        case .needsInput: return "bubble.left"
        case .working: return "circle.dotted"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "link"
        case .idle: return "circle"
        }
    }
    private var projectName: String {
        session.cwd.isEmpty ? session.provider.displayName : URL(fileURLWithPath: session.cwd).lastPathComponent
    }
    private var taskTitle: String { session.title.isEmpty ? "新会话" : session.title }
    private var terminalName: String? {
        guard let bundleID = session.terminal?.appBundleID, !bundleID.isEmpty else { return nil }
        switch bundleID {
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm2"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.openai.codex": return "Codex Desktop"
        default: return "终端"
        }
    }
    private var jumpLabel: String {
        if session.terminal?.appBundleID == "com.openai.codex" { return "打开 Codex" }
        return session.status.needsAttention ? "回终端处理" : "查看会话"
    }
    private var age: String {
        let seconds = max(0, Date().timeIntervalSince1970 - session.lastEventAt)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }
    private var summary: String { Self.messageSummary(for: session) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 8) {
                    identityLine
                    Text(taskTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.91))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .trailing, spacing: 16) {
                    statusBadge
                    actions
                }
                .frame(width: 176, alignment: .topTrailing)
            }
            .frame(minHeight: 72, alignment: .top)
            .padding(16)
            requestContent
            workingDirectory
        }
        .background(Color.white.opacity(selected ? 0.085 : hovered ? 0.075 : 0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? color.opacity(0.45) : Color.white.opacity(hovered ? 0.21 : 0.13), lineWidth: 1)
        }
        .onHover { hovered = $0 }
    }

    private var avatar: some View {
        Text(session.provider.glyph)
            .font(.system(size: session.provider.glyph.count > 1 ? 13 : 23, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var identityLine: some View {
        HStack(spacing: 8) {
            Text(projectName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                .help(session.cwd.isEmpty ? taskTitle : session.cwd)
            if !session.cwd.isEmpty {
                Text(session.provider.displayName).foregroundStyle(color.opacity(0.85))
                    .fixedSize()
            }
            if let terminalName {
                Text("·").foregroundStyle(.tertiary)
                Text(terminalName).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(age).foregroundStyle(.secondary).fixedSize()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }

    private var statusBadge: some View {
        Label(session.status.displayName, systemImage: statusSymbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9).frame(height: 24)
            .background(statusColor.opacity(0.11), in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.jump(session) } label: {
                Label(jumpLabel, systemImage: "arrow.up.right")
            }.buttonStyle(IslandActionStyle()).fixedSize()
                .help(session.status.needsAttention ? "请在原 Agent 中处理；面板仅展示状态" : "返回对应会话")
            Button { model.removeSession(session.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IslandActionStyle())
            .help("删除这条记录")
            .accessibilityLabel("删除记录：\(projectName) · \(taskTitle)")
        }
    }

    @ViewBuilder private var requestContent: some View {
        if !session.pendingRequests.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                separator.frame(height: 1).padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.pendingRequests) { request in
                        RequestView(request: request)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    @ViewBuilder private var workingDirectory: some View {
        if !session.cwd.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "folder")
                Text(session.cwd).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 36, alignment: .leading)
            .overlay(alignment: .top) { separator.frame(height: 1).padding(.horizontal, 16) }
        }
    }

}

private enum SessionTextLayout {
    static func height(_ text: String, width: CGFloat, size: CGFloat,
                       weight: NSFont.Weight = .regular, monospaced: Bool = false,
                       lineSpacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        return ceil(bounds.height) + 2
    }
}

private struct IslandActionStyle: ButtonStyle {
    var primary = false
    var quiet = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Color(red: 0.14, green: 0.21, blue: 0.17) : Color.white.opacity(0.67))
            .padding(.horizontal, quiet ? 2 : 9)
            .frame(height: 28)
            .background(primary ? accent : configuration.isPressed ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if !primary && !quiet { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.7) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct RequestView: View {
    let request: AgentRequest

    static func contentHeight(for request: AgentRequest, width: CGFloat) -> CGFloat {
        var height = SessionTextLayout.height(request.title, width: width, size: 12, weight: .medium)
        if let detail = request.detail, !detail.isEmpty {
            height += 10 + 20 + SessionTextLayout.height(detail, width: width - 20, size: 11, monospaced: true)
        }
        for option in request.options ?? [] {
            height += 10 + 8 + SessionTextLayout.height("• \(option.label)", width: width, size: 12)
        }
        return height + 10 + SessionTextLayout.height("仅展示提醒，请返回原 Agent 处理。", width: width, size: 11)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let detail = request.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(islandBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            if let options = request.options {
                ForEach(options, id: \.id) { option in
                    Text("• \(option.label)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled).padding(.vertical, 4)
                }
            }
            Text("仅展示提醒，请返回原 Agent 处理。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct QuickSettingsView: View {
    @ObservedObject var model: AppModel

    @MainActor static func contentHeight(for model: AppModel) -> CGFloat {
        // Header42 + heading24 + sharedcontrols + settingslink + inner/bottom spacing.
        model.menuBarOnly ? 322 : model.floating ? 352 : 330
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("快捷设置").font(.system(size: 15, weight: .medium))
                Spacer()
                Button("返回会话") { model.showingSettings = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    QuickPreferencesControls(model: model)
                    HStack {
                        Spacer()
                        Button { model.requestSettingsWindow(.agents) } label: {
                            Label("Agent 接入与更多设置…", systemImage: "arrow.up.forward.app")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }.padding(.top, 2)
                }
            }.scrollIndicators(.hidden)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 17)
        .padding(.bottom, 17)
    }
}
