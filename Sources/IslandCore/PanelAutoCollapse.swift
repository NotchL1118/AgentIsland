import Foundation

/// A deterministic deadline policy shared by all panel presentations. Window
/// focus and the source of expansion intentionally do not affect dismissal.
public struct PanelAutoCollapse {
    public enum Reason: Equatable {
        case pointerExit
        case outsideClick
    }

    public struct Pending: Equatable {
        public let reason: Reason
        public let startedAt: TimeInterval
        public let deadline: TimeInterval
    }

    public private(set) var pending: Pending?

    public init() {}

    public mutating func reset() { pending = nil }

    /// Returns true when the caller should collapse the panel. Repeated mouse
    /// events never postpone a deadline. An outside click remains an explicit
    /// dismissal even if the pointer moves back into the panel before it fires.
    @discardableResult
    public mutating func update(now: TimeInterval, expanded: Bool,
                                presentation: IslandPresentation, pointerInside: Bool,
                                isDragging: Bool, delay: TimeInterval,
                                outsideClick: Bool = false) -> Bool {
        guard expanded, !isDragging else {
            reset()
            return false
        }
        guard now.isFinite else { return false }
        let delay = delay.isFinite ? min(2, max(0, delay)) : 0.3

        if outsideClick {
            if pending?.reason != .outsideClick {
                pending = Pending(reason: .outsideClick, startedAt: now, deadline: now + delay)
            }
        } else if pointerInside || presentation == .menuBar {
            if pending?.reason == .pointerExit { reset() }
        } else if pending == nil {
            pending = Pending(reason: .pointerExit, startedAt: now, deadline: now + delay)
        }

        if let current = pending {
            // A changed preference applies to the original trigger time.
            let deadline = current.startedAt + delay
            pending = Pending(reason: current.reason, startedAt: current.startedAt, deadline: deadline)
            if now >= deadline {
                reset()
                return true
            }
        }
        return false
    }
}
