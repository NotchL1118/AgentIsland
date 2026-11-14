import XCTest
@testable import IslandCore

final class PanelAutoCollapseTests: XCTestCase {
    private func update(_ policy: inout PanelAutoCollapse, at now: TimeInterval,
                        mode: IslandPresentation = .floating, inside: Bool = false,
                        expanded: Bool = true, dragging: Bool = false,
                        delay: TimeInterval = 0.3, click: Bool = false) -> Bool {
        policy.update(now: now, expanded: expanded, presentation: mode,
                      pointerInside: inside, isDragging: dragging, delay: delay,
                      outsideClick: click)
    }

    func testOutsideClickCollapsesAllPresentationsAfterSameDelay() {
        for mode in IslandPresentation.allCases {
            var policy = PanelAutoCollapse()
            XCTAssertFalse(update(&policy, at: 0, mode: mode, click: true))
            XCTAssertEqual(policy.pending?.reason, .outsideClick)
            XCTAssertFalse(update(&policy, at: 0.299, mode: mode))
            XCTAssertTrue(update(&policy, at: 0.3, mode: mode))
            XCTAssertNil(policy.pending)
        }
    }

    func testPointerExitCollapsesNotchAndFloatingRegardlessOfOpeningSource() {
        for mode in [IslandPresentation.notch, .floating] {
            var policy = PanelAutoCollapse()
            // No prior entry or hover-open marker is required: clicking or a
            // task event can open a panel while the pointer is already outside.
            XCTAssertFalse(update(&policy, at: 0, mode: mode))
            XCTAssertEqual(policy.pending?.reason, .pointerExit)
            XCTAssertTrue(update(&policy, at: 0.3, mode: mode))
        }
    }

    func testMenuBarIgnoresPointerExitAndCancelsAnOldPointerDeadline() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0, mode: .menuBar))
        XCTAssertFalse(update(&policy, at: 10, mode: .menuBar))
        XCTAssertNil(policy.pending)
        XCTAssertFalse(update(&policy, at: 11, mode: .notch))
        XCTAssertFalse(update(&policy, at: 12, mode: .menuBar))
        XCTAssertNil(policy.pending)
    }

    func testFrequentOutsideMouseMovementDoesNotExtendDeadline() {
        var policy = PanelAutoCollapse()
        for step in 0..<30 {
            XCTAssertFalse(update(&policy, at: Double(step) / 100))
            XCTAssertEqual(policy.pending?.startedAt, 0)
            XCTAssertEqual(policy.pending?.deadline ?? -1, 0.3, accuracy: 0.000001)
        }
        XCTAssertTrue(update(&policy, at: 0.3))
    }

    func testReturningInsideCancelsPointerExitAndNextExitStartsFresh() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0))
        XCTAssertFalse(update(&policy, at: 0.2, inside: true))
        XCTAssertNil(policy.pending)
        XCTAssertFalse(update(&policy, at: 0.5, inside: true))
        XCTAssertFalse(update(&policy, at: 1))
        XCTAssertEqual(policy.pending?.startedAt, 1)
        XCTAssertFalse(update(&policy, at: 1.29))
        XCTAssertTrue(update(&policy, at: 1.3))
    }

    func testOutsideClickSupersedesPointerExitAndSurvivesReentry() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0))
        XCTAssertFalse(update(&policy, at: 0.2, click: true))
        XCTAssertEqual(policy.pending?.reason, .outsideClick)
        XCTAssertEqual(policy.pending?.startedAt, 0.2)
        XCTAssertFalse(update(&policy, at: 0.3, inside: true))
        XCTAssertEqual(policy.pending?.reason, .outsideClick)
        XCTAssertFalse(update(&policy, at: 0.49, inside: true))
        XCTAssertTrue(update(&policy, at: 0.5, inside: true))
    }

    func testRepeatedOutsideClicksDoNotPostponeExplicitDismissal() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0, mode: .menuBar, click: true))
        XCTAssertFalse(update(&policy, at: 0.2, mode: .menuBar, click: true))
        XCTAssertEqual(policy.pending?.startedAt, 0)
        XCTAssertTrue(update(&policy, at: 0.3, mode: .menuBar, click: true))
    }

    func testManualCollapseAndDraggingCancelAllPendingReasons() {
        for click in [false, true] {
            var policy = PanelAutoCollapse()
            XCTAssertFalse(update(&policy, at: 0, click: click))
            XCTAssertFalse(update(&policy, at: 0.1, expanded: false))
            XCTAssertNil(policy.pending)
            XCTAssertFalse(update(&policy, at: 1, click: click))
            XCTAssertFalse(update(&policy, at: 1.1, dragging: true))
            XCTAssertNil(policy.pending)
            XCTAssertFalse(update(&policy, at: 2, dragging: true, click: true))
            XCTAssertNil(policy.pending)
            XCTAssertFalse(update(&policy, at: 3))
            XCTAssertTrue(update(&policy, at: 3.3))
        }
    }

    func testPreferenceChangesUseOriginalTriggerTime() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0, delay: 0.3))
        XCTAssertFalse(update(&policy, at: 0.2, delay: 1))
        XCTAssertEqual(policy.pending?.startedAt, 0)
        XCTAssertEqual(policy.pending?.deadline, 1)
        XCTAssertFalse(update(&policy, at: 0.99, delay: 1))
        XCTAssertTrue(update(&policy, at: 1, delay: 1))

        XCTAssertFalse(update(&policy, at: 2, delay: 1, click: true))
        XCTAssertTrue(update(&policy, at: 2.4, inside: true, delay: 0.3))
    }

    func testZeroNegativeAndOutOfRangeDelaysAreBounded() {
        for delay in [0.0, -1] {
            var policy = PanelAutoCollapse()
            XCTAssertTrue(update(&policy, at: 0, delay: delay, click: true))
            XCTAssertNil(policy.pending)
        }
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0, delay: 100, click: true))
        XCTAssertEqual(policy.pending?.deadline, 2)
        XCTAssertTrue(update(&policy, at: 2, delay: 100))
    }

    func testInvalidTimesDoNotCreateOrPoisonDeadlines() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: .nan, click: true))
        XCTAssertNil(policy.pending)
        XCTAssertFalse(update(&policy, at: 0, delay: .infinity, click: true))
        XCTAssertEqual(policy.pending?.deadline, 0.3)
        XCTAssertFalse(update(&policy, at: .infinity))
        XCTAssertEqual(policy.pending?.deadline, 0.3)
        XCTAssertTrue(update(&policy, at: 0.3, delay: .nan))
    }

    func testResetLetsExplicitReopeningStartANewDeadline() {
        var policy = PanelAutoCollapse()
        XCTAssertFalse(update(&policy, at: 0, click: true))
        policy.reset()
        XCTAssertNil(policy.pending)
        XCTAssertFalse(update(&policy, at: 1, inside: true))
        XCTAssertNil(policy.pending)
        XCTAssertFalse(update(&policy, at: 2))
        XCTAssertEqual(policy.pending?.reason, .pointerExit)
        XCTAssertTrue(update(&policy, at: 2.3))
    }
}
