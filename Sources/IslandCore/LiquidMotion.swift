import Foundation
import CoreGraphics

/// A reversible spring. Retargeting keeps its position and velocity so a close
/// gesture can interrupt an opening without restarting the animation.
public struct LiquidSpring {
    public private(set) var value: Double
    public private(set) var velocity: Double = 0
    public private(set) var target: Double

    public init(value: Double = 0) {
        let initial = Self.unit(value)
        self.value = initial
        self.target = initial
    }

    public mutating func setTarget(_ target: Double) {
        self.target = Self.unit(target)
    }

    public mutating func snap(to value: Double) {
        self.value = Self.unit(value)
        target = self.value
        velocity = 0
    }

    /// Returns whether another animation frame is needed. A long suspended
    /// frame advances by at most 50 ms instead of jumping across the motion.
    @discardableResult
    public mutating func advance(deltaTime: Double) -> Bool {
        if abs(target - value) < 0.0005 && abs(velocity) < 0.006 {
            snap(to: target)
            return false
        }
        guard deltaTime.isFinite, deltaTime > 0 else { return true }
        let opening = target > 0.5
        let stiffness = opening ? 300.0 : 520.0
        let damping = opening ? 30.0 : 43.0
        var remaining = min(deltaTime, 0.05)
        while remaining > 0 {
            let step = min(remaining, 1.0 / 240.0)
            velocity += (stiffness * (target - value) - damping * velocity) * step
            value += velocity * step
            remaining -= step
        }
        if abs(target - value) < 0.0005 && abs(velocity) < 0.006 {
            snap(to: target)
            return false
        }
        return true
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// The mask is expressed in top-left coordinates in a fixed expanded canvas.
/// Text can keep its final layout while this outline unfolds around it.
public struct LiquidGeometry {
    public let path: CGPath
    public let boundingRect: CGRect
    /// Width and height of the body, excluding the shoulders and lower bulge.
    public let width: Double
    public let height: Double
    public let bottomBloom: Double
    public let shoulder: Double

    public init(fullWidth: Double, fullHeight: Double, closedWidth: Double,
                closedHeight: Double, progress: Double, attached: Bool = true) {
        let canvasWidth = Self.dimension(fullWidth)
        let canvasHeight = Self.dimension(fullHeight)
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        let shoulder = attached ? min(min(20, max(8, (canvasWidth - 240) / 17)), canvasWidth * 0.08) : 0
        let bodyWidth = canvasWidth - 2 * shoulder
        let collapsedWidth = min(bodyWidth, Self.dimension(closedWidth))
        let collapsedHeight = min(canvasHeight, Self.dimension(closedHeight))
        let spreadX = 1 - pow(1 - p, 1.25)
        let spreadY = pow(p, 1.06)
        let width = collapsedWidth + (bodyWidth - collapsedWidth) * spreadX
        let height = collapsedHeight + (canvasHeight - collapsedHeight) * spreadY
        let left = (canvasWidth - width) / 2
        let right = (canvasWidth + width) / 2
        let middle = canvasWidth / 2
        let liquid = p == 0 || p == 1 ? 0 : sin(.pi * p)
        let lip = shoulder * p * p * (3 - 2 * p)
        let radius = min(min(height * 0.43, width * 0.49), 14 + 12 * p + 13 * liquid)
        let sideBloom = min(left * 0.5, 7 * liquid)
        let bottomBloom = min((canvasHeight - height) * 0.6, 22 * liquid)
        let bottomSpan = max(0, width / 2 - radius)
        let sideEnd = height - radius
        let sideTop = attached ? min(sideEnd, max(lip, min(1, height * 0.1))) : radius
        let sideRange = max(0, sideEnd - sideTop)
        let outline = CGMutablePath()

        if attached {
            outline.move(to: CGPoint(x: left - lip, y: 0))
            outline.addLine(to: CGPoint(x: right + lip, y: 0))
            outline.addCurve(to: CGPoint(x: right, y: sideTop),
                             control1: CGPoint(x: right + lip * 0.18, y: 0),
                             control2: CGPoint(x: right, y: 0))
        } else {
            outline.move(to: CGPoint(x: left + radius, y: 0))
            outline.addLine(to: CGPoint(x: right - radius, y: 0))
            outline.addCurve(to: CGPoint(x: right, y: sideTop),
                             control1: CGPoint(x: right - radius * 0.43, y: 0),
                             control2: CGPoint(x: right, y: radius * 0.43))
        }
        outline.addCurve(to: CGPoint(x: right, y: sideEnd),
                         control1: CGPoint(x: right, y: sideTop + sideRange * 0.34),
                         control2: CGPoint(x: right + sideBloom, y: sideTop + sideRange * 0.67))
        outline.addCurve(to: CGPoint(x: right - radius, y: height),
                         control1: CGPoint(x: right, y: height - radius * 0.43),
                         control2: CGPoint(x: right - radius * 0.43, y: height))
        outline.addCurve(to: CGPoint(x: middle, y: height + bottomBloom),
                         control1: CGPoint(x: middle + bottomSpan * 0.6, y: height),
                         control2: CGPoint(x: middle + bottomSpan * 0.27, y: height + bottomBloom))
        outline.addCurve(to: CGPoint(x: left + radius, y: height),
                         control1: CGPoint(x: middle - bottomSpan * 0.27, y: height + bottomBloom),
                         control2: CGPoint(x: middle - bottomSpan * 0.6, y: height))
        outline.addCurve(to: CGPoint(x: left, y: sideEnd),
                         control1: CGPoint(x: left + radius * 0.43, y: height),
                         control2: CGPoint(x: left, y: height - radius * 0.43))
        outline.addCurve(to: CGPoint(x: left, y: sideTop),
                         control1: CGPoint(x: left - sideBloom, y: sideTop + sideRange * 0.67),
                         control2: CGPoint(x: left, y: sideTop + sideRange * 0.34))
        if attached {
            outline.addCurve(to: CGPoint(x: left - lip, y: 0),
                             control1: CGPoint(x: left, y: 0),
                             control2: CGPoint(x: left - lip * 0.18, y: 0))
        } else {
            outline.addCurve(to: CGPoint(x: left + radius, y: 0),
                             control1: CGPoint(x: left, y: radius * 0.43),
                             control2: CGPoint(x: left + radius * 0.43, y: 0))
        }
        outline.closeSubpath()
        self.path = outline
        self.boundingRect = outline.boundingBoxOfPath
        self.width = width
        self.height = height
        self.bottomBloom = bottomBloom
        self.shoulder = shoulder
    }

    private static func dimension(_ value: Double) -> Double {
        value.isFinite ? max(1, value) : 1
    }
}
