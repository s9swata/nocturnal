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
            raw: ["x": .null],
            sourceRaw: nil
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

    @Test func sourceRawSurvivesEncodeDecodeHops() throws {
        let original = EventEnvelope(
            source: .unknown,
            eventType: "custom.ping",
            sessionId: "sr-1",
            payload: [:],
            raw: [:],
            sourceRaw: "nocturnal-experimental"
        )
        let data = try TestSupport.isoEncoder().encode(original)
        let once = try TestSupport.isoDecoder().decode(EventEnvelope.self, from: data)
        #expect(once.sourceRaw == "nocturnal-experimental")
        #expect(once.source == .unknown)

        let data2 = try TestSupport.isoEncoder().encode(once)
        let twice = try TestSupport.isoDecoder().decode(EventEnvelope.self, from: data2)
        #expect(twice.sourceRaw == "nocturnal-experimental")

        // Explicit sourceRaw alongside known source also preserved.
        let withBoth = EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "sr-2",
            sourceRaw: "codex-fork"
        )
        let data3 = try TestSupport.isoEncoder().encode(withBoth)
        let decodedBoth = try TestSupport.isoDecoder().decode(EventEnvelope.self, from: data3)
        #expect(decodedBoth.source == .codex)
        #expect(decodedBoth.sourceRaw == "codex-fork")
    }

    @Test func stringValueUsesExactIntegerConversion() {
        #expect(JSONValue.number(42).stringValue == "42")
        #expect(JSONValue.number(42.5).stringValue == "42.5")
        #expect(JSONValue.number(Double.nan).stringValue == nil)
        #expect(JSONValue.number(Double.infinity).stringValue == nil)
        // Exact Int32-range integer.
        #expect(JSONValue.number(2_147_483_647).exactInt32Value == Int32.max)
        // Outside Int32 — no trap; exactInt32 nil.
        #expect(JSONValue.number(3_000_000_000).exactInt32Value == nil)
        #expect(JSONValue.number(3_000_000_000).exactIntValue != nil)
        #expect(JSONValue.number(12.0).exactIntValue == 12)
        #expect(JSONValue.number(12.1).exactIntValue == nil)
    }

    @Test func exactIntegerStringReturnsNilOutsideInt64() {
        // Magnitudes beyond Int64 (and non-exact Double→Int64) must return nil —
        // never the old `String(format: "%.0f")` fallback.
        #expect(JSONValue.exactIntegerString(1e20) == nil)
        #expect(JSONValue.exactIntegerString(Double(Int64.max) * 4) == nil)
        // Int64.max is not exactly representable in Double → nil (not a false string).
        #expect(JSONValue.exactIntegerString(Double(Int64.max)) == nil)
        #expect(JSONValue.exactIntegerString(Double.nan) == nil)
        #expect(JSONValue.exactIntegerString(1.5) == nil)
        #expect(JSONValue.exactIntegerString(42) == "42")
        // Largest integer exactly representable in Double (2^53 − 1) is in Int64 range.
        let maxExactDoubleInt = 9_007_199_254_740_991.0 // 2^53 - 1
        #expect(JSONValue.exactIntegerString(maxExactDoubleInt) == "9007199254740991")
    }

    @Test func epochBoundaryOneE12IsMilliseconds() throws {
        let boundary = 1_000_000_000_000.0
        let date = try #require(EventEnvelopeDateParsing.parseEpoch(boundary))
        #expect(abs(date.timeIntervalSince1970 - 1_000_000_000) < 0.001)

        // Just below threshold remains seconds.
        let seconds = try #require(EventEnvelopeDateParsing.parseEpoch(boundary - 1))
        #expect(abs(seconds.timeIntervalSince1970 - (boundary - 1)) < 0.001)
    }

    @Test func envelopeSchemaVersionFallsBackOnMalformedOrOversizedV() throws {
        let oversized = Data(
            #"{"v":1e300,"id":"00000000-0000-4000-8000-000000000001","source":"codex","eventType":"session.started","sessionId":"v1","timestamp":"2023-11-14T22:13:20Z","payload":{},"raw":{}}"#.utf8
        )
        let fractional = Data(
            #"{"v":1.5,"id":"00000000-0000-4000-8000-000000000002","source":"codex","eventType":"session.started","sessionId":"v2","timestamp":"2023-11-14T22:13:20Z","payload":{},"raw":{}}"#.utf8
        )
        let normalizer = EnvelopeNormalizer(defaultSource: .codex)
        let fromOversized = try #require(normalizer.normalize(line: oversized))
        #expect(fromOversized.schemaVersion == EventEnvelope.currentSchemaVersion)

        let fromFractional = try #require(normalizer.normalize(line: fractional))
        #expect(fromFractional.schemaVersion == EventEnvelope.currentSchemaVersion)

        let decodedOversized = try TestSupport.isoDecoder().decode(EventEnvelope.self, from: oversized)
        #expect(decodedOversized.schemaVersion == EventEnvelope.currentSchemaVersion)
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
