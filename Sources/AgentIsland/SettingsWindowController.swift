import AppKit
import SwiftUI

/// A regular window has its own lifetime and focus, independent of the island's
/// hover and automatic collapse rules. Reopening reuses its existing content.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    let hosting: NSHostingView<SettingsWindowView>

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: SettingsWindowView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Agent Island 设置"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 700, height: 520)
        window.contentView = hosting
        super.init(window: window)
        window.delegate = self
        if !model.demo {
            let restored = window.setFrameUsingName("AgentIslandSettingsWindow")
            window.setFrameAutosaveName("AgentIslandSettingsWindow")
            if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        } else { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(section: SettingsSection, activate: Bool = true) {
        model.settingsWindowSection = section
        model.showingSettings = false
        model.expanded = false
        model.isSettingsWindowVisible = true
        model.refreshIntegrations()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        if activate { NSApp.activate() }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.isSettingsWindowVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { model.isSettingsWindowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { model.isSettingsWindowVisible = true }
}
