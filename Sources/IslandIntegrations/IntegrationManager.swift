import Foundation
import CryptoKit
import IslandCore

/// Paths and environment used by the installer. Tests point everything at a
/// temporary home; production uses the real user home.
public struct IntegrationEnvironment: Sendable {
    public var home: URL
    public var environment: [String: String]
    /// Executable the shim forwards to (the hook helper inside the app bundle).
    public var helperPath: String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                helperPath: String? = nil) {
        self.home = home; self.environment = environment; self.helperPath = helperPath
    }

    public var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/AgentIsland") }
    public var shimURL: URL { home.appendingPathComponent(HookCommand.shimRelativePath) }
    var ledgerURL: URL { supportDirectory.appendingPathComponent("ledger.json") }
    var backupDirectory: URL { supportDirectory.appendingPathComponent("backups") }
}

/// Every configuration file Agent Island has written, so uninstall never has to guess.
struct Ledger: Codable {
    struct Target: Codable, Equatable {
        var provider: String
        var path: String
        var originalExisted: Bool
        var backup: String?
        var installedAt: Double
    }
    var version = 1
    var targets: [Target] = []
}

public struct IntegrationReport: Sendable, Equatable {
    public var provider: AgentProvider
    public var path: String
    public var lines: [String]
}

public struct IntegrationStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable { case notInstalled, installed, outdated, sessionOnly }
    public var provider: AgentProvider
    public var state: State
    public var path: String?
    /// Codex only: trusted hooks / installed hooks. `nil` when the agent has no trust store.
    public var trusted: (Int, Int)?
    public var leftovers: [String]
    public var notes: [String]

    public static func == (a: IntegrationStatus, b: IntegrationStatus) -> Bool {
        a.provider == b.provider && a.state == b.state && a.path == b.path && a.trusted?.0 == b.trusted?.0
            && a.trusted?.1 == b.trusted?.1 && a.leftovers == b.leftovers && a.notes == b.notes
    }
}

public struct IntegrationManager: Sendable {
    public var env: IntegrationEnvironment
    public init(_ env: IntegrationEnvironment = IntegrationEnvironment()) { self.env = env }

    public struct Failure: LocalizedError { public let errorDescription: String? }

    // MARK: Install / uninstall

    @discardableResult
    public func install(_ provider: AgentProvider, configPath: URL? = nil) throws -> IntegrationReport {
        let (descriptor, target) = try hookTarget(provider)
        guard let helper = env.helperPath, FileManager.default.isExecutableFile(atPath: helper) else {
            throw Failure(errorDescription: "找不到 hook 程序，请使用打包后的 Agent Island.app 安装。")
        }
        let path = resolved(configPath ?? target.defaultPath(env.environment, env.home))
        var lines: [String] = []
        let original = try? Data(contentsOf: path)
        let config = try parse(original)
        let (updated, map) = HookConfigPatcher.install(config, groups: HookConfigPatcher.groups(for: descriptor, target: target))

        try writeShim(helper: helper)
        var ledger = loadLedger()
        if !ledger.targets.contains(where: { $0.path == path.path }) {
            var backup: String?
            if let original {
                let name = "\(provider.rawValue)-\(digest(path.path)).orig"
                try FileManager.default.createDirectory(at: env.backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try original.write(to: env.backupDirectory.appendingPathComponent(name), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.backupDirectory.appendingPathComponent(name).path)
                backup = name
                lines.append("已备份原配置到 \(env.backupDirectory.appendingPathComponent(name).path)")
            }
            ledger.targets.append(.init(provider: provider.rawValue, path: path.path, originalExisted: original != nil,
                                        backup: backup, installedAt: Date().timeIntervalSince1970))
        }
        if updated != config {
            try replace(path, expected: original, with: updated.serialized())
            try updateTrust(target, hooksPath: path, map: map, lines: &lines)
            lines.insert("已写入 \(path.path)", at: 0)
        } else {
            lines.insert("已是最新：\(path.path)", at: 0)
        }
        try saveLedger(ledger)
        if let note = descriptor.afterInstall { lines.append(note) }
        return IntegrationReport(provider: provider, path: path.path, lines: lines)
    }

    @discardableResult
    public func uninstall(_ provider: AgentProvider, configPath: URL? = nil) throws -> IntegrationReport {
        let (_, target) = try hookTarget(provider)
        let path = resolved(configPath ?? target.defaultPath(env.environment, env.home))
        var ledger = loadLedger()
        let record = ledger.targets.first { $0.path == path.path }
        var lines: [String] = []
        if let original = try? Data(contentsOf: path) {
            let config = try parse(original)
            let (removed, map) = HookConfigPatcher.removeOwned(config)
            if removed != config || record != nil {
                if let restored = restoration(of: removed, record: record) {
                    if restored.isEmpty {
                        try FileManager.default.removeItem(at: path)
                        lines.append("已删除安装时创建的 \(path.path)")
                    } else {
                        if restored != original { try replace(path, expected: original, with: restored) }
                        lines.append("已按字节还原 \(path.path)")
                    }
                } else if removed != config {
                    try replace(path, expected: original, with: removed.serialized())
                    lines.append("已移除 \(path.path) 中的 Agent Island hooks（保留其他内容与你之后的修改）")
                } else {
                    lines.append("\(path.path) 中没有 Agent Island hooks")
                }
                try updateTrust(target, hooksPath: path, map: map, lines: &lines)
            } else {
                lines.append("\(path.path) 中没有 Agent Island hooks")
            }
            if !HookConfigPatcher.owned(in: (try? parse(try? Data(contentsOf: path))) ?? .object([])).isEmpty {
                throw Failure(errorDescription: "卸载后复查仍发现残留：\(path.path)")
            }
        } else {
            lines.append("\(path.path) 不存在，无需处理")
        }
        if let record {
            if let backup = record.backup { try? FileManager.default.removeItem(at: env.backupDirectory.appendingPathComponent(backup)) }
            ledger.targets.removeAll { $0 == record }
        }
        try saveLedger(ledger)
        if ledger.targets.isEmpty { removeSupportFiles(lines: &lines) }
        return IntegrationReport(provider: provider, path: path.path, lines: lines)
    }

    /// Remove Agent Island from every recorded and default location, plus any
    /// marked leftovers found by the read-only scan; then delete its own files.
    public func uninstallEverything() -> [IntegrationReport] {
        var reports: [IntegrationReport] = []
        for adapter in AdapterRegistry.all {
            guard case .hookConfig = adapter.descriptor.injection else { continue }
            for path in candidatePaths(adapter.descriptor.provider) {
                do { reports.append(try uninstall(adapter.descriptor.provider, configPath: path)) }
                catch { reports.append(IntegrationReport(provider: adapter.descriptor.provider, path: path.path, lines: ["失败：\(error.localizedDescription)"])) }
            }
        }
        var lines: [String] = []
        removeSupportFiles(lines: &lines, force: true)
        if !lines.isEmpty { reports.append(IntegrationReport(provider: "agent-island", path: env.supportDirectory.path, lines: lines)) }
        return reports
    }

    // MARK: Status ("doctor")

    public func status(_ provider: AgentProvider) -> IntegrationStatus {
        guard let adapter = AdapterRegistry.adapter(for: provider) else {
            return IntegrationStatus(provider: provider, state: .notInstalled, leftovers: [], notes: ["未知 Agent"])
        }
        guard case .hookConfig(let target) = adapter.descriptor.injection else {
            return IntegrationStatus(provider: provider, state: .sessionOnly, leftovers: [], notes: [])
        }
        let path = resolved(target.defaultPath(env.environment, env.home))
        let config = (try? parse(try? Data(contentsOf: path))) ?? .object([])
        let owned = HookConfigPatcher.owned(in: config)
        let expected = HookConfigPatcher.groups(for: adapter.descriptor, target: target)
        var notes: [String] = []
        let state: IntegrationStatus.State
        if owned.isEmpty { state = .notInstalled }
        else if HookConfigPatcher.alreadyInstalled(config, groups: expected) { state = .installed }
        else { state = .outdated; notes.append("接入不完整或已过期，点击“安装接入”即可更新。") }
        if state != .notInstalled {
            if !FileManager.default.isExecutableFile(atPath: env.shimURL.path) { notes.append("hook 转发程序缺失，点击“安装接入”修复。") }
            else if let helper = env.helperPath, (try? String(contentsOf: env.shimURL, encoding: .utf8))?.contains(Self.quote(helper)) != true {
                notes.append("应用位置已变化，打开 Agent Island 时会自动更新转发路径。")
            }
        }
        var trusted: (Int, Int)?
        if target.trustStore == .codexConfigToml, !owned.isEmpty {
            let toml = (try? String(contentsOf: path.deletingLastPathComponent().appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            let positions = CodexTrustStore.trustedPositions(in: toml, hooksPath: path.path)
            let count = owned.filter { positions[CodexTrustStore.normalized($0.event)]?.contains($0.position) == true }.count
            trusted = (count, owned.count)
            if count < owned.count { notes.append("还有 \(owned.count - count) 个 hook 未在 Codex 中信任，未信任的 hook 不会运行。") }
        }
        let leftovers = candidatePaths(provider).filter { $0 != path }.compactMap { other -> String? in
            let config = (try? parse(try? Data(contentsOf: other))) ?? .object([])
            return HookConfigPatcher.owned(in: config).isEmpty ? nil : other.path
        }
        if !leftovers.isEmpty { notes.append("其他位置还有残留，可用“完全卸载”清理。") }
        return IntegrationStatus(provider: provider, state: state, path: path.path, trusted: trusted, leftovers: leftovers, notes: notes)
    }

    /// Called when the app launches: keep the shim pointing at the current app
    /// bundle, but only if something is installed (never creates files otherwise).
    public func refreshShimIfInstalled() {
        guard let helper = env.helperPath, !loadLedger().targets.isEmpty else { return }
        try? writeShim(helper: helper)
    }

    // MARK: Internals

    private func hookTarget(_ provider: AgentProvider) throws -> (AgentDescriptor, HookConfigTarget) {
        guard let descriptor = AdapterRegistry.adapter(for: provider)?.descriptor,
              case .hookConfig(let target) = descriptor.injection else {
            throw Failure(errorDescription: "\(provider.displayName) 不需要安装持久配置。")
        }
        return (descriptor, target)
    }

    private func candidatePaths(_ provider: AgentProvider) -> [URL] {
        guard let descriptor = AdapterRegistry.adapter(for: provider)?.descriptor,
              case .hookConfig(let target) = descriptor.injection else { return [] }
        var paths = loadLedger().targets.filter { $0.provider == provider.rawValue }.map { URL(fileURLWithPath: $0.path) }
        paths.append(resolved(target.defaultPath(env.environment, env.home)))
        for path in target.scanPaths(env.environment, env.home).map(resolved) {
            let config = (try? parse(try? Data(contentsOf: path))) ?? .object([])
            if !HookConfigPatcher.owned(in: config).isEmpty { paths.append(path) }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }

    private func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func parse(_ data: Data?) throws -> JSONValue {
        guard let data, !data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) else { return .object([]) }
        let value: JSONValue
        do { value = try JSONValue.parse(data) }
        catch { throw HookConfigPatcher.ConfigError(message: error.localizedDescription) }
        try HookConfigPatcher.validate(value)
        return value
    }

    /// Bytes to restore, or nil to fall back to a structural edit. Empty data
    /// means "delete the file": it did not exist before Agent Island created it.
    private func restoration(of removed: JSONValue, record: Ledger.Target?) -> Data? {
        guard let record else { return nil }
        if !record.originalExisted { return HookConfigPatcher.isEmptyShell(removed) ? Data() : nil }
        // Only a backup without any Agent Island entries may be restored verbatim.
        guard let name = record.backup, let backup = try? Data(contentsOf: env.backupDirectory.appendingPathComponent(name)),
              let parsed = try? parse(backup), HookConfigPatcher.owned(in: parsed).isEmpty,
              Self.comparable(parsed) == Self.comparable(removed) else { return nil }
        return backup
    }

    /// Equality that ignores an empty `hooks` object (removal drops the key once it is empty).
    static func comparable(_ config: JSONValue) -> JSONValue {
        config["hooks"]?.objectValue?.isEmpty == true ? config.setting("hooks", nil) : config
    }

    /// Atomic replace that refuses to overwrite a concurrent edit by the agent or the user.
    private func replace(_ path: URL, expected: Data?, with data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mode = (try? manager.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) ?? 0o600
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".agent-island-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw Failure(errorDescription: "无法写入 \(path.deletingLastPathComponent().path)")
        }
        defer { try? manager.removeItem(at: temporary) }
        guard (try? Data(contentsOf: path)) == expected else {
            throw Failure(errorDescription: "\(path.lastPathComponent) 在修改期间被其他程序更新，已放弃写入，请重试。")
        }
        if expected == nil { try manager.moveItem(at: temporary, to: path) }
        else { _ = try manager.replaceItemAt(path, withItemAt: temporary) }
    }

    private func updateTrust(_ target: HookConfigTarget, hooksPath: URL, map: HookConfigPatcher.PositionMap, lines: inout [String]) throws {
        guard target.trustStore == .codexConfigToml, !map.isEmpty else { return }
        let toml = hooksPath.deletingLastPathComponent().appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: toml), let text = String(data: data, encoding: .utf8) else { return }
        let updated = CodexTrustStore.apply(map, to: text, hooksPath: hooksPath.path)
        guard updated != text else { return }
        try replace(toml, expected: data, with: Data(updated.utf8))
        lines.append("已同步 \(toml.path) 中对应的 hook 信任记录")
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func shimScript(helper: String) -> String {
        """
        #!/bin/sh
        # Agent Island hook forwarder. Safe no-op when Agent Island has been moved or removed.
        # Managed by Agent Island; removed by "完全卸载" or when the last integration is removed.
        h=\(Self.quote(helper))
        [ -x "$h" ] && exec "$h" "$@"
        cat >/dev/null 2>&1
        [ "$2" = codex ] && printf '{}\\n'
        exit 0

        """
    }

    private func writeShim(helper: String) throws {
        let script = shimScript(helper: helper)
        if (try? String(contentsOf: env.shimURL, encoding: .utf8)) == script { return }
        let manager = FileManager.default
        try manager.createDirectory(at: env.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = env.shimURL.deletingLastPathComponent().appendingPathComponent(".shim-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]) else {
            throw Failure(errorDescription: "无法写入 hook 转发程序")
        }
        if manager.fileExists(atPath: env.shimURL.path) { _ = try manager.replaceItemAt(env.shimURL, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: env.shimURL) }
    }

    private func removeSupportFiles(lines: inout [String], force: Bool = false) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: env.supportDirectory.path) else { return }
        if !force, !loadLedger().targets.isEmpty { return }
        try? manager.removeItem(at: env.supportDirectory)
        lines.append("已删除 Agent Island 自身文件 \(env.supportDirectory.path)")
    }

    private func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: env.ledgerURL), let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private func saveLedger(_ ledger: Ledger) throws {
        if ledger.targets.isEmpty { try? FileManager.default.removeItem(at: env.ledgerURL); return }
        try FileManager.default.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ledger).write(to: env.ledgerURL, options: .atomic)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
