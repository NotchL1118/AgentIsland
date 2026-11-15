import XCTest
import AppKit
@testable import AgentIsland

private final class RecordingDragPanel: IslandPanel {
    var receivedDragEvent: NSEvent?
    var duringDrag: (() -> Void)?

    override func performDrag(with event: NSEvent) {
        receivedDragEvent = event
        duringDrag?()
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
        handle.singleClickDelay = 0.02
        content.addSubview(handle)
        panel.contentView = content
        return (panel, handle)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, point: NSPoint, panel: NSWindow, clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                        timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                                        eventNumber: 1, clickCount: clickCount, pressure: 1))
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
        XCTAssertEqual(clicks, 0)
        try await Task.sleep(nanoseconds: 80_000_000)
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
        var savedOrigin: NSPoint?
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
            savedOrigin = panel.frame.origin
            lifecycle.append("end")
        }
        let origin = panel.frame.origin
        let down = try event(.leftMouseDown, point: NSPoint(x: 30, y: 180), panel: panel)
        handle.mouseDown(with: down)
        handle.mouseDragged(with: try event(.leftMouseDragged, point: NSPoint(x: 35, y: 180), panel: panel))
        // Native dragging returns before Window Server moves the panel and
        // does not guarantee delivery of mouseUp to the handle.
        XCTAssertTrue(panel.isUserDragging)
        XCTAssertEqual(lifecycle, ["begin", "drag"])
        panel.finishUserDragIfReleased(pressedMouseButtons: 1)
        XCTAssertTrue(panel.isUserDragging)
        panel.setFrameOrigin(NSPoint(x: origin.x + 120, y: origin.y - 40))
        panel.finishUserDragIfReleased(pressedMouseButtons: 0)
        panel.finishUserDragIfReleased(pressedMouseButtons: 0)
        XCTAssertEqual(savedOrigin, NSPoint(x: origin.x + 120, y: origin.y - 40))
        handle.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 35, y: 180), panel: panel))
        XCTAssertTrue(panel.receivedDragEvent === down)
        XCTAssertEqual(lifecycle, ["begin", "drag", "end"])
        XCTAssertEqual(panel.frame.origin, NSPoint(x: origin.x + 120, y: origin.y - 40))
        XCTAssertEqual(clicks, 0)
        XCTAssertFalse(panel.isUserDragging)
    }

    @MainActor
    func testClosingPanelCancelsAnUnfinishedDrag() async throws {
        let (panel, handle) = fixture()
        var completions = 0
        panel.dragDidEnd = { completions += 1 }
        handle.mouseDown(with: try event(.leftMouseDown, point: NSPoint(x: 30, y: 180), panel: panel))
        handle.mouseDragged(with: try event(.leftMouseDragged, point: NSPoint(x: 35, y: 180), panel: panel))
        XCTAssertTrue(panel.isUserDragging)
        panel.close()
        panel.finishUserDragIfReleased(pressedMouseButtons: 0)
        XCTAssertFalse(panel.isUserDragging)
        XCTAssertEqual(completions, 0)
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
        XCTAssertEqual(clicks, 0)
        try await Task.sleep(nanoseconds: 80_000_000)
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

    @MainActor
    func testDoubleClickAnywhereResetsWithoutToggling() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clicks = 0
        var resets = 0
        handle.onClick = { clicks += 1 }
        handle.onDoubleClick = { resets += 1 }
        // Icon, label/gap and right-hand chevron share the same native view.
        for x: CGFloat in [20, 120, 250] {
            let point = NSPoint(x: x, y: 180)
            handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel))
            handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
            handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel, clickCount: 2))
            // Holding the second press past the first click's deadline must not
            // open a task while the user is still completing a double-click.
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertEqual(clicks, 0)
            handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel, clickCount: 2))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(resets, 3)
        XCTAssertNil(panel.receivedDragEvent)
    }

    @MainActor
    func testDelayedClickPreservesReleasedRegionWhenCallbacksChange() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clickedPoint: NSPoint?
        var replacementCalls = 0
        handle.onClickAt = { clickedPoint = $0 }
        let point = NSPoint(x: 200, y: 180)
        handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
        handle.onClickAt = { _ in replacementCalls += 1 }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(clickedPoint, NSPoint(x: 200, y: 16))
        XCTAssertEqual(replacementCalls, 0)
    }

    @MainActor
    func testDraggingSecondPressCancelsPendingClickAndReset() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var clicks = 0
        var resets = 0
        handle.onClick = { clicks += 1 }
        handle.onDoubleClick = { resets += 1 }
        let point = NSPoint(x: 30, y: 180)
        handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel))
        handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
        handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel, clickCount: 2))
        handle.mouseDragged(with: try event(.leftMouseDragged, point: NSPoint(x: 40, y: 180), panel: panel, clickCount: 2))
        panel.finishUserDragIfReleased(pressedMouseButtons: 0)
        handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel, clickCount: 2))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(resets, 0)
        XCTAssertNotNil(panel.receivedDragEvent)
    }

    @MainActor
    func testPendingClickIsCancelledWhenViewDetachesOrWindowCloses() async throws {
        for detachView in [false, true] {
            let (panel, handle) = fixture()
            var clicks = 0
            handle.onClick = { clicks += 1 }
            let point = NSPoint(x: 30, y: 180)
            handle.mouseDown(with: try event(.leftMouseDown, point: point, panel: panel))
            handle.mouseUp(with: try event(.leftMouseUp, point: point, panel: panel))
            if detachView { handle.removeFromSuperview() }
            else { panel.close() }
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertEqual(clicks, 0)
            if detachView { panel.close() }
        }
    }

    @MainActor
    func testAccessibilityExposesAgentAndResetActionsWithoutMouseGestures() async throws {
        let (panel, handle) = fixture()
        defer { panel.close() }
        var selected = 0
        var resets = 0
        handle.onDoubleClick = { resets += 1 }
        handle.regions = [FloatingDragRegion(frame: handle.bounds, label: "Codex · CodeLand · 运行中", onPress: { selected += 1 })]
        let actions = try XCTUnwrap(handle.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Codex · CodeLand · 运行中", "复位到当前屏幕顶部中央"])
        XCTAssertTrue(try XCTUnwrap(actions.first?.handler)())
        XCTAssertTrue(try XCTUnwrap(actions.last?.handler)())
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(resets, 1)
        XCTAssertNil(panel.receivedDragEvent)
    }
}
