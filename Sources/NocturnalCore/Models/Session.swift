import Foundation

/// Stable identifier for a coding-agent session.
public struct SessionID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public init(_ value: String) {
        self.rawValue = value
    }
}

extension SessionID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// In-memory / persisted model for one agent session surface.
public struct Session: Identifiable, Codable, Sendable, Hashable {
    public var id: SessionID
    public var source: AgentSource
    public var state: SessionState
    public var title: String
    public var summary: String
    public var workingDirectory: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastEventType: String?
    /// Pending approval if state is ``SessionState/waitingForApproval``.
    public var pendingApproval: ApprovalRequest?
    /// Pending question if state is ``SessionState/waitingForInput``.
    public var pendingQuestion: QuestionPrompt?
    /// Context for jump-back (cwd, terminal, editor deep links).
    public var jumpBack: JumpBackContext?
    /// Unmapped upstream fields preserved for diagnostics / future mapping.
    public var rawMetadata: [String: JSONValue]
    /// Chronological envelope ids applied (bounded; see store policy).
    public var recentEventIDs: [UUID]

    public init(
        id: SessionID,
        source: AgentSource,
        state: SessionState = .idle,
        title: String = "",
        summary: String = "",
        workingDirectory: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastEventType: String? = nil,
        pendingApproval: ApprovalRequest? = nil,
        pendingQuestion: QuestionPrompt? = nil,
        jumpBack: JumpBackContext? = nil,
        rawMetadata: [String: JSONValue] = [:],
        recentEventIDs: [UUID] = []
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.title = title.isEmpty ? "\(source.displayName) session" : title
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEventType = lastEventType
        self.pendingApproval = pendingApproval
        self.pendingQuestion = pendingQuestion
        self.jumpBack = jumpBack
        self.rawMetadata = rawMetadata
        self.recentEventIDs = recentEventIDs
    }
}

/// Context needed to return the user to the agent surface.
public struct JumpBackContext: Codable, Sendable, Hashable {
    public var workingDirectory: String?
    public var terminalBundleID: String?
    public var terminalTabTitle: String?
    public var editorURL: URL?
    public var codexDeepLink: URL?
    public var processIdentifier: Int32?
    public var extra: [String: String]

    public init(
        workingDirectory: String? = nil,
        terminalBundleID: String? = nil,
        terminalTabTitle: String? = nil,
        editorURL: URL? = nil,
        codexDeepLink: URL? = nil,
        processIdentifier: Int32? = nil,
        extra: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.terminalBundleID = terminalBundleID
        self.terminalTabTitle = terminalTabTitle
        self.editorURL = editorURL
        self.codexDeepLink = codexDeepLink
        self.processIdentifier = processIdentifier
        self.extra = extra
    }
}
