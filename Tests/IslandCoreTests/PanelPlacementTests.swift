import XCTest
import CoreGraphics
@testable import IslandCore

final class PanelPlacementTests: XCTestCase {
    func testCollapsedBarCanMoveNearEdgesAndExpandedBodyStaysVisible() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let preferred = CGPoint(x: 160, y: 80)
        let collapsed = PanelPlacement.clampedAnchor(preferred, visibleFrame: screen,
                                                     visibleSize: CGSize(width: 300, height: 36))
        let expanded = PanelPlacement.clampedAnchor(preferred, visibleFrame: screen,
                                                    visibleSize: CGSize(width: 800, height: 434))
        XCTAssertEqual(collapsed, preferred)
        XCTAssertEqual(expanded, CGPoint(x: 408, y: 442))
        // Expanding only computes a temporary safe position; it does not mutate
        // the saved collapsed position, which is restored when closing.
        XCTAssertEqual(PanelPlacement.clampedAnchor(preferred, visibleFrame: screen,
                                                    visibleSize: CGSize(width: 300, height: 36)), preferred)
    }

    func testClampingHonorsNegativeScreenOriginsAndTopMargin() {
        let screen = CGRect(x: -1920, y: -250, width: 1920, height: 1050)
        let position = PanelPlacement.clampedAnchor(CGPoint(x: 100, y: 1200), visibleFrame: screen,
                                                   visibleSize: CGSize(width: 800, height: 434))
        XCTAssertEqual(position, CGPoint(x: -408, y: 792))
        let opposite = PanelPlacement.clampedAnchor(CGPoint(x: -3000, y: -1000), visibleFrame: screen,
                                                   visibleSize: CGSize(width: 300, height: 36))
        XCTAssertEqual(opposite, CGPoint(x: -1762, y: -206))
    }

    func testNormalizedPositionRestoresOnChangedResolutionAndOrigin() throws {
        let original = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
        let saved = SavedPanelPosition(displayID: "external-display", anchor: CGPoint(x: -1440, y: 550),
                                      visibleFrame: original)
        XCTAssertEqual(saved.horizontal, 0.25)
        XCTAssertEqual(saved.vertical, 0.75)
        XCTAssertEqual(saved.anchor(in: CGRect(x: 100, y: 400, width: 2560, height: 1400)),
                       CGPoint(x: 740, y: 1450))
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedPanelPosition.self, from: data), saved)
    }

    func testCrossingDisplaysChoosesGreatestVisibleBarArea() {
        let screens = [CGRect(x: -1440, y: 0, width: 1440, height: 900),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: screens, anchor: CGPoint(x: -20, y: 400)), 0)
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: screens, anchor: CGPoint(x: 20, y: 400)), 1)
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: screens, anchor: CGPoint(x: 0, y: 400)), 0)
    }

    func testRemovedDisplayFallsBackToNearestRemainingScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let disappearedAnchor = CGPoint(x: -1200, y: 600)
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: screens, anchor: disappearedAnchor), 0)
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: screens, anchor: CGPoint(x: 4000, y: 400)), 1)
        XCTAssertNil(PanelPlacement.bestScreenIndex(screenFrames: [], anchor: disappearedAnchor))
    }

    func testTinyScreenKeepsTopReachableWithoutInvertedClampRanges() {
        let screen = CGRect(x: -50, y: 20, width: 100, height: 60)
        let anchor = PanelPlacement.clampedAnchor(CGPoint(x: 2000, y: -500), visibleFrame: screen,
                                                 visibleSize: CGSize(width: 800, height: 434))
        XCTAssertEqual(anchor, CGPoint(x: 0, y: 72))
        let onePoint = PanelPlacement.clampedAnchor(.zero, visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                   visibleSize: CGSize(width: 300, height: 36))
        XCTAssertEqual(onePoint, CGPoint(x: 0.5, y: 0.5))
    }

    func testInvalidPersistenceAndFramesCannotCreateOffscreenNaNPositions() {
        let saved = SavedPanelPosition(displayID: "screen", horizontal: .nan, vertical: .infinity)
        XCTAssertEqual(saved.anchor(in: CGRect(x: 0, y: 0, width: 1440, height: 900)), CGPoint(x: 720, y: 900))
        let clamped = PanelPlacement.clampedAnchor(CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                                                  visibleFrame: .null, visibleSize: CGSize(width: CGFloat.nan, height: -1))
        XCTAssertTrue(clamped.x.isFinite)
        XCTAssertTrue(clamped.y.isFinite)
        XCTAssertEqual(SavedPanelPosition(displayID: "screen", horizontal: -20, vertical: 50).anchor(in: .zero),
                       CGPoint(x: 0, y: 1))
        XCTAssertEqual(PanelPlacement.bestScreenIndex(screenFrames: [.null, CGRect(x: 0, y: 0, width: 100, height: 100)],
                                                      anchor: .zero), 1)
        XCTAssertNil(PanelPlacement.bestScreenIndex(screenFrames: [.null, .zero], anchor: .zero))
    }
}
