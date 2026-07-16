import Foundation

/// Catalog entry describing how Nocturnal integrates with one agent product.
///
/// Profiles are pure data. Runtime install / decision delivery lives on
/// ``AgentAdapter`` implementations and existing transport types.
public struct AgentProfile: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Stable product id (`codex`, `cursor`, `kimi`, …).
    public var id: String
    public var displayName: String
    /// Mapped ``AgentSource`` enum value (``.unknown`` for generic / future ids).
    public var source: AgentSource
    public var capabilities: AgentCapabilities
    public var decisionTransport: DecisionTransport
    /// Alternate wire labels accepted by ``AgentRegistry/profile(parsing:)``.
    public var aliases: [String]
    /// Short integration tier note for docs / doctor.
    public var integrationNotes: String

    public init(
        id: String,
        displayName: String,
        source: AgentSource,
        capabilities: AgentCapabilities,
        decisionTransport: DecisionTransport,
        aliases: [String] = [],
        integrationNotes: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.capabilities = capabilities
        self.decisionTransport = decisionTransport
        self.aliases = aliases
        self.integrationNotes = integrationNotes
    }

    /// Inline Deny/Allow is safe only when both capability and transport agree.
    public var supportsInlinePermissionDecision: Bool {
        capabilities.permissions && decisionTransport.supportsInlineDecision
    }

    /// Setup CLI should offer install for this product.
    public var isSetupInstallable: Bool {
        capabilities.installableHooks
    }
}
