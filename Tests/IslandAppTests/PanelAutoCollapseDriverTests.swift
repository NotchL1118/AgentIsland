import XCTest
import Foundation
import IslandCore
@testable import AgentIsland

@MainActor
private final class CollapseDriverFixture {
    let driver = PanelAutoCollapseDriver()
    var context: PanelAutoCollapseDriver.Context
    var collapseTimes: [TimeInterval] = []

    init(presentation: IslandPresentation = .floating, delay: TimeInterval = 0.3) {
        context = .init(expanded: true, presentation: presentation, pointerInside: false,
                        isDragging: false, delay: delay)
        driver.context = { [weak self] in self?.context }
        driver.onCollapse = { [weak self] in
            guard let self else { return }
            self.collapseTimes.append(ProcessInfo.processInfo.systemUptime)
            self.context.expanded = false
        }
    }
}

final class PanelAutoCollapseDriverTests: XCTestCase {
    @MainActor
    private func waitForCollapse(_ fixture: CollapseDriverFixture, timeout: TimeInterval = 1) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while fixture.collapseTimes.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fixture.collapseTimes.count, 1)
    }

    @MainActor
    func testDefaultDelayWaitsThreeTenthsThenCollapsesOnce() async throws {
        let fixture = CollapseDriverFixture()
        defer { fixture.driver.reset() }
        let started = ProcessInfo.processInfo.systemUptime
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)
        try await waitForCollapse(fixture)
        let collapsed = try XCTUnwrap(fixture.collapseTimes.first)
        XCTAssertGreaterThanOrEqual(collapsed - started, 0.29)
        XCTAssertLessThan(collapsed - started, 1)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(fixture.collapseTimes.count, 1)
    }

    @MainActor
    func testReturningInsideCancelsPendingMouseExit() async throws {
        let fixture = CollapseDriverFixture(delay: 0.1)
        defer { fixture.driver.reset() }
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        fixture.context.pointerInside = true
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)
        XCTAssertTrue(fixture.context.expanded)
    }

    @MainActor
    func testOutsideClickCollapsesEveryModeEvenAfterPointerReturns() async throws {
        for mode in IslandPresentation.allCases {
            let fixture = CollapseDriverFixture(presentation: mode, delay: 0.05)
            fixture.driver.update(outsideClick: true)
            fixture.context.pointerInside = true
            fixture.driver.update()
            try await waitForCollapse(fixture)
            XCTAssertFalse(fixture.context.expanded, "Outside clicks must dismiss \(mode.rawValue).")
            fixture.driver.reset()
        }
    }

    @MainActor
    func testMenuBarMouseExitAloneNeverSchedulesCollapse() async throws {
        let fixture = CollapseDriverFixture(presentation: .menuBar, delay: 0.05)
        defer { fixture.driver.reset() }
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 120_000_000)
        fixture.driver.update()
        XCTAssertTrue(fixture.collapseTimes.isEmpty)
        XCTAssertTrue(fixture.context.expanded)
    }

    @MainActor
    func testDraggingCancelsOldDeadlineAndReleaseStartsFreshDelay() async throws {
        let fixture = CollapseDriverFixture(delay: 0.1)
        defer { fixture.driver.reset() }
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        fixture.context.isDragging = true
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)

        fixture.context.isDragging = false
        let released = ProcessInfo.processInfo.systemUptime
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)
        try await waitForCollapse(fixture)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.collapseTimes.first) - released, 0.09)
    }

    @MainActor
    func testRepeatedUpdatesDoNotKeepPostponingCollapse() async throws {
        let fixture = CollapseDriverFixture(delay: 0.12)
        defer { fixture.driver.reset() }
        let stopUpdating = ProcessInfo.processInfo.systemUptime + 0.25
        while ProcessInfo.processInfo.systemUptime < stopUpdating {
            fixture.driver.update()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(fixture.collapseTimes.count, 1, "Continuous motion or redraws must not restart the deadline.")
    }

    @MainActor
    func testShortenedDelayUsesOriginalTriggerTimeAndCancelsOldTimer() async throws {
        let fixture = CollapseDriverFixture(delay: 0.3)
        defer { fixture.driver.reset() }
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 80_000_000)
        fixture.context.delay = 0.05
        fixture.driver.update()
        XCTAssertEqual(fixture.collapseTimes.count, 1, "The shorter deadline has already elapsed and must fire now.")
        try await Task.sleep(nanoseconds: 260_000_000)
        XCTAssertEqual(fixture.collapseTimes.count, 1)
    }

    @MainActor
    func testResetAndMissingContextCancelScheduledCallbacks() async throws {
        let fixture = CollapseDriverFixture(delay: 0.05)
        fixture.driver.update(outsideClick: true)
        fixture.driver.reset()
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)

        fixture.driver.update(outsideClick: true)
        fixture.driver.context = { nil }
        fixture.driver.update()
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(fixture.collapseTimes.isEmpty)
        fixture.driver.reset()
    }
}
