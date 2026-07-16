import Foundation

/// Upstream agent product that emitted an event.
///
/// Prefer ``AgentRegistry/profile(for:)`` for capabilities and decision policy.
/// New products may land as dedicated cases (branded) or as ``unknown`` with
/// a string id resolved through the registry.
public enum AgentSource: String, Codable, Sendable, CaseIterable, Hashable {
    case codex
    case claude
    case opencode
    case cursor
    case kimi
    case grokBuild = "grok-build"
    case agy
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
    /// Wire aliases for dedicated products (excluding each product's primary `rawValue`).
    ///
    /// Single source of truth for parse + ``AgentRegistry`` catalog aliases.
    public static func wireAliases(for source: AgentSource) -> [String] {
        switch source {
        case .codex: return ["openai-codex", "openai_codex"]
        case .claude: return ["claude-code", "claude_code", "anthropic"]
        case .opencode: return ["open-code", "open_code", "anomalyco-opencode"]
        case .cursor: return ["cursor-agent", "cursor_agent", "cursor-ide"]
        case .kimi: return ["kimi-code", "kimi_code", "kimi-cli", "moonshot-kimi"]
        case .grokBuild: return ["grok", "grokbuild", "grok_build", "xai-grok-build"]
        case .agy: return ["agy-agent", "agy_agent"]
        case .unknown: return []
        }
    }

    public init(parsing raw: String) {
        let key = raw.lowercased()
        for source in AgentSource.allCases where source != .unknown {
            if key == source.rawValue
                || Self.wireAliases(for: source).contains(where: { $0.lowercased() == key })
            {
                self = source
                return
            }
        }
        // Including obsolete product labels such as "demo" → unknown.
        self = .unknown
    }

    public var displayName: String {
        AgentRegistry.profile(for: self).displayName
    }

    /// Capability / decision catalog entry for this source.
    public var profile: AgentProfile {
        AgentRegistry.profile(for: self)
    }
}
