import Foundation
import Testing
@testable import NocturnalCore

struct PermissionDecisionTests {
    @Test func translatorAllowDenyStdoutShapes() {
        let envelope = EventEnvelope(
            source: .codex,
            eventType: "PermissionRequest",
            sessionId: "s1",
            payload: ["tool_name": .string("Bash")]
        )
        let allow = HookDecisionTranslator.stdoutJSON(for: envelope, result: .allowed)
        #expect(allow.contains("PermissionRequest"))
        #expect(allow.contains("allow"))

        let deny = HookDecisionTranslator.stdoutJSON(
            for: envelope,
            result: .denied("nope")
        )
        #expect(deny.contains("deny"))
        #expect(deny.contains("nope"))

        let deferred = HookDecisionTranslator.stdoutJSON(for: envelope, result: .deferred)
        #expect(deferred == "{}")
    }

    @Test func stampAndDetectNeedsDecision() {
        let base = EventEnvelope(
            source: .codex,
            eventType: "PermissionRequest",
            sessionId: "s1",
            payload: ["tool_use_id": .string("tu-9"), "tool_name": .string("Bash")]
        )
        #expect(HookDecisionTranslator.shouldRequestDecision(
            eventType: base.eventType,
            source: base.source,
            payload: base.payload
        ))
        let stamped = HookDecisionTranslator.stampForDecision(base, timeoutSec: 90)
        #expect(HookDecisionTranslator.envelopeNeedsDecision(stamped))
        #expect(HookDecisionTranslator.decisionRequestId(for: stamped) == "tu-9")
        #expect(HookDecisionTranslator.timeoutSeconds(from: stamped) == 90)
    }

    @Test func brokerCompletesWaiter() async {
        let broker = PermissionBroker()
        async let waited = broker.wait(for: "req-1", timeoutSeconds: 5)
        // Give waiter a moment to register.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await broker.complete(approvalRequestId: "req-1", approved: true)
        let result = await waited
        #expect(result.behavior == .allow)
    }

    @Test func brokerTimeoutDefers() async {
        let broker = PermissionBroker()
        let result = await broker.wait(for: "never-completed", timeoutSeconds: 0.15)
        #expect(result.behavior == .defer)
    }

    @Test func endToEndDecisionOverSocket() async throws {
        // AF_UNIX path length is limited (~104 bytes on Darwin) — keep short.
        let sock = URL(fileURLWithPath: "/tmp/n-p-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: sock) }
        let broker = PermissionBroker()
        let server = EventSocketServer(path: sock, permissionBroker: broker)
        let stream = try await server.start()
        defer {
            Task { await server.stop() }
        }

        // Consumer: complete as soon as the decision request is seen.
        let consumer = Task {
            for await envelope in stream {
                let id = HookDecisionTranslator.decisionRequestId(for: envelope)
                await broker.complete(approvalRequestId: id, approved: true)
                break
            }
        }

        // Ensure accept loop is running before we connect.
        try? await Task.sleep(nanoseconds: 50_000_000)

        var envelope = EventEnvelope(
            source: .codex,
            eventType: "PermissionRequest",
            sessionId: "sess-dec",
            payload: [
                "tool_use_id": .string("tool-99"),
                "tool_name": .string("Bash"),
                "tool_input": .object(["command": .string("echo hi")]),
            ]
        )
        envelope = HookDecisionTranslator.stampForDecision(envelope, timeoutSec: 3)

        let client = EventSocketClient(path: sock, connectTimeout: 2)
        let reply = try client.sendAndReceiveDecision(envelope, receiveTimeout: 8)
        #expect(reply.behavior == .allow)
        #expect(reply.decisionRequestId == "tool-99")

        await consumer.value
        await server.stop()
    }

    @Test func forwarderDecisionStdoutWhenAppDenies() async throws {
        let sock = URL(fileURLWithPath: "/tmp/n-f-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: sock) }
        let broker = PermissionBroker()
        let server = EventSocketServer(path: sock, permissionBroker: broker)
        let stream = try await server.start()
        defer { Task { await server.stop() } }

        let consumer = Task {
            for await envelope in stream {
                let id = HookDecisionTranslator.decisionRequestId(for: envelope)
                await broker.complete(approvalRequestId: id, approved: false, message: "nope")
                break
            }
        }

        // Let accept loop spin up.
        try? await Task.sleep(nanoseconds: 40_000_000)

        let raw = #"""
        {"session_id":"s-fwd","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"tu-fwd","tool_input":{"command":"rm -rf /"}}
        """#.data(using: .utf8)!

        let forwarder = FailOpenHookForwarder(options: HookForwarderOptions(
            connectTimeout: 2,
            wrapSource: .codex,
            decisionTimeout: 10
        ))
        let outcome = forwarder.forwardWithDecision(line: raw, socketPath: sock)
        #expect(outcome.forward.succeeded)
        #expect(outcome.stdoutJSON.contains("deny"))

        await consumer.value
        await server.stop()
    }
}
