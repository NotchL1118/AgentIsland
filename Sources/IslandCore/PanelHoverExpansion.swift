/// Tracks pointer entry independently of how a panel was last opened or closed.
/// Repeated movement inside a manually collapsed panel must not reopen it.
public struct PanelHoverExpansion {
    private var previousInside = false

    public init() {}

    /// Reset when changing presentation, not on every collapse or redraw.
    public mutating func reset() { previousInside = false }

    /// Call for pointer events, including clicks and events observed during a
    /// drag. When dismissal can run earlier in the same event, pass `expanded`
    /// as the OR of the expansion state before and after dismissal so that the
    /// same mouse movement cannot immediately undo an automatic collapse.
    @discardableResult
    public mutating func update(inside: Bool, expanded: Bool,
                                presentation: IslandPresentation, dragging: Bool,
                                pointerButtonDown: Bool, isMouseMovement: Bool) -> Bool {
        let entered = inside && !previousInside
        previousInside = inside
        return entered && isMouseMovement && !expanded &&
            presentation != .menuBar && !dragging && !pointerButtonDown
    }
}
