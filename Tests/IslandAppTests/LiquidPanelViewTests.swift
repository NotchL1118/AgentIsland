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
    func testMenuBarMaskClosesCompletelyWithoutScalingContent() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        for progress in [1.0, 0.5, 0.1, 0.001, 0.0] {
            view.update(rootView: root(model, progress: progress),
                        geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                                 closedHeight: 0, progress: progress, attached: false),
                        shadowProgress: progress / 0.25)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.hosting.frame.size, CGSize(width: 800, height: 434))
            XCTAssertEqual(view.hosting.rootView.width, 800)
            XCTAssertEqual(view.hosting.rootView.height, 434)
        }
        XCTAssertEqual(view.outline.boundingBoxOfPath.width, 0)
        XCTAssertEqual(view.outline.boundingBoxOfPath.height, 0)
        let endpoint = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        XCTAssertFalse(view.containsScreenPoint(endpoint))
        let localEndpoint = view.convert(CGPoint(x: 424, y: 0), to: view.superview)
        XCTAssertNil(view.hitTest(localEndpoint))
    }

    @MainActor
    func testMenuBarMaskReachesAboveContentWithoutMovingItsCanvas() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        panel.setFrame(NSRect(x: 100, y: 100, width: 848, height: 506), display: false)
        let windowFrame = panel.frame
        let contentOrigin = CGPoint(x: 24, y: 48)
        let target = CGPoint(x: 720, y: -24)
        var contentFrame: CGRect?
        for progress in [1.0, 0.75, 0.5, 0.25, 0.01] {
            view.update(rootView: root(model, progress: progress),
                        geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                                 closedHeight: 0, progress: progress, attached: false,
                                                 collapsePoint: target),
                        contentOrigin: contentOrigin, shadowProgress: progress / 0.25)
            view.layoutSubtreeIfNeeded()
            let frame = panel.convertToScreen(view.hosting.convert(view.hosting.bounds, to: nil))
            if let contentFrame { XCTAssertEqual(frame, contentFrame) }
            else { contentFrame = frame }
            XCTAssertEqual(panel.frame, windowFrame)
            XCTAssertEqual(view.hosting.frame, CGRect(origin: contentOrigin, size: CGSize(width: 800, height: 434)))
        }
        let tail = view.outline.boundingBoxOfPath
        XCTAssertGreaterThan(tail.minY, 0)
        XCTAssertLessThan(tail.maxY, contentOrigin.y)
        let tailCenter = CGPoint(x: tail.midX, y: tail.midY)
        let screenPoint = panel.convertPoint(toScreen: view.convert(tailCenter, to: nil))
        XCTAssertTrue(view.containsScreenPoint(screenPoint))
        XCTAssertNotNil(view.hitTest(view.convert(tailCenter, to: view.superview)))
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

    @MainActor
    func testMenuBarTimelineFinishesInClosingDurationDespiteRepeatedLayoutUpdates() async {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        motion.snap(to: 1)
        motion.setExpanded(false, reduceMotion: false, menuBar: true)
        let step = 1.0 / 120
        let frames = Int(MenuBarCollapse.duration / step)
        for _ in 0..<frames {
            motion.advance(deltaTime: step)
            motion.setExpanded(false, reduceMotion: false, menuBar: true)
        }
        XCTAssertGreaterThan(motion.progress, 0)
        XCTAssertLessThan(motion.progress, step / MenuBarCollapse.duration)
        motion.advance(deltaTime: step)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertEqual(motion.target, 0)
    }

    @MainActor
    func testMenuBarReversalKeepsCurrentOutlineAndCanSwitchBackToSpring() async {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        motion.snap(to: 1)
        motion.setExpanded(false, reduceMotion: false, menuBar: true)
        for _ in 0..<24 { motion.advance(deltaTime: 1.0 / 120) }
        let closingProgress = motion.progress
        XCTAssertGreaterThan(closingProgress, 0)
        XCTAssertLessThan(closingProgress, 1)

        motion.setExpanded(true, reduceMotion: false, menuBar: true)
        XCTAssertEqual(motion.progress, closingProgress)
        motion.advance(deltaTime: 1.0 / 120)
        XCTAssertGreaterThan(motion.progress, closingProgress)
        let reopeningProgress = motion.progress
        motion.setExpanded(true, reduceMotion: false)
        XCTAssertFalse(motion.menuBarAnimation)
        XCTAssertEqual(motion.spring.value, reopeningProgress)
        XCTAssertEqual(motion.spring.target, 1)
        for _ in 0..<240 { motion.advance(deltaTime: 1.0 / 120) }
        XCTAssertEqual(motion.progress, 1)
    }

    @MainActor
    func testMenuBarReducedMotionCancelsIntakeImmediately() async throws {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        var frames: [Double] = []
        motion.onFrame = { frames.append($0) }
        motion.snap(to: 1)
        motion.setExpanded(false, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: 0.05)
        XCTAssertGreaterThan(motion.progress, 0)
        motion.setExpanded(false, reduceMotion: true, menuBar: true)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertEqual(frames.last, 0)
        let count = frames.count
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(frames.count, count)
        motion.setExpanded(true, reduceMotion: true, menuBar: true)
        XCTAssertEqual(motion.progress, 1)
    }

    @MainActor
    func testMenuBarTerminalFadeIncludesUnderlyingShadowFill() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        let opacity = MenuBarCollapse.surfaceOpacity(progress: 0.05)
        view.update(rootView: root(model, progress: 0.05),
                    geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                             closedHeight: 0, progress: 0.05, attached: false),
                    shadowProgress: MenuBarCollapse.shadowProgress(progress: 0.05),
                    surfaceOpacity: opacity)
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThan(opacity, 1)
        XCTAssertEqual(view.subviews.first?.layer?.opacity, Float(opacity))
        XCTAssertEqual(view.layer?.sublayers?.first?.opacity, Float(opacity))
        XCTAssertEqual(view.layer?.sublayers?.first?.shadowOpacity, 0)
    }

    @MainActor
    func testMenuBarMissedFramesDoNotStretchWallClockDuration() async {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        motion.snap(to: 1)
        motion.setExpanded(false, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: 0.20)
        XCTAssertEqual(motion.progress, 1 - 0.20 / MenuBarCollapse.duration, accuracy: 0.000001)
        motion.advance(deltaTime: 0.06)
        XCTAssertEqual(motion.progress, 0)
        motion.setExpanded(true, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: MenuBarCollapse.openingDuration)
        XCTAssertEqual(motion.progress, 1)

        motion.setExpanded(false, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: 1)
        XCTAssertEqual(motion.progress, 0)
    }

    @MainActor
    func testMenuBarOpeningShowsContentEarlyAndFinishesWithinItsOwnDuration() async {
        let motion = IslandMotionDriver()
        defer { motion.stop() }
        motion.setExpanded(true, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: 0.09)
        XCTAssertGreaterThan(MenuBarCollapse.contentVisibility(progress: motion.progress, index: 0), 0.5)
        motion.setExpanded(true, reduceMotion: false, menuBar: true)
        motion.advance(deltaTime: 0.09)
        XCTAssertEqual(motion.progress, 1)
    }

    @MainActor
    func testMenuBarFramesFadeCachedContentWithoutReplacingSwiftUIRoot() async {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        let origin = CGPoint(x: 24, y: 48)
        let open = LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                  closedHeight: 0, progress: 1, attached: false)
        view.update(rootView: root(model, progress: 1), geometry: open, contentOrigin: origin)
        let frame = view.hosting.frame
        let opacity = MenuBarCollapse.contentVisibility(progress: 0.8, index: 0)
        view.update(rootView: root(model, progress: 0.8),
                    geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                             closedHeight: 0, progress: 0.8, attached: false),
                    contentOrigin: origin, updateContent: false,
                    contentOpacity: opacity, contentInteractive: false)
        XCTAssertEqual(view.hosting.rootView.progress, 1)
        XCTAssertEqual(view.hosting.frame, frame)
        XCTAssertEqual(view.hosting.alphaValue, opacity, accuracy: 0.000001)
        XCTAssertTrue(view.hosting.isAccessibilityHidden())
        let point = view.convert(CGPoint(x: 424, y: 140), to: view.superview)
        XCTAssertTrue(view.hitTest(point) === view)
    }

    @MainActor
    private func renderedAlpha(of view: NSView) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        try XCTUnwrap(view.layer).render(in: context)
        let bytes = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (width, height, stride(from: 3, to: width * height * 4, by: 4).map { bytes[$0] })
    }

    @MainActor
    func testMenuBarClipKeepsRenderedSurfaceAndShadowBelowMenuBarThroughoutMotion() async throws {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        panel.setFrame(NSRect(x: 100, y: 100, width: 848, height: 506), display: false)
        let origin = CGPoint(x: 24, y: 48)
        let target = CGPoint(x: 720, y: -24)
        let cutoff: CGFloat = 36
        let expectedContentFrame = CGRect(origin: origin, size: CGSize(width: 800, height: 434))

        for progress in [1.0, 0.75, 0.5, 0.25, 0.05] {
            view.update(rootView: root(model, progress: 1),
                        geometry: LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                                 closedHeight: 0, progress: progress, attached: false,
                                                 collapsePoint: target),
                        contentOrigin: origin, shadowProgress: 1, menuBarClipTop: cutoff)
            XCTAssertEqual(view.hosting.frame, expectedContentFrame)
            XCTAssertEqual(view.drawingClipRect,
                           CGRect(x: 0, y: cutoff, width: 848, height: 506 - cutoff))
            let image = try renderedAlpha(of: view)
            let aboveCutoff = image.pixels.prefix(Int(cutoff) * image.width)
            XCTAssertEqual(aboveCutoff.max(), 0,
                           "Surface and shadow must remain transparent above the menu boundary at progress \(progress)")
            if progress >= 0.5 {
                XCTAssertGreaterThan(image.pixels.dropFirst(Int(cutoff) * image.width).max() ?? 0, 0,
                                     "Clipping must preserve the visible body below the menu bar")
            }
        }
    }

    @MainActor
    func testMenuBarClipRejectsInvisibleHitsAndIsRemovedForOtherPresentations() async throws {
        let (model, panel, view) = fixture()
        defer { model.shutdown(); panel.close() }
        panel.setFrame(NSRect(x: 100, y: 100, width: 848, height: 506), display: false)
        let origin = CGPoint(x: 24, y: 48)
        let geometry = LiquidGeometry(fullWidth: 800, fullHeight: 434, closedWidth: 0,
                                      closedHeight: 0, progress: 0.5, attached: false,
                                      collapsePoint: CGPoint(x: 720, y: -24))
        view.update(rootView: root(model, progress: 1), geometry: geometry,
                    contentOrigin: origin, menuBarClipTop: 36)
        view.layoutSubtreeIfNeeded()
        let hiddenPoint = try XCTUnwrap((0..<848).map { CGPoint(x: CGFloat($0) + 0.5, y: 32) }
            .first(where: { view.outline.contains($0) }))
        let screenPoint = panel.convertPoint(toScreen: view.convert(hiddenPoint, to: nil))
        let superviewPoint = view.convert(hiddenPoint, to: view.superview)
        XCTAssertFalse(view.containsScreenPoint(screenPoint))
        XCTAssertNil(view.hitTest(superviewPoint))

        view.update(rootView: root(model, progress: 1), geometry: geometry, contentOrigin: origin)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.drawingClipRect)
        XCTAssertNil(view.layer?.mask)
        XCTAssertTrue(view.containsScreenPoint(screenPoint))
        XCTAssertNotNil(view.hitTest(superviewPoint))
        let unmasked = try renderedAlpha(of: view)
        XCTAssertGreaterThan(unmasked.pixels.prefix(36 * unmasked.width).max() ?? 0, 0,
                             "The regression fixture must actually paint above the boundary without the clip")
    }
}
