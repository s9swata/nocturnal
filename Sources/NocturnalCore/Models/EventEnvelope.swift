import Foundation

/// Wire format for one NDJSON line on the Unix domain socket.
///
/// Each line is a single JSON object. The forwarder never blocks the agent:
/// parse/write failures are logged and discarded (fail-open).
///
/// Example:
/// ```json
/// {"v":1,"id":"...","source":"codex","eventType":"session.updated","sessionId":"...","timestamp":"...","payload":{},"raw":{}}
/// ```
public struct EventEnvelope: Codable, Sendable, Hashable, Identifiable {
    /// Envelope schema version. Bump only on breaking wire changes.
    public static let currentSchemaVersion: Int = 1

    public var id: UUID
    public var schemaVersion: Int
    public var source: AgentSource
    /// Upstream or normalized event type string (e.g. `session.started`, `tool.approval_required`).
    public var eventType: String
    public var sessionId: String
    public var timestamp: Date
    /// Decoded structured fields when known; empty object when only raw is available.
    public var payload: [String: JSONValue]
    /// Original upstream JSON object (or wrapper), preserved for unknown events.
    public var raw: [String: JSONValue]
    /// Optional original source string when ``source`` is ``AgentSource/unknown``,
    /// or any explicit `sourceRaw` supplied on the wire. Always preserved across
    /// encode/decode hops when present.
    public var sourceRaw: String?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = EventEnvelope.currentSchemaVersion,
        source: AgentSource,
        eventType: String,
        sessionId: String,
        timestamp: Date = Date(),
        payload: [String: JSONValue] = [:],
        raw: [String: JSONValue] = [:],
        sourceRaw: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.source = source
        self.eventType = eventType
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.payload = payload
        self.raw = raw
        self.sourceRaw = sourceRaw
    }

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion = "v"
        case source
        case eventType
        case sessionId
        case timestamp
        case payload
        case raw
        case sourceRaw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else if let string = try? container.decode(String.self, forKey: .id),
                  let uuid = UUID(uuidString: string)
        {
            id = uuid
        } else {
            id = UUID()
        }

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? EventEnvelope.currentSchemaVersion

        let explicitSourceRaw = try container.decodeIfPresent(String.self, forKey: .sourceRaw)

        if let sourceString = try? container.decode(String.self, forKey: .source) {
            source = AgentSource(parsing: sourceString)
            // Always preserve an explicit sourceRaw field. When source is unknown
            // and sourceRaw was omitted, fall back to the raw source string so the
            // original label survives encode/decode hops.
            if let explicitSourceRaw {
                sourceRaw = explicitSourceRaw
            } else if source == .unknown {
                sourceRaw = sourceString
            } else {
                sourceRaw = nil
            }
        } else {
            source = try container.decodeIfPresent(AgentSource.self, forKey: .source) ?? .unknown
            sourceRaw = explicitSourceRaw
        }

        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? "unknown"
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? "unknown"

        if let date = try? container.decode(Date.self, forKey: .timestamp) {
            timestamp = date
        } else if let string = try? container.decode(String.self, forKey: .timestamp),
                  let date = EventEnvelopeDateParsing.parse(string)
        {
            timestamp = date
        } else if let number = try? container.decode(Double.self, forKey: .timestamp),
                  let date = EventEnvelopeDateParsing.parseEpoch(number)
        {
            timestamp = date
        } else {
            timestamp = Date()
        }

        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        raw = try container.decodeIfPresent([String: JSONValue].self, forKey: .raw) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(source, forKey: .source)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(payload, forKey: .payload)
        try container.encode(raw, forKey: .raw)
        try container.encodeIfPresent(sourceRaw, forKey: .sourceRaw)
    }
}

/// ISO-8601 parsing tolerant of fractional seconds and bare dates.
/// Formatters are created per call — `ISO8601DateFormatter` is not Sendable.
enum EventEnvelopeDateParsing {
    static func parse(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }

    /// Epoch seconds or milliseconds (heuristic: values ≥ 1e12 are ms).
    static func parseEpoch(_ number: Double) -> Date? {
        guard number.isFinite else { return nil }
        if number > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        return Date(timeIntervalSince1970: number)
    }

    /// Safe `JSONDecoder.dateDecodingStrategy` implementation.
    ///
    /// **Never** call `container.decode(Date.self)` inside a custom date strategy —
    /// that re-enters the strategy and stack-overflows (SIGBUS / crash).
    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            if let date = parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(string)"
            )
        }
        if let number = try? container.decode(Double.self) {
            if let date = parseEpoch(number) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid epoch timestamp: \(number)"
            )
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO-8601 date string or epoch number"
        )
    }
}

/// Minimal JSON value type for preserving unknown fields without Foundation.JSONSerialization bridging.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// String projection. Integer-valued numbers use an **exact** conversion —
    /// never a truncating `Int(double)` that can trap or misrepresent large values.
    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            guard value.isFinite else { return nil }
            if let exact = Self.exactIntegerString(value) {
                return exact
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// Convert a Double to a decimal integer string only when it is an exact
    /// integer in the inclusive `Int64` range (safe for `pid` / id display).
    /// Returns `nil` for non-integers, NaN/Inf, or out-of-range values.
    public static func exactIntegerString(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        // Must be integral (no fractional part).
        guard value.rounded(.towardZero) == value else { return nil }
        // Bound to Int64 before converting — avoids Int trap on 32-bit and
        // avoids imprecise Double→Int for values near Int.max.
        let asInt64 = Int64(exactly: value)
        if let asInt64 {
            return String(asInt64)
        }
        // Integers outside Int64 but still exact in Double (rare): format without
        // scientific notation via truncating remainder check already done.
        // Fall back to fixed formatting only for whole numbers.
        return String(format: "%.0f", value)
    }

    /// Failable exact integer conversion (no trap on out-of-range doubles).
    public var exactIntValue: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        guard value.rounded(.towardZero) == value else { return nil }
        return Int(exactly: value)
    }

    /// Failable exact Int32 conversion for PIDs and similar OS fields.
    public var exactInt32Value: Int32? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        guard value.rounded(.towardZero) == value else { return nil }
        return Int32(exactly: value)
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case .number(let value): return value != 0
        default: return nil
        }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        if case .string(let value) = self { return Double(value) }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Parse arbitrary JSON data into a ``JSONValue`` tree. Never crashes on valid JSON.
    public static func parse(data: Data) throws -> JSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(JSONValue.self, from: data)
    }

    /// Best-effort object extraction (top-level object or empty).
    public var asObject: [String: JSONValue] {
        objectValue ?? [:]
    }
}
