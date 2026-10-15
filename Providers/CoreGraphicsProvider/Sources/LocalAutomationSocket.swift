#if os(macOS)
import Darwin
import Foundation

/// Public POSIX same-user transport, shared by the app and CLI. The private directory protects the
/// bind→chmod window. A held flock distinguishes a crashed listener from an active owner, so a
/// second app cannot unlink the first app's endpoint. No command is retried on transport failure.
public enum LocalAutomationSocket {
    public struct TransportError: Error, Sendable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
    public static func defaultPath() throws -> String {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("OpenDisplay/ipc/control.sock").path
    }

    private static func failure(_ operation: String) -> TransportError {
        TransportError("\(operation): \(String(cString: strerror(errno)))")
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw TransportError("FreeDisplay IPC path is too long for a Unix socket")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var value = try address(path)
        return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private static func check(_ path: String, type: mode_t, mode: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == type, info.st_mode & 0o777 == mode else {
            throw TransportError("FreeDisplay IPC endpoint has unsafe ownership, type or permissions")
        }
    }
    private static func sameUser(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw TransportError("FreeDisplay IPC peer is not the current user")
        }
    }
    private static func socketFD() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket") }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = failure("socket options"); close(fd); throw error
        }
        return fd
    }
    private static func wait(_ fd: Int32, event: Int16, deadline: Date?) throws {
        guard let deadline else { return }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TransportError("FreeDisplay IPC deadline expired; accepted work may still complete") }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            // poll's integer representation is an OS ABI bound, not a chosen deadline/cap.
            let milliseconds = Int32(min((remaining * 1000).rounded(.up), Double(Int32.max)))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw failure("poll") }
        }
    }
    private static func readAll(_ fd: Int32, deadline: Date?) throws -> Data {
        var data = Data()
        // Chunk size only: the accumulated document has no imposed size limit.
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(fd, event: Int16(POLLIN), deadline: deadline)
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw failure("read")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writeAll(_ data: Data, to fd: Int32, deadline: Date?) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw failure("write")
                }
                guard count > 0 else { throw TransportError("FreeDisplay IPC connection closed") }
                offset += count
            }
        }
    }

    private final class ClientConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?
        private var cancelled = false
        func install(_ fd: Int32) throws {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                descriptor = fd
            }
        }
        func finish(_ fd: Int32) {
            lock.withLock { descriptor = nil; close(fd) }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
            }
        }
        func checkCancellation() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
    }

    public static func exchange(_ data: Data, path: String, timeout: TimeInterval? = nil) async throws -> Data {
        if let timeout, !timeout.isFinite || timeout <= 0 { throw TransportError("IPC timeout must be finite and positive") }
        let connection = ClientConnection()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try connection.checkCancellation()
                        let deadline = timeout.map { Date().addingTimeInterval($0) }
                        try check(URL(fileURLWithPath: path).deletingLastPathComponent().path, type: mode_t(S_IFDIR), mode: 0o700)
                        try check(path, type: mode_t(S_IFSOCK), mode: 0o600)
                        let fd = try socketFD()
                        do { try connection.install(fd) }
                        catch { close(fd); throw error }
                        defer { connection.finish(fd) }
                        if deadline != nil, fcntl(fd, F_SETFL, O_NONBLOCK) != 0 { throw failure("nonblocking client") }
                        let connected = try withAddress(path) { connect(fd, $0, $1) }
                        if connected != 0 {
                            guard deadline != nil, errno == EINPROGRESS else { throw failure("connect") }
                            try wait(fd, event: Int16(POLLOUT), deadline: deadline)
                            var error: Int32 = 0
                            var size = socklen_t(MemoryLayout.size(ofValue: error))
                            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                                throw TransportError("FreeDisplay IPC connection failed")
                            }
                        }
                        try sameUser(fd)
                        try writeAll(data, to: fd, deadline: deadline)
                        guard shutdown(fd, SHUT_WR) == 0 else { throw failure("shutdown") }
                        let response = try readAll(fd, deadline: deadline)
                        try connection.checkCancellation()
                        continuation.resume(returning: response)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { connection.cancel() })
    }

    public final class Server: @unchecked Sendable {
        private let queue = DispatchQueue(label: "FreeDisplay.IPC.listener")
        private let lock = NSLock()
        private let queueKey = DispatchSpecificKey<Bool>()
        private var source: DispatchSourceRead?
        private var peers: Set<Int32> = []
        private var lockFD: Int32 = -1
        private var path: String?

        public init() { queue.setSpecific(key: queueKey, value: true) }
        public func start(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
            try queue.sync { try bind(path: path, handler: handler) }
        }
        private func bind(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
            guard source == nil else { throw TransportError("FreeDisplay IPC is already started") }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try check(directory, type: mode_t(S_IFDIR), mode: 0o700)
            let owner = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard owner >= 0 else { throw failure("open lock") }
            guard flock(owner, LOCK_EX | LOCK_NB) == 0 else {
                close(owner); throw TransportError("A FreeDisplay IPC server already owns this endpoint")
            }
            let fd: Int32
            do {
                try check(path + ".lock", type: mode_t(S_IFREG), mode: 0o600)
                if FileManager.default.fileExists(atPath: path) {
                    try check(path, type: mode_t(S_IFSOCK), mode: 0o600)
                    guard unlink(path) == 0 else { throw failure("remove stale socket") }
                }
                fd = try socketFD()
            } catch { close(owner); throw error }
            do {
                guard try withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0 else { throw failure("bind") }
                guard chmod(path, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                      listen(fd, SOMAXCONN) == 0 else { throw failure("listen") }
            } catch { close(fd); unlink(path); close(owner); throw error }
            lock.withLock { self.path = path; lockFD = owner }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { return }
                do { try sameUser(peer) } catch { close(peer); return }
                var yes: Int32 = 1
                guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
                      fcntl(peer, F_SETFD, FD_CLOEXEC) == 0, fcntl(peer, F_SETFL, 0) == 0 else {
                    close(peer); return
                }
                self.lock.withLock { _ = self.peers.insert(peer) }
                DispatchQueue.global().async { [self] in
                    do {
                        let request = try readAll(peer, deadline: nil)
                        Task {
                            let response = await handler(request)
                            DispatchQueue.global().async { [self] in
                                try? writeAll(response, to: peer, deadline: nil)
                                finish(peer)
                            }
                        }
                    } catch { self.finish(peer) }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }
        private func finish(_ fd: Int32) {
            lock.withLock { _ = peers.remove(fd); close(fd) }
        }
        public func stop() {
            if DispatchQueue.getSpecific(key: queueKey) == true { closeListener() }
            else { queue.sync { closeListener() } }
        }
        private func closeListener() {
            source?.cancel(); source = nil
            lock.withLock {
                for peer in peers { _ = shutdown(peer, SHUT_RDWR) }
                if let path { unlink(path) }
                path = nil
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
            }
        }
        deinit { stop() }
    }
}
#endif
