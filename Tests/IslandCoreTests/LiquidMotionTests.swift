import XCTest
import CoreGraphics
@testable import IslandCore

final class LiquidMotionTests: XCTestCase {
    private func geometry(_ progress: Double, attached: Bool = true) -> LiquidGeometry {
        LiquidGeometry(fullWidth: 800, fullHeight: 420, closedWidth: 280,
                       closedHeight: 36, progress: progress, attached: attached)
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
