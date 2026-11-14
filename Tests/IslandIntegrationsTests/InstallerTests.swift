import XCTest
import IslandCore
@testable import IslandIntegrations

/// Every test runs against a temporary HOME. Real agent configuration is never read or written.
final class InstallerTests: XCTestCase {
    var home: URL!
    var helper: URL!
    var manager: IntegrationManager!
    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
    var codexToml: URL { home.appendingPathComponent(".codex/config.toml") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Stand-in for the bundled helper: records how the shim forwarded the call.
        helper = home.appendingPathComponent("App/agent-island-hook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncat >/dev/null\necho \"forwarded $*\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        manager = IntegrationManager(IntegrationEnvironment(home: home, environment: [:], helperPath: helper.path))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func json(_ url: URL) throws -> JSONValue { try JSONValue.parse(Data(contentsOf: url)) }

    func commands(_ url: URL) throws -> [String] {
        try HookConfigPatcher.owned(in: json(url)).compactMap { entry in
            let config = try json(url)
            return config["hooks"]?[entry.event]?.arrayValue?[entry.position.group]["hooks"]?.arrayValue?[entry.position.hook]["command"]?.stringValue
        }
    }

    /// Run an installed hook command exactly as an agent would: through a shell, with JSON on stdin.
    func runInstalled(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s","hook_event_name":"PreToolUse"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    // MARK: Format preservation

    func testOrderedJSONRoundTripIsByteIdentical() throws {
        let text = "{\n  \"z\": 1.50,\n  \"a\": [\n    true,\n    null,\n    \"é \\\" \\u0001\"\n  ],\n  \"m\": {}\n}\n"
        XCTAssertEqual(String(decoding: try JSONValue.parse(Data(text.utf8)).serialized(), as: UTF8.self), text)
    }

    // MARK: Claude

    func testInstallIsIdempotentAndAppendsAfterUserHooks() throws {
        try write(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#, to: claudeSettings)
        try manager.install(.claude)
        let first = try Data(contentsOf: claudeSettings)
        let config = try json(claudeSettings)
        XCTAssertEqual(config.objectValue?.first?.0, "model", "user key order is preserved")
        XCTAssertEqual(config["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue, "say done")
        XCTAssertEqual(try commands(claudeSettings).count, ClaudeAdapter().descriptor.hooks.count)
        try manager.install(.claude)
        XCTAssertEqual(try Data(contentsOf: claudeSettings), first, "second install changes nothing")
        XCTAssertEqual(manager.status(.claude).state, .installed)
    }

    func testOnlyApprovalsAndQuestionsBlockTheAgent() throws {
        try manager.install(.claude)
        let config = try json(claudeSettings)
        for (event, groups) in config["hooks"]?.objectValue ?? [] {
            for group in groups.arrayValue ?? [] {
                let hook = group["hooks"]!.arrayValue![0]
                let blocking = event == "PermissionRequest" || group["matcher"]?.stringValue == "AskUserQuestion"
                XCTAssertEqual(hook["async"], blocking ? nil : .bool(true), event)
                XCTAssertEqual(hook["command"]?.stringValue?.contains("--wait"), blocking, event)
            }
        }
    }

    func testUninstallRestoresOriginalBytes() throws {
        let original = "{\n    \"model\": \"opus\",\n    \"hooks\": {}\n}"
        try write(original, to: claudeSettings)
        try manager.install(.claude)
        try manager.uninstall(.claude)
        XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/AgentIsland").path),
                       "nothing of Agent Island remains")
    }

    func testUninstallDeletesFileItCreated() throws {
        try manager.install(.claude)
        try manager.uninstall(.claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSettings.path))
    }

    func testUninstallKeepsLaterUserEditsAndSharedGroups() throws {
        try manager.install(.claude)
        // The user (or Claude Code) edits settings after install, including adding a hook to our group.
        var config = try json(claudeSettings).setting("theme", .string("dark"))
        var stop = config["hooks"]!["Stop"]!.arrayValue!
        let ours = stop[0]["hooks"]!.arrayValue!
        stop[0] = stop[0].setting("hooks", .array(ours + [.object([("type", .string("command")), ("command", .string("mine"))])]))
        config = config.setting("hooks", config["hooks"]!.setting("Stop", .array(stop)))
        try config.serialized().write(to: claudeSettings)
        try manager.uninstall(.claude)
        let after = try json(claudeSettings)
        XCTAssertEqual(after["theme"]?.stringValue, "dark")
        XCTAssertEqual(after["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.map { $0["command"]?.stringValue }, ["mine"])
        XCTAssertTrue(HookConfigPatcher.owned(in: after).isEmpty)
    }

    func testHooksThatOnlyMentionTheMarkerAreNotOurs() throws {
        let mine = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo --agent-island-owned"}]}]}}"#
        try write(mine, to: claudeSettings)
        try manager.install(.claude)
        try manager.uninstall(.claude)
        XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), mine)
    }

    func testSymlinkIsPreserved() throws {
        let real = home.appendingPathComponent("dotfiles/claude.json")
        try write("{}", to: real)
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeSettings, withDestinationURL: real)
        try manager.install(.claude)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claudeSettings.path), real.path)
        XCTAssertFalse(try commands(real).isEmpty)
    }

    func testInvalidConfigurationIsNotOverwritten() throws {
        for text in ["[1]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}", "{oops"] {
            try write(text, to: claudeSettings)
            XCTAssertThrowsError(try manager.install(.claude))
            XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), text)
        }
    }

    // MARK: Safety after the app is gone (the P0 regression)

    func testInstalledHooksForwardWhilePresentAndStayInertWhenRemoved() throws {
        try manager.install(.claude)
        try manager.install(.codex)
        let claude = try XCTUnwrap(commands(claudeSettings).first { $0.contains("--wait") })
        let codex = try XCTUnwrap(commands(codexHooks).first)

        XCTAssertEqual(try runInstalled(claude).output, "forwarded hook claude --wait --agent-island-owned\n")

        try FileManager.default.removeItem(at: helper)               // app deleted / moved
        XCTAssertEqual(try runInstalled(claude).status, 0)
        XCTAssertEqual(try runInstalled(claude).output, "")
        XCTAssertEqual(try runInstalled(codex).output, "{}\n")

        try FileManager.default.removeItem(at: home.appendingPathComponent("Library"))  // support files gone too
        XCTAssertEqual(try runInstalled(claude).status, 0)
        XCTAssertEqual(try runInstalled(claude).output, "")
        XCTAssertEqual(try runInstalled(codex).status, 0)
        XCTAssertEqual(try runInstalled(codex).output, "{}\n")
    }

    func testShimIsOnlyRefreshedWhenSomethingIsInstalled() {
        manager.refreshShimIfInstalled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    // MARK: Codex trust records

    func testCodexUninstallRemovesOwnTrustAndRekeysMovedUserHooks() throws {
        let path = codexHooks.path
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify","async":true}]}]}}"#, to: codexHooks)
        try manager.install(.codex)
        // The user later appends another Stop hook after ours, and trusts everything in Codex.
        var config = try json(codexHooks)
        let stop = config["hooks"]!["Stop"]!.arrayValue! + [.object([("hooks", .array([.object([("type", .string("command")), ("command", .string("later"))])]))])]
        config = config.setting("hooks", config["hooks"]!.setting("Stop", .array(stop)))
        try config.serialized().write(to: codexHooks)
        let toml = """
        model = "gpt"

        [hooks.state."\(path):stop:0:0"]
        trusted_hash = "sha256:user"

        [hooks.state."\(path):stop:1:0"]
        trusted_hash = "sha256:ours"

        [hooks.state."\(path):session_start:0:0"]
        trusted_hash = "sha256:ours2"

        [hooks.state."\(path):stop:2:0"]
        trusted_hash = "sha256:later"

        [apps.other]
        enabled = false

        """
        try write(toml, to: codexToml)
        XCTAssertEqual(manager.status(.codex).trusted?.0, 2)

        try manager.uninstall(.codex)
        let after = try String(contentsOf: codexToml, encoding: .utf8)
        XCTAssertEqual(after, """
        model = "gpt"

        [hooks.state."\(path):stop:0:0"]
        trusted_hash = "sha256:user"

        [hooks.state."\(path):stop:1:0"]
        trusted_hash = "sha256:later"

        [apps.other]
        enabled = false

        """)
        XCTAssertEqual(try json(codexHooks)["hooks"]?["Stop"]?.arrayValue?.count, 2)
    }

    // MARK: Full uninstall

    func testUninstallEverythingFindsCustomLocations() throws {
        let custom = home.appendingPathComponent(".claude-work/settings.json")
        try write("{}", to: custom)
        try manager.install(.claude, configPath: custom)
        try manager.install(.codex)
        _ = manager.uninstallEverything()
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "{}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHooks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/AgentIsland").path))
    }

    func testLeftoverInUnrecordedConfigDirIsReported() throws {
        let other = home.appendingPathComponent(".claude-old/settings.json")
        try write("{}", to: other)
        try manager.install(.claude, configPath: other)
        // Simulate a lost ledger: the scan still finds marked hooks.
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/AgentIsland/ledger.json"))
        XCTAssertEqual(manager.status(.claude).leftovers, [other.path])
        _ = manager.uninstallEverything()
        XCTAssertTrue(HookConfigPatcher.owned(in: try json(other)).isEmpty)
    }
}
