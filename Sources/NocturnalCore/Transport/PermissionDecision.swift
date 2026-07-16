import Foundation

/// Decision returned to a blocked hook forwarder (and mapped to agent stdout).
public enum PermissionBehavior: String, Codable, Sendable, Hashable {
    /// Grant permission — Codex skips its prompt.
    case allow
    /// Block the tool/request.
    case deny
    /// No opinion — forwarder prints `{}` so Codex shows its own prompt.
    case `defer`
}

/// Result of waiting for a UI decision (includes optional deny message).
public struct PermissionDecisionResult: Sendable, Hashable, Equatable {
    public var behavior: PermissionBehavior
    public var message: String?

    public init(behavior: PermissionBehavior, message: String? = nil) {
        self.behavior = behavior
        self.message = message
    }

    public static let deferred = PermissionDecisionResult(behavior: .defer)
    public static let allowed = PermissionDecisionResult(behavior: .allow)
    public static func denied(_ message: String? = nil) -> PermissionDecisionResult {
        PermissionDecisionResult(behavior: .deny, message: message)
    }
}

/// Wire reply from app → forwarder after user decides (or timeout).
public struct PermissionDecisionReply: Codable, Sendable, Hashable, Equatable {
    public static let kindValue = "permission.decision_reply"

    public var v: Int
    public var kind: String
    public var decisionRequestId: String
    public var behavior: PermissionBehavior
    public var message: String?
    public var decidedAt: Date

    public init(
        decisionRequestId: String,
        behavior: PermissionBehavior,
        message: String? = nil,
        decidedAt: Date = Date(),
        v: Int = 1
    ) {
        self.v = v
        self.kind = Self.kindValue
        self.decisionRequestId = decisionRequestId
        self.behavior = behavior
        self.message = message
        self.decidedAt = decidedAt
    }

    public var result: PermissionDecisionResult {
        PermissionDecisionResult(behavior: behavior, message: message)
    }
}

/// Keys injected into ``EventEnvelope/payload`` for decision-mode hooks.
public enum PermissionDecisionKeys {
    public static let needsDecision = "nocturnalNeedsDecision"
    public static let decisionRequestId = "nocturnalDecisionRequestId"
    public static let timeoutSec = "nocturnalDecisionTimeoutSec"
}

/// Maps a behavior to Codex / Claude hook stdout JSON.
public enum HookDecisionTranslator: Sendable {
    /// Whether this event type should block for a UI decision.
    public static func shouldRequestDecision(
        eventType: String,
        source: AgentSource,
        payload: [String: JSONValue]
    ) -> Bool {
        switch eventType {
        case "PermissionRequest", "tool.approval_required":
            return true
        case "PreToolUse":
            if source == .claude {
                return ClaudeEventDecoder.shouldRequestApproval(eventType: eventType, payload: payload)
            }
            return false
        default:
            return false
        }
    }

    /// Resolve correlation id shared with ``ApprovalRequest/id``.
    public static func decisionRequestId(for envelope: EventEnvelope) -> String {
        if let existing = envelope.payload[PermissionDecisionKeys.decisionRequestId]?.stringValue,
           !existing.isEmpty
        {
            return existing
        }
        return EventDecodeHelpers.string(
            envelope.payload,
            "tool_use_id",
            "toolUseId",
            "request_id",
            "approval_id",
            "id"
        ) ?? envelope.id.uuidString
    }

    /// Stamp decision-mode fields onto an envelope before socket send.
    public static func stampForDecision(
        _ envelope: EventEnvelope,
        timeoutSec: TimeInterval
    ) -> EventEnvelope {
        var env = envelope
        let id = decisionRequestId(for: envelope)
        env.payload[PermissionDecisionKeys.needsDecision] = .bool(true)
        env.payload[PermissionDecisionKeys.decisionRequestId] = .string(id)
        env.payload[PermissionDecisionKeys.timeoutSec] = .number(timeoutSec)
        return env
    }

    public static func envelopeNeedsDecision(_ envelope: EventEnvelope) -> Bool {
        envelope.payload[PermissionDecisionKeys.needsDecision]?.boolValue == true
    }

    public static func timeoutSeconds(from envelope: EventEnvelope, default defaultSec: TimeInterval = 120) -> TimeInterval {
        if let n = envelope.payload[PermissionDecisionKeys.timeoutSec]?.numberValue, n > 0 {
            return min(n, 600)
        }
        return defaultSec
    }

    /// JSON object for hook process stdout.
    public static func stdoutJSON(
        for envelope: EventEnvelope,
        result: PermissionDecisionResult
    ) -> String {
        switch result.behavior {
        case .defer:
            return "{}"
        case .allow:
            return allowJSON(eventType: envelope.eventType, source: envelope.source)
        case .deny:
            return denyJSON(
                eventType: envelope.eventType,
                source: envelope.source,
                message: result.message ?? "Denied in Nocturnal"
            )
        }
    }

    private static func allowJSON(eventType: String, source: AgentSource) -> String {
        if eventType == "PreToolUse" || (source == .claude && eventType != "PermissionRequest") {
            return #"{"hookSpecificOutput":{"hookEventName":"\#(escape(eventType))","permissionDecision":"allow","permissionDecisionReason":"Approved in Nocturnal"}}"#
        }
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    }

    private static func denyJSON(eventType: String, source: AgentSource, message: String) -> String {
        let msg = escape(message)
        if eventType == "PreToolUse" || (source == .claude && eventType != "PermissionRequest") {
            return #"{"hookSpecificOutput":{"hookEventName":"\#(escape(eventType))","permissionDecision":"deny","permissionDecisionReason":"\#(msg)"}}"#
        }
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"\#(msg)"}}}"#
    }

    private static func escape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

/// In-process registry: socket handlers wait; UI completes.
public actor PermissionBroker {
    private var waiters: [String: CheckedContinuation<PermissionDecisionResult, Never>] = [:]
    /// Completions that arrived before ``wait`` (always-allow race).
    private var early: [String: PermissionDecisionResult] = [:]

    public init() {}

    /// Wait for a UI decision or return early completion / defer on timeout.
    public func wait(
        for decisionRequestId: String,
        timeoutSeconds: TimeInterval
    ) async -> PermissionDecisionResult {
        let id = decisionRequestId
        if let done = early.removeValue(forKey: id) {
            return done
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<PermissionDecisionResult, Never>) in
            waiters[id] = continuation
            let timeout = max(1, timeoutSeconds)
            Task { [weak self] in
                let ns = UInt64(min(timeout, 600) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                await self?.timeout(id: id)
            }
        }
    }

    public func complete(decisionRequestId: String, result: PermissionDecisionResult) {
        let id = decisionRequestId
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: result)
        } else {
            early[id] = result
            if early.count > 64 {
                early.removeAll(keepingCapacity: true)
            }
        }
    }

    public func complete(
        approvalRequestId: String,
        approved: Bool,
        message: String? = nil
    ) {
        let result: PermissionDecisionResult = approved
            ? .allowed
            : .denied(message)
        complete(decisionRequestId: approvalRequestId, result: result)
    }

    private func timeout(id: String) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: .deferred)
    }
}
