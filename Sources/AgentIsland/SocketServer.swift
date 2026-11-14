import Foundation
import Darwin
import IslandCore

enum SocketFailure: LocalizedError {
    case system(String, Int32)
    case alreadyRunning
    case unsafePath
    var errorDescription: String? {
        switch self {
        case .system(let action, let code): return "\(action): \(String(cString: strerror(code)))"
        case .alreadyRunning: return "已有 Agent Island 正在监听。请退出旧实例后重试。"
        case .unsafePath: return "Socket 路径不安全或过长。"
        }
    }
}

/// One newline-delimited request/reply connection. Never executes incoming commands.
final class EventConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    let createdAt = Date()
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count > 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
    }
    @discardableResult
    func reply(_ response: BridgeReply) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        defer { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(0x0a)
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
    deinit {
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
    }
}

final class SocketServer: @unchecked Sendable {
    static var defaultPath: String {
        if let custom = ProcessInfo.processInfo.environment["AGENT_ISLAND_SOCKET"], !custom.isEmpty { return custom }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-island-\(getuid()).sock").path
    }
    let path: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var ownsPath = false
    private let onEvent: (AgentEvent, EventConnection) -> Void
    init(path: String = SocketServer.defaultPath, onEvent: @escaping (AgentEvent, EventConnection) -> Void) {
        self.path = path; self.onEvent = onEvent
    }
    func start() throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw SocketFailure.unsafePath }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (index, byte) in path.utf8.enumerated() { target[index] = byte }
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { throw SocketFailure.unsafePath }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let code = errno
            Darwin.close(probe)
            if result == 0 { throw SocketFailure.alreadyRunning }
            guard code == ECONNREFUSED || code == ENOENT else { throw SocketFailure.system("检查 Socket", code) }
            guard unlink(path) == 0 || errno == ENOENT else { throw SocketFailure.system("移除失效 Socket", errno) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure.system("创建 Socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; Darwin.close(fd); throw SocketFailure.system("绑定 Socket", code) }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0, listen(fd, 32) == 0 else {
            let code = errno; Darwin.close(fd); unlink(path); throw SocketFailure.system("监听 Socket", code)
        }
        lock.lock(); descriptor = fd; ownsPath = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd) }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
        if ownsPath { unlink(path); ownsPath = false }
    }
    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var readTimeout = timeval(tv_sec: 3, tv_usec: 0)
            var writeTimeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .utility).async { [self] in receive(client) }
        }
    }
    private func receive(_ fd: Int32) {
        let connection = EventConnection(fd)
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while bytes.count <= 1_048_576 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            guard let newline = bytes.firstIndex(of: 0x0a) else { continue }
            guard newline <= 1_048_576 else { break }
            do {
                let event = try JSONDecoder().decode(AgentEvent.self, from: bytes.prefix(upTo: newline))
                guard event.version == 1, !event.id.isEmpty, !event.sessionID.isEmpty, event.sessionID.count < 4096,
                      event.timestamp.isFinite, event.timestamp >= 0, event.timestamp <= Date().timeIntervalSince1970 + 300 else {
                    connection.reply(BridgeReply(status: "error", message: "Invalid event identity, version or timestamp")); return
                }
                onEvent(event, connection)
            } catch { connection.reply(BridgeReply(status: "error", message: "Invalid JSON event: \(error.localizedDescription)")) }
            return
        }
        connection.reply(BridgeReply(status: "error", message: "Event exceeds 1 MiB"))
    }
    deinit { stop() }
}
