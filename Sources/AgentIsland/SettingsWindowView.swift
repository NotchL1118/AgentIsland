import SwiftUI
import IslandCore
import IslandIntegrations

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
    @State private var confirmingFullUninstall = false

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
                    if model.settingsWindowSection == .agents { agentSettings.onAppear { model.refreshIntegrations() } }
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
            Text("点击安装才会修改 Agent 配置。卸载时按字节还原原文件；即使先删除了应用，残留的 hook 也只会静默跳过，不会影响 Agent。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(AdapterRegistry.all.map(\.descriptor), id: \.provider.rawValue) { descriptor in
                agentCard(descriptor)
            }
            HStack {
                Button("完全卸载…", role: .destructive) { confirmingFullUninstall = true }
                    .disabled(model.integrationBusy || model.demo)
                Text("移除所有 Agent 中的接入、信任记录与 Agent Island 自身文件。之后可直接删除应用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11)).buttonStyle(.bordered)
            .confirmationDialog("完全卸载 Agent Island 接入？", isPresented: $confirmingFullUninstall) {
                Button("完全卸载", role: .destructive) { model.uninstallEverything() }
            } message: {
                Text("会还原 Claude Code 与 Codex 的配置，删除对应的 Codex 信任记录与 Agent Island 自身文件。")
            }
            if !model.integrationOutput.isEmpty {
                Text(model.integrationOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Terminal 与 iTerm2 优先定位对应会话；Codex Desktop 与其他应用会被激活。首次精确跳转可能需要系统“自动化”授权。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func agentCard(_ descriptor: AgentDescriptor) -> some View {
        let status = model.integrationStatuses[descriptor.provider]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(descriptor.provider.displayName).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let status { statusBadge(status) }
            }
            Text(descriptor.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                VStack(alignment: .leading, spacing: 3) {
                    if let path = status.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled) }
                    if let trusted = status.trusted { Text("Codex 信任：\(trusted.0)/\(trusted.1)").font(.system(size: 11)).foregroundStyle(.secondary) }
                    ForEach(status.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                    ForEach(status.leftovers, id: \.self) { Text("残留：" + $0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange) }
                }
            }
            HStack(spacing: 8) {
                switch descriptor.injection {
                case .hookConfig:
                    Button(status?.state == .installed ? "重新安装" : "安装接入") { model.install(descriptor.provider) }
                    Button("移除") { model.install(descriptor.provider, remove: true) }
                        .disabled(status?.state == .notInstalled && status?.leftovers.isEmpty == true)
                case .sessionExtension:
                    Button("复制启动命令") { model.copyLaunchCommand(descriptor.provider) }
                }
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

    private func statusBadge(_ status: IntegrationStatus) -> some View {
        let (label, color): (String, Color) = switch status.state {
        case .installed: (status.trusted.map { $0.0 < $0.1 } == true ? "待信任" : "已接入", status.trusted.map { $0.0 < $0.1 } == true ? .orange : .green)
        case .outdated: ("需更新", .orange)
        case .notInstalled: ("未接入", .secondary)
        case .sessionOnly: ("按会话加载", .secondary)
        }
        return Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
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
