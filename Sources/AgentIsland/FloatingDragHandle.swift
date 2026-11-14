import AppKit
import SwiftUI

/// An explicit drag surface leaves the adjacent chevron and task controls clickable.
struct FloatingDragHandle: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> FloatingDragView {
        let view = FloatingDragView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: FloatingDragView, context: Context) { view.onClick = onClick }
}

final class FloatingDragView: NSView {
    var onClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("移动浮条；点击展开或收起")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let panel = window as? IslandPanel,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
        mouseDownEvent = nil
        panel.isUserDragging = true
        panel.dragDidBegin?()
        NSCursor.closedHand.push()
        panel.performDrag(with: down)
        NSCursor.pop()
        panel.isUserDragging = false
        panel.dragDidEnd?()
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
