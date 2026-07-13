import Foundation

/// Maps wire envelopes into structured session mutations.
public protocol EventDecoding: Sendable {
    func decode(_ envelope: EventEnvelope) -> DecodedEvent
}

/// Optional decode metrics (unknown counts). Safe to ignore for UI.
public struct EventDecodeMetrics: Sendable, Equatable {
    public var total: UInt64
    public var unknown: UInt64
    public var bySource: [String: UInt64]

    public init(total: UInt64 = 0, unknown: UInt64 = 0, bySource: [String: UInt64] = [:]) {
        self.total = total
        self.unknown = unknown
        self.bySource = bySource
    }
}

/// Routes by ``AgentSource`` then falls back to passthrough unknown handling.
///
/// Thread-safe metrics via internal lock (decoders themselves are pure).
public final class CompositeEventDecoder: EventDecoding, @unchecked Sendable {
    private let codex: CodexEventDecoder
    private let claude: ClaudeEventDecoder
    private let demo: DemoEventDecoder
    private let lock = NSLock()
    private var metrics = EventDecodeMetrics()

    public init(
        codex: CodexEventDecoder = CodexEventDecoder(),
        claude: ClaudeEventDecoder = ClaudeEventDecoder(),
        demo: DemoEventDecoder = DemoEventDecoder()
    ) {
        self.codex = codex
        self.claude = claude
        self.demo = demo
    }

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let result: DecodedEvent
        switch envelope.source {
        case .codex:
            result = codex.decode(envelope)
        case .claude:
            result = claude.decode(envelope)
        case .demo:
            result = demo.decode(envelope)
        case .unknown:
            // Try both; prefer first non-unknown structured decode.
            let codexResult = codex.decode(envelope)
            if !codexResult.isUnknown {
                result = codexResult
            } else {
                let claudeResult = claude.decode(envelope)
                if !claudeResult.isUnknown {
                    result = claudeResult
                } else {
                    result = Self.unknownPassthrough(envelope)
                }
            }
        }
        record(result, source: envelope.source)
        return result
    }

    public func currentMetrics() -> EventDecodeMetrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    public func resetMetrics() {
        lock.lock()
        metrics = EventDecodeMetrics()
        lock.unlock()
    }

    public static func unknownPassthrough(_ envelope: EventEnvelope) -> DecodedEvent {
        DecodedEvent(
            inferredSource: envelope.source,
            summaryHint: "Unhandled event: \(envelope.eventType)",
            extraMetadata: [
                "unhandledEventType": .string(envelope.eventType),
                "envelopeId": .string(envelope.id.uuidString),
            ],
            isUnknown: true
        )
    }

    private func record(_ result: DecodedEvent, source: AgentSource) {
        lock.lock()
        metrics.total &+= 1
        if result.isUnknown {
            metrics.unknown &+= 1
        }
        let key = source.rawValue
        metrics.bySource[key, default: 0] &+= 1
        lock.unlock()
    }
}

/// Shared helpers for source-specific decoders.
public enum EventDecodeHelpers {
    public static func string(_ payload: [String: JSONValue], _ keys: String...) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public static func nestedString(_ payload: [String: JSONValue], _ keys: String...) -> String? {
        var current: JSONValue? = .object(payload)
        for key in keys {
            guard case .object(let obj)? = current else { return nil }
            current = obj[key]
        }
        return current?.stringValue
    }

    public static func bool(_ payload: [String: JSONValue], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = payload[key]?.boolValue {
                return value
            }
        }
        return nil
    }

    public static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }
}

// MARK: - Raw stdin → EventEnvelope normalization

/// Wraps non-envelope JSON (Claude/Codex raw hook stdin) into ``EventEnvelope``.
///
/// When input already looks like an envelope (`eventType`/`sessionId` present), it
/// is decoded as-is. Otherwise fields are inferred best-effort and the full object
/// is preserved under `raw`.
public struct EnvelopeNormalizer: Sendable {
    public var defaultSource: AgentSource
    public var defaultSessionId: String?

    public init(defaultSource: AgentSource = .unknown, defaultSessionId: String? = nil) {
        self.defaultSource = defaultSource
        self.defaultSessionId = defaultSessionId
    }

    /// Normalize one JSON line into an envelope. Returns nil only for empty input.
    public func normalize(line: Data) -> EventEnvelope? {
        let trimmed = line.trimmingCRLFPublic
        guard !trimmed.isEmpty else { return nil }

        // Fast path: already an EventEnvelope.
        if let envelope = try? makeDecoder().decode(EventEnvelope.self, from: trimmed),
           !envelope.eventType.isEmpty,
           envelope.eventType != "unknown" || envelope.sessionId != "unknown"
        {
            // If decode succeeded with real fields, use it.
            if envelope.sessionId != "unknown" || envelope.payload.isEmpty == false || !envelope.raw.isEmpty {
                return envelope
            }
        }

        let root: JSONValue
        do {
            root = try JSONValue.parse(data: trimmed)
        } catch {
            // Not JSON — wrap as opaque string payload so store still gets a line.
            return EventEnvelope(
                source: defaultSource,
                eventType: "raw.unparsed",
                sessionId: defaultSessionId ?? "unknown",
                payload: ["text": .string(String(data: trimmed, encoding: .utf8) ?? "")],
                raw: ["parseError": .string(String(describing: error))],
                sourceRaw: defaultSource == .unknown ? nil : nil
            )
        }

        let object = root.asObject

        // Detect envelope-shaped objects that failed UUID/date decode.
        if object["eventType"] != nil || object["event_type"] != nil {
            return envelopeFromPartial(object, original: root)
        }

        return envelopeFromUpstreamHook(object, original: root)
    }

    private func envelopeFromPartial(_ object: [String: JSONValue], original: JSONValue) -> EventEnvelope {
        let eventType = EventDecodeHelpers.string(object, "eventType", "event_type") ?? "unknown"
        let sessionId = EventDecodeHelpers.string(object, "sessionId", "session_id")
            ?? defaultSessionId
            ?? "unknown"
        let sourceRaw = EventDecodeHelpers.string(object, "source")
        let source = sourceRaw.map { AgentSource(parsing: $0) } ?? defaultSource
        let payload = object["payload"]?.objectValue ?? object
        let raw = object["raw"]?.objectValue ?? original.asObject
        let timestamp = parseTimestamp(object["timestamp"]) ?? Date()
        let id = parseUUID(object["id"]) ?? UUID()

        return EventEnvelope(
            id: id,
            schemaVersion: Int(object["v"]?.numberValue ?? Double(EventEnvelope.currentSchemaVersion)),
            source: source,
            eventType: eventType,
            sessionId: sessionId,
            timestamp: timestamp,
            payload: payload,
            raw: raw,
            sourceRaw: source == .unknown ? sourceRaw : nil
        )
    }

    private func envelopeFromUpstreamHook(_ object: [String: JSONValue], original: JSONValue) -> EventEnvelope {
        // Claude Code common fields: hook_event_name, session_id, cwd, tool_name, …
        // Codex-ish: type / event / session_id
        let eventType = EventDecodeHelpers.string(
            object,
            "hook_event_name",
            "hookEventName",
            "event_type",
            "eventType",
            "type",
            "event"
        ) ?? "unknown"

        let sessionId = EventDecodeHelpers.string(
            object,
            "session_id",
            "sessionId",
            "conversation_id",
            "thread_id"
        ) ?? defaultSessionId ?? UUID().uuidString

        let inferredSource: AgentSource = {
            if defaultSource != .unknown { return defaultSource }
            if object["hook_event_name"] != nil || object["hookEventName"] != nil {
                return .claude
            }
            if ClaudeEventDecoder.implementedEventTypes.contains(eventType) {
                return .claude
            }
            if CodexEventDecoder.implementedEventTypes.contains(eventType) {
                return .codex
            }
            return .unknown
        }()

        return EventEnvelope(
            source: inferredSource,
            eventType: eventType,
            sessionId: sessionId,
            timestamp: parseTimestamp(object["timestamp"])
                ?? parseTimestamp(object["time"])
                ?? Date(),
            payload: object,
            raw: original.asObject,
            sourceRaw: inferredSource == .unknown ? EventDecodeHelpers.string(object, "source") : nil
        )
    }

    private func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if case .number(let n) = value {
            // Heuristic: ms vs s
            if n > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: n / 1000)
            }
            return Date(timeIntervalSince1970: n)
        }
        if let s = value.stringValue {
            return EventEnvelopeDateParsing.parse(s)
        }
        return nil
    }

    private func parseUUID(_ value: JSONValue?) -> UUID? {
        guard let s = value?.stringValue else { return nil }
        return UUID(uuidString: s)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Data {
    /// Shared CRLF trim used by normalizer and forwarder.
    var trimmingCRLFPublic: Data {
        var data = self
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        // Trim leading whitespace/newlines
        while let first = data.first, first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09 {
            data.removeFirst()
        }
        return data
    }
}
