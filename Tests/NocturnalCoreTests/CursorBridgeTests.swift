import Foundation
import Testing
@testable import NocturnalCore

struct CursorBridgeTests {
    @Test func wrapSourceAndSetupAcceptCursor() throws {
        #expect(AgentSource(parsing: "cursor") == .cursor)
        let wrap = HookForwarderCLIOptions.parse(arguments: ["--wrap-source", "cursor"])
        #expect(wrap.wrapSource == .cursor)
        let setup = try SetupCLIOptions.parse(arguments: ["--product", "cursor"])
        #expect(setup.products == [.cursor])
    }

    @Test func installCursorHooksUnderTempRoot() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-cursor-hooks")
        defer { cleanup() }

        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "\(temp.path)/bin/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "\(temp.path)/ipc.sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )

        // Pre-seed a foreign Cursor hook to prove we merge, not clobber.
        let native = installer.nativeConfigURL(for: .cursor)
        try FileManager.default.createDirectory(
            at: native.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = """
        {
          "version": 1,
          "hooks": {
            "afterFileEdit": [
              { "command": "./hooks/format.sh" }
            ]
          }
        }
        """
        try foreign.write(to: native, atomically: true, encoding: .utf8)

        let result = try installer.install(product: .cursor)
        #expect(result.succeeded)
        #expect(result.nativeConfigPath?.contains(".cursor/hooks.json") == true)
        #expect(native.path.hasPrefix(temp.path))
        #expect(native.path.contains(NSHomeDirectory() + "/.cursor") == false)

        let body = try String(contentsOf: native, encoding: .utf8)
        #expect(body.contains("nocturnal-hook-forwarder"))
        #expect(body.contains("--wrap-source cursor"))
        #expect(body.contains("sessionStart"))
        #expect(body.contains("preToolUse"))
        #expect(body.contains("format.sh")) // foreign preserved

        let doctor = installer.doctor(product: .cursor)
        #expect(doctor.succeeded)

        let removed = try installer.uninstall(product: .cursor)
        #expect(removed.succeeded)
        let after = try String(contentsOf: native, encoding: .utf8)
        #expect(after.contains("format.sh"))
        #expect(after.contains("nocturnal-hook-forwarder") == false)
    }

    @Test func decoderMapsCursorHookLifecycle() {
        let decoder = CursorEventDecoder()
        let start = EventEnvelope(
            source: .cursor,
            eventType: "sessionStart",
            sessionId: "conv-1",
            payload: [
                "workspace_roots": .array([.string("/tmp/proj")]),
                "conversation_id": .string("conv-1"),
                "cursor_version": .string("1.7.2"),
            ],
            raw: [
                "workspace_roots": .array([.string("/tmp/proj")]),
                "hook_event_name": .string("sessionStart"),
            ]
        )
        let decoded = decoder.decode(start)
        #expect(!decoded.isUnknown)
        #expect(decoded.inferredSource == .cursor)
        #expect(decoded.state == .running)
        #expect(decoded.workingDirectory == "/tmp/proj")

        let tool = decoder.decode(
            EventEnvelope(
                source: .cursor,
                eventType: "preToolUse",
                sessionId: "conv-1",
                payload: [
                    "tool_name": .string("Shell"),
                    "tool_input": .object(["command": .string("ls")]),
                    "cwd": .string("/tmp/proj"),
                ]
            )
        )
        #expect(tool.state == .running)
        #expect(tool.approval == nil)
        #expect(tool.inferredSource == .cursor)
    }

    @Test func compositeRoutesCursorSource() {
        let composite = CompositeEventDecoder()
        let decoded = composite.decode(
            EventEnvelope(
                source: .cursor,
                eventType: "postToolUse",
                sessionId: "c1",
                payload: ["tool_name": .string("Write")]
            )
        )
        #expect(decoded.inferredSource == .cursor)
        #expect(!decoded.isUnknown)
    }

    @Test func normalizerWrapsCursorStdin() throws {
        let normalizer = EnvelopeNormalizer(defaultSource: .cursor)
        let line = """
        {"hook_event_name":"preToolUse","conversation_id":"abc","tool_name":"Shell","tool_input":{"command":"pwd"},"workspace_roots":["/tmp/x"],"cursor_version":"1.7.2"}
        """
        let env = try #require(normalizer.normalize(line: Data(line.utf8)))
        #expect(env.source == .cursor)
        #expect(env.sessionId == "abc")
    }

    @Test func storeBuildsLiveActivityFromCursorHooks() async throws {
        let store = SessionStore()
        let normalizer = EnvelopeNormalizer(defaultSource: .cursor)
        let lines = try TestSupport.fixtureLines(relativePath: "cursor/session-lifecycle.ndjson")
        #expect(!lines.isEmpty)

        for line in lines {
            guard let envelope = normalizer.normalize(line: line) else { continue }
            _ = await store.apply(envelope)
        }

        let sessions = await store.allSessions()
        let session = try #require(sessions.first)
        #expect(session.source == .cursor)
        #expect(session.id.rawValue.contains("conv-cursor") || !session.id.rawValue.isEmpty)
        #expect(
            session.stats.lastToolName != nil
                || session.stats.toolUseCount > 0
                || session.recentActivities.contains { $0.kind == .tool }
        )
    }

    @Test func activityMappingHandlesCursorPreToolUse() {
        var session = Session(
            id: SessionID("c-tool"),
            source: .cursor,
            state: .running,
            title: "Work",
            createdAt: Date(),
            updatedAt: Date()
        )
        let envelope = EventEnvelope(
            source: .cursor,
            eventType: "preToolUse",
            sessionId: "c-tool",
            payload: [
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "path": .string("/tmp/nocturnal/PillView.swift"),
                ]),
                "cwd": .string("/tmp/nocturnal"),
            ]
        )
        let decoded = CursorEventDecoder().decode(envelope)
        SessionActivityMapping.apply(
            to: &session,
            envelope: envelope,
            decoded: decoded,
            allowLifecycleMutation: true
        )
        #expect(session.stats.lastToolName == "Write")
        #expect(session.currentActivity?.kind == .tool)
        #expect(session.source == .cursor)
    }
}
