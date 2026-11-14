import XCTest
import AppKit
@testable import AgentIsland

final class SettingsWindowControllerTests: XCTestCase {
    @MainActor
    private func fixture() -> (AppModel, SettingsWindowController) {
        _ = NSApplication.shared
        let model = AppModel(demo: true)
        return (model, SettingsWindowController(model: model))
    }

    @MainActor
    func testSettingsUsesRegularResizableWindowInsteadOfFloatingPanel() async throws {
        let (model, controller) = fixture()
        defer { controller.close(); model.shutdown() }
        let window = try XCTUnwrap(controller.window)

        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.title, "Agent Island 设置")
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.isReleasedWhenClosed,
                       "Closing settings must leave the controller's window reusable.")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 700,
                                    "The minimum window width must fit its SwiftUI settings content.")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 500)
        XCTAssertTrue(window.contentView === controller.hosting)
        XCTAssertFalse(model.isSettingsWindowVisible)
    }

    @MainActor
    func testPresentReusesWindowAndRoutesSectionsWhileClosingQuickPanel() async throws {
        let (model, controller) = fixture()
        defer { controller.close(); model.shutdown() }
        let originalWindow = try XCTUnwrap(controller.window)
        model.showingSettings = true
        model.expanded = true

        controller.present(section: .agents, activate: false)

        XCTAssertTrue(originalWindow.isVisible)
        XCTAssertTrue(model.isSettingsWindowVisible)
        XCTAssertEqual(model.settingsWindowSection, .agents)
        XCTAssertFalse(model.showingSettings)
        XCTAssertFalse(model.expanded)

        controller.present(section: .general, activate: false)

        XCTAssertTrue(controller.window === originalWindow)
        XCTAssertTrue(originalWindow.isVisible)
        XCTAssertTrue(model.isSettingsWindowVisible)
        XCTAssertEqual(model.settingsWindowSection, .general)
    }

    @MainActor
    func testClosingClearsVisibilityAndReopeningKeepsSameWindow() async throws {
        let (model, controller) = fixture()
        defer { controller.close(); model.shutdown() }
        let originalWindow = try XCTUnwrap(controller.window)
        controller.present(section: .agents, activate: false)

        controller.close()

        XCTAssertFalse(originalWindow.isVisible)
        XCTAssertFalse(model.isSettingsWindowVisible,
                       "Closing the normal window must restore the app's automatic expansion policy.")
        XCTAssertTrue(controller.window === originalWindow)

        controller.present(section: .general, activate: false)

        XCTAssertTrue(controller.window === originalWindow)
        XCTAssertTrue(originalWindow.isVisible)
        XCTAssertTrue(model.isSettingsWindowVisible)
        XCTAssertEqual(model.settingsWindowSection, .general)
    }
}
