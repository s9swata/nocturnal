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
    public var decidedAt: Date

    public init(
        requestId: String,
        sessionId: SessionID,
        approved: Bool,
        note: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.approved = approved
        self.note = note
        self.decidedAt = decidedAt
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
