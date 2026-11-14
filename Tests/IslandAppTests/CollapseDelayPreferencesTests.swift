import XCTest
import Foundation
@testable import AgentIsland

final class CollapseDelayPreferencesTests: XCTestCase {
    @MainActor
    func testUnsetOrInvalidStoredDelayUsesPointThreeSeconds() async throws {
        let suite = "AgentIsland.CollapseDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AppModel(demo: true, defaults: defaults)
        defer { initial.shutdown() }
        XCTAssertEqual(initial.collapseDelay, 0.3)
        defaults.set("invalid", forKey: "collapseDelay")
        let invalid = AppModel(demo: true, defaults: defaults)
        defer { invalid.shutdown() }
        XCTAssertEqual(invalid.collapseDelay, 0.3)
    }

    @MainActor
    func testExplicitDelayPersistsAndRestoresIncludingImmediate() async throws {
        let suite = "AgentIsland.CollapseDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: false, socketPath: testSocketPath(), defaults: defaults)
        defer { model.shutdown() }
        model.setCollapseDelay(0.44)
        XCTAssertEqual(model.collapseDelay, 0.4)
        XCTAssertEqual(defaults.double(forKey: "collapseDelay"), 0.4)
        let restored = AppModel(demo: true, defaults: defaults)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.collapseDelay, 0.4)
        model.setCollapseDelay(0)
        let immediate = AppModel(demo: true, defaults: defaults)
        defer { immediate.shutdown() }
        XCTAssertEqual(immediate.collapseDelay, 0)
    }

    @MainActor
    func testSetDelayClampsAndRejectsNonFiniteValues() async throws {
        let suite = "AgentIsland.CollapseDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }
        for (input, expected) in [(Double(-4), 0.0), (8, 2), (0.36, 0.4), (Double.nan, 0.3), (Double.infinity, 0.3), (-Double.infinity, 0.3)] {
            model.setCollapseDelay(input)
            XCTAssertEqual(model.collapseDelay, expected)
        }
    }

    @MainActor
    func testRestoredOutOfRangeDelayIsNormalized() async throws {
        let suite = "AgentIsland.CollapseDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (input, expected) in [(7.0, 2.0), (-2, 0), (0.86, 0.9)] {
            defaults.set(input, forKey: "collapseDelay")
            let model = AppModel(demo: true, defaults: defaults)
            XCTAssertEqual(model.collapseDelay, expected)
            model.shutdown()
        }
    }

    @MainActor
    func testDemoDelayDoesNotOverwriteSavedPreferences() async throws {
        let suite = "AgentIsland.CollapseDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.5, forKey: "collapseDelay")
        let model = AppModel(demo: true, defaults: defaults)
        defer { model.shutdown() }
        model.setCollapseDelay(1)
        model.savePreferences()
        XCTAssertEqual(model.collapseDelay, 1)
        XCTAssertEqual(defaults.double(forKey: "collapseDelay"), 0.5)
    }
}
