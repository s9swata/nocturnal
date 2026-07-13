import Foundation

/// Upstream agent product that emitted an event.
public enum AgentSource: String, Codable, Sendable, CaseIterable, Hashable {
    case codex
    case claude
    /// Unrecognized source string; raw value preserved in envelope metadata.
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AgentSource(parsing: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AgentSource {
    public init(parsing raw: String) {
        switch raw.lowercased() {
        case "codex", "openai-codex", "openai_codex":
            self = .codex
        case "claude", "claude-code", "claude_code", "anthropic":
            self = .claude
        default:
            // Including obsolete product labels such as "demo" → unknown.
            self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .unknown: return "Unknown"
        }
    }
}
