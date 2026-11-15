import XCTest
import AppKit
import IslandCore
@testable import AgentIsland

final class MenuBarStatusPresenterTests: XCTestCase {
    @MainActor
    func testRunningAnimatesWithoutRestartingOnUpdatesAndCompletionStopsIt() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let presenter = MenuBarStatusPresenter(button: button)
        defer { presenter.stop() }

        presenter.update(activity: .running, pendingCount: 0, menuBarOnly: true, reduceMotion: false)
        let firstImage = button.image
        try await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertTrue(presenter.isAnimating)
        XCTAssertGreaterThan(presenter.frameIndex, 0)
        XCTAssertFalse(button.image === firstImage)
        let currentFrame = presenter.frameIndex
        presenter.update(activity: .running, pendingCount: 2, menuBarOnly: true, reduceMotion: false)
        XCTAssertEqual(presenter.frameIndex, currentFrame)
        XCTAssertEqual(button.title, "")
        XCTAssertTrue(button.toolTip?.contains("有待处理任务") == true)

        presenter.update(activity: .completed, pendingCount: 0, menuBarOnly: true, reduceMotion: false)
        XCTAssertFalse(presenter.isAnimating)
        XCTAssertTrue(button.image === MenuBarStatusPresenter.staticImage(for: .completed))
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(button.image === MenuBarStatusPresenter.staticImage(for: .completed))
        XCTAssertEqual(button.accessibilityLabel(), "Agent Island · Agent 已完成")
    }

    @MainActor
    func testReduceMotionStopsAndRestartsRunningAnimation() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let presenter = MenuBarStatusPresenter(button: button)
        defer { presenter.stop() }

        presenter.update(activity: .running, pendingCount: 0, menuBarOnly: true, reduceMotion: false)
        XCTAssertTrue(presenter.isAnimating)
        presenter.update(activity: .running, pendingCount: 0, menuBarOnly: true, reduceMotion: true)
        XCTAssertFalse(presenter.isAnimating)
        XCTAssertTrue(button.image === MenuBarStatusPresenter.staticImage(for: .running))
        XCTAssertFalse(button.image === MenuBarStatusPresenter.staticImage(for: .idle))
        presenter.update(activity: .running, pendingCount: 0, menuBarOnly: true, reduceMotion: false)
        XCTAssertTrue(presenter.isAnimating)
        XCTAssertTrue(button.image === MenuBarStatusPresenter.runningFrames[0])

        presenter.update(activity: .needsAttention, pendingCount: 1, menuBarOnly: true, reduceMotion: false)
        XCTAssertFalse(presenter.isAnimating)
        XCTAssertTrue(button.image === MenuBarStatusPresenter.staticImage(for: .needsAttention))
    }

    @MainActor
    func testMenuBarStaysTextFreeAndPreservesNativeButtonActions() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let target = NSObject()
        let action = NSSelectorFromString("togglePanel:")
        button.target = target
        button.action = action
        let presenter = MenuBarStatusPresenter(button: button)
        defer { presenter.stop() }

        presenter.update(activity: .needsAttention, pendingCount: 3, menuBarOnly: false, reduceMotion: true)
        XCTAssertEqual(button.title, " 3")
        for activity in MenuBarActivity.allCases {
            presenter.update(activity: activity, pendingCount: 3, menuBarOnly: true, reduceMotion: true)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertEqual(button.image?.size, MenuBarStatusPresenter.imageSize)
            XCTAssertTrue(button.target === target)
            XCTAssertEqual(button.action, action)
            XCTAssertFalse(presenter.isAnimating)
        }
    }

    @MainActor
    func testAllStateGlyphsAreDistinctTemplatesOnTheSameCanvas() throws {
        _ = NSApplication.shared
        var images: [Data] = []
        for activity in MenuBarActivity.allCases {
            let image = try XCTUnwrap(MenuBarStatusPresenter.staticImage(for: activity))
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image.isTemplate)
            let data = try XCTUnwrap(image.tiffRepresentation)
            XCTAssertFalse(images.contains(data), "Each state must have a distinct glyph")
            images.append(data)
        }
        let frames = MenuBarStatusPresenter.runningFrames
        for frame in frames {
            XCTAssertEqual(frame.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(frame.isTemplate)
        }
        XCTAssertNotEqual(frames[0].tiffRepresentation, frames[6].tiffRepresentation)
    }
}
