import XCTest
import Foundation
import Darwin
import IslandCore
@testable import IslandIntegrations

private enum PublicationTestError: Error {
    case syscall(String, Int32)
    case missingConnection
    case incompletePacket
}

/// All sockets belong to this test; the listener never sends acknowledgements.
/// Nonblocking accept also lets cleanup release a regressed, blocking publisher.
private final class ObservationListener: @unchecked Sendable {
    let path = "/tmp/ai-publish-\(UUID().uuidString).sock"
    private(set) var descriptor: Int32 = -1

    init(backlog: Int32 = 8, receiveBuffer: Int32? = nil) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PublicationTestError.syscall("socket", errno) }
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw PublicationTestError.syscall("fcntl", errno) }
            if var receiveBuffer {
                guard setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw PublicationTestError.syscall("SO_RCVBUF", errno)
                }
            }
            var address = Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw PublicationTestError.syscall("bind", errno) }
            guard listen(descriptor, backlog) == 0 else { throw PublicationTestError.syscall("listen", errno) }
        } catch {
            close()
            throw error
        }
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8)
            bytes[path.utf8.count] = 0
        }
        return address
    }

    func acceptConnection() throws -> Int32 {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw PublicationTestError.missingConnection }
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        return client
    }

    func readEvent() throws -> AgentEvent {
        let client = try acceptConnection()
        defer { Darwin.close(client) }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        // publish has already returned, so the entire successful packet is queued.
        while data.count <= HookTransport.maximumBytes {
            let count = recv(client, &bytes, bytes.count, 0)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
            if data.last == 0x0a { return try JSONDecoder().decode(AgentEvent.self, from: data.dropLast()) }
        }
        throw PublicationTestError.incompletePacket
    }

    func close() {
        guard descriptor >= 0 else { return }
        // Release queued publishers before closing the listener. A failed test
        // must not leave a blocked send/connect running after its timeout.
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { break }
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
        unlink(path)
    }

    deinit { close() }
}

private final class PublicationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ result: Bool) { lock.lock(); defer { lock.unlock() }; value = result }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

final class HookTransportTests: XCTestCase {
    private func event(message: String = "正在执行测试 🧪") -> AgentEvent {
        AgentEvent(provider: .claude, sessionID: "passive-session", kind: .toolStarted, message: message)
    }

    /// A generous failure deadline, not a performance benchmark. The server is
    /// deliberately untouched until this returns; waiting for its UI cannot pass.
    private func publishWithoutServing(_ event: AgentEvent, listener: ObservationListener,
                                       file: StaticString = #filePath, line: UInt = #line) -> Bool? {
        let completed = expectation(description: "Observation returned without a server response")
        let result = PublicationResult()
        let transport = HookTransport(path: listener.path)
        DispatchQueue.global().async {
            result.set(transport.publish(event))
            completed.fulfill()
        }
        let outcome = XCTWaiter.wait(for: [completed], timeout: 2)
        if outcome != .completed {
            listener.close()
            XCTFail("Publishing waited for the observation server", file: file, line: line)
        }
        return result.get()
    }

    func testPublishFinishesBeforeAcceptAndDeliversOneCompleteJSONLine() throws {
        let listener = try ObservationListener()
        defer { listener.close() }
        let expected = event()
        XCTAssertEqual(publishWithoutServing(expected, listener: listener), true)
        XCTAssertEqual(try listener.readEvent(), expected)
    }

    func testOfflineStaleAndNonSocketPathsReturnFalse() throws {
        let listener = try ObservationListener()
        let transport = HookTransport(path: listener.path)
        listener.close()
        XCTAssertFalse(transport.publish(event()), "No observer is a normal no-op")

        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: listener.path))
        defer { unlink(listener.path) }
        XCTAssertFalse(transport.publish(event()), "An ordinary file is never opened as a transport")
        unlink(listener.path)

        // bind without listen leaves a genuine but unavailable socket pathname.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        guard stale >= 0 else { throw PublicationTestError.syscall("socket", errno) }
        defer { Darwin.close(stale) }
        var address = ObservationListener.address(listener.path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(transport.isListening, "The cheap pathname check alone cannot prove availability")
        XCTAssertFalse(transport.publish(event()), "A stale socket cannot delay the agent")
    }

    func testFullReceiveBufferDropsEventWithoutWaitingForReader() throws {
        let listener = try ObservationListener(receiveBuffer: 1024)
        defer { listener.close() }
        // Fits the protocol limit but cannot fit in the undrained socket buffers.
        let large = event(message: String(repeating: "x", count: 900_000))
        XCTAssertLessThan(try JSONEncoder().encode(large).count, HookTransport.maximumBytes)
        XCTAssertEqual(publishWithoutServing(large, listener: listener), false)
    }

    func testFullAcceptBacklogDropsEventWithoutWaitingForServer() throws {
        let listener = try ObservationListener(backlog: 1)
        defer { listener.close() }
        var queued: [Int32] = []
        defer { queued.forEach { Darwin.close($0) } }
        var saturated = false
        for _ in 0..<64 {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            guard client >= 0 else { throw PublicationTestError.syscall("socket", errno) }
            guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(client); throw PublicationTestError.syscall("fcntl", errno)
            }
            queued.append(client)
            var address = ObservationListener.address(listener.path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 { saturated = true; break }
        }
        XCTAssertTrue(saturated, "The fixture must actually fill the accept backlog")
        XCTAssertGreaterThan(queued.count, 1)
        XCTAssertEqual(publishWithoutServing(event(), listener: listener), false)
    }

    func testLegacyDecisionCannotBeReadAfterPublishClosesConnection() throws {
        let listener = try ObservationListener()
        defer { listener.close() }
        XCTAssertEqual(publishWithoutServing(event(), listener: listener), true)
        let client = try listener.acceptConnection()
        defer { Darwin.close(client) }
        let decision = Data(#"{"status":"resolved","requestID":"legacy","decision":"deny"}"#.utf8) + Data([0x0a])
        // A previous app may still try to answer. The publisher has already
        // exited and closed its connection before any reply is available.
        var bytes = [UInt8](repeating: 0, count: 4096)
        var count = recv(client, &bytes, bytes.count, 0)
        XCTAssertGreaterThan(count, 0, "The observation was delivered")
        while count > 0 { count = recv(client, &bytes, bytes.count, 0) }
        XCTAssertEqual(count, 0, "The publisher closed before the old app could reply")
        // macOS rejects SO_NOSIGPIPE with EINVAL when set after the peer has
        // already closed. Suppress the signal per send, without process-wide
        // signal handling that could hide a production regression.
        let sent = decision.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        let sendError = errno
        XCTAssertEqual(sent, -1)
        XCTAssertEqual(sendError, EPIPE)
    }

    func testLegacyWaitFlagExitsWithoutApprovalFromEitherProvider() throws {
        let helper = try helperExecutable()
        for provider in ["claude", "codex"] {
            let listener = try ObservationListener()
            defer { listener.close() }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["hook", provider, "--wait"]
            var environment = ProcessInfo.processInfo.environment
            environment["AGENT_ISLAND_SOCKET"] = listener.path
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let exited = expectation(description: "Legacy \(provider) hook exits without approval")
            process.terminationHandler = { _ in exited.fulfill() }
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","session_id":"legacy-wait","transcript_path":"/synthetic/session.jsonl","tool_name":"Bash","tool_use_id":"call-1","tool_input":{"command":"echo test"}}"#.utf8))
            try input.fileHandleForWriting.close()
            let outcome = XCTWaiter.wait(for: [exited], timeout: 2)
            if outcome != .completed {
                // SIGKILL bounds failure cleanup even if a future helper stops
                // handling SIGTERM; no agent or user process is involved.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                XCTFail("\(provider) still waited for an approval reply")
                continue
            }
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), provider == "codex" ? "{}\n" : "")
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertEqual(try listener.readEvent().kind, .approvalRequested)
        }
    }

    private func helperExecutable() throws -> URL {
        // SwiftPM and Xcode place executable products beside the test bundle.
        // Walk upward from the actual bundle instead of assuming an architecture.
        var directory = Bundle(for: HookTransportTests.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("agent-island-hook")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Build agent-island-hook alongside the test bundle to exercise the legacy CLI")
    }
}
