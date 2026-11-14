import SwiftUI
import IslandCore

/// The same controls back the island's quick settings and the full window.
struct QuickPreferencesControls: View {
    @ObservedObject var model: AppModel

    private var collapseDelayOptions: [TimeInterval] {
        let common: [TimeInterval] = [0, 0.1, 0.2, 0.3, 0.5, 1, 2]
        return common.contains(model.collapseDelay) ? common : (common + [model.collapseDelay]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.menuBarOnly {
                Toggle("任务完成时自动展开", isOn: $model.autoExpand)
                    .onChange(of: model.autoExpand) { _, _ in model.savePreferences() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("显示方式", selection: Binding(get: { model.presentation }, set: { model.setPresentation($0) })) {
                    ForEach(IslandPresentation.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }.pickerStyle(.segmented)
                if model.floating {
                    HStack {
                        Text("移入展开，拖动名称区域可移动。")
                        Spacer()
                        Button("重置位置") { model.resetFloatingPosition() }.buttonStyle(.plain)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                } else if model.menuBarOnly {
                    Text("点击菜单栏图标展开，点击外部收起。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("自动收回延迟")
                Picker("自动收回延迟", selection: Binding(get: { model.collapseDelay }, set: { model.setCollapseDelay($0) })) {
                    ForEach(collapseDelayOptions, id: \.self) { delay in
                        Text(delay == 0 ? "立即" : String(format: "%.1f 秒", delay)).tag(delay)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                Text("点击外部收回；刘海和浮条也会在鼠标移出后收回。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("系统完成通知", isOn: Binding(get: { model.notificationsEnabled }, set: { model.enableNotifications($0) }))
        }
        .font(.system(size: 12))
        .toggleStyle(.switch)
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.settingsWindowSection.title).font(.system(size: 24, weight: .semibold))
                        Text(model.settingsWindowSection == .agents ? "连接你的编程工具，管理接入与启动方式。" : "调整面板的显示与启动方式。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !model.statusMessage.isEmpty { feedback }
                    if model.settingsWindowSection == .agents { agentSettings }
                    else { generalSettings }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                Text("Agent Island").font(.system(size: 13, weight: .semibold))
            }.padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 22)
            ForEach(SettingsSection.allCases, id: \.rawValue) { section in
                Button { model.settingsWindowSection = section } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.settingsWindowSection == section ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityAddTraits(model.settingsWindowSection == section ? .isSelected : [])
            }
            Spacer()
            if model.demo {
                Text("演示模式").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 156)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            QuickPreferencesControls(model: model)
            Divider()
            Toggle("登录 Mac 时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).disabled(model.demo)
            if model.demo {
                Button("重新载入演示会话") { model.loadDemo() }.buttonStyle(.bordered)
            }
            Text("Agent Island · v0.1.0").font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("点击安装才会更新配置，并备份原文件。重启对应 Agent 后生效。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach([AgentProvider.claude, .codex, .pi], id: \.rawValue) { provider in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    }
                    Text(agentDescription(provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if provider != .pi {
                            Button("安装接入") { model.install(provider) }
                            Button("移除") { model.install(provider, remove: true) }
                        }
                        Button("复制启动命令") { model.copyLaunchCommand(provider) }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .disabled(model.integrationBusy || model.demo)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
            }
            if !model.integrationOutput.isEmpty {
                Text(model.integrationOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Terminal 与 iTerm2 优先定位对应会话；其他终端先激活应用。首次精确跳转可能需要系统“自动化”授权。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func agentDescription(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "状态、单次审批、单选或文本问答。"
        case .codex: return "状态与审批。安装后，在 Codex /hooks 中检查并信任接入。"
        case .pi: return "通过扩展监控任务；启动命令添加 --island-approve-tools 可启用工具审批。"
        }
    }

    private var feedback: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(model.statusMessage).font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.statusMessage = "" } label: {
                Image(systemName: "xmark").frame(width: 20, height: 20)
            }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
