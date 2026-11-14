import Foundation
import Darwin
import IslandCore

/// Sends one event per connection and reads one reply line. Every failure maps
/// to `nil`, which adapters must treat as "no decision", never as approval.
public struct HookTransport: Sendable {
    public static let maximumBytes = 1024 * 1024
    public var path: String

    public init(path: String = HookTransport.defaultPath()) { self.path = path }

    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let custom = environment["AGENT_ISLAND_SOCKET"], !custom.isEmpty { return custom }
        let temporary = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: temporary).appendingPathComponent("agent-island-\(getuid()).sock").path
    }

    /// Cheap pre-check so hooks exit before any other work when the app is not running.
    public var isListening: Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    public func send(_ event: AgentEvent, timeout: TimeInterval) -> BridgeReply? {
        guard isListening, var packet = try? JSONEncoder().encode(event) else { return nil }
        packet.append(0x0A)
        guard packet.count <= Self.maximumBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        Self.setTimeout(descriptor, min(timeout, 0.8))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        Self.setTimeout(descriptor, max(timeout, 0.01))
        let sent = packet.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard sent else { return nil }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !received.contains(0x0A) {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            received.append(contentsOf: chunk[0..<count])
            guard received.count <= Self.maximumBytes else { return nil }
        }
        let line = received.prefix { $0 != 0x0A }
        return try? JSONDecoder().decode(BridgeReply.self, from: line)
    }

    private static func setTimeout(_ descriptor: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Terminal identity from the environment and the controlling TTY (read via
/// sysctl, no subprocess). Nothing is invented when a source is missing.
public enum TerminalProbe {
    static let bundleIDs = [
        "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable",
    ]

    /// Desktop agents that run hooks themselves; navigation activates the app.
    public static let guiAgentBundleIDs: Set<String> = ["com.openai.codex"]

    public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment,
                               controllingTTY: () -> String? = TerminalProbe.controllingTTY) -> TerminalTarget? {
        var target = TerminalTarget()
        // A hook spawned by a GUI agent (Codex Desktop) belongs to that app, even if
        // its environment still carries a terminal's TERM_PROGRAM.
        let launcher = nonEmpty(env["__CFBundleIdentifier"])
        let guiAgent = launcher.flatMap { guiAgentBundleIDs.contains($0) ? $0 : nil }
        target.appBundleID = nonEmpty(env["AGENT_ISLAND_TERMINAL_BUNDLE_ID"]) ?? guiAgent ?? bundleIDs[env["TERM_PROGRAM"] ?? ""] ?? launcher
        if let tty = nonEmpty(env["AGENT_ISLAND_TTY"]) ?? controllingTTY(), tty.hasPrefix("/dev/"), tty != "/dev/tty" {
            target.tty = tty
        }
        target.tmuxPane = nonEmpty(env["TMUX_PANE"])
        target.paneID = nonEmpty(env["ITERM_SESSION_ID"])
        target.tabID = nonEmpty(env["TERM_SESSION_ID"])
        target.windowID = nonEmpty(env["WINDOWID"])
        return target == TerminalTarget() ? nil : target
    }

    public static func controllingTTY() -> String? {
        for pid in [getpid(), getppid()] {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { continue }
            let device = info.kp_eproc.e_tdev
            guard device != -1, let name = devname(device, S_IFCHR) else { continue }
            let value = String(cString: name)
            if !value.isEmpty, value != "??" { return "/dev/" + value }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }
}
