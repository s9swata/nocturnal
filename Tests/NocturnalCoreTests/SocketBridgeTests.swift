import Foundation
import Testing
@testable import NocturnalCore

@Suite(.serialized)
struct SocketBridgeTests {
    @Test func roundTripEnvelopeOnTempSocket() async throws {
        let (temp, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "ns")
        defer { cleanup() }

        let socketURL = SocketPaths.testingSocketPath(in: temp, name: "i.sock")
        #expect(socketURL.path.utf8.count < 100)

        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()

        // Give the accept loop a tick to bind.
        try await Task.sleep(for: .milliseconds(50))

        let envelope = EventEnvelope(
            id: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            source: .codex,
            eventType: "session.started",
            sessionId: "sock-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            payload: ["title": .string("Socket ping")],
            raw: [:]
        )

        let client = EventSocketClient(path: socketURL, connectTimeout: 2.0)
        try client.send(envelope)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }

        let got = try #require(received)
        #expect(got.sessionId == "sock-1")
        #expect(got.eventType == "session.started")
        #expect(got.source == .codex)
        #expect(got.payload["title"] == .string("Socket ping"))

        let diagnostics = await server.currentDiagnostics()
        #expect(diagnostics.envelopesYielded >= 1)
        #expect(diagnostics.linesReceived >= 1)

        await server.stop()
    }

    @Test func rawLineAndMultipleClients() async throws {
        let (temp, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "nm")
        defer { cleanup() }

        let socketURL = SocketPaths.testingSocketPath(in: temp, name: "m.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(50))

        let line1 = Data(#"{"v":1,"id":"11111111-1111-4111-8111-111111111101","source":"claude","eventType":"SessionStart","sessionId":"c1","timestamp":"2023-11-14T22:13:20Z","payload":{"title":"A"},"raw":{}}"#.utf8)
        let line2 = Data(#"{"v":1,"id":"11111111-1111-4111-8111-111111111102","source":"claude","eventType":"Stop","sessionId":"c1","timestamp":"2023-11-14T22:13:25Z","payload":{},"raw":{}}"#.utf8)

        let client = EventSocketClient(path: socketURL, connectTimeout: 2.0)
        try client.sendRawLine(line1)
        try client.sendRawLine(line2)

        var collected: [EventEnvelope] = []
        for await event in stream {
            collected.append(event)
            if collected.count >= 2 { break }
        }

        #expect(collected.count == 2)
        #expect(collected[0].sessionId == "c1")
        #expect(collected.map(\.eventType) == ["SessionStart", "Stop"])

        await server.stop()
    }

    @Test func badLineDoesNotCrashServer() async throws {
        let (temp, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "nb")
        defer { cleanup() }

        let socketURL = SocketPaths.testingSocketPath(in: temp, name: "b.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(50))

        let client = EventSocketClient(path: socketURL, connectTimeout: 2.0)
        try client.sendRawLine(Data("this is not json".utf8))

        let good = EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "after-bad",
            payload: ["title": .string("ok")]
        )
        try client.send(good)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }
        #expect(received?.sessionId == "after-bad")

        let diagnostics = await server.currentDiagnostics()
        #expect(diagnostics.decodeFailures >= 1)

        await server.stop()
    }

    @Test func forwarderSucceedsWhenServerListening() async throws {
        let (temp, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "nf")
        defer { cleanup() }

        let socketURL = SocketPaths.testingSocketPath(in: temp, name: "f.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(50))

        let encoder = TestSupport.isoEncoder()
        let envelope = EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "fwd-1",
            payload: ["title": .string("via forwarder")]
        )
        let line = try encoder.encode(envelope)

        let forwarder = FailOpenHookForwarder(options: HookForwarderOptions(connectTimeout: 2.0))
        let result = forwarder.forward(line: line, socketPath: socketURL)
        #expect(result.succeeded)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }
        #expect(received?.sessionId == "fwd-1")

        await server.stop()
    }

    /// Idle first client must not block a second client from delivering, and
    /// `stop()` must complete promptly while a client is connected idle.
    @Test func secondClientDeliversWhileFirstIsIdleAndStopIsResponsive() async throws {
        let (temp, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "ni")
        defer { cleanup() }

        let socketURL = SocketPaths.testingSocketPath(in: temp, name: "i2.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(50))

        // Hold an idle connection open (no data) while another client sends.
        let pathString = socketURL.path
        let idleHold = Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            pathString.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                    _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
                }
            }
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(80))

        let envelope = EventEnvelope(
            source: .claude,
            eventType: "SessionStart",
            sessionId: "second-client",
            payload: ["title": .string("from-second")]
        )
        let client = EventSocketClient(path: socketURL, connectTimeout: 2.0)
        try client.send(envelope)

        // Collect with a timeout via next() pattern — no shared mutable state races.
        let received: EventEnvelope? = await withTaskGroup(of: EventEnvelope?.self) { group in
            group.addTask {
                for await event in stream {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        #expect(received?.sessionId == "second-client")

        let stopStarted = ContinuousClock.now
        await server.stop()
        let stopElapsed = ContinuousClock.now - stopStarted
        #expect(stopElapsed < .seconds(2))

        idleHold.cancel()
    }
}

// MARK: - Jump-back scheme validation

struct JumpBackStrategyTests {
    @Test func codexDeepLinkRejectsUnknownSchemes() async {
        let strategy = CodexDeepLinkStrategy()
        let bad = JumpBackContext(codexDeepLink: URL(string: "https://evil.example/x"))
        #expect(strategy.canHandle(bad) == false)
        let result = await strategy.perform(bad)
        #expect(result.succeeded == false)
        #expect(result.detail.lowercased().contains("scheme") || result.detail.contains("Unsupported"))

        let good = JumpBackContext(codexDeepLink: URL(string: "codex://session/1"))
        #expect(strategy.canHandle(good))
        #expect(CodexDeepLinkStrategy.isAllowedScheme("codex"))
        #expect(CodexDeepLinkStrategy.isAllowedScheme("openai-codex"))
        #expect(CodexDeepLinkStrategy.isAllowedScheme("CODEX"))
        #expect(CodexDeepLinkStrategy.isAllowedScheme("javascript") == false)
    }
}
