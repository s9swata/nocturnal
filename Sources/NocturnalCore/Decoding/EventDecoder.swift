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
    private let lock = NSLock()
    private var metrics = EventDecodeMetrics()

    public init(
        codex: CodexEventDecoder = CodexEventDecoder(),
        claude: ClaudeEventDecoder = ClaudeEventDecoder()
    ) {
        self.codex = codex
        self.claude = claude
    }

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let result: DecodedEvent
        switch envelope.source {
        case .codex:
            result = codex.decode(envelope)
        case .claude:
            result = claude.decode(envelope)
        case .unknown:
            // Try both; prefer first non-unknown structured decode.
            // Unrecognized source strings (including obsolete labels) land here.
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
        // Attribute metrics to the resolved/inferred source, not only the wire label.
        let metricSource: AgentSource = {
            if result.inferredSource != .unknown { return result.inferredSource }
            if envelope.source != .unknown { return envelope.source }
            return .unknown
        }()
        record(result, source: metricSource)
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
/// When input already looks like a **complete** envelope (`eventType` + `sessionId`
/// present with real values), it is decoded as-is. Incomplete shapes such as
/// sessionId-only objects are **rejected** from the fast path so upstream fields
/// are normalized through the full object path.
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

        // Fast path: already a complete EventEnvelope (not sessionId-only stubs).
        if let envelope = try? makeDecoder().decode(EventEnvelope.self, from: trimmed),
           Self.isCompleteEnvelope(envelope)
        {
            return envelope
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
                sourceRaw: nil
            )
        }

        let object = root.asObject

        // Detect envelope-shaped objects that failed UUID/date decode or failed the
        // completeness check (e.g. sessionId-only stubs).
        if object["eventType"] != nil || object["event_type"] != nil
            || object["sessionId"] != nil || object["session_id"] != nil
        {
            // Prefer partial envelope reconstruction when event type keys exist;
            // sessionId-only still goes through upstream hook normalization so
            // raw fields (cwd, hook_event_name, …) land in payload.
            if object["eventType"] != nil || object["event_type"] != nil {
                return envelopeFromPartial(object, original: root)
            }
            return envelopeFromUpstreamHook(object, original: root)
        }

        return envelopeFromUpstreamHook(object, original: root)
    }

    /// A fast-path envelope must carry a real event type (not the decode default
    /// `"unknown"`) and a real session id. SessionId-only stubs are incomplete.
    public static func isCompleteEnvelope(_ envelope: EventEnvelope) -> Bool {
        guard !envelope.eventType.isEmpty, envelope.eventType != "unknown" else {
            return false
        }
        guard !envelope.sessionId.isEmpty, envelope.sessionId != "unknown" else {
            return false
        }
        return true
    }

    private func envelopeFromPartial(_ object: [String: JSONValue], original: JSONValue) -> EventEnvelope {
        let eventType = EventDecodeHelpers.string(object, "eventType", "event_type") ?? "unknown"
        let sessionId = EventDecodeHelpers.string(object, "sessionId", "session_id")
            ?? defaultSessionId
            ?? "unknown"
        let sourceRaw = EventDecodeHelpers.string(object, "sourceRaw")
            ?? EventDecodeHelpers.string(object, "source")
        let source: AgentSource = {
            if let raw = EventDecodeHelpers.string(object, "source") {
                return AgentSource(parsing: raw)
            }
            return defaultSource
        }()
        let payload = object["payload"]?.objectValue ?? [:]
        // When payload key is absent, keep structured fields out of a fake payload
        // only if this is a true envelope shape; otherwise use full object.
        let resolvedPayload: [String: JSONValue] = {
            if object["payload"] != nil {
                return payload
            }
            // Envelope-like without payload key: remaining keys become payload-ish raw.
            return object
        }()
        let raw = object["raw"]?.objectValue ?? original.asObject
        let timestamp = parseTimestamp(object["timestamp"]) ?? Date()
        let id = parseUUID(object["id"]) ?? UUID()
        let schema: Int = {
            if let exact = object["v"]?.exactIntValue { return exact }
            if let n = object["v"]?.numberValue { return Int(n) }
            return EventEnvelope.currentSchemaVersion
        }()

        return EventEnvelope(
            id: id,
            schemaVersion: schema,
            source: source,
            eventType: eventType,
            sessionId: sessionId,
            timestamp: timestamp,
            payload: resolvedPayload,
            raw: raw,
            sourceRaw: source == .unknown ? sourceRaw : (object["sourceRaw"] != nil ? sourceRaw : nil)
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

        let sourceRaw = EventDecodeHelpers.string(object, "sourceRaw")
            ?? EventDecodeHelpers.string(object, "source")

        return EventEnvelope(
            source: inferredSource,
            eventType: eventType,
            sessionId: sessionId,
            timestamp: parseTimestamp(object["timestamp"])
                ?? parseTimestamp(object["time"])
                ?? Date(),
            payload: object,
            raw: original.asObject,
            sourceRaw: inferredSource == .unknown ? sourceRaw : nil
        )
    }

    private func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if case .number(let n) = value {
            return EventEnvelopeDateParsing.parseEpoch(n)
        }
        if let s = value.stringValue {
            // Prefer ISO parse; numeric strings go through epoch when finite.
            if let date = EventEnvelopeDateParsing.parse(s) {
                return date
            }
            if let n = Double(s) {
                return EventEnvelopeDateParsing.parseEpoch(n)
            }
        }
        return nil
    }

    private func parseUUID(_ value: JSONValue?) -> UUID? {
        guard let s = value?.stringValue else { return nil }
        return UUID(uuidString: s)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Shared date parser: ISO-8601 **and** numeric epoch timestamps.
        decoder.dateDecodingStrategy = .custom { decoder in
            try EventEnvelopeDateParsing.decode(from: decoder)
        }
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
