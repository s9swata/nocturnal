import Foundation

/// Normalized lifecycle state for an agent coding session.
///
/// Upstream Codex/Claude event names map into this enum; unknown upstream
/// states become ``unknown`` while preserving raw metadata on the session.
public enum SessionState: String, Codable, Sendable, CaseIterable, Hashable {
    /// No active work; session exists but is quiet.
    case idle
    /// Agent is actively generating or executing tools.
    case running
    /// Agent is blocked waiting for user approval (tool / permission).
    case waitingForApproval
    /// Agent is blocked waiting for free-form user input / question answer.
    case waitingForInput
    /// Session finished successfully.
    case completed
    /// Session ended with an error.
    case failed
    /// Session was cancelled by the user or host.
    case cancelled
    /// Could not map upstream state; see session `rawMetadata`.
    case unknown
}

extension SessionState {
    /// Whether the UI should treat this state as needing attention.
    public var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .failed:
            return true
        case .idle, .running, .completed, .cancelled, .unknown:
            return false
        }
    }

    /// Whether the session is considered terminal (no further events expected).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .idle, .running, .waitingForApproval, .waitingForInput, .unknown:
            return false
        }
    }
}
