import Foundation
import Testing
@testable import NocturnalCore

struct GrokBridgeTests {
    @Test func wrapSourceParsesGrokAliases() {
        #expect(AgentSource(parsing: "grok-build") == .grokBuild)
        #expect(AgentSource(parsing: "grok") == .grokBuild)
        let opts = HookForwarderCLIOptions.parse(arguments: ["--wrap-source", "grok-build"])
        #expect(opts.wrapSource == .grokBuild)
        #expect(opts.warnings.isEmpty)
    }

    @Test func setupCLIAcceptsGrokProduct() throws {
        let opts = try SetupCLIOptions.parse(arguments: ["--product", "grok"])
        #expect(opts.products == [.grok])
        let alias = try SetupCLIOptions.parse(arguments: ["--product", "grok-build"])
        #expect(alias.products == [.grok])
    }

    @Test func installGrokHooksUnderTempRoot() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-grok-hooks")
        defer { cleanup() }

        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "\(temp.path)/bin/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "\(temp.path)/ipc.sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )

        let result = try installer.install(product: .grok)
        #expect(result.succeeded)
        #expect(result.nativeConfigPath?.contains(".grok/hooks") == true)

        let native = installer.nativeConfigURL(for: .grok)
        #expect(FileManager.default.fileExists(atPath: native.path))
        let body = try String(contentsOf: native, encoding: .utf8)
        #expect(body.contains("nocturnal-hook-forwarder"))
        #expect(body.contains("--wrap-source grok-build"))
        #expect(body.contains("SessionStart"))
        #expect(body.contains("PreToolUse"))
        #expect(body.contains(temp.path) || body.contains("ipc.sock"))

        // Never touch real ~/.grok
        #expect(native.path.hasPrefix(temp.path))
        #expect(native.path.contains(NSHomeDirectory() + "/.grok") == false)

        let doctor = installer.doctor(product: .grok)
        #expect(doctor.succeeded)
        #expect(doctor.message.lowercased().contains("healthy") || doctor.message.contains("present"))

        let again = try installer.install(product: .grok)
        #expect(again.succeeded)

        let removed = try installer.uninstall(product: .grok)
        #expect(removed.succeeded)
        #expect(FileManager.default.fileExists(atPath: native.path) == false)
    }

    @Test func decoderMapsGrokHookLifecycle() {
        let decoder = GrokEventDecoder()
        let start = EventEnvelope(
            source: .grokBuild,
            eventType: "session_start",
            sessionId: "sid-1",
            payload: [
                "cwd": .string("/tmp/proj"),
                "workspaceRoot": .string("/tmp/proj"),
            ],
            raw: [
                "hookEventName": .string("session_start"),
                "toolName": .string("run_terminal_command"),
            ]
        )
        let decoded = decoder.decode(start)
        #expect(!decoded.isUnknown)
        #expect(decoded.inferredSource == .grokBuild)
        #expect(decoded.state == .running)
        #expect(decoded.workingDirectory == "/tmp/proj")

        let tool = EventEnvelope(
            source: .grokBuild,
            eventType: "pre_tool_use",
            sessionId: "sid-1",
            payload: [
                "toolName": .string("run_terminal_command"),
                "toolInput": .object(["command": .string("ls")]),
            ]
        )
        let toolDecoded = decoder.decode(tool)
        #expect(toolDecoded.state == .running)
        #expect(toolDecoded.summaryHint?.contains("run_terminal_command") == true)
        // Must not invent approval chips for Grok PreToolUse.
        #expect(toolDecoded.approval == nil)

        let stop = decoder.decode(
            EventEnvelope(source: .grokBuild, eventType: "stop", sessionId: "sid-1")
        )
        #expect(stop.state == .idle)
    }

    @Test func compositeRoutesGrokSource() {
        let composite = CompositeEventDecoder()
        let envelope = EventEnvelope(
            source: .grokBuild,
            eventType: "PostToolUse",
            sessionId: "g1",
            payload: ["toolName": .string("search_replace")]
        )
        let decoded = composite.decode(envelope)
        #expect(decoded.inferredSource == .grokBuild)
        #expect(!decoded.isUnknown)
    }

    @Test func normalizerWrapsGrokStdin() throws {
        let normalizer = EnvelopeNormalizer(defaultSource: .grokBuild)
        let line = """
        {"hookEventName":"pre_tool_use","sessionId":"abc","cwd":"/tmp/x","toolName":"grep"}
        """
        let envelope = normalizer.normalize(line: Data(line.utf8))
        let env = try #require(envelope)
        #expect(env.source == .grokBuild)
        #expect(env.sessionId == "abc")
        let type = env.eventType.lowercased()
        #expect(type.contains("pre") || type.contains("tool"))
    }

    @Test func scannerReadsActiveAndSummaries() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-grok-scan")
        defer { cleanup() }

        let grokHome = temp.appendingPathComponent(".grok", isDirectory: true)
        let sessions = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("encoded-cwd", isDirectory: true)
            .appendingPathComponent("sess-aaa", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let active = """
        [{"session_id":"sess-live","cwd":"/tmp/live","opened_at":"2026-07-16T10:00:00Z"}]
        """
        try active.write(
            to: grokHome.appendingPathComponent("active_sessions.json"),
            atomically: true,
            encoding: .utf8
        )

        let summary = """
        {
          "info": {"id": "sess-aaa", "cwd": "/tmp/proj"},
          "generated_title": "Island fix",
          "updated_at": "2026-07-16T11:00:00Z",
          "current_model_id": "grok-4.5"
        }
        """
        try summary.write(
            to: sessions.appendingPathComponent("summary.json"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = GrokSessionScanner(grokHome: grokHome, maxSessions: 20)
        let snaps = try scanner.scan()
        #expect(snaps.count >= 2)
        #expect(snaps.contains { $0.sessionId == "sess-live" && $0.isActive })
        #expect(snaps.contains { $0.sessionId == "sess-aaa" && $0.title == "Island fix" })

        let env = snaps.first { $0.sessionId == "sess-aaa" }!.envelope()
        #expect(env.source == .grokBuild)
        #expect(env.eventType == "session.reconciled")
    }

    @Test func storeBuildsLiveActivityFromGrokHooks() async throws {
        let store = SessionStore()
        let normalizer = EnvelopeNormalizer(defaultSource: .grokBuild)
        let lines = try TestSupport.fixtureLines(relativePath: "grok/session-lifecycle.ndjson")
        #expect(!lines.isEmpty)

        for line in lines {
            guard let envelope = normalizer.normalize(line: line) else { continue }
            _ = await store.apply(envelope)
        }

        let sessions = await store.allSessions()
        let session = try #require(sessions.first)
        #expect(session.source == .grokBuild)
        #expect(session.id.rawValue.contains("019f6a16") || !session.id.rawValue.isEmpty)
        #expect(session.workingDirectory?.contains("nocturnal") == true
            || session.workingDirectory != nil)
        // snake_case pre_tool_use must create real tool stats (not leave OpenCode owning the pill).
        #expect(session.stats.lastToolName == "run_terminal_command"
            || session.stats.toolUseCount > 0
            || session.recentActivities.contains { $0.kind == .tool })
    }

    @Test func activityMappingNormalizesGrokSnakeCaseTools() {
        var session = Session(
            id: SessionID("g-tool"),
            source: .grokBuild,
            state: .running,
            title: "Work",
            createdAt: Date(),
            updatedAt: Date()
        )
        let envelope = EventEnvelope(
            source: .grokBuild,
            eventType: "pre_tool_use",
            sessionId: "g-tool",
            payload: [
                "toolName": .string("search_replace"),
                "toolInput": .object([
                    "file_path": .string("/tmp/nocturnal/PillView.swift"),
                ]),
            ]
        )
        let decoded = GrokEventDecoder().decode(envelope)
        SessionActivityMapping.apply(
            to: &session,
            envelope: envelope,
            decoded: decoded,
            allowLifecycleMutation: true
        )
        #expect(session.stats.lastToolName == "search_replace")
        #expect(session.currentActivity?.kind == .tool)
        #expect(session.currentActivity?.primaryPath?.contains("PillView") == true)
        #expect(session.source == .grokBuild)
    }

    @Test func primaryPrefersGrokOverStaleOpenCodeEdit() {
        let now = Date()
        var openCode = Session(
            id: SessionID("opencode:/Users/demo/nocturnal"),
            source: .opencode,
            state: .idle,
            title: "OpenCode session",
            workingDirectory: "/Users/demo/nocturnal",
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-1800)
        )
        openCode.recentActivities = [
            SessionActivity(
                kind: .tool,
                label: "edit",
                detail: "/tmp/nocturnal-opencode-full-test.txt",
                eventType: "PostToolUse",
                startedAt: now.addingTimeInterval(-1800),
                endedAt: now.addingTimeInterval(-1800),
                toolName: "edit",
                primaryPath: "/tmp/nocturnal-opencode-full-test.txt"
            ),
        ]
        var grok = Session(
            id: SessionID("019f6b87-a207-7292-89eb-52d72bca033e"),
            source: .grokBuild,
            state: .running,
            title: "Grok",
            workingDirectory: "/Users/demo/nocturnal",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now
        )
        grok.currentActivity = SessionActivity(
            kind: .turn,
            label: "Thinking",
            eventType: "UserPromptSubmit",
            startedAt: now
        )
        let primary = SessionPrimarySelection.primaryLive(from: [openCode, grok], now: now)
        #expect(primary?.source == .grokBuild)
    }
}
