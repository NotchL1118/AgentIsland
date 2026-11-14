import Foundation
import CoreGraphics

/// A display-relative position survives changes to screen resolution and to the
/// global origins of screens. Vertical position describes the bar's top edge.
public struct SavedPanelPosition: Codable, Equatable {
    public let displayID: String
    public let horizontal: Double
    public let vertical: Double

    public init(displayID: String, horizontal: Double, vertical: Double) {
        self.displayID = displayID
        self.horizontal = Self.fraction(horizontal, fallback: 0.5)
        self.vertical = Self.fraction(vertical, fallback: 1)
    }

    public init(displayID: String, anchor: CGPoint, visibleFrame: CGRect) {
        let frame = PanelPlacement.usableFrame(visibleFrame)
        self.init(displayID: displayID,
                  horizontal: (anchor.x - frame.minX) / frame.width,
                  vertical: (anchor.y - frame.minY) / frame.height)
    }

    public func anchor(in visibleFrame: CGRect) -> CGPoint {
        let frame = PanelPlacement.usableFrame(visibleFrame)
        return CGPoint(x: frame.minX + frame.width * Self.fraction(horizontal, fallback: 0.5),
                       y: frame.minY + frame.height * Self.fraction(vertical, fallback: 1))
    }

    private static func fraction(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
}

public enum PanelPlacement {
    /// Anchor coordinates are AppKit global coordinates: horizontal center and
    /// top edge. visibleSize describes the silhouette, excluding its shadow.
    /// An oversized panel keeps its top edge reachable; the caller should also
    /// constrain panel dimensions to the display's available space.
    public static func clampedAnchor(_ preferredAnchor: CGPoint, visibleFrame: CGRect,
                                     visibleSize: CGSize, margin: CGFloat = 8) -> CGPoint {
        let frame = usableFrame(visibleFrame)
        let requestedMargin = margin.isFinite ? max(0, margin) : 8
        let inset = min(requestedMargin, frame.width / 2, frame.height / 2)
        let available = frame.insetBy(dx: inset, dy: inset)
        let width = dimension(visibleSize.width)
        let height = dimension(visibleSize.height)
        let x = preferredAnchor.x.isFinite ? preferredAnchor.x : available.midX
        let y = preferredAnchor.y.isFinite ? preferredAnchor.y : available.maxY
        let halfWidth = min(width, available.width) / 2
        let fittedHeight = min(height, available.height)
        return CGPoint(x: min(available.maxX - halfWidth, max(available.minX + halfWidth, x)),
                       y: min(available.maxY, max(available.minY + fittedHeight, y)))
    }

    /// Finds the display containing the greatest portion of the dragged bar.
    /// When the previous display disappears, the nearest remaining rectangle
    /// wins. Invalid frames are ignored and equal matches retain input order.
    public static func bestScreenIndex(screenFrames: [CGRect], anchor: CGPoint,
                                       barSize: CGSize = CGSize(width: 300, height: 36)) -> Int? {
        let x = anchor.x.isFinite ? anchor.x : 0
        let y = anchor.y.isFinite ? anchor.y : 0
        let width = dimension(barSize.width)
        let height = dimension(barSize.height)
        let bar = CGRect(x: x - width / 2, y: y - height, width: width, height: height)
        let center = CGPoint(x: bar.midX, y: bar.midY)
        var best: Int?
        var bestOverlap: CGFloat = -1
        var bestDistance: CGFloat = .infinity
        for (index, frame) in screenFrames.enumerated() where isUsable(frame) {
            let overlap = frame.intersection(bar)
            let area: CGFloat = overlap.isNull ? 0 : overlap.width * overlap.height
            let dx = max(frame.minX - center.x, 0, center.x - frame.maxX)
            let dy = max(frame.minY - center.y, 0, center.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if area > bestOverlap || area == bestOverlap && distance < bestDistance {
                best = index
                bestOverlap = area
                bestDistance = distance
            }
        }
        return best
    }

    fileprivate static func usableFrame(_ frame: CGRect) -> CGRect {
        isUsable(frame) ? frame : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    private static func dimension(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(1, value) : 1
    }
}
