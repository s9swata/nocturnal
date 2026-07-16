import Foundation
import Testing
@testable import NocturnalCore

struct EventDecodingTests {
    // MARK: - Codex

    @Test func codexSessionStartedFromFixture() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "codex/session-started.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        #expect(envelopes.count >= 1)

        let decoder = CodexEventDecoder()
        let started = decoder.decode(envelopes[0])
        #expect(started.isUnknown == false)
        #expect(started.state == .running)
        #expect(started.titleHint == "Wire SessionStore")
        #expect(started.workingDirectory == "/Users/demo/Projects/nocturnal")
    }

    @Test func codexApprovalRequiredFromFixture() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "codex/approval-required.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        let decoder = CodexEventDecoder()

        let required = decoder.decode(envelopes[0])
        #expect(required.isUnknown == false)
        #expect(required.state == .waitingForApproval)
        #expect(required.approval?.toolName == "shell")
        #expect(required.approval?.id == "apr-100")
        #expect(required.approval?.riskHint == .low)

        if envelopes.count > 1 {
            let resolved = decoder.decode(envelopes[1])
            #expect(resolved.clearApproval)
            #expect(resolved.state == .running)
        }
    }

    @Test func codexUnknownEventPreservesRawMetadata() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "codex/unknown-event.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        #expect(envelopes.count == 1)

        let decoder = CodexEventDecoder()
        let decoded = decoder.decode(envelopes[0])
        #expect(decoded.isUnknown)
        #expect(decoded.extraMetadata["unhandledEventType"] == .string("experimental.widget.ping"))
    }

    @Test func codexQuestionAndTerminalStates() {
        let decoder = CodexEventDecoder()

        let question = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "agent.question",
            sessionId: "q1",
            payload: [
                "prompt_id": .string("p1"),
                "prompt": .string("Which branch?"),
                "choices": .array([.string("main"), .string("dev")]),
            ]
        ))
        #expect(question.state == .waitingForInput)
        #expect(question.question?.id == "p1")
        #expect(question.question?.choices == ["main", "dev"])

        let completed = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.completed",
            sessionId: "q1"
        ))
        #expect(completed.state == .completed)

        let failed = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.failed",
            sessionId: "q1",
            payload: ["error": .string("boom")]
        ))
        #expect(failed.state == .failed)
        #expect(failed.summaryHint == "boom")

        let cancelled = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.cancelled",
            sessionId: "q1"
        ))
        #expect(cancelled.state == .cancelled)
    }

    // MARK: - Claude

    @Test func claudeSessionLifecycleFromFixture() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "claude/session-lifecycle.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        #expect(envelopes.count >= 4)

        let decoder = ClaudeEventDecoder()
        let start = decoder.decode(envelopes[0])
        #expect(start.state == .running)
        #expect(start.titleHint == "Docs pass")

        let freeTool = decoder.decode(envelopes[1])
        #expect(freeTool.state == .running)
        #expect(freeTool.approval == nil)

        let permissionTool = decoder.decode(envelopes[2])
        #expect(permissionTool.state == .waitingForApproval)
        #expect(permissionTool.approval?.toolName == "Bash")
        #expect(permissionTool.approval?.id == "tu-9")

        let stop = decoder.decode(envelopes[3])
        #expect(stop.state == .idle)
    }

    @Test func claudeNotificationFromFixture() throws {
        let lines = try TestSupport.fixtureLines(relativePath: "claude/notification.ndjson")
        let envelopes = try TestSupport.decodeEnvelopes(from: lines)
        let decoder = ClaudeEventDecoder()
        let decoded = decoder.decode(envelopes[0])
        #expect(decoded.isUnknown == false)
        #expect(decoded.state == nil) // summary-only
        #expect(decoded.summaryHint == "Claude needs your attention")
    }

    @Test(arguments: [
        (true, SessionState.waitingForApproval),
        (false, SessionState.running),
    ])
    func claudePreToolUsePermissionMatrix(requiresPermission: Bool, expected: SessionState) {
        let decoder = ClaudeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: "pre-1",
            payload: [
                "tool_name": .string("Bash"),
                "requires_permission": .bool(requiresPermission),
                "tool_use_id": .string("tu-1"),
            ]
        ))
        #expect(decoded.state == expected)
        if requiresPermission {
            #expect(decoded.approval != nil)
        } else {
            #expect(decoded.approval == nil)
        }
    }

    @Test func claudePermissionModeStringTriggersApproval() {
        let decoder = ClaudeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: "pre-2",
            payload: [
                "tool_name": .string("Write"),
                "permission_mode": .string("ask"),
            ]
        ))
        #expect(decoded.state == .waitingForApproval)
        #expect(decoded.approval?.toolName == "Write")
    }

    @Test(arguments: ["ask", "default", "prompt", "ASK", "Default"])
    func claudePermissionModesRequiringApproval(mode: String) {
        let decoder = ClaudeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: "pre-ask",
            payload: [
                "tool_name": .string("Bash"),
                "permission_mode": .string(mode),
            ]
        ))
        #expect(decoded.state == .waitingForApproval)
        #expect(decoded.approval != nil)
    }

    @Test(arguments: [
        "none", "off", "allow", "bypassPermissions", "bypass_permissions",
        "dontAsk", "acceptEdits", "ACCEPTEdits",
    ])
    func claudePermissionModesDoNotCreateFalseApproval(mode: String) {
        let decoder = ClaudeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: "pre-auto",
            payload: [
                "tool_name": .string("Bash"),
                "permission_mode": .string(mode),
            ]
        ))
        #expect(decoded.state == .running)
        #expect(decoded.approval == nil)
    }

    @Test func codexPidConversionIsRangeSafe() {
        let decoder = CodexEventDecoder()

        let ok = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "pid-ok",
            payload: ["pid": .number(12345), "title": .string("t")]
        ))
        #expect(ok.jumpBack?.processIdentifier == 12345)

        // Oversized / non-integral must not trap.
        let huge = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "pid-huge",
            payload: ["pid": .number(Double.greatestFiniteMagnitude), "title": .string("t")]
        ))
        #expect(huge.jumpBack?.processIdentifier == nil)

        let fractional = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "pid-frac",
            payload: ["process_id": .number(12.5), "title": .string("t")]
        ))
        #expect(fractional.jumpBack?.processIdentifier == nil)

        let negativeOverflow = decoder.decode(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "pid-neg",
            payload: ["pid": .number(-9_000_000_000), "title": .string("t")]
        ))
        #expect(negativeOverflow.jumpBack?.processIdentifier == nil)
    }

    // MARK: - Normalizer & composite

    @Test func envelopeNormalizerWrapsRawClaudeStdin() throws {
        let line = Data(#"{"hook_event_name":"SessionStart","session_id":"raw-1","cwd":"/tmp"}"#.utf8)
        let normalizer = EnvelopeNormalizer(defaultSource: .claude)
        let envelope = normalizer.normalize(line: line)
        let unwrapped = try #require(envelope)
        #expect(unwrapped.eventType == "SessionStart")
        #expect(unwrapped.sessionId == "raw-1")
        #expect(unwrapped.source == .claude)
        #expect(unwrapped.payload["cwd"] == .string("/tmp"))
    }

    @Test func compositeDecoderRoutesBySourceAndCountsUnknown() {
        let composite = CompositeEventDecoder()
        _ = composite.decode(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "a",
            payload: ["title": .string("A")]
        ))
        _ = composite.decode(EventEnvelope(
            source: .codex,
            eventType: "future.experimental",
            sessionId: "b",
            raw: ["k": .string("v")]
        ))
        let metrics = composite.currentMetrics()
        #expect(metrics.total == 2)
        #expect(metrics.unknown == 1)
        #expect(metrics.bySource["codex"] == 2)
    }

    @Test func metricsAttributeToInferredSourceWhenWireSourceUnknown() {
        let composite = CompositeEventDecoder()
        _ = composite.decode(EventEnvelope(
            source: .unknown,
            eventType: "session.started",
            sessionId: "inf-1",
            payload: ["title": .string("Inferred codex")]
        ))
        _ = composite.decode(EventEnvelope(
            source: .unknown,
            eventType: "SessionStart",
            sessionId: "inf-2",
            payload: ["title": .string("Inferred claude")]
        ))
        let metrics = composite.currentMetrics()
        #expect(metrics.total == 2)
        #expect(metrics.bySource["codex"] == 1)
        #expect(metrics.bySource["claude"] == 1)
        #expect(metrics.bySource["unknown"] == nil || metrics.bySource["unknown"] == 0)
    }

    @Test func normalizerRejectsSessionIdOnlyFastPath() throws {
        let line = Data(#"{"sessionId":"only-sid","cwd":"/tmp/project","hook_event_name":"SessionStart"}"#.utf8)
        let normalizer = EnvelopeNormalizer(defaultSource: .unknown)
        let envelope = normalizer.normalize(line: line)
        let unwrapped = try #require(envelope)
        // Must normalize upstream fields, not stop at incomplete envelope decode.
        #expect(unwrapped.eventType == "SessionStart")
        #expect(unwrapped.sessionId == "only-sid")
        #expect(unwrapped.payload["cwd"] == .string("/tmp/project")
            || unwrapped.raw["cwd"] == .string("/tmp/project"))
        #expect(unwrapped.source == .claude)
    }

    @Test func normalizerPreservesNumericEpochTimestamps() throws {
        let epoch: Double = 1_700_000_000
        let line = Data(#"{"v":1,"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","source":"codex","eventType":"session.started","sessionId":"epoch-1","timestamp":1700000000,"payload":{"title":"E"},"raw":{}}"#.utf8)
        let normalizer = EnvelopeNormalizer()
        let envelope = try #require(normalizer.normalize(line: line))
        #expect(abs(envelope.timestamp.timeIntervalSince1970 - epoch) < 1)

        // Milliseconds heuristic.
        let msLine = Data(#"{"hook_event_name":"SessionStart","session_id":"ms-1","timestamp":1700000000000}"#.utf8)
        let msEnv = try #require(normalizer.normalize(line: msLine))
        #expect(abs(msEnv.timestamp.timeIntervalSince1970 - epoch) < 1)
    }

    @Test func implementedEventTypeSetsAreNonEmpty() {
        #expect(CodexEventDecoder.implementedEventTypes.contains("session.started"))
        #expect(CodexEventDecoder.implementedEventTypes.contains("tool.approval_required"))
        #expect(ClaudeEventDecoder.implementedEventTypes.contains("SessionStart"))
        #expect(ClaudeEventDecoder.implementedEventTypes.contains("PreToolUse"))
    }

    @Test func codexNativeLifecycleFixtureMapsWithExplicitSource() throws {
        let lines = try TestSupport.fixtureLines(
            relativePath: "codex/native-lifecycle-0.144.1.ndjson"
        )
        let normalizer = EnvelopeNormalizer(defaultSource: .codex)
        let decoder = CodexEventDecoder()
        let events = try lines.map { line in
            try #require(normalizer.normalize(line: line))
        }
        #expect(events.map(\.eventType) == ["SessionStart", "PermissionRequest", "Stop"])
        #expect(events.allSatisfy { $0.source == .codex })

        let started = decoder.decode(events[0])
        #expect(started.state == .running)
        #expect(started.workingDirectory == "/tmp/nocturnal-project")

        let permission = decoder.decode(events[1])
        #expect(permission.state == .waitingForApproval)
        #expect(permission.approval?.id == "tool-42")
        #expect(permission.approval?.toolName == "shell")

        let stopped = decoder.decode(events[2])
        #expect(stopped.state == .idle)
    }
}
