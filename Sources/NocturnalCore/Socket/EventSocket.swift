import Foundation

/// Errors from the NDJSON Unix-domain socket bridge.
public enum EventSocketError: Error, Sendable, Equatable {
    case pathTooLong(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case connectTimeout(String)
    case notRunning
    case encodingFailed
    case decodingFailed(String)
}

/// Lightweight diagnostics for the socket bridge (Sendable snapshot).
public struct EventSocketDiagnostics: Sendable, Equatable {
    public var acceptedClients: UInt64
    public var closedClients: UInt64
    public var linesReceived: UInt64
    public var envelopesYielded: UInt64
    public var decodeFailures: UInt64
    public var lastError: String?

    public init(
        acceptedClients: UInt64 = 0,
        closedClients: UInt64 = 0,
        linesReceived: UInt64 = 0,
        envelopesYielded: UInt64 = 0,
        decodeFailures: UInt64 = 0,
        lastError: String? = nil
    ) {
        self.acceptedClients = acceptedClients
        self.closedClients = closedClients
        self.linesReceived = linesReceived
        self.envelopesYielded = envelopesYielded
        self.decodeFailures = decodeFailures
        self.lastError = lastError
    }
}

/// Server side: app listens for NDJSON lines from hook forwarders.
///
/// Accept loop is cancel-safe: ``stop()`` closes the listening fd so a blocked
/// `accept` unblocks. Client **reads** run **off actor isolation** so an idle
/// client cannot stall accept / a second client / `stop()`. Multi-client reads
/// fan into a single ``AsyncStream``.
public actor EventSocketServer {
    public private(set) var isRunning = false
    public private(set) var diagnostics = EventSocketDiagnostics()

    private let path: URL
    private let maxLineBytes: Int
    /// Shared with AppModel so Approve/Deny can unblock waiting forwarders.
    private let permissionBroker: PermissionBroker
    private var listener: LocalUnixListener?
    private var clientTasks: [UUID: Task<Void, Never>] = [:]
    /// Open client handles so ``stop()`` can close them and unblock idle reads.
    private var clientHandles: [UUID: FileHandle] = [:]
    private var acceptTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<EventEnvelope>.Continuation?
    private var eventStream: AsyncStream<EventEnvelope>?

    public init(
        path: URL,
        maxLineBytes: Int = 1_048_576,
        permissionBroker: PermissionBroker = PermissionBroker()
    ) {
        self.path = path
        self.maxLineBytes = max(4096, maxLineBytes)
        self.permissionBroker = permissionBroker
    }

    public func broker() -> PermissionBroker {
        permissionBroker
    }

    /// Start listening. Yields decoded envelopes on the returned stream.
    /// Calling again while running returns the existing stream.
    public func start() throws -> AsyncStream<EventEnvelope> {
        if let existing = eventStream, isRunning {
            return existing
        }

        let listener = LocalUnixListener(path: path)
        try listener.bindAndListen()
        self.listener = listener
        isRunning = true
        diagnostics = EventSocketDiagnostics()

        let (stream, continuation) = AsyncStream<EventEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self.eventContinuation = continuation
        self.eventStream = stream

        acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }

        return stream
    }

    public func stop() {
        isRunning = false
        acceptTask?.cancel()
        acceptTask = nil
        listener?.close()
        listener = nil
        // Shutdown then close client fds so off-actor blocking reads unblock promptly.
        // `close` alone can leave a peer `read` blocked on some Darwin kernels;
        // `shutdown(SHUT_RDWR)` forces EOF/error on the blocked reader first.
        for handle in clientHandles.values {
            let fd = handle.fileDescriptor
            if fd >= 0 {
                Darwin.shutdown(fd, SHUT_RDWR)
            }
            try? handle.close()
        }
        clientHandles.removeAll()
        for task in clientTasks.values {
            task.cancel()
        }
        clientTasks.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        try? FileManager.default.removeItem(at: path)
    }

    public func currentDiagnostics() -> EventSocketDiagnostics {
        diagnostics
    }

    private func acceptLoop() async {
        while isRunning, !Task.isCancelled, let listener {
            do {
                let handle = try await listener.accept()
                guard isRunning, !Task.isCancelled else {
                    try? handle.close()
                    break
                }
                diagnostics.acceptedClients &+= 1
                let clientID = UUID()
                clientHandles[clientID] = handle
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.readClient(handle, id: clientID)
                }
                clientTasks[clientID] = task
            } catch {
                if isRunning && !Task.isCancelled {
                    diagnostics.lastError = String(describing: error)
                }
                break
            }
        }
    }

    private func readClient(_ handle: FileHandle, id: UUID) async {
        // Capture fd once for send/recv (avoid NSFileHandle.fileDescriptor races).
        let clientFD = handle.fileDescriptor
        defer {
            if clientFD >= 0 {
                Darwin.shutdown(clientFD, SHUT_RDWR)
            }
            try? handle.close()
            clientHandles[id] = nil
            clientTasks[id] = nil
            diagnostics.closedClients &+= 1
        }

        let decoder = makeEnvelopeDecoder()
        var buffer = Data()
        let lineLimit = maxLineBytes

        while !Task.isCancelled && isRunning {
            let chunk: Data?
            do {
                chunk = try await Self.readChunkFromFD(clientFD, maxBytes: 8192)
            } catch {
                if isRunning && !Task.isCancelled {
                    diagnostics.lastError = error.localizedDescription
                }
                break
            }
            guard let data = chunk, !data.isEmpty else {
                break
            }

            buffer.append(data)
            if buffer.count > lineLimit * 2 {
                diagnostics.decodeFailures &+= 1
                diagnostics.lastError = "client buffer exceeded limit"
                if let nl = buffer.lastIndex(of: 0x0A) {
                    buffer.removeSubrange(..<buffer.index(after: nl))
                } else {
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            while let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                guard !line.isEmpty else { continue }
                diagnostics.linesReceived &+= 1

                if line.count > lineLimit {
                    diagnostics.decodeFailures &+= 1
                    diagnostics.lastError = "line exceeded \(lineLimit) bytes"
                    continue
                }

                do {
                    let envelope = try decoder.decode(EventEnvelope.self, from: line)
                    eventContinuation?.yield(envelope)
                    diagnostics.envelopesYielded &+= 1

                    // Decision-mode: block this client until UI answers (or timeout → defer).
                    if HookDecisionTranslator.envelopeNeedsDecision(envelope) {
                        let decisionId = HookDecisionTranslator.decisionRequestId(for: envelope)
                        let timeout = HookDecisionTranslator.timeoutSeconds(from: envelope)
                        let result = await permissionBroker.wait(
                            for: decisionId,
                            timeoutSeconds: timeout
                        )
                        let reply = PermissionDecisionReply(
                            decisionRequestId: decisionId,
                            behavior: result.behavior,
                            message: result.message
                        )
                        await Self.writeReplyToFD(clientFD, reply: reply)
                    }
                } catch {
                    diagnostics.decodeFailures &+= 1
                    diagnostics.lastError = "decode: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func writeReplyToFD(_ fd: Int32, reply: PermissionDecisionReply) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(reply) else { return }
        data.append(0x0A)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                guard fd >= 0 else {
                    cont.resume()
                    return
                }
                data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var sent = 0
                    let total = buffer.count
                    while sent < total {
                        let n = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                cont.resume()
            }
        }
    }

    private static func readChunkFromFD(_ fd: Int32, maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: maxBytes)
                let n = Darwin.recv(fd, &buffer, maxBytes, 0)
                if n > 0 {
                    continuation.resume(returning: Data(buffer.prefix(n)))
                } else if n == 0 {
                    continuation.resume(returning: Data())
                } else {
                    if errno == EINTR || errno == EAGAIN {
                        continuation.resume(returning: Data())
                    } else {
                        continuation.resume(throwing: EventSocketError.connectFailed("recv \(errno)"))
                    }
                }
            }
        }
    }

    private func makeEnvelopeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try EventEnvelopeDateParsing.decode(from: decoder)
        }
        return decoder
    }
}

/// Client side used by hook-forwarder and simulation CLIs.
public struct EventSocketClient: Sendable {
    public var path: URL
    /// Connect timeout in seconds. Default 500ms keeps hooks snappy / fail-open.
    public var connectTimeout: TimeInterval

    public init(path: URL, connectTimeout: TimeInterval = 0.5) {
        self.path = path
        self.connectTimeout = max(0.05, connectTimeout)
    }

    /// Connect, write one NDJSON line (with trailing newline), disconnect.
    /// Throws on hard failures so the forwarder can decide fail-open policy.
    public func send(_ envelope: EventEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(envelope) else {
            throw EventSocketError.encodingFailed
        }
        data.append(0x0A)
        try LocalUnixClient.send(data: data, to: path, timeout: connectTimeout)
    }

    /// Send raw bytes (already NDJSON). Used by fail-open forwarder.
    public func sendRawLine(_ line: Data) throws {
        var data = line
        if data.last != 0x0A {
            data.append(0x0A)
        }
        try LocalUnixClient.send(data: data, to: path, timeout: connectTimeout)
    }

    /// Send one NDJSON line and wait for a decision reply (decision-mode hooks).
    public func sendAndReceiveDecision(
        _ envelope: EventEnvelope,
        receiveTimeout: TimeInterval
    ) throws -> PermissionDecisionReply {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(envelope) else {
            throw EventSocketError.encodingFailed
        }
        data.append(0x0A)
        let replyData = try LocalUnixClient.sendAndReceive(
            data: data,
            to: path,
            connectTimeout: connectTimeout,
            receiveTimeout: receiveTimeout
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PermissionDecisionReply.self, from: replyData)
        } catch {
            throw EventSocketError.decodingFailed(error.localizedDescription)
        }
    }
}

// MARK: - BSD socket helpers

/// Unix-domain stream listener with cancel-friendly accept.
final class LocalUnixListener: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()
    private var fd: Int32 = -1

    init(path: URL) {
        self.path = path
    }

    func bindAndListen(backlog: Int32 = 32) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw EventSocketError.bindFailed("socket() failed: \(errno)")
        }

        var on: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // Avoid SIGPIPE if a client disconnects mid-write (server rarely writes, but safe).
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathString = path.path
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathString.utf8.count <= maxLen else {
            Darwin.close(sock)
            throw EventSocketError.pathTooLong(pathString)
        }
        pathString.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(sock)
            throw EventSocketError.bindFailed("bind failed: \(err)")
        }

        guard Darwin.listen(sock, backlog) == 0 else {
            let err = errno
            Darwin.close(sock)
            throw EventSocketError.listenFailed("listen failed: \(err)")
        }

        lock.lock()
        fd = sock
        lock.unlock()
    }

    func accept() async throws -> FileHandle {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.lock.lock()
                let listenFD = self.fd
                self.lock.unlock()
                guard listenFD >= 0 else {
                    continuation.resume(throwing: EventSocketError.notRunning)
                    return
                }

                var addr = sockaddr_un()
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(listenFD, sockPtr, &len)
                    }
                }
                if clientFD < 0 {
                    let err = errno
                    // EBADF / EINVAL after close() during stop — treat as not running.
                    if err == EBADF || err == EINVAL {
                        continuation.resume(throwing: EventSocketError.notRunning)
                    } else {
                        continuation.resume(throwing: EventSocketError.listenFailed("accept failed: \(err)"))
                    }
                } else {
                    var on: Int32 = 1
                    _ = setsockopt(
                        clientFD,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &on,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                    // Independent lifetime from the listener.
                    let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
                    continuation.resume(returning: handle)
                }
            }
        }
    }

    func close() {
        lock.lock()
        let toClose = fd
        fd = -1
        lock.unlock()
        if toClose >= 0 {
            Darwin.shutdown(toClose, SHUT_RDWR)
            Darwin.close(toClose)
        }
    }

    deinit {
        close()
    }
}

enum LocalUnixClient {
    static func send(data: Data, to path: URL, timeout: TimeInterval) throws {
        let fd = try connect(to: path, timeout: timeout)
        defer { Darwin.close(fd) }
        try writeAll(fd: fd, data: data, timeout: timeout)
    }

    /// Connect, write one line, read one reply line (decision-mode).
    static func sendAndReceive(
        data: Data,
        to path: URL,
        connectTimeout: TimeInterval,
        receiveTimeout: TimeInterval
    ) throws -> Data {
        let fd = try connect(to: path, timeout: connectTimeout)
        defer { Darwin.close(fd) }
        try writeAll(fd: fd, data: data, timeout: connectTimeout)
        return try readLine(fd: fd, timeout: receiveTimeout, maxBytes: 65_536)
    }

    private static func connect(to path: URL, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EventSocketError.connectFailed("socket() failed: \(errno)")
        }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathString = path.path
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathString.utf8.count <= maxLen else {
            Darwin.close(fd)
            throw EventSocketError.pathTooLong(pathString)
        }
        pathString.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            let err = errno
            if err == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let timeoutMs = Int32((timeout * 1000).rounded(.up))
                let pr = poll(&pfd, 1, timeoutMs)
                if pr == 0 {
                    Darwin.close(fd)
                    throw EventSocketError.connectTimeout(pathString)
                }
                if pr < 0 {
                    Darwin.close(fd)
                    throw EventSocketError.connectFailed("poll failed: \(errno) path=\(pathString)")
                }
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                if soError != 0 {
                    Darwin.close(fd)
                    throw EventSocketError.connectFailed("connect failed: \(soError) path=\(pathString)")
                }
            } else {
                Darwin.close(fd)
                throw EventSocketError.connectFailed("connect failed: \(err) path=\(pathString)")
            }
        }

        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags)
        }
        return fd
    }

    private static func writeAll(fd: Int32, data: Data, timeout: TimeInterval) throws {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            let total = buffer.count
            while sent < total {
                let n = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EventSocketError.connectFailed("send failed: \(errno)")
                }
                if n == 0 {
                    throw EventSocketError.connectFailed("send returned 0")
                }
                sent += n
            }
        }
    }

    private static func readLine(fd: Int32, timeout: TimeInterval, maxBytes: Int) throws -> Data {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var result = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while result.count < maxBytes {
            if Date() > deadline {
                throw EventSocketError.connectTimeout("receive")
            }
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n == 1 {
                if byte == 0x0A { break }
                result.append(byte)
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw EventSocketError.connectTimeout("receive")
                }
                throw EventSocketError.connectFailed("recv failed: \(errno)")
            }
        }
        guard !result.isEmpty else {
            throw EventSocketError.decodingFailed("empty decision reply")
        }
        return result
    }
}
