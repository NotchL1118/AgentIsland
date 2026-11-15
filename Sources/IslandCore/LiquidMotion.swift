import Foundation
import CoreGraphics

/// The menu-bar outline gathers before its lower edge rises into the icon.
/// Opening traverses the same shape faster and eases out, so the body appears
/// promptly instead of waiting through the close animation's terminal intake.
public enum MenuBarCollapse {
    public static let duration: Double = 0.26
    public static let openingDuration: Double = 0.18

    public static func openingProgress(_ elapsedFraction: Double) -> Double {
        let remaining = 1 - unit(elapsedFraction)
        return 1 - remaining * remaining * remaining
    }

    /// Recover the opening clock at the current shape when reversing a close.
    public static func openingTime(for progress: Double) -> Double {
        1 - cbrt(1 - unit(progress))
    }

    public static func surfaceOpacity(progress: Double) -> Double {
        smooth(unit(progress) / 0.11)
    }

    public static func shadowProgress(progress: Double) -> Double {
        1 - smooth((1 - unit(progress)) / 0.70)
    }

    public static func contentVisibility(progress: Double, index: Int) -> Double {
        let end = 0.34 - Double(min(4, max(0, index))) * 0.022
        return 1 - smooth((1 - unit(progress)) / end)
    }

    fileprivate static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    fileprivate static func smooth(_ value: Double) -> Double {
        let t = unit(value)
        return t * t * (3 - 2 * t)
    }

    fileprivate static func smoother(_ value: Double) -> Double {
        let t = unit(value)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

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
                closedHeight: Double, progress: Double, attached: Bool = true,
                collapsePoint: CGPoint? = nil) {
        let canvasWidth = Self.dimension(fullWidth)
        let canvasHeight = Self.dimension(fullHeight)
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        let shoulder = attached ? min(min(20, max(8, (canvasWidth - 240) / 17)), canvasWidth * 0.08) : 0
        let bodyWidth = canvasWidth - 2 * shoulder
        // Menu-bar panels disappear into their status item. Their closed
        // silhouette must reach zero rather than leave a minimum-size tile.
        let collapsedWidth = min(bodyWidth, Self.closedDimension(closedWidth))
        let collapsedHeight = min(canvasHeight, Self.closedDimension(closedHeight))
        let spreadX = 1 - pow(1 - p, 1.25)
        let spreadY = pow(p, 1.06)
        let target = collapsePoint.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
            ?? CGPoint(x: canvasWidth / 2, y: 0)
        if !attached, collapsedWidth == 0, collapsedHeight == 0 {
            self = Self.menuBar(width: canvasWidth, height: canvasHeight, progress: p, target: target)
            return
        }
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
        // Only the mask moves. Each edge converges on the status image using
        // the same continuous spread as its size, with no separate flight.
        var offset = CGAffineTransform(translationX: (target.x - middle) * (1 - spreadX),
                                       y: target.y * (1 - spreadY))
        let positionedOutline = outline.copy(using: &offset) ?? outline
        // Core Graphics treats the endpoint of a degenerate closed path as a
        // hit. An empty path also removes the fill and shadow at rest.
        self.path = width == 0 && height == 0 ? CGMutablePath() : positionedOutline
        self.boundingRect = width == 0 && height == 0
            ? CGRect(origin: target, size: .zero)
            : positionedOutline.boundingBoxOfPath
        self.width = width
        self.height = height
        self.bottomBloom = bottomBloom
        self.shoulder = shoulder
    }

    private init(path: CGPath, boundingRect: CGRect, width: Double, height: Double) {
        self.path = path
        self.boundingRect = boundingRect
        self.width = width
        self.height = height
        self.bottomBloom = 0
        self.shoulder = 0
    }

    private static func menuBar(width: Double, height: Double, progress: Double,
                                target: CGPoint) -> LiquidGeometry {
        guard progress > 0 else {
            // A degenerate closed path still counts as a hit in Core Graphics.
            return LiquidGeometry(path: CGMutablePath(), boundingRect: CGRect(origin: target, size: .zero),
                                  width: 0, height: 0)
        }
        let t = 1 - progress
        func mix(_ start: Double, _ end: Double, _ amount: Double) -> Double {
            start + (end - start) * amount
        }
        let middle = width / 2
        let halfTipHeight = min(5, height / 2)
        let topWidth = mix(width, min(12, width), MenuBarCollapse.smooth(t / 0.68))
        let bottomWidth = mix(width, min(10, width), MenuBarCollapse.smooth((t - 0.08) / 0.84))
        let leftLimit = min(0, target.x - min(6, width / 2))
        let rightLimit = max(width, target.x + min(6, width / 2))
        func center(_ amount: Double, span: Double) -> Double {
            min(rightLimit - span / 2, max(leftLimit + span / 2, mix(middle, target.x, amount)))
        }
        let topX = center(MenuBarCollapse.smooth(t / 0.59), span: topWidth)
        let bottomX = center(MenuBarCollapse.smooth((t - 0.035) / 0.82), span: bottomWidth)
        let top = mix(0, target.y - halfTipHeight, MenuBarCollapse.smooth(t / 0.72))
        let bottom = max(top, mix(height, target.y + halfTipHeight,
                                  MenuBarCollapse.smoother((t - 0.10) / 0.90)))
        let span = bottom - top
        let topRadius = min(mix(20, 5, t), topWidth / 2, span / 2)
        let bottomRadius = min(mix(22, 5, t), bottomWidth / 2, span / 2)
        let leftTop = topX - topWidth / 2
        let rightTop = topX + topWidth / 2
        let leftBottom = bottomX - bottomWidth / 2
        let rightBottom = bottomX + bottomWidth / 2
        // Clamp control heights to the straight side's endpoints so even a
        // subpixel terminal frame cannot fold back on itself.
        let sideStart = top + topRadius
        let sideEnd = bottom - bottomRadius
        let controlTop = min(sideEnd, max(sideStart, top + span * 0.52))
        let controlBottom = min(sideEnd, max(controlTop, bottom - span * 0.42))
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: leftTop + topRadius, y: top))
        outline.addLine(to: CGPoint(x: rightTop - topRadius, y: top))
        outline.addQuadCurve(to: CGPoint(x: rightTop, y: sideStart),
                             control: CGPoint(x: rightTop, y: top))
        outline.addCurve(to: CGPoint(x: rightBottom, y: sideEnd),
                         control1: CGPoint(x: rightTop, y: controlTop),
                         control2: CGPoint(x: rightBottom, y: controlBottom))
        outline.addQuadCurve(to: CGPoint(x: rightBottom - bottomRadius, y: bottom),
                             control: CGPoint(x: rightBottom, y: bottom))
        outline.addLine(to: CGPoint(x: leftBottom + bottomRadius, y: bottom))
        outline.addQuadCurve(to: CGPoint(x: leftBottom, y: sideEnd),
                             control: CGPoint(x: leftBottom, y: bottom))
        outline.addCurve(to: CGPoint(x: leftTop, y: sideStart),
                         control1: CGPoint(x: leftBottom, y: controlBottom),
                         control2: CGPoint(x: leftTop, y: controlTop))
        outline.addQuadCurve(to: CGPoint(x: leftTop + topRadius, y: top),
                             control: CGPoint(x: leftTop, y: top))
        outline.closeSubpath()

        // The final intake fades and shrinks inside the icon, with no minimum
        // tile and no discontinuity when the window is hidden at progress zero.
        let terminalScale = MenuBarCollapse.surfaceOpacity(progress: progress)
        var transform = CGAffineTransform(a: terminalScale, b: 0, c: 0, d: terminalScale,
                                          tx: target.x * (1 - terminalScale),
                                          ty: target.y * (1 - terminalScale))
        let path = outline.copy(using: &transform) ?? outline
        let bounds = path.boundingBoxOfPath
        return LiquidGeometry(path: path, boundingRect: bounds, width: bounds.width, height: bounds.height)
    }

    private static func dimension(_ value: Double) -> Double {
        value.isFinite ? max(1, value) : 1
    }

    private static func closedDimension(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
