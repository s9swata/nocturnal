import Foundation

/// SPI for product-specific integration (hooks, recovery, decisions).
///
/// First-party adapters wrap existing installers / clients. Community or
/// future agents implement this protocol (or post ``EventEnvelope`` NDJSON
/// for Tier A live activity without a compiled adapter).
public protocol AgentAdapter: Sendable {
    var profile: AgentProfile { get }
}

/// Marker for adapters that can install/uninstall native hooks via setup CLI.
public protocol HookInstallingAdapter: AgentAdapter {
    /// Product key understood by ``HookInstaller`` when installable.
    var hookProduct: HookProduct? { get }
}

/// Marker for adapters that deliver permission decisions over HTTP.
public protocol HTTPPermissionAdapter: AgentAdapter {
    /// Whether this request should use the HTTP decision path.
    func shouldDeliverHTTPPermission(for request: ApprovalRequest) -> Bool
}

// MARK: - Built-in adapters (catalog only; install still via HookInstaller)

public struct CodexAgentAdapter: HookInstallingAdapter {
    public init() {}
    public var profile: AgentProfile { AgentRegistry.codex }
    public var hookProduct: HookProduct? { .codex }
}

public struct ClaudeAgentAdapter: HookInstallingAdapter {
    public init() {}
    public var profile: AgentProfile { AgentRegistry.claude }
    public var hookProduct: HookProduct? { .claude }
}

public struct OpenCodeAgentAdapter: HookInstallingAdapter, HTTPPermissionAdapter {
    public init() {}
    public var profile: AgentProfile { AgentRegistry.opencode }
    public var hookProduct: HookProduct? { .opencode }

    public func shouldDeliverHTTPPermission(for request: ApprovalRequest) -> Bool {
        if request.raw["source"]?.stringValue == "opencode" { return true }
        if request.raw["opencode"]?.boolValue == true { return true }
        if request.raw["permission"] != nil,
           OpenCodeSessionIdentity.isOpenCodeSessionId(request.sessionId.rawValue)
        {
            return true
        }
        return OpenCodeSessionIdentity.isOpenCodeSessionId(request.sessionId.rawValue)
            || OpenCodePermissionClient.correlation(from: request) != nil
    }
}

public struct GrokAgentAdapter: HookInstallingAdapter {
    public init() {}
    public var profile: AgentProfile { AgentRegistry.grokBuild }
    public var hookProduct: HookProduct? { .grok }
}

/// Envelope-bridge adapters: accept wire events only; no install / decisions yet.
public struct EnvelopeBridgeAdapter: AgentAdapter {
    public let profile: AgentProfile
    public init(profile: AgentProfile) {
        self.profile = profile
    }
}

/// Resolves the built-in adapter for a profile / source.
public enum AgentAdapterCatalog: Sendable {
    public static let builtIn: [any AgentAdapter] = [
        CodexAgentAdapter(),
        ClaudeAgentAdapter(),
        OpenCodeAgentAdapter(),
        GrokAgentAdapter(),
        EnvelopeBridgeAdapter(profile: AgentRegistry.cursor),
        EnvelopeBridgeAdapter(profile: AgentRegistry.kimi),
        EnvelopeBridgeAdapter(profile: AgentRegistry.agy),
        EnvelopeBridgeAdapter(profile: AgentRegistry.generic),
    ]

    public static func adapter(for source: AgentSource) -> any AgentAdapter {
        switch source {
        case .codex: return CodexAgentAdapter()
        case .claude: return ClaudeAgentAdapter()
        case .opencode: return OpenCodeAgentAdapter()
        case .cursor: return EnvelopeBridgeAdapter(profile: AgentRegistry.cursor)
        case .kimi: return EnvelopeBridgeAdapter(profile: AgentRegistry.kimi)
        case .grokBuild: return GrokAgentAdapter()
        case .agy: return EnvelopeBridgeAdapter(profile: AgentRegistry.agy)
        case .unknown: return EnvelopeBridgeAdapter(profile: AgentRegistry.unknown)
        }
    }

    public static func adapter(parsing raw: String) -> any AgentAdapter {
        adapter(for: AgentSource(parsing: raw))
    }

    public static func adapter(for profile: AgentProfile) -> any AgentAdapter {
        if let match = builtIn.first(where: { $0.profile.id == profile.id }) {
            return match
        }
        return EnvelopeBridgeAdapter(profile: profile)
    }
}
