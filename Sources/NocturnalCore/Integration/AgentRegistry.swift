import Foundation

/// Catalog of agent profiles. Single place for capabilities and decision policy.
///
/// UI and setup should query the registry instead of hardcoding product names
/// for “can we show Deny/Allow?” or “can we install hooks?”.
public enum AgentRegistry: Sendable {
    // MARK: - First-party (Tier C)

    public static let codex = AgentProfile(
        id: "codex",
        displayName: "Codex",
        source: .codex,
        capabilities: .fullNative,
        decisionTransport: .stdoutJSON,
        aliases: ["openai-codex", "openai_codex"],
        integrationNotes: "Native hooks via nocturnal-hook-forwarder; PermissionRequest blocks for UI decision."
    )

    public static let claude = AgentProfile(
        id: "claude",
        displayName: "Claude",
        source: .claude,
        capabilities: .fullNative,
        decisionTransport: .stdoutJSON,
        aliases: ["claude-code", "claude_code", "anthropic"],
        integrationNotes: "Native Claude Code hooks; PreToolUse / PermissionRequest decision path."
    )

    public static let opencode = AgentProfile(
        id: "opencode",
        displayName: "OpenCode",
        source: .opencode,
        capabilities: .openCode,
        decisionTransport: .http,
        aliases: ["open-code", "open_code", "anomalyco-opencode"],
        integrationNotes: "Plugin + bus events; permission.ask → HTTP reply to OpenCode server."
    )

    // MARK: - Envelope bridge (Tier A) — ready for adapters

    public static let cursor = AgentProfile(
        id: "cursor",
        displayName: "Cursor",
        source: .cursor,
        capabilities: AgentCapabilities(
            liveActivity: true,
            permissions: false,
            questions: false,
            recoveryScan: false,
            jumpBack: true,
            installableHooks: true
        ),
        decisionTransport: .none,
        aliases: ["cursor-agent", "cursor_agent", "cursor-ide"],
        integrationNotes: "Tier B: ~/.cursor/hooks.json → nocturnal-hook-forwarder --wrap-source cursor. Live activity; Cursor owns permissions."
    )

    public static let kimi = AgentProfile(
        id: "kimi",
        displayName: "Kimi Code",
        source: .kimi,
        capabilities: .envelopeBridge,
        decisionTransport: .none,
        aliases: ["kimi-code", "kimi_code", "kimi-cli", "moonshot-kimi"],
        integrationNotes: "Tier A bridge; Kimi hooks/ACP can map to NAP for Tier B/C later."
    )

    public static let grokBuild = AgentProfile(
        id: "grok-build",
        displayName: "Grok Build",
        source: .grokBuild,
        capabilities: AgentCapabilities(
            liveActivity: true,
            permissions: false,
            questions: false,
            recoveryScan: true,
            jumpBack: true,
            installableHooks: true
        ),
        decisionTransport: .none,
        aliases: ["grok", "grokbuild", "grok_build", "xai-grok-build"],
        integrationNotes: "Tier B: ~/.grok/hooks/nocturnal.json → nocturnal-hook-forwarder. Live activity + recovery; Grok owns permissions."
    )

    public static let agy = AgentProfile(
        id: "agy",
        displayName: "Agy",
        source: .agy,
        capabilities: .envelopeBridge,
        decisionTransport: .none,
        aliases: ["agy-agent", "agy_agent"],
        integrationNotes: "Tier A envelope bridge until product hooks are documented."
    )

    /// Generic community adapter id for custom envelope bridges.
    public static let generic = AgentProfile(
        id: "generic",
        displayName: "Generic",
        source: .unknown,
        capabilities: .envelopeBridge,
        decisionTransport: .responseFile,
        aliases: ["custom", "bridge", "nap", "nocturnal-bridge"],
        integrationNotes: "Any tool posting NAP EventEnvelope lines; optional response-file decisions."
    )

    public static let unknown = AgentProfile(
        id: "unknown",
        displayName: "Unknown",
        source: .unknown,
        capabilities: .unknown,
        decisionTransport: .none,
        aliases: [],
        integrationNotes: "Unrecognized source; raw metadata preserved, no decision chips."
    )

    /// All catalog profiles (first-party + declared Tier A targets).
    public static let all: [AgentProfile] = [
        codex, claude, opencode,
        cursor, kimi, grokBuild, agy,
        generic, unknown,
    ]

    /// Profiles that `nocturnal-setup install` may target today.
    public static var installable: [AgentProfile] {
        all.filter(\.isSetupInstallable)
    }

    // MARK: - Lookup

    public static func profile(for source: AgentSource) -> AgentProfile {
        switch source {
        case .codex: return codex
        case .claude: return claude
        case .opencode: return opencode
        case .cursor: return cursor
        case .kimi: return kimi
        case .grokBuild: return grokBuild
        case .agy: return agy
        case .unknown: return unknown
        }
    }

    /// Resolve from a wire label (`source` field or `sourceRaw`).
    public static func profile(parsing raw: String) -> AgentProfile {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return unknown }

        if let exact = all.first(where: { $0.id == key }) {
            return exact
        }
        if let aliased = all.first(where: { profile in
            profile.aliases.contains { $0.lowercased() == key }
        }) {
            return aliased
        }
        // Fall back through AgentSource parsing (handles codex/claude aliases).
        let source = AgentSource(parsing: key)
        if source != .unknown {
            return profile(for: source)
        }
        // Unknown label still gets envelope-bridge capabilities so events can surface.
        return AgentProfile(
            id: key,
            displayName: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .unknown,
            capabilities: .envelopeBridge,
            decisionTransport: .none,
            aliases: [],
            integrationNotes: "Ad-hoc source; treat as Tier A envelope bridge."
        )
    }

    public static func profile(for session: Session) -> AgentProfile {
        if session.source != .unknown {
            return profile(for: session.source)
        }
        if let raw = session.rawMetadata["sourceRaw"]?.stringValue
            ?? session.rawMetadata["source"]?.stringValue
        {
            return profile(parsing: raw)
        }
        return unknown
    }

    public static func profile(for envelope: EventEnvelope) -> AgentProfile {
        if envelope.source != .unknown {
            return profile(for: envelope.source)
        }
        if let raw = envelope.sourceRaw, !raw.isEmpty {
            return profile(parsing: raw)
        }
        return unknown
    }

    /// Hook setup product when the profile maps to a native installer.
    public static func hookProduct(for profile: AgentProfile) -> HookProduct? {
        guard profile.isSetupInstallable else { return nil }
        switch profile.source {
        case .codex: return .codex
        case .claude: return .claude
        case .opencode: return .opencode
        case .grokBuild: return .grok
        case .cursor: return .cursor
        default: return nil
        }
    }
}
