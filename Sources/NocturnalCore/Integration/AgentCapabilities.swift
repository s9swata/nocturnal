import Foundation

/// What an agent can do in Nocturnal — drives UI and setup, not branding.
///
/// Capabilities are progressive. Tier A adapters may only set ``liveActivity``.
/// Deny/Allow chips require ``permissions`` plus a non-``.none`` decision transport.
public struct AgentCapabilities: Sendable, Equatable, Hashable, Codable {
    /// Session / tool / turn events can drive the island live strip.
    public var liveActivity: Bool
    /// External Allow/Deny is possible (hook decision, HTTP, etc.).
    public var permissions: Bool
    /// Agent can surface freeform / choice questions to Nocturnal.
    public var questions: Bool
    /// Local disk/db scan can recover idle session stubs on launch.
    public var recoveryScan: Bool
    /// Jump-back hints (cwd, deep link, terminal) are meaningful.
    public var jumpBack: Bool
    /// `nocturnal-setup` can install product-native hooks/plugins.
    public var installableHooks: Bool

    public init(
        liveActivity: Bool = false,
        permissions: Bool = false,
        questions: Bool = false,
        recoveryScan: Bool = false,
        jumpBack: Bool = false,
        installableHooks: Bool = false
    ) {
        self.liveActivity = liveActivity
        self.permissions = permissions
        self.questions = questions
        self.recoveryScan = recoveryScan
        self.jumpBack = jumpBack
        self.installableHooks = installableHooks
    }

    /// Full first-party Codex / Claude style surface.
    public static let fullNative = AgentCapabilities(
        liveActivity: true,
        permissions: true,
        questions: true,
        recoveryScan: true,
        jumpBack: true,
        installableHooks: true
    )

    /// OpenCode: live + permissions (HTTP) + installable plugin; questions best-effort.
    public static let openCode = AgentCapabilities(
        liveActivity: true,
        permissions: true,
        questions: false,
        recoveryScan: true,
        jumpBack: true,
        installableHooks: true
    )

    /// Envelope-only bridge (Tier A): sessions appear; no Deny/Allow, no setup install.
    public static let envelopeBridge = AgentCapabilities(
        liveActivity: true,
        permissions: false,
        questions: false,
        recoveryScan: false,
        jumpBack: true,
        installableHooks: false
    )

    /// Unknown / opaque source — accept events, never pretend decision support.
    public static let unknown = AgentCapabilities(
        liveActivity: true,
        permissions: false,
        questions: false,
        recoveryScan: false,
        jumpBack: false,
        installableHooks: false
    )
}
