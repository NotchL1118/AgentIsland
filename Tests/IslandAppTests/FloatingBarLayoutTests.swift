import XCTest
import IslandCore
@testable import AgentIsland

final class FloatingBarLayoutTests: XCTestCase {
    private func session(_ index: Int, provider: AgentProvider = .codex,
                         project: String = "CodeLand", title: String = "") -> SessionState {
        SessionState(provider: provider, sessionID: "session-\(index)", title: title,
                     cwd: "/Projects/\(project)", status: .working)
    }

    func testEmptyBarUsesBrandAndNoRunningCount() {
        let layout = FloatingBarLayout(sessions: [], maximumWidth: 760)
        XCTAssertNotNil(layout.brandFrame)
        XCTAssertTrue(layout.items.isEmpty)
        XCTAssertFalse(layout.iconsOnly)
        XCTAssertEqual(layout.overflowCount, 0)
        XCTAssertLessThanOrEqual(layout.width, 200)
    }

    func testThreeSessionsKeepIndividualProjectsWhileFourUseOnlyIcons() {
        let sessions = [session(1, project: "CodeLand"),
                        session(2, provider: .claude, project: "Website"),
                        session(3, provider: .pi, project: "API"),
                        session(4, project: "Server")]
        let named = FloatingBarLayout(sessions: Array(sessions.prefix(3)), maximumWidth: 760)
        XCTAssertFalse(named.iconsOnly)
        XCTAssertNil(named.brandFrame)
        XCTAssertEqual(named.items.map(\.label), ["CodeLand", "Website", "API"])
        let compact = FloatingBarLayout(sessions: sessions, maximumWidth: 760)
        XCTAssertTrue(compact.iconsOnly)
        XCTAssertEqual(compact.items.map(\.sessionID), sessions.map(\.id))
        XCTAssertLessThan(compact.width, named.width)
    }

    func testSameProviderAndProjectRetainSeparateIdentitiesAndTaskLabels() {
        let sessions = [session(1, title: "修复拖拽"), session(2, title: "补充测试")]
        let layout = FloatingBarLayout(sessions: sessions, maximumWidth: 760)
        XCTAssertEqual(layout.items.map(\.sessionID), sessions.map(\.id))
        XCTAssertEqual(layout.items.map(\.label), ["修复拖拽", "补充测试"])
        XCTAssertTrue(layout.items[0].tooltip.contains("/Projects/CodeLand"))
        XCTAssertTrue(layout.items[0].tooltip.contains("Codex"))
        XCTAssertTrue(layout.items[0].tooltip.contains("运行中"))
    }

    func testNarrowScreenUsesIconsAndLeavesEveryAgentDiscoverable() throws {
        let sessions = (0..<40).map { session($0) }
        let layout = FloatingBarLayout(sessions: sessions, maximumWidth: 200)
        XCTAssertTrue(layout.iconsOnly)
        XCTAssertGreaterThan(layout.items.count, 0)
        XCTAssertEqual(layout.items.count + layout.overflowCount, sessions.count)
        XCTAssertEqual(layout.items.map(\.sessionID), Array(sessions.prefix(layout.items.count)).map(\.id))
        XCTAssertLessThanOrEqual(layout.width, 200)
        let overflow = try XCTUnwrap(layout.overflowFrame)
        let frames = layout.items.map(\.frame) + [overflow, layout.chevronFrame]
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, layout.width)
            XCTAssertGreaterThan(frame.width, 0)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
    }

    func testUnknownProviderAndLongProjectStillFitWithoutLosingMetadata() {
        let session = session(1, provider: "new-tool", project: String(repeating: "项目", count: 40))
        let layout = FloatingBarLayout(sessions: [session], maximumWidth: 200)
        XCTAssertEqual(layout.items.first?.provider, "new-tool")
        XCTAssertEqual(layout.items.first?.label, String(repeating: "项目", count: 40))
        XCTAssertLessThanOrEqual(layout.width, 200)
    }
}
