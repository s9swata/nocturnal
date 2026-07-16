import Foundation

/// Provenance for detail enrichment (never invent data).
public enum SessionDetailSource: String, Codable, Sendable, Hashable {
    case hook
    case jsonl
    case mixed
}

/// Bounded enrichment for inspector / last-reply / extended timeline.
public struct SessionDetailSnapshot: Codable, Sendable, Hashable, Equatable {
    public var sessionId: SessionID
    public var lastUserSnippet: String?
    public var lastAssistantSnippet: String?
    public var recentToolRows: [SessionActivity]
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var diffAdded: Int?
    public var diffRemoved: Int?
    public var source: SessionDetailSource
    public var transcriptPath: String?
    public var capturedAt: Date

    public init(
        sessionId: SessionID,
        lastUserSnippet: String? = nil,
        lastAssistantSnippet: String? = nil,
        recentToolRows: [SessionActivity] = [],
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        source: SessionDetailSource = .hook,
        transcriptPath: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.lastUserSnippet = lastUserSnippet
        self.lastAssistantSnippet = lastAssistantSnippet
        self.recentToolRows = recentToolRows
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.source = source
        self.transcriptPath = transcriptPath
        self.capturedAt = capturedAt
    }

    public var lastSignalLine: String? {
        if let lastAssistantSnippet, !lastAssistantSnippet.isEmpty,
           !Session.isSystemDumpText(lastAssistantSnippet),
           !Session.isNoiseStatusText(lastAssistantSnippet)
        {
            return lastAssistantSnippet
        }
        if let lastUserSnippet, !lastUserSnippet.isEmpty,
           !Session.isSystemDumpText(lastUserSnippet),
           !Session.isNoiseStatusText(lastUserSnippet)
        {
            return lastUserSnippet
        }
        if let tool = recentToolRows.first?.displayLine, !Session.isNoiseStatusText(tool) {
            return tool
        }
        return nil
    }
}
