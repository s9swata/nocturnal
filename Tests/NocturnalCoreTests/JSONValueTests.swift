import Foundation
import Testing
@testable import NocturnalCore

struct JSONValueTests {
    @Test func envelopeRoundTrip() throws {
        let envelope = EventEnvelope(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
            source: .codex,
            eventType: "session.started",
            sessionId: "abc",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            payload: [
                "title": .string("T"),
                "count": .number(2),
                "ok": .bool(true),
                "nested": .object(["k": .string("v")]),
            ],
            raw: ["x": .null]
        )

        let data = try TestSupport.isoEncoder().encode(envelope)
        let decoded = try TestSupport.isoDecoder().decode(EventEnvelope.self, from: data)

        #expect(decoded.sessionId == "abc")
        #expect(decoded.payload["title"] == .string("T"))
        #expect(decoded.payload["ok"] == .bool(true))
        #expect(decoded.raw["x"] == .null)
        #expect(decoded.schemaVersion == EventEnvelope.currentSchemaVersion)
        #expect(decoded.eventType == "session.started")
        #expect(decoded.source == .codex)
    }

    @Test func failOpenForwarderEmptyLine() {
        let forwarder = FailOpenHookForwarder()
        let result = forwarder.forward(
            line: Data(),
            socketPath: URL(fileURLWithPath: "/tmp/definitely-missing-nocturnal.sock")
        )
        #expect(result.succeeded)
    }

    @Test func failOpenWhenSocketMissing() {
        let forwarder = FailOpenHookForwarder()
        let line = Data(#"{"v":1,"eventType":"x"}"#.utf8)
        let result = forwarder.forward(
            line: line,
            socketPath: URL(fileURLWithPath: "/tmp/definitely-missing-nocturnal.sock")
        )
        #expect(result.succeeded == false)
        #expect(result.detail.contains("socket") || result.detail.lowercased().contains("connect"))
    }
}
