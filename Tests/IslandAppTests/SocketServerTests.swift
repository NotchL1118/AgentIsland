import XCTest
import Foundation
import Darwin
import IslandCore
@testable import AgentIsland

enum SocketTestError: Error {
    case syscall(String, Int32)
    case closed
    case missingNewline
    case conditionTimedOut
}

/// Test-owned local connection. It never reads an agent config or starts a model.
final class TestSocketClient: @unchecked Sendable {
    private(set) var descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketTestError.syscall("socket", errno) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(); throw SocketTestError.syscall("path", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (index, byte) in path.utf8.enumerated() { target[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno; close(); throw SocketTestError.syscall("connect", code)
        }
    }

    func send(_ event: AgentEvent) throws {
        var data = try JSONEncoder().encode(event)
        data.append(0x0a)
        try send(data)
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SocketTestError.syscall("send", errno) }
                offset += count
            }
        }
    }

    func readReply() throws -> BridgeReply {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while bytes.count <= 1_048_576 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SocketTestError.syscall("recv", errno) }
            guard count > 0 else { throw SocketTestError.closed }
            bytes.append(contentsOf: buffer.prefix(count))
            if let newline = bytes.firstIndex(of: 0x0a) {
                return try JSONDecoder().decode(BridgeReply.self, from: bytes.prefix(upTo: newline))
            }
        }
        throw SocketTestError.missingNewline
    }

    func close() {
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    deinit { close() }
}

func testSocketPath() -> String { "/tmp/agent-island-test-\(UUID().uuidString).sock" }

final class SocketServerTests: XCTestCase {
    func testAcknowledgementToAnAlreadyClosedObserverIsHarmless() throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw SocketTestError.syscall("socketpair", errno)
        }
        Darwin.close(pair[1])
        // No SO_NOSIGPIPE setup: the send itself must handle a vanished reader.
        let connection = EventConnection(pair[0])
        XCTAssertFalse(connection.reply(BridgeReply(status: "accepted")))
        XCTAssertFalse(connection.reply(BridgeReply(status: "accepted")))
    }

    func testValidEventRoundtripAndSocketPermissions() throws {
        let expected = AgentEvent(provider: .claude, sessionID: "session", kind: .turnStarted, title: "中文标题")
        let received = expectation(description: "Decoded event")
        let server = SocketServer(path: testSocketPath()) { event, connection in
            XCTAssertEqual(event, expected)
            connection.reply(BridgeReply(status: "accepted"))
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(server.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let client = try TestSocketClient(path: server.path)
        defer { client.close() }
        try client.send(expected)
        XCTAssertEqual(try client.readReply().status, "accepted")
        wait(for: [received], timeout: 2)
    }

    func testFragmentedJSONIsAssembledBeforeDispatch() throws {
        let event = AgentEvent(provider: .pi, sessionID: "fragmented", kind: .toolStarted, message: "中文字符跨包")
        let server = SocketServer(path: testSocketPath()) { received, connection in
            XCTAssertEqual(received.message, event.message)
            connection.reply(BridgeReply(status: "accepted"))
        }
        try server.start()
        defer { server.stop() }
        let client = try TestSocketClient(path: server.path)
        defer { client.close() }
        var packet = try JSONEncoder().encode(event)
        packet.append(0x0a)
        for index in stride(from: 0, to: packet.count, by: 7) {
            try client.send(packet.subdata(in: index..<min(index + 7, packet.count)))
        }
        XCTAssertEqual(try client.readReply().status, "accepted")
    }

    func testInvalidJSONReturnsErrorWithoutDispatching() throws {
        let server = SocketServer(path: testSocketPath()) { _, _ in XCTFail("Invalid JSON must not be dispatched") }
        try server.start()
        defer { server.stop() }
        let client = try TestSocketClient(path: server.path)
        defer { client.close() }
        try client.send(Data("{broken}\n".utf8))
        XCTAssertEqual(try client.readReply().status, "error")
    }

    func testInvalidProtocolVersionAndFutureTimestampAreRejected() throws {
        let server = SocketServer(path: testSocketPath()) { _, _ in XCTFail("Invalid protocol must not be dispatched") }
        try server.start()
        defer { server.stop() }
        let invalid = [
            AgentEvent(version: 99, provider: .codex, sessionID: "version", kind: .sessionStarted),
            AgentEvent(provider: .codex, sessionID: "future", timestamp: Date().timeIntervalSince1970 + 3600, kind: .sessionStarted),
        ]
        for event in invalid {
            let client = try TestSocketClient(path: server.path)
            try client.send(event)
            XCTAssertEqual(try client.readReply().status, "error")
            client.close()
        }
    }

    func testSecondInstanceCannotReplaceAnActiveSocket() throws {
        let path = testSocketPath()
        let first = SocketServer(path: path) { _, connection in connection.reply(BridgeReply(status: "accepted")) }
        try first.start()
        defer { first.stop() }
        let second = SocketServer(path: path) { _, _ in XCTFail("Second server cannot run") }
        XCTAssertThrowsError(try second.start()) { error in
            guard case SocketFailure.alreadyRunning = error else { return XCTFail("Unexpected failure: \(error)") }
        }
        second.stop()
        let client = try TestSocketClient(path: path)
        defer { client.close() }
        try client.send(AgentEvent(provider: .claude, sessionID: "first-still-works", kind: .heartbeat))
        XCTAssertEqual(try client.readReply().status, "accepted")
    }

    func testUnsafePathDoesNotDeleteExistingFile() throws {
        let path = testSocketPath()
        let original = Data("keep this file".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let server = SocketServer(path: path) { _, _ in }
        XCTAssertThrowsError(try server.start()) { error in
            guard case SocketFailure.unsafePath = error else { return XCTFail("Unexpected failure: \(error)") }
        }
        server.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testOversizedSocketPathIsRejected() {
        let server = SocketServer(path: "/tmp/" + String(repeating: "x", count: 150)) { _, _ in }
        XCTAssertThrowsError(try server.start()) { error in
            guard case SocketFailure.unsafePath = error else { return XCTFail("Unexpected failure: \(error)") }
        }
    }

    func testPromptConnectionReceivesOnlyReceiptAcknowledgement() throws {
        let request = AgentRequest(id: "request-123", kind: .approval, title: "Run tests?")
        let server = SocketServer(path: testSocketPath()) { event, connection in
            XCTAssertEqual(event.request?.id, request.id)
            XCTAssertTrue(connection.reply(BridgeReply(status: "accepted")))
            XCTAssertFalse(connection.reply(BridgeReply(status: "accepted")), "Each event closes after its acknowledgement")
        }
        try server.start()
        defer { server.stop() }
        let client = try TestSocketClient(path: server.path)
        defer { client.close() }
        try client.send(AgentEvent(provider: .claude, sessionID: "s", kind: .approvalRequested, request: request))
        XCTAssertEqual(try client.readReply(), BridgeReply(status: "accepted"))
    }
}
