import Foundation

/// Nocturnal Agent Protocol (NAP) — canonical `eventType` strings on ``EventEnvelope``.
///
/// Product-native names are mapped via ``normalize(_:)`` at store apply and
/// activity mapping (see ``SessionStore/apply`` and ``SessionActivityMapping``).
/// Unknown types remain fail-open metadata and never crash the store.
public enum CanonicalAgentEvent: String, Sendable, Codable, Hashable, CaseIterable {
    // Lifecycle
    case sessionStarted = "session.started"
    case sessionUpdated = "session.updated"
    case sessionCompleted = "session.completed"
    case sessionFailed = "session.failed"
    case sessionCancelled = "session.cancelled"
    case sessionReconciled = "session.reconciled"

    // Turns
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"

    // Tools
    case toolStarted = "tool.started"
    case toolCompleted = "tool.completed"

    // Attention
    case permissionAsked = "permission.asked"
    case permissionResolved = "permission.resolved"
    case questionAsked = "question.asked"
    case questionAnswered = "question.answered"

    /// Whether this event type is part of the attention / decision surface.
    public var isAttention: Bool {
        switch self {
        case .permissionAsked, .questionAsked:
            return true
        default:
            return false
        }
    }

    /// Best-effort map from common native / legacy names into NAP.
    public static func normalize(_ raw: String) -> String {
        switch raw {
        case "session.started", "SessionStart":
            return sessionStarted.rawValue
        case "session.updated":
            return sessionUpdated.rawValue
        case "session.completed", "Stop", "SessionEnd":
            return sessionCompleted.rawValue
        case "session.failed":
            return sessionFailed.rawValue
        case "session.cancelled":
            return sessionCancelled.rawValue
        case "session.reconciled":
            return sessionReconciled.rawValue
        case "agent.turn.started", "turn.started":
            return turnStarted.rawValue
        case "agent.turn.completed", "turn.completed":
            return turnCompleted.rawValue
        case "tool.started", "PreToolUse":
            return toolStarted.rawValue
        case "tool.completed", "PostToolUse":
            return toolCompleted.rawValue
        case "permission.asked", "PermissionRequest", "tool.approval_required":
            return permissionAsked.rawValue
        case "permission.resolved", "tool.approval_resolved":
            return permissionResolved.rawValue
        case "question.asked", "agent.question":
            return questionAsked.rawValue
        case "question.answered", "agent.question_answered":
            return questionAnswered.rawValue
        default:
            return raw
        }
    }
}
