import SwiftUI
import IslandCore

private let islandBackground = Color(red: 0.045, green: 0.05, blue: 0.055)
private let surface = Color(red: 0.12, green: 0.135, blue: 0.145)
private let accent = Color(red: 0.68, green: 0.84, blue: 0.73)
private let separator = Color.white.opacity(0.075)

struct IslandView: View {
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
                heading.modifier(IslandReveal(progress: progress, index: 0))
                if !model.statusMessage.isEmpty {
                    feedback.modifier(IslandReveal(progress: progress, index: 0))
                }
                if model.showingSettings {
                    QuickSettingsView(model: model)
                        .modifier(IslandReveal(progress: progress, index: 1))
                } else {
                    sessions
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(model.expanded && progress > 0.7)
            .disabled(!model.expanded)
            .accessibilityHidden(!model.expanded)
        }
        .frame(width: width, height: height, alignment: .top)
        .foregroundStyle(Color(white: 0.94))
        .preferredColorScheme(.dark)
        .onExitCommand {
            if model.showingSettings { model.showingSettings = false }
            else { model.expanded = false }
        }
    }

    @MainActor static func contentHeight(for model: AppModel, notchHeight: CGFloat) -> CGFloat {
        let top: CGFloat = model.menuBarOnly ? 0 : max(notchHeight, 36)
        let feedback: CGFloat = model.statusMessage.isEmpty ? 0 : 40
        if model.showingSettings { return top + QuickSettingsView.contentHeight(for: model) + feedback }
        if model.sessions.isEmpty { return top + 220 + feedback }
        let detail = model.sessions.first(where: { $0.id == model.selectedID }).map(SessionCard.detailHeight(for:)) ?? 0
        return top + 54 + CGFloat(min(model.sessions.count, 5)) * 104 + detail + feedback
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
        HStack(spacing: 0) {
            FloatingDragHandle(onClick: { model.expanded.toggle() })
                .frame(width: max(0, min(width - 40, 300) - 36), height: 36)
                .overlay {
                    HStack(spacing: 0) {
                        Image(systemName: "waveform").foregroundStyle(accent)
                        Text("Agent Island").fontWeight(.medium).padding(.leading, 8)
                        Spacer(minLength: 8)
                        Circle().fill(model.pendingCount > 0 ? .orange : accent).frame(width: 4, height: 4)
                        Text(model.pendingCount > 0 ? "\(model.pendingCount) 待处理" : "\(model.runningCount) 运行")
                            .foregroundStyle(.secondary).padding(.leading, 5)
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 20)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                }
                .help("拖动浮条可移动；点击展开或收起")
            Button { model.expanded.toggle() } label: {
                Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.expanded ? "收起 Agent Island" : "展开 Agent Island")
            .accessibilityLabel(model.expanded ? "收起 Agent Island" : "展开 Agent Island")
        }
        .frame(maxWidth: .infinity)
    }

    private var heading: some View {
        HStack(spacing: 9) {
            Text("Agent Island").font(.system(size: 12, weight: .medium))
            Text(model.demo ? "演示 · \(model.sessions.count) 个会话" : "\(model.sessions.count) 个会话")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(model.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Button { model.showingSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 26)
            }.help("快捷设置")
            Button { model.expanded = false } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 26)
            }.help("收起面板")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 13)
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
                .modifier(IslandReveal(progress: progress, index: 1))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionCard(model: model, session: session, selected: model.selectedID == session.id)
                                .modifier(IslandReveal(progress: progress, index: min(index + 1, 4)))
                        }
                    }
                }.scrollIndicators(.hidden)
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
    private var amount: CGFloat {
        let start = 0.12 + CGFloat(index) * 0.085
        let value = min(1, max(0, (pow(min(1, max(0, progress)), 1.06) - start) / (0.72 - start)))
        return value * value * (3 - 2 * value)
    }
    func body(content: Content) -> some View {
        content.opacity(Double(amount)).offset(y: -7 * (1 - amount))
    }
}

struct SessionCard: View {
    @ObservedObject var model: AppModel
    let session: SessionState
    let selected: Bool

    static func detailHeight(for session: SessionState) -> CGFloat {
        guard let request = session.pendingRequests.first else { return 100 }
        return request.kind == .question ? 268 : 84
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
        case .needsApproval, .needsInput: return Color(red: 0.91, green: 0.73, blue: 0.43)
        case .failed: return .red
        case .working: return Color(red: 0.67, green: 0.74, blue: 0.96)
        default: return accent
        }
    }
    private var statusLabel: String { session.status.displayName }
    private var statusSymbol: String {
        switch session.status {
        case .needsApproval: return "exclamationmark.circle"
        case .needsInput: return "bubble.left"
        case .working: return "circle.dotted"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "link.badge.plus"
        case .idle: return "circle"
        }
    }
    private var projectTitle: String {
        let project = session.cwd.isEmpty ? "" : URL(fileURLWithPath: session.cwd).lastPathComponent
        let title = session.title.isEmpty ? "新会话" : session.title
        return project.isEmpty ? title : "\(project) · \(title)"
    }
    private var terminalName: String? {
        guard let bundleID = session.terminal?.appBundleID, !bundleID.isEmpty else { return nil }
        switch bundleID {
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm2"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.openai.codex": return "Codex.app"
        default: return "终端"
        }
    }
    private var age: String {
        let seconds = max(0, Date().timeIntervalSince1970 - session.lastEventAt)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时" }
        return "\(Int(seconds / 86_400)) 天"
    }
    private var summary: String {
        if !session.message.isEmpty { return session.message }
        return session.pendingRequests.first?.title ?? statusLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                avatar.padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    titleLine
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineSpacing(3).lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    bottomLine
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(height: 104, alignment: .top)
            if selected {
                detail
                    .padding(.leading, 55)
                    .padding(.trailing, 13)
                    .frame(height: Self.detailHeight(for: session), alignment: .top)
            }
        }
        .background(selected ? Color.white.opacity(0.022) : .clear)
        .overlay(alignment: .top) { separator.frame(height: 0.5).padding(.horizontal, 13) }
    }

    private var avatar: some View {
        Text(session.provider.glyph)
            .font(.system(size: session.provider.glyph.count > 1 ? 11 : 20, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private var titleLine: some View {
        HStack(spacing: 10) {
            Button { model.selectedID = selected ? nil : session.id } label: {
                HStack(spacing: 4) {
                    Text(projectTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(projectTitle) · 点击\(selected ? "收起" : "查看")详情")
            HStack(spacing: 5) {
                Text(session.provider.displayName).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 4))
                if let terminalName {
                    Text(terminalName).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(age).padding(.leading, 2)
            }.font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 16)
    }

    private var bottomLine: some View {
        HStack(spacing: 7) {
            Label(statusLabel, systemImage: statusSymbol).foregroundStyle(statusColor)
                .font(.system(size: 10)).fixedSize()
            if let request = session.pendingRequests.first, request.kind == .approval, let command = request.detail {
                Text(command.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(command)
            } else if session.pendingRequests.count > 1 {
                Text("\(session.pendingRequests.count) 个请求").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let request = session.pendingRequests.first, request.kind == .approval {
                HStack(spacing: 6) {
                    Button { model.respond(session: session, request: request, decision: "allow") } label: {
                        Label("允许一次", systemImage: "checkmark")
                    }.buttonStyle(IslandActionStyle(primary: true))
                    Button("拒绝") { model.respond(session: session, request: request, decision: "deny") }
                        .buttonStyle(IslandActionStyle())
                }.fixedSize()
            } else if let request = session.pendingRequests.first, request.kind == .question {
                Button { model.selectedID = selected ? nil : session.id } label: {
                    Label(selected ? "收起回答" : "回答问题", systemImage: "bubble.left")
                }.buttonStyle(IslandActionStyle()).fixedSize()
            } else {
                Button { model.jump(session) } label: {
                    Label(session.status.needsAttention ? "回终端处理" : "查看会话", systemImage: "arrow.up.right")
                }.buttonStyle(IslandActionStyle(quiet: true)).fixedSize()
            }
        }.frame(height: 24)
    }

    @ViewBuilder private var detail: some View {
        if let request = session.pendingRequests.first, request.kind == .question {
            ScrollView {
                RequestView(model: model, session: session, request: request).id(request.id)
                    .padding(.vertical, 8)
                if session.pendingRequests.count > 1 {
                    Text("还有 \(session.pendingRequests.count - 1) 个请求等待处理")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }.scrollIndicators(.hidden)
        } else if let request = session.pendingRequests.first {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(request.title).lineLimit(1)
                    Spacer()
                    if session.pendingRequests.count > 1 { Text("还有 \(session.pendingRequests.count - 1) 个请求").foregroundStyle(.secondary) }
                    Button { model.jump(session) } label: { Label("返回终端", systemImage: "arrow.up.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.system(size: 10))
                ScrollView {
                    Text(request.detail ?? request.title).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9).frame(height: 45)
                .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            }.padding(.top, 2)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 48)
                HStack {
                    if session.status.needsAttention {
                        Text("此请求需要在原 Agent 中处理。").font(.system(size: 10)).foregroundStyle(statusColor)
                    }
                    Spacer()
                    Button { model.jump(session) } label: { Label("返回终端", systemImage: "arrow.up.right") }
                        .buttonStyle(IslandActionStyle(quiet: true))
                }
            }.padding(.top, 3)
        }
    }
}

private struct IslandActionStyle: ButtonStyle {
    var primary = false
    var quiet = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Color(red: 0.14, green: 0.21, blue: 0.17) : Color.white.opacity(0.67))
            .padding(.horizontal, quiet ? 2 : 9)
            .frame(height: 24)
            .background(primary ? accent : configuration.isPressed ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if !primary && !quiet { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.7) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct RequestView: View {
    @ObservedObject var model: AppModel
    let session: SessionState
    let request: AgentRequest
    @State private var selectedOption = ""
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let detail = request.detail, !detail.isEmpty {
                ScrollView { Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100).padding(10).background(islandBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            if request.kind == .approval {
                HStack(spacing: 8) {
                    Button { model.respond(session: session, request: request, decision: "allow") } label: { Label("允许一次", systemImage: "checkmark") }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    Button("拒绝") { model.respond(session: session, request: request, decision: "deny") }.buttonStyle(.bordered)
                    Spacer()
                    Button { model.jump(session) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("返回终端")
                }.font(.system(size: 11))
            } else {
                if let options = request.options {
                    ForEach(options, id: \.id) { option in
                        Button { selectedOption = option.label } label: {
                            HStack(spacing: 8) { Image(systemName: selectedOption == option.label ? "largecircle.fill.circle" : "circle").foregroundStyle(selectedOption == option.label ? accent : .secondary); Text(option.label); Spacer() }.font(.system(size: 12)).padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(selectedOption == option.label ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                TextField("补充说明或自定义回答", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).font(.system(size: 12))
                HStack {
                    Button("发送回答") {
                        let text = [selectedOption, answer.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "；")
                        model.respond(session: session, request: request, decision: "answer", answer: text)
                    }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        .disabled(selectedOption.isEmpty && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("返回终端") { model.jump(session) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.system(size: 11))
            }
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
