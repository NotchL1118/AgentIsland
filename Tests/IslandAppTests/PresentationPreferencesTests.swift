import XCTest
import Foundation
import IslandCore
@testable import AgentIsland

final class PresentationPreferencesTests: XCTestCase {
    func testLegacyFloatingPreferenceOnlyAppliesWithoutAValidExplicitMode() {
        XCTAssertEqual(IslandPresentation.restored(rawValue: nil, legacyFloating: true), .floating)
        XCTAssertEqual(IslandPresentation.restored(rawValue: nil, legacyFloating: false), .notch)
        XCTAssertEqual(IslandPresentation.restored(rawValue: "unknown", legacyFloating: true), .floating)
        XCTAssertEqual(IslandPresentation.restored(rawValue: "menuBar", legacyFloating: true), .menuBar)
        XCTAssertEqual(IslandPresentation.restored(rawValue: "notch", legacyFloating: true), .notch)
    }

    @MainActor
    func testExplicitModePersistsAndRestoresWithoutChangingExpansion() async throws {
        let suite = "AgentIsland.PresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "floating")
        let model = AppModel(demo: false, socketPath: testSocketPath(), defaults: defaults)
        defer { model.shutdown() }
        XCTAssertEqual(model.presentation, .floating)
        model.expanded = false
        model.setPresentation(.menuBar)
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(defaults.string(forKey: "presentationMode"), "menuBar")

        let restored = AppModel(demo: false, socketPath: testSocketPath(), defaults: defaults)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.menuBarOnly)
        XCTAssertFalse(restored.floating)
    }

    @MainActor
    func testDemoPresentationAndPreferencesDoNotPersist() async throws {
        let suite = "AgentIsland.PresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("notch", forKey: "presentationMode")
        defaults.set(true, forKey: "autoExpand")
        defaults.set(false, forKey: "notificationsEnabled")
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }
        model.setPresentation(.floating)
        model.autoExpand = false
        model.notificationsEnabled = true
        model.savePreferences()
        XCTAssertTrue(model.floating)
        XCTAssertEqual(defaults.string(forKey: "presentationMode"), "notch")
        XCTAssertTrue(defaults.bool(forKey: "autoExpand"))
        XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
    }

    @MainActor
    func testMenuBarLayoutOmitsCompactStripAndResetOnlyEmitsPositionRequest() async throws {
        let suite = "AgentIsland.PresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }
        model.setPresentation(.floating)
        let floatingHeight = IslandView.contentHeight(for: model, notchHeight: 0)
        let resetID = model.positionResetID
        model.resetFloatingPosition()
        XCTAssertNotEqual(model.positionResetID, resetID)
        XCTAssertEqual(model.presentation, .floating)
        model.setPresentation(.menuBar)
        XCTAssertEqual(IslandView.contentHeight(for: model, notchHeight: 0), floatingHeight - 36)
    }

    @MainActor
    func testMenuBarPendingEventStaysHiddenUntilExplicitNotificationClick() async throws {
        let suite = "AgentIsland.PresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("menuBar", forKey: "presentationMode")
        defaults.set(true, forKey: "autoExpand")
        let path = testSocketPath()
        let model = AppModel(demo: false, socketPath: path, defaults: defaults)
        defer { model.shutdown() }
        model.expanded = false
        model.notificationsEnabled = false
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        try client.send(AgentEvent(provider: .claude, sessionID: "menu-bar", kind: .approvalRequested,
                                   request: AgentRequest(id: "run-tests", kind: .approval, title: "Run tests?")))
        let deadline = Date().addingTimeInterval(3)
        while model.pendingCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertFalse(model.expanded, "Background requests should only update the menu bar status.")
        model.revealFromNotification("claude:menu-bar")
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.selectedID, "claude:menu-bar")
    }
}
