import XCTest
import Foundation
import IslandCore
@testable import AgentIsland

final class SettingsRoutingTests: XCTestCase {
    @MainActor
    func testAgentSettingsRequestClosesQuickPanelAndCanRepeat() async throws {
        let suite = "AgentIsland.SettingsRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }
        model.showingSettings = true
        model.expanded = true
        let originalRequest = model.settingsWindowRequestID

        model.requestSettingsWindow()

        XCTAssertEqual(model.settingsWindowSection, .agents)
        XCTAssertNotEqual(model.settingsWindowRequestID, originalRequest)
        XCTAssertFalse(model.showingSettings)
        XCTAssertFalse(model.expanded)
        let firstRequest = model.settingsWindowRequestID
        model.requestSettingsWindow()
        XCTAssertNotEqual(model.settingsWindowRequestID, firstRequest,
                          "Repeated requests must bring an existing settings window forward.")
    }

    @MainActor
    func testRequestsSelectSectionsWhileWindowControllerOwnsVisibility() async throws {
        let suite = "AgentIsland.SettingsRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }

        model.requestSettingsWindow(.general)

        XCTAssertEqual(model.settingsWindowSection, .general)
        XCTAssertFalse(model.isSettingsWindowVisible,
                       "Requesting a window should not claim it is already visible.")
        model.isSettingsWindowVisible = true
        model.requestSettingsWindow(.agents)
        XCTAssertEqual(model.settingsWindowSection, .agents)
        XCTAssertTrue(model.isSettingsWindowVisible)
    }

    @MainActor
    func testBackgroundApprovalDoesNotExpandWhileSettingsWindowIsVisible() async throws {
        let suite = "AgentIsland.SettingsRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("floating", forKey: "presentationMode")
        defaults.set(true, forKey: "autoExpand")
        defaults.set(false, forKey: "notificationsEnabled")
        let path = testSocketPath()
        let model = AppModel(demo: false, socketPath: path, defaults: defaults)
        defer { model.shutdown() }
        model.expanded = false
        model.isSettingsWindowVisible = true
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        try client.send(AgentEvent(provider: .claude, sessionID: "settings-visible", kind: .approvalRequested,
                                   request: AgentRequest(id: "run-tests", kind: .approval, title: "Run tests?")))
        let deadline = Date().addingTimeInterval(3)
        while model.pendingCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertFalse(model.expanded,
                       "Agent requests should update state without interrupting the settings window.")
        model.revealFromNotification("claude:settings-visible")
        XCTAssertTrue(model.expanded, "An explicit notification click should still reveal its session.")
        XCTAssertEqual(model.selectedID, "claude:settings-visible")
    }
}
