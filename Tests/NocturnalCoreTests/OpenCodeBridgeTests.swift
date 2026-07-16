import Foundation
import Testing
@testable import NocturnalCore

struct OpenCodeBridgeTests {
    @Test func agentSourceParsesOpenCodeAliases() {
        #expect(AgentSource(parsing: "opencode") == .opencode)
        #expect(AgentSource(parsing: "OpenCode") == .opencode)
        #expect(AgentSource(parsing: "open-code") == .opencode)
        #expect(AgentSource.opencode.displayName == "OpenCode")
    }

    @Test func mapsNativeBusNamesToLifecycle() {
        #expect(OpenCodeEventDecoder.mapEventType("session.created") == "SessionStart")
        #expect(OpenCodeEventDecoder.mapEventType("session.idle") == "Stop")
        #expect(OpenCodeEventDecoder.mapEventType("session.error") == "session.failed")
        #expect(OpenCodeEventDecoder.mapEventType("tool.execute.before") == "PreToolUse")
        #expect(OpenCodeEventDecoder.mapEventType("tool.execute.after") == "PostToolUse")
        #expect(OpenCodeEventDecoder.mapEventType("permission.asked") == "PermissionRequest")
        #expect(OpenCodeEventDecoder.mapEventType("PreToolUse") == "PreToolUse")
    }

    @Test func decodesStrategyALifecycleFixture() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "opencode/session-lifecycle.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        #expect(envelopes.count == 5)

        let decoder = OpenCodeEventDecoder()
        let started = decoder.decode(envelopes[0])
        #expect(started.isUnknown == false)
        #expect(started.inferredSource == .opencode)
        #expect(started.state == .running)
        #expect(started.titleHint == "Refactor auth")
        #expect(started.workingDirectory == "/Users/demo/Projects/app")

        let pre = decoder.decode(envelopes[1])
        #expect(pre.state == .running)
        #expect(pre.isUnknown == false)

        let idle = decoder.decode(envelopes[4])
        #expect(idle.state == .idle)
    }

    @Test func decodesNativeBusEventNames() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "opencode/native-bus-events.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        let decoder = OpenCodeEventDecoder()

        let created = decoder.decode(envelopes[0])
        #expect(created.state == .running)
        #expect(created.inferredSource == .opencode)

        let tool = decoder.decode(envelopes[1])
        #expect(tool.state == .running)
        #expect(tool.isUnknown == false)

        let idle = decoder.decode(envelopes[2])
        #expect(idle.state == .idle)
    }

    @Test func compositeRoutesOpenCodeSource() {
        let decoder = CompositeEventDecoder()
        let envelope = EventEnvelope(
            source: .opencode,
            eventType: "PreToolUse",
            sessionId: "s1",
            payload: [
                "tool_name": .string("bash"),
                "command": .string("ls"),
            ]
        )
        let decoded = decoder.decode(envelope)
        #expect(decoded.inferredSource == .opencode)
        #expect(decoded.isUnknown == false)
        #expect(decoded.state == .running)
    }

    @Test func storeBuildsLiveActivityLikeCodex() async throws {
        let lines = try TestSupport.fixtureLines(relativePath: "opencode/session-lifecycle.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        let store = SessionStore()

        for envelope in envelopes {
            _ = await store.apply(envelope)
        }

        let session = try #require(await store.session(id: SessionID("oc-sess-1")))
        #expect(session.source == .opencode)
        #expect(session.state == .idle)
        #expect(session.title == "Refactor auth")
        #expect(session.workingDirectory == "/Users/demo/Projects/app")
        #expect(session.stats.toolUseCount >= 2)
        #expect(session.stats.lastToolName == "read" || session.stats.lastCommand != nil)
        // PreToolUse bash + read should leave humanized recent activity.
        #expect(!session.recentActivities.isEmpty || session.currentActivity != nil)
    }

    @Test func toolPayloadExtractsOpenCodeArgs() {
        let extracted = ToolPayloadExtraction.extract(from: [
            "tool": .string("bash"),
            "args": .object([
                "command": .string("git status"),
            ]),
        ])
        #expect(extracted.toolName == "bash")
        #expect(extracted.command == "git status")
        #expect(extracted.integration == .shell || extracted.integration == .git)

        let read = ToolPayloadExtraction.extract(from: [
            "tool": .string("read"),
            "args": .object([
                "filePath": .string("/tmp/a.swift"),
            ]),
        ])
        #expect(read.path == "/tmp/a.swift")
        #expect(read.integration == .read)
    }

    @Test func installOpenCodePluginUnderTempRoot() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-opencode")
        defer { cleanup() }

        let socket = temp.appendingPathComponent("ipc.sock")
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: socket,
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true),
            mode: .sidecar
        )

        let installed = try installer.install(product: .opencode)
        #expect(installed.succeeded)
        #expect(FileManager.default.fileExists(atPath: installer.configURL(for: .opencode).path))

        let pluginURL = installer.nativeConfigURL(for: .opencode)
        #expect(pluginURL.path.hasPrefix(temp.path))
        #expect(pluginURL.path.contains(".config/opencode/plugins"))
        #expect(FileManager.default.fileExists(atPath: pluginURL.path))

        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)
        #expect(plugin.contains(HookInstaller.openCodePluginMarker))
        #expect(plugin.contains(socket.path))
        #expect(plugin.contains("PreToolUse"))
        #expect(plugin.contains("fail-open") || plugin.contains("fail open") || plugin.contains("Fail-open"))

        let doctor = installer.doctor(product: .opencode)
        #expect(doctor.succeeded)
        #expect(doctor.message.contains("plugin") || doctor.message.contains("healthy") || doctor.message.contains("present"))

        let again = try installer.install(product: .opencode)
        #expect(again.succeeded)
        #expect(
            again.message.lowercased().contains("idempotent")
                || again.message.lowercased().contains("already")
                || again.message.lowercased().contains("healthy")
        )

        let removed = try installer.uninstall(product: .opencode)
        #expect(removed.succeeded)
        #expect(FileManager.default.fileExists(atPath: pluginURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: installer.configURL(for: .opencode).path) == false)
    }

    @Test func setupCLIAcceptsOpenCodeProduct() throws {
        let options = try SetupCLIOptions.parse(arguments: [
            "install",
            "--product", "opencode",
        ])
        #expect(options.products == [.opencode])
    }

    @Test func forwarderCLIAcceptsOpenCodeWrapSource() {
        let parsed = HookForwarderCLIOptions.parse(arguments: [
            "--wrap-source", "opencode",
        ])
        #expect(parsed.wrapSource == .opencode)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func normalizePayloadFlattensArgs() {
        let payload = OpenCodeEventDecoder.normalizePayload([
            "tool": .string("webfetch"),
            "args": .object([
                "url": .string("https://example.com"),
            ]),
        ])
        #expect(payload["tool_name"]?.stringValue == "webfetch" || payload["tool"]?.stringValue == "webfetch")
        #expect(payload["detail"]?.stringValue == "https://example.com")
        #expect(payload["tool_input"] != nil)
    }
}
