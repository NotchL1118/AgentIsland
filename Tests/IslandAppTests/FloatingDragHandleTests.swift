import XCTest
import AppKit
@testable import AgentIsland

private final class RecordingDragPanel: IslandPanel {
    var receivedDragEvent: NSEvent?
    var duringDrag: (() -> Void)?

    override func performDrag(with event: NSEvent) {
        receivedDragEvent = event
        duringDrag?()
        setFrameOrigin(NSPoint(x: frame.minX + 120, y: frame.minY - 40))
    }
}

final class FloatingDragHandleTests: XCTestCase {
    @MainActor
    private func fixture() -> (RecordingDragPanel, FloatingDragView) {
        _ = NSApplication.shared
        let panel = RecordingDragPanel(contentRect: NSRect(x: 100, y: 100, width: 500, height: 200),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.allowsFreePosition = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let handle = FloatingDragView(frame: NSRect(x: 0, y: 164, width: 264, height: 36))
        content.addSubview(handle)
        panel.contentView = content
        return (panel, handle)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, point: NSPoint, panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                        timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                                        eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    func testSimpleClickTogglesOnceWithoutStartingDrag() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clicks = 0
        handle.onClick = { clicks += 1 }
        let point = NSPoint(x: 30, y: 180)
        handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
        XCTAssertEqual(clicks, 1)
        XCTAssertNil(panel.receivedDragEvent)
        XCTAssertFalse(panel.isUserDragging)
    }

    @MainActor
    func testDragUsesOriginalMouseDownAndDoesNotToggleOnRelease() async throws {
        let (panel, handle) = fixture()
        defer {
            panel.dragDidBegin = nil
            panel.dragDidEnd = nil
            panel.duringDrag = nil
            panel.close()
        }
        var clicks = 0
        var lifecycle: [String] = []
        handle.onClick = { clicks += 1 }
        panel.dragDidBegin = {
            XCTAssertTrue(panel.isUserDragging)
            lifecycle.append("begin")
        }
        panel.duringDrag = {
            XCTAssertTrue(panel.isUserDragging)
            lifecycle.append("drag")
        }
        panel.dragDidEnd = {
            XCTAssertFalse(panel.isUserDragging)
            lifecycle.append("end")
        }
        let origin = panel.frame.origin
        let down = try event(.leftMouseDown, point: NSPoint(x: 30, y: 180), panel: panel)
        handle.mouseDown(with: down)
        handle.mouseDragged(with: try event(.leftMouseDragged, point: NSPoint(x: 35, y: 180), panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 35, y: 180), panel: panel))
        XCTAssertTrue(panel.receivedDragEvent === down)
        XCTAssertEqual(lifecycle, ["begin", "drag", "end"])
        XCTAssertEqual(panel.frame.origin, NSPoint(x: origin.x + 120, y: origin.y - 40))
        XCTAssertEqual(clicks, 0)
        XCTAssertFalse(panel.isUserDragging)
    }

    @MainActor
    func testSubthresholdPointerMovementStillCountsAsClick() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clicks = 0
        handle.onClick = { clicks += 1 }
        handle.mouseDown(with: try event(.leftMouseDown, point: NSPoint(x: 30, y: 180), panel: panel))
        handle.mouseDragged(with: try event(.leftMouseDragged, point: NSPoint(x: 32, y: 181), panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 32, y: 181), panel: panel))
        XCTAssertEqual(clicks, 1)
        XCTAssertNil(panel.receivedDragEvent)
        XCTAssertFalse(panel.isUserDragging)
    }

    @MainActor
    func testAccessibilityPressActivatesWithoutDragging() async {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clicks = 0
        handle.onClick = { clicks += 1 }
        XCTAssertTrue(handle.accessibilityPerformPress())
        XCTAssertEqual(clicks, 1)
        XCTAssertNil(panel.receivedDragEvent)
    }
}
