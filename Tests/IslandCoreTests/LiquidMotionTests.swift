import XCTest
import CoreGraphics
@testable import IslandCore

final class LiquidMotionTests: XCTestCase {
    private func geometry(_ progress: Double, attached: Bool = true) -> LiquidGeometry {
        LiquidGeometry(fullWidth: 800, fullHeight: 420, closedWidth: 280,
                       closedHeight: 36, progress: progress, attached: attached)
    }

    private func menuBarGeometry(_ progress: Double, collapsePoint: CGPoint? = nil) -> LiquidGeometry {
        LiquidGeometry(fullWidth: 800, fullHeight: 420, closedWidth: 0,
                       closedHeight: 0, progress: progress, attached: false, collapsePoint: collapsePoint)
    }

    func testMenuBarClosesToAZeroAreaPointWithoutHitTarget() {
        let closed = menuBarGeometry(0)
        XCTAssertEqual(closed.width, 0)
        XCTAssertEqual(closed.height, 0)
        XCTAssertEqual(closed.boundingRect, CGRect(x: 400, y: 0, width: 0, height: 0))
        XCTAssertFalse(closed.boundingRect.isNull)
        XCTAssertFalse(closed.boundingRect.isInfinite)
        XCTAssertFalse(closed.path.contains(CGPoint(x: 400, y: 0)))
        XCTAssertFalse(closed.path.contains(CGPoint(x: 400, y: 1)))
    }

    func testMenuBarKeepsExpandedBoundsAndGathersItsTopBeforeTheBottom() {
        let open = menuBarGeometry(1)
        XCTAssertEqual(open.boundingRect, geometry(1, attached: false).boundingRect)
        XCTAssertEqual(open.width, 800)
        XCTAssertEqual(open.height, 420)

        let middle = menuBarGeometry(0.5)
        let top = horizontalExtent(of: middle, y: middle.boundingRect.minY + 10)
        let bottom = horizontalExtent(of: middle, y: middle.boundingRect.maxY - 10)
        XCTAssertLessThan(top.width, bottom.width * 0.6)
        XCTAssertEqual(top.midX, 400, accuracy: 1)
        XCTAssertEqual(bottom.midX, 400, accuracy: 1)
        XCTAssertEqual(middle.bottomBloom, 0)
        XCTAssertGreaterThan(middle.height, 0)
        XCTAssertLessThan(middle.height, open.height)
    }

    private func horizontalExtent(of shape: LiquidGeometry, y: CGFloat) -> CGRect {
        let points = stride(from: shape.boundingRect.minX, through: shape.boundingRect.maxX, by: 0.5)
            .filter { shape.path.contains(CGPoint(x: $0, y: y)) }
        guard let left = points.first, let right = points.last else {
            XCTFail("Expected a nonempty horizontal section through the outline")
            return .zero
        }
        return CGRect(x: left, y: y, width: right - left, height: 0)
    }

    func testMenuBarTerminalFramesHaveNoMinimumSizeRemnant() {
        var previousWidth = Double.infinity
        var previousHeight = Double.infinity
        for progress in [0.01, 0.001, 0.0001, 0.000001, 0] {
            let shape = menuBarGeometry(progress)
            XCTAssertLessThan(shape.width, previousWidth)
            XCTAssertLessThan(shape.height, previousHeight)
            XCTAssertTrue(shape.boundingRect.origin.x.isFinite)
            XCTAssertTrue(shape.boundingRect.origin.y.isFinite)
            XCTAssertTrue(shape.boundingRect.width.isFinite)
            XCTAssertTrue(shape.boundingRect.height.isFinite)
            previousWidth = shape.width
            previousHeight = shape.height
        }
        let nearlyClosed = menuBarGeometry(0.0001)
        XCTAssertGreaterThan(nearlyClosed.width, 0)
        XCTAssertGreaterThan(nearlyClosed.height, 0)
        XCTAssertLessThan(nearlyClosed.boundingRect.width, 1)
        XCTAssertLessThan(nearlyClosed.boundingRect.height, 1)
    }

    func testOffsetMenuBarTargetKeepsOpenShapeAndEndsAtTheIcon() {
        let target = CGPoint(x: 720, y: -24)
        let open = menuBarGeometry(1, collapsePoint: target)
        XCTAssertEqual(open.boundingRect, menuBarGeometry(1).boundingRect)
        XCTAssertEqual(open.width, 800)
        XCTAssertEqual(open.height, 420)
        XCTAssertEqual(open.bottomBloom, 0)

        let closed = menuBarGeometry(0, collapsePoint: target)
        XCTAssertTrue(closed.path.isEmpty)
        XCTAssertFalse(closed.path.contains(target))
        XCTAssertEqual(closed.boundingRect, CGRect(origin: target, size: .zero))
        XCTAssertFalse(closed.boundingRect.isNull)
        XCTAssertFalse(closed.boundingRect.isInfinite)
    }

    func testOffsetMenuBarTopLeadsTowardTheIconWhileTheBottomFollows() {
        let target = CGPoint(x: 720, y: -24)
        let middle = menuBarGeometry(0.5, collapsePoint: target)
        let top = horizontalExtent(of: middle, y: middle.boundingRect.minY + 10)
        let bottom = horizontalExtent(of: middle, y: middle.boundingRect.maxY - 10)
        XCTAssertLessThan(top.width, bottom.width * 0.6)
        XCTAssertLessThan(abs(top.midX - target.x), abs(bottom.midX - target.x))
        XCTAssertGreaterThan(bottom.midX, 400)
        XCTAssertEqual(middle.bottomBloom, 0)
        XCTAssertLessThan(middle.boundingRect.minY, 0)
        XCTAssertGreaterThan(middle.boundingRect.maxY, 0)

        let intake = menuBarGeometry(0.15, collapsePoint: target)
        XCTAssertEqual(intake.boundingRect.midX, target.x, accuracy: 1)
        XCTAssertLessThan(intake.width, 30)
        XCTAssertLessThan(intake.boundingRect.maxY, 0)
    }

    func testMenuBarBottomRisesContinuouslyWithoutBloomOrEscapeAtDisplayEdges() {
        for target in [CGPoint(x: 20, y: -24), CGPoint(x: 720, y: -24), CGPoint(x: 798, y: -38)] {
            var previous = menuBarGeometry(1, collapsePoint: target).boundingRect
            for frame in 1...1000 {
                let shape = menuBarGeometry(1 - Double(frame) / 1000, collapsePoint: target)
                let bounds = shape.boundingRect
                XCTAssertEqual(shape.bottomBloom, 0)
                XCTAssertEqual(shape.shoulder, 0)
                XCTAssertGreaterThanOrEqual(bounds.minX, min(0, target.x - 6) - 0.000001)
                XCTAssertLessThanOrEqual(bounds.maxX, max(800, target.x + 6) + 0.000001)
                XCTAssertGreaterThanOrEqual(bounds.minY, target.y - 5 - 0.000001)
                XCTAssertLessThanOrEqual(bounds.maxY, previous.maxY + 0.000001)
                XCTAssertLessThan(abs(bounds.minX - previous.minX), 3)
                XCTAssertLessThan(abs(bounds.maxX - previous.maxX), 3)
                XCTAssertLessThan(abs(bounds.maxY - previous.maxY), 3)
                previous = bounds
            }
            XCTAssertEqual(previous, CGRect(origin: target, size: .zero))
        }
    }

    func testMenuBarVisibilityRemovesTextAndShadowBeforeTheTerminalIntake() {
        XCTAssertEqual(MenuBarCollapse.duration, 0.26)
        for index in 0...4 {
            XCTAssertEqual(MenuBarCollapse.contentVisibility(progress: 1, index: index), 1)
            XCTAssertEqual(MenuBarCollapse.contentVisibility(progress: 0.65, index: index), 0)
        }
        XCTAssertLessThan(MenuBarCollapse.contentVisibility(progress: 0.85, index: 4),
                          MenuBarCollapse.contentVisibility(progress: 0.85, index: 0))
        XCTAssertEqual(MenuBarCollapse.shadowProgress(progress: 1), 1)
        XCTAssertEqual(MenuBarCollapse.shadowProgress(progress: 0.3), 0, accuracy: 0.000001)
        XCTAssertEqual(MenuBarCollapse.surfaceOpacity(progress: 0.11), 1)
        XCTAssertEqual(MenuBarCollapse.surfaceOpacity(progress: 0), 0)
        XCTAssertGreaterThan(MenuBarCollapse.surfaceOpacity(progress: 0.05), 0)
        XCTAssertLessThan(MenuBarCollapse.surfaceOpacity(progress: 0.05), 1)
        for progress in [-1.0, 0, 0.5, 1, 2, .nan, .infinity] {
            for value in [MenuBarCollapse.surfaceOpacity(progress: progress),
                          MenuBarCollapse.shadowProgress(progress: progress),
                          MenuBarCollapse.contentVisibility(progress: progress, index: Int.max)] {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testMenuBarOpeningShowsBodyAndTextEarlyInsteadOfReversingSlowIntake() {
        XCTAssertEqual(MenuBarCollapse.openingDuration, 0.18)
        let earlyProgress = MenuBarCollapse.openingProgress(0.05 / MenuBarCollapse.openingDuration)
        let earlyBody = menuBarGeometry(earlyProgress)
        XCTAssertEqual(MenuBarCollapse.surfaceOpacity(progress: earlyProgress), 1)
        XCTAssertGreaterThan(earlyBody.height, menuBarGeometry(1).height * 0.6)

        let halfway = MenuBarCollapse.openingProgress(0.5)
        for index in 0...4 {
            XCTAssertGreaterThan(MenuBarCollapse.contentVisibility(progress: halfway, index: index), 0.5)
        }
        XCTAssertEqual(MenuBarCollapse.openingProgress(0), 0)
        XCTAssertEqual(MenuBarCollapse.openingProgress(1), 1)
    }

    func testMenuBarOpeningClockRoundTripsForContinuousDirectionChanges() {
        var previous = -1.0
        for step in 0...1000 {
            let progress = Double(step) / 1000
            let time = MenuBarCollapse.openingTime(for: progress)
            XCTAssertGreaterThan(time, previous)
            XCTAssertEqual(MenuBarCollapse.openingProgress(time), progress, accuracy: 0.000000001)
            XCTAssertEqual(MenuBarCollapse.openingTime(for: MenuBarCollapse.openingProgress(progress)),
                           progress, accuracy: 0.000000001)
            previous = time
        }
        for value in [-1.0, 0, 0.5, 1, 2, .nan, .infinity] {
            for mapped in [MenuBarCollapse.openingProgress(value), MenuBarCollapse.openingTime(for: value)] {
                XCTAssertTrue(mapped.isFinite)
                XCTAssertGreaterThanOrEqual(mapped, 0)
                XCTAssertLessThanOrEqual(mapped, 1)
            }
        }
    }

    func testMenuBarSmallAndInvalidInputsKeepFinitePaths() {
        for size in [1.0, 5, 30, 320, 800] {
            for progress in [-1.0, 0, 0.0001, 0.1, 0.5, 1, 2, .nan] {
                let shape = LiquidGeometry(fullWidth: size, fullHeight: size, closedWidth: 0,
                                           closedHeight: 0, progress: progress, attached: false,
                                           collapsePoint: CGPoint(x: size * 0.9, y: -24))
                XCTAssertTrue(shape.boundingRect.origin.x.isFinite)
                XCTAssertTrue(shape.boundingRect.origin.y.isFinite)
                XCTAssertTrue(shape.width.isFinite)
                XCTAssertTrue(shape.height.isFinite)
                XCTAssertGreaterThanOrEqual(shape.width, 0)
                XCTAssertGreaterThanOrEqual(shape.height, 0)
                XCTAssertLessThanOrEqual(shape.boundingRect.maxY, size + 0.000001)
            }
        }
        let invalid = LiquidGeometry(fullWidth: .nan, fullHeight: .infinity, closedWidth: 0,
                                     closedHeight: 0, progress: 0.5, attached: false,
                                     collapsePoint: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        XCTAssertFalse(invalid.boundingRect.isInfinite)
        XCTAssertFalse(invalid.boundingRect.isNull)
    }

    func testCollapsedAndExpandedBoundsMatchNotchAndPanel() {
        let closed = geometry(0)
        XCTAssertEqual(closed.boundingRect, CGRect(x: 260, y: 0, width: 280, height: 36))
        let open = geometry(1)
        XCTAssertEqual(open.boundingRect, CGRect(x: 0, y: 0, width: 800, height: 420))
        XCTAssertEqual(open.width, 760)
        XCTAssertEqual(open.bottomBloom, 0)
        XCTAssertEqual(geometry(1, attached: false).width, 800)
    }

    func testCenterLeadsLowerCornersDuringExpansion() {
        let middle = geometry(0.5)
        XCTAssertGreaterThan(middle.width, 280)
        XCTAssertLessThan(middle.width, 760)
        XCTAssertGreaterThan(middle.height, 36)
        XCTAssertLessThan(middle.height, 420)
        XCTAssertEqual(middle.bottomBloom, 22, accuracy: 0.000001)
        XCTAssertEqual(middle.boundingRect.maxY, middle.height + middle.bottomBloom, accuracy: 0.000001)
        XCTAssertTrue(middle.path.contains(CGPoint(x: 400, y: middle.height + 10)))
        XCTAssertFalse(middle.path.contains(CGPoint(x: 400 + middle.width / 2 - 30, y: middle.height + 10)))
    }

    func testEveryFrameIsBoundedAndHorizontallySymmetric() {
        for attached in [true, false] {
            for frame in 0...100 {
                let shape = geometry(Double(frame) / 100, attached: attached)
                XCTAssertGreaterThanOrEqual(shape.boundingRect.minX, -0.000001)
                XCTAssertLessThanOrEqual(shape.boundingRect.maxX, 800.000001)
                XCTAssertEqual(shape.boundingRect.minY, 0, accuracy: 0.000001)
                XCTAssertLessThanOrEqual(shape.boundingRect.maxY, 420.000001)
                XCTAssertEqual(shape.boundingRect.midX, 400, accuracy: 0.000001)
                for x in stride(from: 17.0, through: 390, by: 47) {
                    for y in stride(from: 13.0, through: 420, by: 37) {
                        XCTAssertEqual(shape.path.contains(CGPoint(x: x, y: y)),
                                       shape.path.contains(CGPoint(x: 800 - x, y: y)))
                    }
                }
            }
        }
    }

    func testNarrowAndDegenerateInputsProduceFiniteContainedPaths() {
        for size in [1.0, 30, 320, 800] {
            for progress in [-1.0, 0, 0.5, 1, 2, .nan] {
                let shape = LiquidGeometry(fullWidth: size, fullHeight: size, closedWidth: 280,
                                           closedHeight: 36, progress: progress)
                XCTAssertTrue(shape.boundingRect.width.isFinite)
                XCTAssertTrue(shape.boundingRect.height.isFinite)
                XCTAssertGreaterThanOrEqual(shape.boundingRect.minX, -0.000001)
                XCTAssertLessThanOrEqual(shape.boundingRect.maxX, size + 0.000001)
                XCTAssertLessThanOrEqual(shape.boundingRect.maxY, size + 0.000001)
            }
        }
        let invalid = LiquidGeometry(fullWidth: .nan, fullHeight: .infinity,
                                     closedWidth: -.infinity, closedHeight: -10, progress: .nan)
        XCTAssertFalse(invalid.boundingRect.isInfinite)
        XCTAssertFalse(invalid.boundingRect.isNull)
    }

    func testRetargetingPreservesPositionAndVelocityThenCloses() {
        var spring = LiquidSpring()
        spring.setTarget(1)
        for _ in 0..<7 { spring.advance(deltaTime: 1 / 60) }
        let position = spring.value
        let velocity = spring.velocity
        spring.setTarget(0)
        XCTAssertEqual(spring.value, position)
        XCTAssertEqual(spring.velocity, velocity)
        spring.advance(deltaTime: 1 / 240)
        XCTAssertLessThan(abs(spring.value - position), 0.03)
        for _ in 0..<240 { spring.advance(deltaTime: 1 / 120) }
        XCTAssertEqual(spring.value, 0)
        XCTAssertEqual(spring.velocity, 0)
        XCTAssertFalse(spring.advance(deltaTime: 1 / 60))
    }

    func testSpringSettlesExactlyAndSnapCancelsMotion() {
        var spring = LiquidSpring()
        spring.setTarget(1)
        XCTAssertTrue(spring.advance(deltaTime: 1 / 60))
        XCTAssertGreaterThan(spring.value, 0)
        for _ in 0..<240 { spring.advance(deltaTime: 1 / 120) }
        XCTAssertEqual(spring.value, 1)
        XCTAssertEqual(spring.velocity, 0)
        XCTAssertFalse(spring.advance(deltaTime: 1 / 60))
        spring.setTarget(0)
        spring.advance(deltaTime: 1 / 60)
        spring.snap(to: 0)
        XCTAssertEqual(spring.value, 0)
        XCTAssertEqual(spring.target, 0)
        XCTAssertEqual(spring.velocity, 0)
    }

    func testFrameRatePartitionKeepsTheSameTrajectory() {
        var sixtyHz = LiquidSpring()
        var oneTwentyHz = LiquidSpring()
        sixtyHz.setTarget(1)
        oneTwentyHz.setTarget(1)
        for _ in 0..<18 { sixtyHz.advance(deltaTime: 1 / 60) }
        for _ in 0..<36 { oneTwentyHz.advance(deltaTime: 1 / 120) }
        XCTAssertEqual(sixtyHz.value, oneTwentyHz.value, accuracy: 0.000001)
        XCTAssertEqual(sixtyHz.velocity, oneTwentyHz.velocity, accuracy: 0.000001)
    }

    func testLongFramesAreCappedAndInvalidDeltaDoesNotPoisonSpring() {
        var delayed = LiquidSpring()
        var capped = LiquidSpring()
        delayed.setTarget(1)
        capped.setTarget(1)
        delayed.advance(deltaTime: 12)
        capped.advance(deltaTime: 0.05)
        XCTAssertEqual(delayed.value, capped.value)
        XCTAssertEqual(delayed.velocity, capped.velocity)
        delayed.advance(deltaTime: .nan)
        delayed.advance(deltaTime: -.infinity)
        XCTAssertEqual(delayed.value, capped.value)
        XCTAssertEqual(delayed.velocity, capped.velocity)
    }
}
