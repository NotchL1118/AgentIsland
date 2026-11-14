import XCTest
import AppKit
import IslandCore
@testable import AgentIsland

final class LiquidPanelViewTests: XCTestCase {
    @MainActor
    private func fixture() -> (AppModel, IslandPanel, LiquidPanelView) {
        _ = NSApplication.shared
        let model = AppModel(demo: true)
        model.selectedID = nil
        let panel = IslandPanel(contentRect: NSRect(x: 100, y: 100, width: 848, height: 458),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = LiquidPanelView(rootView: root(model, progress: 0))
        panel.contentView = view
        return (model, panel, view)
    }

    @MainActor
    private func root(_ model: AppModel, progress: CGFloat) -> IslandView {
        IslandView(model: model, width: 800, height: 434, notchWidth: 0, notchHeight: 0, progress: progress)
    }

    @MainActor
    private func update(_ view: LiquidPanelView, model: AppModel, progress: Double) {
        view.update(rootView: root(model, progress: progress),
                    geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 300,
                                             closedHeight: 36, progress: progress))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testScreenCoordinatesFollowTopAnchoredSilhouette() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        let centerTop = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 18)
        let centerBody = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 150)
        let leftMargin = CGPoint(x: panel.frame.minX + 10, y: panel.frame.maxY - 18)
        let belowBody = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 445)

        update(view, model: model, progress: 0)
        XCTAssertTrue(view.containsScreenPoint(centerTop))
        XCTAssertFalse(view.containsScreenPoint(centerBody))
        XCTAssertFalse(view.containsScreenPoint(leftMargin))
        XCTAssertFalse(view.containsScreenPoint(belowBody))

        update(view, model: model, progress: 1)
        XCTAssertTrue(view.containsScreenPoint(centerTop))
        XCTAssertTrue(view.containsScreenPoint(centerBody))
        XCTAssertFalse(view.containsScreenPoint(leftMargin))
        XCTAssertFalse(view.containsScreenPoint(belowBody))
    }

    @MainActor
    func testHitTestingRejectsTransparentCanvasAndShadow() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            view.hitTest(view.convert(CGPoint(x: x, y: y), to: view.superview))
        }

        update(view, model: model, progress: 0)
        XCTAssertNotNil(hit(424, 18))
        XCTAssertNil(hit(424, 150))
        XCTAssertNil(hit(10, 18))
        XCTAssertNil(hit(424, 445))

        update(view, model: model, progress: 1)
        XCTAssertNotNil(hit(424, 150))
        XCTAssertNil(hit(29, 200))
        XCTAssertNil(hit(424, 445))
    }

    @MainActor
    func testTextCanvasKeepsExpandedDimensionsThroughoutMotion() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        var outlineWidths: [CGFloat] = []
        for progress in [0.0, 0.45, 1.0] {
            update(view, model: model, progress: progress)
            XCTAssertEqual(view.hosting.frame.size, CGSize(width: 800, height: 434))
            XCTAssertEqual(view.hosting.rootView.width, 800)
            XCTAssertEqual(view.hosting.rootView.height, 434)
            XCTAssertEqual(view.outline.boundingBoxOfPath.midX, 424, accuracy: 0.000001)
            outlineWidths.append(view.outline.boundingBoxOfPath.width)
        }
        XCTAssertLessThan(outlineWidths[0], outlineWidths[1])
        XCTAssertLessThan(outlineWidths[1], outlineWidths[2])
    }

    @MainActor
    func testReducedMotionAndSnapImmediatelyCancelScheduledFrames() async throws {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        var frames: [Double] = []
        motion.onFrame = { frames.append($0) }
        motion.setExpanded(true, reduceMotion: false)
        motion.setExpanded(true, reduceMotion: true)
        XCTAssertEqual(motion.spring.value, 1)
        XCTAssertEqual(motion.spring.velocity, 0)
        XCTAssertEqual(frames.last, 1)
        let count = frames.count
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(frames.count, count)

        motion.setExpanded(false, reduceMotion: false)
        motion.snap(to: 0.45)
        XCTAssertEqual(motion.spring.value, 0.45)
        XCTAssertEqual(motion.spring.target, 0.45)
        XCTAssertEqual(motion.spring.velocity, 0)
        XCTAssertEqual(frames.last, 0.45)
        let snapCount = frames.count
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(frames.count, snapCount)

        motion.setExpanded(false, reduceMotion: true)
        XCTAssertEqual(motion.spring.value, 0)
        XCTAssertEqual(frames.last, 0)
    }

    @MainActor
    func testDriverRetargetsAnActiveOpeningWithoutResettingPositionOrVelocity() async throws {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        motion.setExpanded(true, reduceMotion: false)
        let deadline = Date().addingTimeInterval(2)
        while motion.spring.value < 0.08, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(motion.spring.value, 0)
        XCTAssertGreaterThan(motion.spring.velocity, 0)
        let position = motion.spring.value
        let velocity = motion.spring.velocity
        motion.setExpanded(false, reduceMotion: false)
        XCTAssertEqual(motion.spring.target, 0)
        XCTAssertEqual(motion.spring.value, position)
        XCTAssertEqual(motion.spring.velocity, velocity)

        let closeDeadline = Date().addingTimeInterval(2)
        while motion.spring.value != 0, Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(motion.spring.value, 0)
        XCTAssertEqual(motion.spring.velocity, 0)
    }
}
