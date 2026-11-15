import Foundation
import IslandCore

/// The command string written into agent configuration.
///
/// It never points into the app bundle. It runs a stable shim under
/// `~/Library/Application Support/AgentIsland/bin`, and only if that shim is
/// executable; otherwise it drains stdin and exits 0. So a moved, updated or
/// deleted Agent Island leaves an inert entry, never a blocking error (exit 2)
/// or a "command not found" (exit 127). Because the string never changes when
/// the app moves, Codex's hash-based hook trust survives app updates.
public enum HookCommand {
    public static let marker = "--agent-island-owned"
    public static let shimRelativePath = "Library/Application Support/AgentIsland/bin/agent-island-hook"

    public static func command(for provider: AgentProvider, waiting: Bool, fallbackPrintsEmptyObject: Bool) -> String {
        let fallback = fallbackPrintsEmptyObject ? "cat >/dev/null; printf \"{}\\n\"; exit 0" : "cat >/dev/null; exit 0"
        let script = "h=\"$HOME/\(shimRelativePath)\"; [ -x \"$h\" ] && exec \"$h\" \"$@\"; \(fallback)"
        // Keep the parameter for callers upgrading from decision-capable hooks.
        // No installed command may re-enable the legacy wait mode.
        let arguments = ["agent-island-hook", "hook", provider.rawValue, marker]
        return "/bin/sh -c '\(script)' " + arguments.joined(separator: " ")
    }

    /// Ownership is decided only by the exact shape Agent Island itself writes.
    public static func isOwned(_ hook: JSONValue) -> Bool {
        guard hook["type"]?.stringValue == "command", let command = hook["command"]?.stringValue else { return false }
        return command.hasPrefix("/bin/sh -c '") && command.hasSuffix(" " + marker) && command.contains(shimRelativePath)
    }
}

public struct HookPosition: Hashable, Sendable { public var group: Int; public var hook: Int }

/// Pure edits of the shared `{"hooks": {"<Event>": [{"matcher"?, "hooks": [...]}]}}` shape
/// used by both Claude Code settings and Codex hooks.json.
public enum HookConfigPatcher {
    public struct ConfigError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message + "；配置未修改。" }
    }

    /// For each event, where every pre-existing hook ended up (nil = removed).
    public typealias PositionMap = [String: [HookPosition: HookPosition?]]

    public static func validate(_ config: JSONValue) throws {
        guard case .object = config else { throw ConfigError(message: "配置必须是 JSON 对象") }
        guard let hooks = config["hooks"] else { return }
        guard let events = hooks.objectValue else { throw ConfigError(message: "hooks 必须是对象") }
        for (event, groups) in events {
            guard let groups = groups.arrayValue else { throw ConfigError(message: "hooks.\(event) 必须是数组") }
            for group in groups where group.objectValue != nil {
                if let inner = group["hooks"], inner.arrayValue == nil { throw ConfigError(message: "hooks.\(event) 中的 hooks 必须是数组") }
            }
        }
    }

    public static func owned(in config: JSONValue) -> [(event: String, position: HookPosition)] {
        var result: [(String, HookPosition)] = []
        for (event, groups) in config["hooks"]?.objectValue ?? [] {
            for (g, group) in (groups.arrayValue ?? []).enumerated() {
                for (h, hook) in (group["hooks"]?.arrayValue ?? []).enumerated() {
                    if HookCommand.isOwned(hook) { result.append((event, HookPosition(group: g, hook: h))) }
                }
            }
        }
        return result
    }

    /// Remove every Agent Island hook and nothing else.
    /// A user group that also contains our hook keeps its other hooks.
    public static func removeOwned(_ config: JSONValue) -> (JSONValue, PositionMap) {
        guard let events = config["hooks"]?.objectValue else { return (config, [:]) }
        var map: PositionMap = [:]
        var keptEvents: [(String, JSONValue)] = []
        var touched = false
        for (event, value) in events {
            guard let groups = value.arrayValue else { keptEvents.append((event, value)); continue }
            var keptGroups: [JSONValue] = []
            var eventMap: [HookPosition: HookPosition?] = [:]
            var changed = false
            for (g, group) in groups.enumerated() {
                guard let hooks = group["hooks"]?.arrayValue else {
                    keptGroups.append(group); continue
                }
                var keptHooks: [JSONValue] = []
                var pending: [(Int, Bool)] = []
                for (h, hook) in hooks.enumerated() {
                    let ours = HookCommand.isOwned(hook)
                    pending.append((h, ours))
                    if !ours { keptHooks.append(hook) }
                }
                let removedAny = keptHooks.count != hooks.count
                changed = changed || removedAny
                let keepGroup = !removedAny || !keptHooks.isEmpty
                var newHook = 0
                for (h, ours) in pending {
                    if ours || !keepGroup { eventMap[HookPosition(group: g, hook: h)] = .some(nil) }
                    else { eventMap[HookPosition(group: g, hook: h)] = HookPosition(group: keptGroups.count, hook: newHook); newHook += 1 }
                }
                if keepGroup { keptGroups.append(removedAny ? group.setting("hooks", .array(keptHooks)) : group) }
            }
            if changed {
                touched = true
                map[event] = eventMap
                if !keptGroups.isEmpty { keptEvents.append((event, .array(keptGroups))) }
            } else {
                keptEvents.append((event, value))
            }
        }
        guard touched else { return (config, [:]) }
        let result = keptEvents.isEmpty ? config.setting("hooks", nil) : config.setting("hooks", .object(keptEvents))
        return (result, map)
    }

    public static func groups(for descriptor: AgentDescriptor, target: HookConfigTarget) -> [(String, JSONValue)] {
        descriptor.hooks.map { spec in
            var handler: [(String, JSONValue)] = [
                ("type", .string("command")),
                ("command", .string(HookCommand.command(for: descriptor.provider, waiting: false,
                                                       fallbackPrintsEmptyObject: target.fallbackPrintsEmptyObject))),
                ("timeout", .number(String(spec.timeout))),
            ]
            if spec.asynchronous { handler.append(("async", .bool(true))) }
            var group: [(String, JSONValue)] = []
            if let matcher = spec.matcher { group.append(("matcher", .string(matcher))) }
            group.append(("hooks", .array([.object(handler)])))
            return (spec.event, .object(group))
        }
    }

    /// Append our groups after every existing group, so the positions of the
    /// user's own hooks (and therefore Codex trust keys) never change.
    public static func install(_ config: JSONValue, groups: [(String, JSONValue)]) -> (JSONValue, PositionMap) {
        if alreadyInstalled(config, groups: groups) { return (config, [:]) }
        let (base, map) = removeOwned(config)
        var events = base["hooks"]?.objectValue ?? []
        for (event, group) in groups {
            if let index = events.firstIndex(where: { $0.0 == event }) {
                events[index].1 = .array((events[index].1.arrayValue ?? []) + [group])
            } else {
                events.append((event, .array([group])))
            }
        }
        return (base.setting("hooks", .object(events)), map)
    }

    static func alreadyInstalled(_ config: JSONValue, groups: [(String, JSONValue)]) -> Bool {
        let owned = owned(in: config)
        guard owned.count == groups.count else { return false }
        var expected: [String: [JSONValue]] = [:]
        for (event, group) in groups { expected[event, default: []].append(group) }
        for (event, wanted) in expected {
            let present = config["hooks"]?[event]?.arrayValue ?? []
            let ours = present.filter { group in (group["hooks"]?.arrayValue ?? []).contains(where: HookCommand.isOwned) }
            guard ours == wanted, Array(present.suffix(wanted.count)) == wanted else { return false }
        }
        return true
    }

    /// A configuration with nothing left but structure Agent Island created.
    static func isEmptyShell(_ config: JSONValue) -> Bool {
        guard let members = config.objectValue else { return false }
        return members.allSatisfy { $0.0 == "hooks" && ($0.1.objectValue?.isEmpty ?? false) }
    }
}

/// Codex stores hook trust in `config.toml` as
/// `[hooks.state."<hooks.json path>:<event>:<group>:<hook>"]` with a content hash.
/// Keys are positional, so removing our groups must delete our keys and re-key
/// any user hook that moved. All other lines are left byte-for-byte unchanged.
public enum CodexTrustStore {
    struct Key { var path: String; var event: String; var position: HookPosition }

    static func parseHeader(_ line: String) -> Key? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "[hooks.state.\"", suffix = "\"]"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix), trimmed.count > prefix.count + suffix.count else { return nil }
        let body = String(trimmed.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 4, let hook = Int(parts[parts.count - 1]), let group = Int(parts[parts.count - 2]) else { return nil }
        let path = parts[0..<(parts.count - 3)].joined(separator: ":").replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        return Key(path: path, event: parts[parts.count - 3], position: HookPosition(group: group, hook: hook))
    }

    static func header(_ key: Key) -> String {
        let path = key.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[hooks.state.\"\(path):\(key.event):\(key.position.group):\(key.position.hook)\"]"
    }

    static func normalized(_ event: String) -> String {
        event.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    /// Positions (per normalized event) of trust entries recorded for `hooksPath`.
    public static func trustedPositions(in toml: String, hooksPath: String) -> [String: Set<HookPosition>] {
        var result: [String: Set<HookPosition>] = [:]
        for line in toml.components(separatedBy: "\n") {
            if let key = parseHeader(line), key.path == hooksPath { result[normalized(key.event), default: []].insert(key.position) }
        }
        return result
    }

    public static func apply(_ map: HookConfigPatcher.PositionMap, to toml: String, hooksPath: String) -> String {
        guard !map.isEmpty else { return toml }
        let normalizedMap = Dictionary(map.map { (normalized($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        var lines = toml.components(separatedBy: "\n")
        var index = 0
        var changed = false
        while index < lines.count {
            guard var key = parseHeader(lines[index]), key.path == hooksPath,
                  let eventMap = normalizedMap[normalized(key.event)] else { index += 1; continue }
            // A stale entry for a position that did not exist must not collide
            // with a re-keyed one (duplicate tables would make config.toml invalid).
            let destinations = Set(eventMap.values.compactMap { $0 })
            let destination: HookPosition?? = eventMap[key.position] ?? (destinations.contains(key.position) ? .some(nil) : nil)
            guard let destination else { index += 1; continue }
            if let moved = destination {
                if moved != key.position { key.position = moved; lines[index] = header(key); changed = true }
                index += 1
            } else {
                // Delete this table: its header and every line up to the next table header.
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
                lines.removeSubrange(index..<end)
                changed = true
            }
        }
        guard changed else { return toml }
        var result = lines.joined(separator: "\n")
        if toml.hasSuffix("\n") && !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
