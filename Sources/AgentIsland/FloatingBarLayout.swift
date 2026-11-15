import Foundation
import CoreGraphics
import IslandCore

/// Shared by the native window silhouette and SwiftUI's compact content so
/// both use the same width and click regions as the number of sessions changes.
struct FloatingBarLayout {
    static let height: CGFloat = 36

    struct Item: Identifiable {
        var id: String { sessionID }
        let sessionID: String
        let provider: AgentProvider
        let label: String
        let tooltip: String
        let status: SessionStatus
        let frame: CGRect
    }

    let width: CGFloat
    let items: [Item]
    let iconsOnly: Bool
    let overflowCount: Int
    let overflowFrame: CGRect?
    let chevronFrame: CGRect
    let brandFrame: CGRect?

    init(sessions: [SessionState], maximumWidth: CGFloat) {
        let limit = maximumWidth.isFinite ? max(1, maximumWidth) : 190
        let leading = min(14, limit * 0.1)
        let trailing = min(8, limit * 0.05)
        let chevronWidth = min(28, (limit - leading - trailing) / 2)
        let chrome = leading + trailing + chevronWidth
        let namedItemWidth: CGFloat = sessions.count == 1 ? 132 : 110
        let namedWidth = chrome + CGFloat(sessions.count) * namedItemWidth
        iconsOnly = sessions.count > 3 || !sessions.isEmpty && namedWidth > limit

        if sessions.isEmpty {
            width = min(190, limit)
            items = []
            overflowCount = 0
            overflowFrame = nil
            brandFrame = CGRect(x: leading, y: 0, width: width - chrome, height: Self.height)
            chevronFrame = CGRect(x: width - trailing - chevronWidth, y: 0,
                                 width: chevronWidth, height: Self.height)
            return
        }

        brandFrame = nil
        let itemWidth: CGFloat = iconsOnly ? 30 : namedItemWidth
        let available = max(0, limit - chrome)
        var visibleCount = min(sessions.count, Int(available / itemWidth))
        var overflowWidth: CGFloat = 0
        if visibleCount < sessions.count {
            // Reserve a full +N target before selecting the visible prefix;
            // every omitted session remains discoverable through this target.
            overflowWidth = min(available, max(36, 14 + CGFloat(String(sessions.count).count) * 7))
            visibleCount = min(sessions.count, Int(max(0, available - overflowWidth) / itemWidth))
        }
        overflowCount = sessions.count - visibleCount
        let contentWidth = CGFloat(visibleCount) * itemWidth
        width = min(limit, chrome + contentWidth + overflowWidth)
        overflowFrame = overflowCount > 0
            ? CGRect(x: leading + contentWidth, y: 0, width: overflowWidth, height: Self.height)
            : nil
        chevronFrame = CGRect(x: width - trailing - chevronWidth, y: 0,
                             width: chevronWidth, height: Self.height)

        let groups = Dictionary(grouping: sessions) { session in
            session.provider.rawValue + ":" + Self.projectName(session)
        }
        items = sessions.prefix(visibleCount).enumerated().map { index, session in
            let project = Self.projectName(session)
            let peers = groups[session.provider.rawValue + ":" + project] ?? []
            let task = !session.title.isEmpty ? session.title : session.message
            let label: String
            if peers.count > 1 {
                // The provider icon and project alone cannot distinguish two
                // sessions working in the same checkout.
                let taskIsUnique = !task.isEmpty && peers.filter {
                    (!$0.title.isEmpty ? $0.title : $0.message) == task
                }.count == 1
                label = taskIsUnique ? task : project + " · " + String(session.sessionID.suffix(6))
            } else {
                label = project
            }
            var details = [session.provider.displayName]
            if !session.cwd.isEmpty { details.append(session.cwd) }
            if !session.title.isEmpty { details.append(session.title) }
            if !session.message.isEmpty && session.message != session.title { details.append(session.message) }
            details.append(session.status.displayName)
            return Item(sessionID: session.id, provider: session.provider, label: label,
                        tooltip: details.joined(separator: " · "), status: session.status,
                        frame: CGRect(x: leading + CGFloat(index) * itemWidth, y: 0,
                                      width: itemWidth, height: Self.height))
        }
    }

    private static func projectName(_ session: SessionState) -> String {
        if !session.cwd.isEmpty {
            let name = URL(fileURLWithPath: session.cwd).lastPathComponent
            if !name.isEmpty { return name }
        }
        return session.title.isEmpty ? session.provider.displayName : session.title
    }
}
