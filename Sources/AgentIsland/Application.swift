import AppKit
import SwiftUI
import Combine
import UserNotifications
import IslandCore

class IslandPanel: NSPanel {
    var isUserDragging = false
    var allowsFreePosition = false
    var dragDidBegin: (() -> Void)?
    var dragDidEnd: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsFreePosition ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var panel: IslandPanel!
    private var surface: LiquidPanelView!
    private let motion = IslandMotionDriver()
    private let autoCollapse = PanelAutoCollapseDriver()
    private var hoverExpansion = PanelHoverExpansion()
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var modeMenuItems: [NSMenuItem] = []
    private var subscriptions = Set<AnyCancellable>()
    private var hoverMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var isPresentationDiagnostic = false
    private var layout: PanelLayout?
    private var wasExpanded = false
    private var previousPresentation: IslandPresentation?
    private var positionResetID: UUID?
    private var floatingPosition: SavedPanelPosition?
    private var lastFloatingAnchor: CGPoint?
    private static let floatingPositionKey = "floatingPanelPosition"

    private struct PanelLayout {
        var width: CGFloat
        var height: CGFloat
        var notchWidth: CGFloat
        var notchHeight: CGFloat
        var closedWidth: CGFloat
        var closedHeight: CGFloat
        var attached: Bool
        var preferredAnchor: CGPoint
        var visibleFrame: CGRect
        var presentation: IslandPresentation
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        #if DEBUG
        isPresentationDiagnostic = demo && (CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--presentation-checks"))
        #endif
        model = AppModel(demo: demo)
        if demo { model.selectedID = nil }
        if model.menuBarOnly { model.expanded = false }
        if !demo, let data = UserDefaults.standard.data(forKey: Self.floatingPositionKey) {
            floatingPosition = try? JSONDecoder().decode(SavedPanelPosition.self, from: data)
        }
        positionResetID = model.positionResetID
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.dragDidBegin = { [weak self] in
            guard let self else { return }
            self.autoCollapse.reset()
            self.motion.snap(to: self.model.expanded ? 1 : 0)
        }
        panel.dragDidEnd = { [weak self] in self?.finishFloatingDrag() }
        surface = LiquidPanelView(rootView: IslandView(model: model, width: 800, height: 434, notchWidth: 0, notchHeight: 0))
        panel.contentView = surface
        autoCollapse.context = { [weak self] in
            guard let self, !self.isPresentationDiagnostic else { return nil }
            return .init(expanded: self.model.expanded, presentation: self.model.presentation,
                         pointerInside: self.surface.containsScreenPoint(NSEvent.mouseLocation),
                         isDragging: self.panel.isUserDragging, delay: self.model.collapseDelay)
        }
        autoCollapse.onCollapse = { [weak self] in self?.model.expanded = false }
        motion.onFrame = { [weak self] progress in self?.renderSurface(progress: progress) }
        makeStatusMenu(demo: demo)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutPanel() }
        }.store(in: &subscriptions)
        model.$settingsWindowRequestID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.presentSettingsWindow() }
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layoutPanel() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layoutPanel() }
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateMouseAcceptance(); self?.autoCollapse.update() }
        }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !self.isPresentationDiagnostic else { return }
                self.handlePointerEvent(event, at: point)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, !self.isPresentationDiagnostic { self.handlePointerEvent(event) }
            return event
        }
        panel.acceptsMouseMovedEvents = true
        layoutPanel()
        #if DEBUG
        if demo, let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            var capturesSettingsWindow = false
            if let sceneIndex = CommandLine.arguments.firstIndex(of: "--snapshot-scene"), sceneIndex + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[sceneIndex + 1] {
                case "settings": model.showingSettings = true
                case "question": model.selectedID = "pi:demo-pi"
                case "approval": model.selectedID = "claude:demo-claude"
                case "floating": model.setPresentation(.floating)
                case "floatingSettings": model.setPresentation(.floating); model.showingSettings = true
                case "menuBar": model.setPresentation(.menuBar); model.showingSettings = false
                case "menuBarSettings": model.setPresentation(.menuBar); model.showingSettings = true
                case "settingsWindowAgents", "settingsWindowGeneral":
                    model.settingsWindowSection = CommandLine.arguments[sceneIndex + 1] == "settingsWindowAgents" ? .agents : .general
                    presentSettingsWindow()
                    capturesSettingsWindow = true
                default: break
                }
                layoutPanel()
                if model.menuBarOnly { model.expanded = true; layoutPanel() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if let progressIndex = CommandLine.arguments.firstIndex(of: "--snapshot-progress"), progressIndex + 1 < CommandLine.arguments.count,
                   let progress = Double(CommandLine.arguments[progressIndex + 1]) { self.motion.snap(to: progress) }
                // Let SwiftUI commit the requested diagnostic frame before caching it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if capturesSettingsWindow, let hosting = self.settingsWindowController?.hosting {
                        hosting.layoutSubtreeIfNeeded()
                        hosting.displayIfNeeded()
                        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                        NSApp.terminate(nil)
                        return
                    }
                    self.surface.layoutSubtreeIfNeeded()
                    self.surface.displayIfNeeded()
                    // Materialize SwiftUI's cached descendants, then capture the
                    // composited mask and shadow from the enclosing layer tree.
                    if let surfaceImage = self.surface.bitmapImageRepForCachingDisplay(in: self.surface.bounds) {
                        self.surface.cacheDisplay(in: self.surface.bounds, to: surfaceImage)
                    }
                    if let content = self.surface.hosting.bitmapImageRepForCachingDisplay(in: self.surface.hosting.bounds) {
                        self.surface.hosting.cacheDisplay(in: self.surface.hosting.bounds, to: content)
                    }
                    if let context = CGContext(data: nil, width: Int(self.surface.bounds.width * 2), height: Int(self.surface.bounds.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.translateBy(x: 0, y: self.surface.bounds.height * 2)
                        context.scaleBy(x: 2, y: -2)
                        self.surface.layer?.render(in: context)
                        if let image = context.makeImage() {
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if demo, let index = CommandLine.arguments.firstIndex(of: "--presentation-checks"), index + 1 < CommandLine.arguments.count {
            runPresentationChecks(to: CommandLine.arguments[index + 1])
        }
        #endif
    }
    private func makeStatusMenu(demo: Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Agent Island")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: demo ? "Agent Island · 演示模式" : "Agent Island", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        menu.addItem(NSMenuItem(title: "显示 / 收起面板", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "快捷设置…", action: #selector(showQuickSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Agent 接入与更多设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        for presentation in IslandPresentation.allCases {
            let item = NSMenuItem(title: presentation.displayName, action: #selector(selectPresentation(_:)), keyEquivalent: "")
            item.representedObject = presentation.rawValue
            menu.addItem(item)
            modeMenuItems.append(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Agent Island", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusMenu = menu
    }
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            guard let button = statusItem.button else { return }
            autoCollapse.update(outsideClick: true)
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        } else { togglePanel() }
    }
    @objc private func selectPresentation(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let presentation = IslandPresentation(rawValue: rawValue) else { return }
        model.setPresentation(presentation)
        layoutPanel()
    }
    @objc private func togglePanel() {
        autoCollapse.reset()
        model.expanded.toggle()
        layoutPanel()
        if model.expanded { panel.makeKeyAndOrderFront(nil) }
    }
    @objc private func showSettings() {
        model.requestSettingsWindow(.agents)
    }
    @objc private func showQuickSettings() {
        autoCollapse.reset()
        model.showingSettings = true
        model.expanded = true
        layoutPanel()
        panel.makeKeyAndOrderFront(nil)
    }
    private func presentSettingsWindow() {
        autoCollapse.reset()
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(model: model) }
        settingsWindowController?.present(section: model.settingsWindowSection)
        layoutPanel()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func statusButtonFrame() -> CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    private func displayID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return number?.stringValue ?? screen.localizedName
    }
    private func display() -> NSScreen? {
        let screens = NSScreen.screens
        switch model.presentation {
        case .notch:
            return screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        case .menuBar:
            if let rect = statusButtonFrame(), let screen = screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) { return screen }
            return statusItem.button?.window?.screen ?? NSScreen.main ?? screens.first
        case .floating:
            if let saved = floatingPosition, let screen = screens.first(where: { displayID($0) == saved.displayID }) { return screen }
            if let anchor = lastFloatingAnchor, let index = PanelPlacement.bestScreenIndex(screenFrames: screens.map(\.visibleFrame), anchor: anchor) { return screens[index] }
            return NSScreen.main ?? screens.first
        }
    }
    private func updateStatusItem() {
        let pending = model.pendingCount
        statusItem.button?.image = NSImage(systemSymbolName: pending > 0 ? "exclamationmark.circle.fill" : "waveform", accessibilityDescription: "Agent Island")
        statusItem.button?.title = pending > 0 ? " \(pending)" : ""
        statusItem.button?.toolTip = "\(model.summary) · 点击展开，右键设置"
        for item in modeMenuItems {
            item.state = (item.representedObject as? String) == model.presentation.rawValue ? .on : .off
        }
    }
    private func layoutPanel() {
        guard !panel.isUserDragging else { return }
        updateStatusItem()
        if positionResetID != model.positionResetID {
            positionResetID = model.positionResetID
            floatingPosition = nil
            lastFloatingAnchor = nil
            if !model.demo { UserDefaults.standard.removeObject(forKey: Self.floatingPositionKey) }
        }
        if previousPresentation != model.presentation {
            let changingExistingMode = previousPresentation != nil
            previousPresentation = model.presentation
            autoCollapse.reset()
            hoverExpansion.reset()
            motion.stop()
            if model.menuBarOnly && changingExistingMode && !model.showingSettings { model.expanded = false }
            // A different presentation has a different origin; never carry a
            // half-finished shape from the old origin into the new mode.
            if changingExistingMode { motion.snap(to: model.expanded ? 1 : 0) }
        }
        guard let screen = display() else { return }
        let hasNotch = screen.safeAreaInsets.top > 0 && model.presentation == .notch
        let notchWidth: CGFloat
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { notchWidth = max(0, right.minX - left.maxX) }
        else { notchWidth = 0 }
        let notchHeight: CGFloat = hasNotch ? screen.safeAreaInsets.top : 0
        let availableHeight = screen.visibleFrame.height - 40
        let width: CGFloat = min(800, screen.visibleFrame.width - 48)
        let closedHeight: CGFloat = model.menuBarOnly ? 6 : max(notchHeight, 36)
        let closedWidth: CGFloat = model.menuBarOnly ? 28 : min(width - 40, hasNotch ? max(360, notchWidth + 160) : 300)
        let desired = IslandView.contentHeight(for: model, notchHeight: notchHeight)
        let height = min(desired, availableHeight)
        let anchor: CGPoint
        if model.floating {
            anchor = floatingPosition?.anchor(in: screen.visibleFrame) ?? CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 24)
            lastFloatingAnchor = anchor
        } else if model.menuBarOnly, let rect = statusButtonFrame() {
            anchor = CGPoint(x: rect.midX, y: min(rect.minY - 6, screen.visibleFrame.maxY - 6))
        } else {
            anchor = CGPoint(x: screen.frame.midX, y: hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 6)
        }
        layout = PanelLayout(width: width, height: height, notchWidth: notchWidth, notchHeight: notchHeight, closedWidth: closedWidth, closedHeight: closedHeight, attached: model.presentation == .notch, preferredAnchor: anchor, visibleFrame: screen.visibleFrame, presentation: model.presentation)
        panel.allowsFreePosition = model.presentation != .notch
        if wasExpanded != model.expanded { autoCollapse.reset() }
        if wasExpanded && !model.expanded {
            // End editing before the controls become clipped and inaccessible.
            panel.makeFirstResponder(nil)
            panel.resignKey()
        }
        wasExpanded = model.expanded
        renderSurface(progress: motion.spring.value)
        motion.setExpanded(model.expanded, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if model.expanded || !model.menuBarOnly { panel.orderFrontRegardless() }
    }
    private func renderSurface(progress: Double) {
        guard let layout else { return }
        let geometry = LiquidGeometry(fullWidth: layout.width, fullHeight: layout.height, closedWidth: layout.closedWidth, closedHeight: layout.closedHeight, progress: progress, attached: layout.attached)
        if !panel.isUserDragging {
            let anchor = layout.presentation == .notch ? layout.preferredAnchor : PanelPlacement.clampedAnchor(layout.preferredAnchor, visibleFrame: layout.visibleFrame, visibleSize: geometry.boundingRect.size)
            let inset = LiquidPanelView.shadowInset
            let frame = CGRect(x: anchor.x - layout.width / 2 - inset, y: anchor.y - layout.height - inset, width: layout.width + inset * 2, height: layout.height + inset)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        surface.update(rootView: IslandView(model: model, width: layout.width, height: layout.height, notchWidth: layout.notchWidth, notchHeight: layout.notchHeight, progress: min(1, max(0, progress))), geometry: geometry)
        updateMouseAcceptance()
        if layout.presentation == .menuBar, !model.expanded, progress <= 0.0005 { panel.orderOut(nil) }
        autoCollapse.update()
    }
    private func finishFloatingDrag() {
        guard model.floating else { return }
        let anchor = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        let screens = NSScreen.screens
        guard let index = PanelPlacement.bestScreenIndex(screenFrames: screens.map(\.visibleFrame), anchor: anchor) else { return }
        let screen = screens[index]
        let size = surface.outline.boundingBoxOfPath.size
        let fitted = PanelPlacement.clampedAnchor(anchor, visibleFrame: screen.visibleFrame, visibleSize: size)
        floatingPosition = SavedPanelPosition(displayID: displayID(screen), anchor: fitted, visibleFrame: screen.visibleFrame)
        lastFloatingAnchor = fitted
        if !model.demo, let data = try? JSONEncoder().encode(floatingPosition) {
            UserDefaults.standard.set(data, forKey: Self.floatingPositionKey)
        }
        layoutPanel()
        // Dropping under the pointer must not synthesize a fresh mouse entry.
        _ = hoverExpansion.update(inside: surface.containsScreenPoint(NSEvent.mouseLocation),
                                  expanded: model.expanded, presentation: model.presentation,
                                  dragging: false, pointerButtonDown: false, isMouseMovement: false)
    }
    private func updateMouseAcceptance() {
        // The fixed canvas includes transparent space. Let clicks in that space
        // reach the desktop or another application, even while the mask moves.
        guard !panel.isUserDragging else { return }
        panel.ignoresMouseEvents = !surface.containsScreenPoint(NSEvent.mouseLocation)
    }
    private func handlePointerEvent(_ event: NSEvent, at eventPoint: CGPoint? = nil) {
        let point = eventPoint ?? NSEvent.mouseLocation
        let inside = surface.containsScreenPoint(point)
        if panel.isUserDragging {
            _ = hoverExpansion.update(inside: inside, expanded: model.expanded, presentation: model.presentation,
                                      dragging: true, pointerButtonDown: true, isMouseMovement: false)
            return
        }
        let wasExpandedAtEvent = model.expanded
        let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        updateMouseAcceptance()
        // The status item is the explicit toggle itself; don't queue a second
        // collapse on its mouse-down before its click action runs.
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control), statusButtonFrame()?.contains(point) == true {
            autoCollapse.reset()
            return
        }
        if isClick && !inside {
            autoCollapse.update(outsideClick: true)
        } else { autoCollapse.update() }
        if hoverExpansion.update(inside: inside, expanded: wasExpandedAtEvent || model.expanded,
                                 presentation: model.presentation, dragging: false,
                                 pointerButtonDown: isClick || NSEvent.pressedMouseButtons != 0,
                                 isMouseMovement: event.type == .mouseMoved) {
            autoCollapse.reset()
            model.expanded = true
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        autoCollapse.reset()
        motion.stop()
        settingsWindowController?.close()
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    #if DEBUG
    /// Exercises real panel visibility and placement without mouse injection,
    /// Agent connections, or changes to the user's saved preferences.
    private func runPresentationChecks(to path: String) {
        Task { @MainActor [self] in
            var results: [String: Bool] = [:]
            func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }
            model.setPresentation(.floating)
            model.expanded = false
            layoutPanel()
            await settle()
            results["floatingCollapsedVisible"] = panel.isVisible
            guard let screen = display(), let currentLayout = layout else { NSApp.terminate(nil); return }
            let destination = CGPoint(x: screen.visibleFrame.minX + 170, y: screen.visibleFrame.minY + 70)
            panel.setFrameOrigin(CGPoint(x: destination.x - panel.frame.width / 2, y: destination.y - panel.frame.height))
            finishFloatingDrag()
            let savedPosition = floatingPosition
            let collapsedAnchor = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
            results["dragPositionRecorded"] = abs(collapsedAnchor.x - destination.x) < 1 && abs(collapsedAnchor.y - destination.y) < 1
            model.expanded = true
            layoutPanel()
            await settle()
            let body = CGRect(x: panel.frame.midX - currentLayout.width / 2, y: panel.frame.maxY - currentLayout.height, width: currentLayout.width, height: currentLayout.height)
            results["expandedBodyFitsDisplay"] = screen.visibleFrame.contains(body)
            results["expansionPreservesSavedPosition"] = floatingPosition == savedPosition
            model.expanded = false
            layoutPanel()
            await settle()
            results["collapseReturnsToDraggedPosition"] = abs(panel.frame.midX - collapsedAnchor.x) < 1 && abs(panel.frame.maxY - collapsedAnchor.y) < 1
            if let savedPosition, let data = try? JSONEncoder().encode(savedPosition),
               let restored = try? JSONDecoder().decode(SavedPanelPosition.self, from: data) {
                results["savedPositionRoundTrip"] = restored == savedPosition
            }
            model.setPresentation(.menuBar)
            layoutPanel()
            await settle()
            results["menuBarHasNoPersistentWindow"] = !panel.isVisible
            togglePanel()
            await settle()
            results["menuBarClickOpens"] = panel.isVisible && model.expanded
            if let menuLayout = layout {
                let menuBody = CGRect(x: panel.frame.midX - menuLayout.width / 2, y: panel.frame.maxY - menuLayout.height, width: menuLayout.width, height: menuLayout.height)
                results["menuBarBodyFitsDisplay"] = menuLayout.visibleFrame.contains(menuBody)
            }
            togglePanel()
            await settle()
            results["menuBarCloseHidesWindow"] = !panel.isVisible && !model.expanded
            showQuickSettings()
            await settle()
            results["settingsRemainReachable"] = panel.isVisible && model.showingSettings
            model.setPresentation(.floating)
            layoutPanel()
            model.resetFloatingPosition()
            layoutPanel()
            results["positionResetWorks"] = floatingPosition == nil

            for mode in IslandPresentation.allCases {
                model.setPresentation(mode)
                model.showingSettings = false
                model.expanded = false
                layoutPanel()
                motion.snap(to: 0)
                hoverExpansion.reset()
                let inside = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 18)
                let outside = CGPoint(x: panel.frame.minX - 50, y: panel.frame.midY)
                if let move = NSEvent.mouseEvent(with: .mouseMoved, location: inside, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    handlePointerEvent(move, at: outside)
                    handlePointerEvent(move, at: inside)
                    results["\(mode.rawValue)MouseEntryRule"] = model.expanded == (mode != .menuBar)
                    model.expanded = false
                    layoutPanel()
                    motion.snap(to: 0)
                    handlePointerEvent(move, at: inside)
                    results["\(mode.rawValue)ManualCollapseStaysClosed"] = !model.expanded
                }
            }

            // Enable the real deadline driver with a controlled pointer. This
            // verifies focused native windows without moving the user's mouse.
            var pointerInside = true
            autoCollapse.context = { [weak self] in
                guard let self else { return nil }
                return .init(expanded: self.model.expanded, presentation: self.model.presentation,
                             pointerInside: pointerInside, isDragging: self.panel.isUserDragging,
                             delay: self.model.collapseDelay)
            }
            model.setCollapseDelay(0.3)
            for mode in IslandPresentation.allCases {
                pointerInside = true
                model.setPresentation(mode)
                layoutPanel()
                model.showingSettings = false
                model.expanded = true
                layoutPanel()
                NSApp.activate()
                panel.makeKeyAndOrderFront(nil)
                await settle()
                let wasKey = panel.isKeyWindow
                results["\(mode.rawValue)FocusedBeforeOutsideClick"] = wasKey
                let outside = CGPoint(x: panel.frame.minX - 50, y: panel.frame.midY)
                if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: outside, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    handlePointerEvent(click, at: outside)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    results["\(mode.rawValue)OutsideClickWaits"] = model.expanded
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    results["\(mode.rawValue)OutsideClickCloses"] = !model.expanded
                    results["\(mode.rawValue)OutsideClickClosesWithFocus"] = wasKey && !model.expanded
                }
                model.expanded = true
                layoutPanel()
                pointerInside = false
                autoCollapse.update()
                try? await Task.sleep(nanoseconds: 400_000_000)
                results["\(mode.rawValue)MouseExitRule"] = model.expanded == (mode == .menuBar)
                autoCollapse.reset()
            }
            autoCollapse.reset()

            model.setPresentation(.floating)
            model.requestSettingsWindow(.agents)
            await settle()
            let settingsWindow = settingsWindowController?.window
            results["agentSettingsUsesNormalWindow"] = settingsWindow != nil && !(settingsWindow is NSPanel) && settingsWindow?.level == .normal
            results["agentSettingsSurvivesPointerExit"] = settingsWindow?.isVisible == true && model.isSettingsWindowVisible && !model.expanded && !model.showingSettings
            model.requestSettingsWindow(.general)
            await settle()
            results["settingsWindowReusedForGeneral"] = settingsWindowController?.window === settingsWindow && model.settingsWindowSection == .general
            settingsWindowController?.close()
            results["settingsWindowCloseClearsVisibility"] = !model.isSettingsWindowVisible && settingsWindow?.isVisible == false
            model.requestSettingsWindow(.agents)
            await settle()
            results["settingsWindowReopens"] = settingsWindowController?.window === settingsWindow && settingsWindow?.isVisible == true && model.isSettingsWindowVisible
            settingsWindowController?.close()
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
    #endif
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionID"] as? String {
            Task { @MainActor [weak self] in self?.model.revealFromNotification(id) }
        }
        completionHandler()
    }
}

@main
enum AgentIslandMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
