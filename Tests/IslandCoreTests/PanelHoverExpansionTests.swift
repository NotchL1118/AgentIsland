import XCTest
@testable import IslandCore

final class PanelHoverExpansionTests: XCTestCase {
    private func update(_ policy: inout PanelHoverExpansion, inside: Bool,
                        expanded: Bool = false, mode: IslandPresentation = .floating,
                        dragging: Bool = false, buttonDown: Bool = false,
                        movement: Bool = true) -> Bool {
        policy.update(inside: inside, expanded: expanded, presentation: mode,
                      dragging: dragging, pointerButtonDown: buttonDown,
                      isMouseMovement: movement)
    }

    func testEntryOpensNotchAndFloatingImmediately() {
        for mode in [IslandPresentation.notch, .floating] {
            var policy = PanelHoverExpansion()
            XCTAssertFalse(update(&policy, inside: false, mode: mode))
            XCTAssertTrue(update(&policy, inside: true, mode: mode))
        }
    }

    func testMenuBarNeverOpensFromHover() {
        var policy = PanelHoverExpansion()
        for _ in 0..<3 {
            XCTAssertFalse(update(&policy, inside: false, mode: .menuBar))
            XCTAssertFalse(update(&policy, inside: true, mode: .menuBar))
        }
    }

    func testManualCollapseWhileInsideRequiresLeavingAndReentering() {
        var policy = PanelHoverExpansion()
        XCTAssertTrue(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: true, expanded: true))
        XCTAssertFalse(update(&policy, inside: true, movement: false))
        XCTAssertFalse(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: false))
        XCTAssertTrue(update(&policy, inside: true))
    }

    func testClicksRecordPositionButDoNotCountAsHoverEntry() {
        var policy = PanelHoverExpansion()
        XCTAssertFalse(update(&policy, inside: false, buttonDown: true, movement: false))
        XCTAssertFalse(update(&policy, inside: true, buttonDown: true, movement: false))
        XCTAssertFalse(update(&policy, inside: true, movement: false))
        XCTAssertFalse(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: false))
        XCTAssertTrue(update(&policy, inside: true))
    }

    func testHeldButtonEntryDoesNotExpandAfterButtonReleaseInside() {
        var policy = PanelHoverExpansion()
        XCTAssertFalse(update(&policy, inside: true, buttonDown: true))
        XCTAssertFalse(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: false))
        XCTAssertTrue(update(&policy, inside: true))
    }

    func testDraggingEntryDoesNotBecomeAReleaseEntry() {
        var policy = PanelHoverExpansion()
        XCTAssertFalse(update(&policy, inside: false, dragging: true))
        XCTAssertFalse(update(&policy, inside: true, dragging: true))
        XCTAssertFalse(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: false))
        XCTAssertTrue(update(&policy, inside: true))
    }

    func testModeResetAllowsTheNewPresentationToObserveEntry() {
        var policy = PanelHoverExpansion()
        XCTAssertFalse(update(&policy, inside: true, mode: .menuBar))
        policy.reset()
        XCTAssertTrue(update(&policy, inside: true, mode: .floating))
    }

    func testExpandedBeforeDismissalPreventsReopeningInTheSameEvent() {
        var policy = PanelHoverExpansion()
        let expandedBeforeDismissal = true
        let expandedAfterDismissal = false
        XCTAssertFalse(update(&policy, inside: true,
                              expanded: expandedBeforeDismissal || expandedAfterDismissal))
        XCTAssertFalse(update(&policy, inside: true))
        XCTAssertFalse(update(&policy, inside: false))
        XCTAssertTrue(update(&policy, inside: true))
    }
}
