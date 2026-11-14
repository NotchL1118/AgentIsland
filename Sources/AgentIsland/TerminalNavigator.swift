import AppKit
import IslandCore

struct NavigationOutcome { let message: String; let precise: Bool }

enum TerminalNavigator {
    /// Only fixed AppleScript templates are executed. Session content never becomes source code.
    static func jump(to session: SessionState) async -> NavigationOutcome {
        guard let target = session.terminal else { return NavigationOutcome(message: "缺少终端信息，请手动返回 \(session.provider.displayName)。", precise: false) }
        guard let app = target.appBundleID, !app.isEmpty else {
            return NavigationOutcome(message: "终端未上报应用标识，请手动返回对应会话。", precise: false)
        }
        if app == "com.apple.Terminal", let tty = target.tty, !tty.isEmpty {
            let script = """
            on run argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is item 1 of argv then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
            if await runAppleScript(script, args: [tty]) == "found" { return NavigationOutcome(message: "已返回对应 Terminal 标签。", precise: true) }
        }
        if app == "com.googlecode.iterm2", let tty = target.tty, !tty.isEmpty {
            let script = """
            on run argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is item 1 of argv then
                                    select s
                                    select t
                                    select w
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
            if await runAppleScript(script, args: [tty]) == "found" { return NavigationOutcome(message: "已返回对应 iTerm2 分屏。", precise: true) }
        }
        return await MainActor.run {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else {
                return NavigationOutcome(message: "原终端未运行，请手动打开对应会话。", precise: false)
            }
            running.activate()
            return NavigationOutcome(message: "已激活终端应用；当前接入无法精确定位此标签。", precise: false)
        }
    }
    private static func runAppleScript(_ source: String, args: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process(); let output = Pipe(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source] + args
            process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch { return nil }
            // Bound unresponsive Automation calls; no speculative keystrokes or terminal commands.
            let deadline = Date().addingTimeInterval(12)
            while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.terminate(); return nil }
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
