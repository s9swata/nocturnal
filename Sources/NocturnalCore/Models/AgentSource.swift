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
    public init(parsing raw: String) {
        switch raw.lowercased() {
        case "codex", "openai-codex", "openai_codex":
            self = .codex
        case "claude", "claude-code", "claude_code", "anthropic":
            self = .claude
        case "opencode", "open-code", "open_code", "anomalyco-opencode":
            self = .opencode
        case "cursor", "cursor-agent", "cursor_agent", "cursor-ide":
            self = .cursor
        case "kimi", "kimi-code", "kimi_code", "kimi-cli", "moonshot-kimi":
            self = .kimi
        case "grok-build", "grokbuild", "grok_build", "grok", "xai-grok-build":
            self = .grokBuild
        case "agy", "agy-agent", "agy_agent":
            self = .agy
        default:
            // Including obsolete product labels such as "demo" → unknown.
            self = .unknown
        }
    }

    public var displayName: String {
        AgentRegistry.profile(for: self).displayName
    }

    /// Capability / decision catalog entry for this source.
    public var profile: AgentProfile {
        AgentRegistry.profile(for: self)
    }
}
