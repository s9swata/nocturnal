import Foundation

/// Tool / permission approval requested by an agent.
public struct ApprovalRequest: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var sessionId: SessionID
    public var toolName: String
    public var summary: String
    public var detail: String?
    public var riskHint: ApprovalRiskHint
    public var createdAt: Date
    public var raw: [String: JSONValue]

    public init(
        id: String,
        sessionId: SessionID,
        toolName: String,
        summary: String,
        detail: String? = nil,
        riskHint: ApprovalRiskHint = .unknown,
        createdAt: Date = Date(),
        raw: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.riskHint = riskHint
        self.createdAt = createdAt
        self.raw = raw
    }
}

public enum ApprovalRiskHint: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case unknown
}

/// How long an approval decision should stick (Nocturnal-local policy).
///
/// Agents may ignore this field; Nocturnal records it for UI sticky always-allow
/// and best-effort sidecar flags only.
public enum ApprovalScope: String, Codable, Sendable, Hashable {
    /// Single approval (default when missing on wire).
    case once
    /// Always allow this tool name for the remainder of the session (local sticky).
    case sessionTool
}

/// Free-form question the agent needs answered before continuing.
public struct QuestionPrompt: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var sessionId: SessionID
    public var prompt: String
    public var placeholder: String?
    public var choices: [String]
    public var allowFreeform: Bool
    public var createdAt: Date
    public var raw: [String: JSONValue]

    public init(
        id: String,
        sessionId: SessionID,
        prompt: String,
        placeholder: String? = nil,
        choices: [String] = [],
        allowFreeform: Bool = true,
        createdAt: Date = Date(),
        raw: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.prompt = prompt
        self.placeholder = placeholder
        self.choices = choices
        self.allowFreeform = allowFreeform
        self.createdAt = createdAt
        self.raw = raw
    }
}

/// User decision written back toward the agent (file drop or reply socket).
public enum AgentResponse: Codable, Sendable, Hashable {
    case approval(ApprovalDecision)
    case question(QuestionAnswer)

    public var sessionId: SessionID {
        switch self {
        case .approval(let decision): return decision.sessionId
        case .question(let answer): return answer.sessionId
        }
    }
}

public struct ApprovalDecision: Codable, Sendable, Hashable {
    public var requestId: String
    public var sessionId: SessionID
    public var approved: Bool
    public var note: String?
    /// Sticky scope; `nil` on wire means ``ApprovalScope/once``.
    public var scope: ApprovalScope?
    public var decidedAt: Date

    /// Effective scope treating missing as `.once`.
    public var resolvedScope: ApprovalScope { scope ?? .once }

    public init(
        requestId: String,
        sessionId: SessionID,
        approved: Bool,
        note: String? = nil,
        scope: ApprovalScope? = nil,
        decidedAt: Date = Date()
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.approved = approved
        self.note = note
        self.scope = scope
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, sessionId, approved, note, scope, decidedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        sessionId = try container.decode(SessionID.self, forKey: .sessionId)
        approved = try container.decode(Bool.self, forKey: .approved)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        // Missing scope → once (backward compatible).
        scope = try container.decodeIfPresent(ApprovalScope.self, forKey: .scope) ?? .once
        decidedAt = try container.decode(Date.self, forKey: .decidedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(approved, forKey: .approved)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(resolvedScope, forKey: .scope)
        try container.encode(decidedAt, forKey: .decidedAt)
    }
}

public struct QuestionAnswer: Codable, Sendable, Hashable {
    public var promptId: String
    public var sessionId: SessionID
    public var text: String
    public var answeredAt: Date

    public init(
        promptId: String,
        sessionId: SessionID,
        text: String,
        answeredAt: Date = Date()
    ) {
        self.promptId = promptId
        self.sessionId = sessionId
        self.text = text
        self.answeredAt = answeredAt
    }
}
