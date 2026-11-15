import AppKit
import SwiftUI

struct FloatingDragRegion {
    var frame: CGRect
    var label: String
    var onPress: () -> Void
}

/// One native surface arbitrates gestures across icons, labels, gaps and the
/// chevron, so a double-click cannot trigger either of its single-click actions.
struct FloatingDragHandle: NSViewRepresentable {
    var onClick: () -> Void
    var onClickAt: ((CGPoint) -> Void)? = nil
    var onDoubleClick: () -> Void = {}
    var regions: [FloatingDragRegion] = []

    func makeNSView(context: Context) -> FloatingDragView {
        let view = FloatingDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FloatingDragView, context: Context) {
        view.onClick = onClick
        view.onClickAt = onClickAt
        view.onDoubleClick = onDoubleClick
        view.regions = regions
    }

    static func dismantleNSView(_ view: FloatingDragView, coordinator: ()) {
        view.cancelPendingInteraction()
    }
}

final class FloatingDragView: NSView, NSViewToolTipOwner {
    var onClick: (() -> Void)?
    var onClickAt: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var regions: [FloatingDragRegion] = [] {
        didSet { updateRegions() }
    }
    // Overridable for deterministic, short tests; production follows the user's
    // macOS double-click speed instead of using a hard-coded gesture deadline.
    var singleClickDelay = NSEvent.doubleClickInterval
    private var mouseDownEvent: NSEvent?
    private var pendingClick: Timer?
    private var toolTipLabels: [NSView.ToolTipTag: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Agent 浮条")
        setAccessibilityHelp("拖动移动；单击查看任务；双击任意位置复位到当前屏幕顶部中央")
        updateRegions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelPendingInteraction()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                   name: NSWindow.willCloseNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowWillClose(_ notification: Notification) { cancelPendingInteraction() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { cancelPendingClick() }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let panel = window as? IslandPanel,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
        cancelPendingInteraction()
        panel.beginUserDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        mouseDownEvent = nil
        if down.clickCount >= 2 || event.clickCount >= 2 {
            cancelPendingClick()
            onDoubleClick?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clickAt = onClickAt
        let click = onClick
        cancelPendingClick()
        let timer = Timer(timeInterval: singleClickDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pendingClick = nil
            // Preserve the session hit at release even if status updates reorder
            // the floating bar while waiting for a potential second click.
            if let clickAt { clickAt(point) }
            else { click?() }
        }
        pendingClick = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingClick() {
        pendingClick?.invalidate()
        pendingClick = nil
    }

    func cancelPendingInteraction() {
        mouseDownEvent = nil
        cancelPendingClick()
    }

    override func accessibilityPerformPress() -> Bool {
        cancelPendingInteraction()
        onClick?()
        return true
    }

    private func updateRegions() {
        removeAllToolTips()
        toolTipLabels.removeAll()
        for region in regions {
            let tag = addToolTip(region.frame, owner: self, userData: nil)
            toolTipLabels[tag] = region.label
        }
        var actions = regions.map { region in
            NSAccessibilityCustomAction(name: region.label) { [weak self] in
                guard let self else { return false }
                self.cancelPendingInteraction()
                region.onPress()
                return true
            }
        }
        actions.append(NSAccessibilityCustomAction(name: "复位到当前屏幕顶部中央") { [weak self] in
            guard let self else { return false }
            self.cancelPendingInteraction()
            self.onDoubleClick?()
            return true
        })
        setAccessibilityCustomActions(actions)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        toolTipLabels[tag] ?? "拖动移动；双击复位到当前屏幕顶部中央"
    }
}
