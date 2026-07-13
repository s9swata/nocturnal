import Darwin
import Foundation
import Testing
@testable import NocturnalCore

struct HookForwarderTests {
    @Test func rawClaudeJSONNormalizesBeforeSend() async throws {
        let (root, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "fwd-norm")
        defer { cleanup() }

        let socketURL = root.appendingPathComponent("ipc.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(40))

        // Upstream Claude-style hook JSON (not an EventEnvelope).
        let raw = Data(#"{"hook_event_name":"SessionStart","session_id":"claude-sess-1","cwd":"/tmp/proj"}"#.utf8)
        let forwarder = FailOpenHookForwarder(
            options: HookForwarderOptions(connectTimeout: 2.0, wrapSource: .claude)
        )
        let result = forwarder.forward(line: raw, socketPath: socketURL)
        #expect(result.succeeded)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }
        let envelope = try #require(received)
        #expect(envelope.sessionId == "claude-sess-1")
        #expect(envelope.eventType == "SessionStart")
        #expect(envelope.source == .claude)
        #expect(envelope.raw["hook_event_name"] == .string("SessionStart"))

        await server.stop()
    }

    @Test func rawJSONWithoutWrapSourceStillNormalizes() async throws {
        let (root, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "fwd-raw")
        defer { cleanup() }

        let socketURL = root.appendingPathComponent("ipc.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(40))

        // Codex-ish raw type field; no --wrap-source.
        let raw = Data(#"{"type":"session.started","session_id":"codex-42","title":"hi"}"#.utf8)
        let forwarder = FailOpenHookForwarder(options: HookForwarderOptions(connectTimeout: 2.0))
        let result = forwarder.forward(line: raw, socketPath: socketURL)
        #expect(result.succeeded)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }
        let envelope = try #require(received)
        #expect(envelope.sessionId == "codex-42")
        #expect(envelope.eventType == "session.started")
        // Must not land as soft EventEnvelope defaults.
        #expect(envelope.sessionId != "unknown")
        #expect(envelope.eventType != "unknown")

        await server.stop()
    }

    @Test func existingEnvelopePassthroughKeepsSession() async throws {
        let (root, cleanup) = try TestSupport.makeShortSocketRoot(prefix: "fwd-env")
        defer { cleanup() }

        let socketURL = root.appendingPathComponent("ipc.sock")
        let server = EventSocketServer(path: socketURL)
        let stream = try await server.start()
        try await Task.sleep(for: .milliseconds(40))

        let original = EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "keep-me",
            payload: ["title": .string("T")]
        )
        let line = try TestSupport.isoEncoder().encode(original)
        let forwarder = FailOpenHookForwarder(options: HookForwarderOptions(connectTimeout: 2.0))
        #expect(forwarder.forward(line: line, socketPath: socketURL).succeeded)

        var received: EventEnvelope?
        for await event in stream {
            received = event
            break
        }
        #expect(received?.sessionId == "keep-me")
        #expect(received?.eventType == "session.started")

        await server.stop()
    }

    @Test func stdinReaderReadsPipeUntilEOF() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer {
            close(readFD)
            // write may already be closed
        }

        let payload = Data("line-one\nline-two\n".utf8)
        let written = payload.withUnsafeBytes { ptr in
            Darwin.write(writeFD, ptr.baseAddress!, payload.count)
        }
        #expect(written == payload.count)
        close(writeFD)

        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
        let data = StdinReader.read(from: handle, maxBytes: 4096, timeout: 1.0)
        #expect(String(data: data, encoding: .utf8) == "line-one\nline-two\n")
    }

    @Test func stdinReaderRespectsMaxBytes() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer { close(readFD) }

        let payload = Data(repeating: UInt8(ascii: "a"), count: 200)
        _ = payload.withUnsafeBytes { ptr in
            Darwin.write(writeFD, ptr.baseAddress!, payload.count)
        }
        close(writeFD)

        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
        let data = StdinReader.read(from: handle, maxBytes: 50, timeout: 1.0)
        #expect(data.count == 50)
    }

    @Test func stdinReaderTimeoutOnOpenWriterReturnsPartialOrEmpty() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        // Writer left open without data → timeout should return without hanging.
        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
        let started = Date()
        let data = StdinReader.read(from: handle, maxBytes: 1024, timeout: 0.15)
        let elapsed = Date().timeIntervalSince(started)
        #expect(data.isEmpty)
        #expect(elapsed < 1.0)
    }
}
