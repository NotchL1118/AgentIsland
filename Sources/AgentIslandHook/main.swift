import Foundation
import Darwin
import IslandCore
import IslandIntegrations

// agent-island-hook — the single runtime every persistent integration calls.
//
//   hook <provider> [--wait]            run as an agent hook (stdin JSON → stdout)
//   install|uninstall <provider> [--config <path>]
//   uninstall-all                       remove every integration and Agent Island's own files
//   status                              show what is installed where
//   emit [--timeout <seconds>]          send one protocol event from stdin, print the reply
//
// In hook mode it always exits 0. Silence means "no decision", never "allow".

signal(SIGPIPE, SIG_IGN)
var arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != HookCommand.marker }

func readStdin(limit: Int = HookTransport.maximumBytes) -> Data? {
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        data.append(chunk)
        if data.count > limit { return nil }
    }
    return data
}

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func helperPath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
}

func runHook() -> Never {
    let provider = AgentProvider(rawValue: arguments.count > 1 ? arguments[1] : "")
    let adapter = AdapterRegistry.adapter(for: provider)
    let silent = adapter?.silentOutput
    let transport = HookTransport()
    let input = readStdin()
    // Fast path: no app, nothing to do. Exit before probing the terminal.
    guard let adapter, transport.isListening, let input,
          let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
        if let silent { print(silent) }
        exit(0)
    }
    let context = HookContext(send: { transport.send($0, timeout: $1) })
    if let output = adapter.handle(payload, waiting: arguments.contains("--wait"), context: context) { print(output) }
    else if let silent { print(silent) }
    exit(0)
}

func printReports(_ reports: [IntegrationReport]) {
    for report in reports {
        print("[\(report.provider.displayName)] \(report.path)")
        report.lines.forEach { print("  " + $0) }
    }
}

let manager = IntegrationManager(IntegrationEnvironment(helperPath: helperPath()))
switch arguments.first {
case "hook":
    runHook()
case "install", "uninstall":
    guard arguments.count > 1 else { fputs("用法：agent-island-hook \(arguments[0]) <claude|codex> [--config <path>]\n", stderr); exit(2) }
    do {
        let provider = AgentProvider(rawValue: arguments[1])
        let path = value(after: "--config").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let report = arguments[0] == "install" ? try manager.install(provider, configPath: path) : try manager.uninstall(provider, configPath: path)
        printReports([report])
    } catch {
        fputs("Agent Island: \(error.localizedDescription)\n", stderr); exit(1)
    }
case "uninstall-all":
    printReports(manager.uninstallEverything())
case "status":
    for adapter in AdapterRegistry.all {
        let status = manager.status(adapter.descriptor.provider)
        print("[\(status.provider.displayName)] \(status.state) \(status.path ?? "")")
        if let trusted = status.trusted { print("  已信任 \(trusted.0)/\(trusted.1)") }
        (status.notes + status.leftovers.map { "残留：" + $0 }).forEach { print("  " + $0) }
    }
case "emit":
    guard let input = readStdin(), let event = try? JSONDecoder().decode(AgentEvent.self, from: input) else {
        fputs("stdin 必须是一个协议事件 JSON\n", stderr); exit(1)
    }
    let timeout = value(after: "--timeout").flatMap(Double.init) ?? 0.8
    let reply = HookTransport().send(event, timeout: min(120, max(0.01, timeout))) ?? BridgeReply(status: "unavailable")
    print(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
default:
    fputs("用法：agent-island-hook <hook|install|uninstall|uninstall-all|status|emit> …\n", stderr)
    exit(2)
}
