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
            source: .demo,
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
}
