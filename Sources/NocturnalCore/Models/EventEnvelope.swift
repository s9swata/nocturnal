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
    /// Optional original source string when ``source`` is ``AgentSource/unknown``.
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

        if let sourceString = try? container.decode(String.self, forKey: .source) {
            source = AgentSource(parsing: sourceString)
            sourceRaw = source == .unknown ? sourceString : try container.decodeIfPresent(String.self, forKey: .sourceRaw)
        } else {
            source = try container.decodeIfPresent(AgentSource.self, forKey: .source) ?? .unknown
            sourceRaw = try container.decodeIfPresent(String.self, forKey: .sourceRaw)
        }

        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? "unknown"
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? "unknown"

        if let date = try? container.decode(Date.self, forKey: .timestamp) {
            timestamp = date
        } else if let string = try? container.decode(String.self, forKey: .timestamp),
                  let date = EventEnvelopeDateParsing.parse(string)
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
            // Heuristic: ms vs s timestamps
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            return Date(timeIntervalSince1970: number)
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

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
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
