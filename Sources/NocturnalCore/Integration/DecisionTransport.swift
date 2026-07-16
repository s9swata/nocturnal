import Foundation

/// How a permission / approval decision is delivered back to the agent.
///
/// UI must not show inline Deny/Allow when transport is ``none``, even if a
/// pending approval row exists in the session model.
public enum DecisionTransport: String, Sendable, Codable, Hashable, CaseIterable {
    /// No external decision path — agent keeps its own prompt UI.
    case none
    /// Blocked `nocturnal-hook-forwarder` prints Codex/Claude decision JSON on stdout.
    case stdoutJSON
    /// HTTP reply to agent server (OpenCode permission API).
    case http
    /// Write `responses/<id>.json` for agents that poll files (generic fallback).
    case responseFile

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .stdoutJSON: return "Hook stdout"
        case .http: return "HTTP"
        case .responseFile: return "Response file"
        }
    }

    /// Whether Nocturnal can complete a bidirectional decision for this transport.
    public var supportsInlineDecision: Bool {
        switch self {
        case .none: return false
        case .stdoutJSON, .http, .responseFile: return true
        }
    }
}
