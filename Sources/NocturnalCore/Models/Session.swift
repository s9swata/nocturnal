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

/// Hook / log-derived counters for a session.
///
/// Token and diff fields are **optional** — UI shows them only when non-nil (found
/// in hooks or local log tails). Never invent zeros as decoration.
public struct SessionStats: Codable, Sendable, Hashable, Equatable {
    public var toolUseCount: Int
    /// Unique paths observed (mirrors ``touchedPathKeys`` count).
    public var filesTouchedCount: Int
    /// Bounded unique path keys for uniqueness bookkeeping (UI should not dump).
    public var touchedPathKeys: [String]
    public var lastToolName: String?
    public var lastCommand: String?
    /// Present only when a real source reported input tokens.
    public var tokensIn: Int?
    /// Present only when a real source reported output tokens.
    public var tokensOut: Int?
    /// Present only when a real source reported added lines.
    public var diffAdded: Int?
    /// Present only when a real source reported removed lines.
    public var diffRemoved: Int?

    public static let maxTrackedPaths = 32

    public static let empty = SessionStats(
        toolUseCount: 0,
        filesTouchedCount: 0,
        touchedPathKeys: [],
        lastToolName: nil,
        lastCommand: nil,
        tokensIn: nil,
        tokensOut: nil,
        diffAdded: nil,
        diffRemoved: nil
    )

    public init(
        toolUseCount: Int = 0,
        filesTouchedCount: Int = 0,
        touchedPathKeys: [String] = [],
        lastToolName: String? = nil,
        lastCommand: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil
    ) {
        self.toolUseCount = max(0, toolUseCount)
        self.filesTouchedCount = max(0, filesTouchedCount)
        self.touchedPathKeys = touchedPathKeys
        self.lastToolName = lastToolName
        self.lastCommand = lastCommand
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
    }

    /// Record a unique file path if capacity remains. Returns whether the set grew.
    @discardableResult
    public mutating func recordTouchedPath(_ path: String) -> Bool {
        let key = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        if touchedPathKeys.contains(key) { return false }
        if touchedPathKeys.count >= Self.maxTrackedPaths {
            return false
        }
        touchedPathKeys.append(key)
        filesTouchedCount = touchedPathKeys.count
        return true
    }

    /// Merge token/diff metrics only when the source provided values.
    public mutating func mergeMetrics(
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil
    ) {
        if let tokensIn { self.tokensIn = tokensIn }
        if let tokensOut { self.tokensOut = tokensOut }
        if let diffAdded { self.diffAdded = diffAdded }
        if let diffRemoved { self.diffRemoved = diffRemoved }
    }

    /// `↑ 12.0k / 3.1k` style when either token field is known.
    /// Only renders directions that were actually reported (no synthetic zeros).
    public var tokensMetaLine: String? {
        switch (tokensIn, tokensOut) {
        case let (i?, o?):
            return "↑ \(Self.compactCount(i)) / \(Self.compactCount(o))"
        case let (i?, nil):
            return "↑ \(Self.compactCount(i))"
        case let (nil, o?):
            return "↓ \(Self.compactCount(o))"
        case (nil, nil):
            return nil
        }
    }

    /// `+12 -3` when either diff field is known.
    /// Only renders sides that were actually reported (no synthetic zeros).
    public var diffMetaLine: String? {
        switch (diffAdded, diffRemoved) {
        case let (a?, r?):
            return "+\(a) −\(r)"
        case let (a?, nil):
            return "+\(a)"
        case let (nil, r?):
            return "−\(r)"
        case (nil, nil):
            return nil
        }
    }

    private static func compactCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1000.0
            return String(format: k >= 10 ? "%.0fk" : "%.1fk", k)
        }
        let m = Double(n) / 1_000_000.0
        return String(format: m >= 10 ? "%.0fM" : "%.1fM", m)
    }

    // MARK: - Codable (missing fields → zeros / nil)

    private enum CodingKeys: String, CodingKey {
        case toolUseCount, filesTouchedCount, touchedPathKeys, lastToolName
        case lastCommand, tokensIn, tokensOut, diffAdded, diffRemoved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolUseCount = try container.decodeIfPresent(Int.self, forKey: .toolUseCount) ?? 0
        filesTouchedCount = try container.decodeIfPresent(Int.self, forKey: .filesTouchedCount) ?? 0
        touchedPathKeys = try container.decodeIfPresent([String].self, forKey: .touchedPathKeys) ?? []
        lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        lastCommand = try container.decodeIfPresent(String.self, forKey: .lastCommand)
        tokensIn = try container.decodeIfPresent(Int.self, forKey: .tokensIn)
        tokensOut = try container.decodeIfPresent(Int.self, forKey: .tokensOut)
        diffAdded = try container.decodeIfPresent(Int.self, forKey: .diffAdded)
        diffRemoved = try container.decodeIfPresent(Int.self, forKey: .diffRemoved)
    }
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
    /// Live “what is the agent doing” line (tool, turn, approval, …).
    public var currentActivity: SessionActivity?
    /// Recently finished activities (newest first; bounded by ``SessionActivityPolicy``).
    public var recentActivities: [SessionActivity]
    /// Hook / log-derived stats (tokens/diff only when found).
    public var stats: SessionStats
    /// Tool names the user chose “always allow” for this session (local UI policy only).
    public var sessionAlwaysAllowTools: Set<String>
    /// Local Codex/Claude rollout JSONL path when known (for detail enrichment).
    public var transcriptPath: String?
    /// Latest bounded detail snapshot from local logs (not authoritative for lifecycle).
    public var detailSnapshot: SessionDetailSnapshot?

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
        recentEventIDs: [UUID] = [],
        currentActivity: SessionActivity? = nil,
        recentActivities: [SessionActivity] = [],
        stats: SessionStats = .empty,
        sessionAlwaysAllowTools: Set<String> = [],
        transcriptPath: String? = nil,
        detailSnapshot: SessionDetailSnapshot? = nil
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
        self.currentActivity = currentActivity
        self.recentActivities = recentActivities
        self.stats = stats
        self.sessionAlwaysAllowTools = sessionAlwaysAllowTools
        self.transcriptPath = transcriptPath
        self.detailSnapshot = detailSnapshot
    }

    /// Recovery stub from local transcript metadata — not a live agent session.
    ///
    /// Depends on the **latest** event type (and only falls back to recovery
    /// summary when no live event has arrived yet). Tool/turn events clear the
    /// stub label even if a recovery summary string remains on the session.
    public var isRecoveryStub: Bool {
        if let last = lastEventType, !last.isEmpty {
            return last == "session.reconciled"
        }
        return summary.localizedCaseInsensitiveContains("Recovered from local")
    }

    /// Finished-tool synthetic activity for notch/panel fallbacks (past tense).
    ///
    /// Shared by island and expanded-panel presentation so both surfaces use
    /// the same completion semantics (`Ran` not `Running`).
    public var statsFallbackFinishedToolActivity: SessionActivity? {
        guard let tool = stats.lastToolName, !tool.isEmpty else { return nil }
        return SessionActivity(
            kind: .tool,
            label: tool,
            detail: stats.lastCommand,
            eventType: "stats",
            startedAt: updatedAt,
            endedAt: updatedAt,
            toolName: tool,
            command: stats.lastCommand,
            integration: ToolPayloadExtraction.classify(
                toolName: tool,
                command: stats.lastCommand,
                path: nil,
                detail: nil
            )
        )
    }

    /// Quiet: idle/terminal with nothing actionable.
    public var isQuiet: Bool {
        if state.needsAttention { return false }
        if state == .running { return false }
        if currentActivity?.isActive == true { return false }
        if isRecoveryStub { return true }
        return state == .idle || state.isTerminal
    }

    /// Best single line for live UI: tool activity preferred over "Working"/lifecycle noise.
    ///
    /// When the session is idle/terminal, lead with stop status so rows do not look
    /// like the agent is still running the last tool.
    public var liveStatusLine: String {
        if let current = currentActivity, current.isActive {
            // Prefer real tools; ignore placeholder turn labels.
            if current.kind == .tool || current.kind == .approval || current.kind == .question {
                return current.humanizedTitle
            }
            if current.kind != .turn, !Self.isNoiseStatusText(current.displayLine) {
                return current.displayLine
            }
        }
        if state == .idle || state.isTerminal {
            let status: String = {
                switch state {
                case .completed: return "Done"
                case .failed: return "Failed"
                case .cancelled: return "Cancelled"
                default: return "Idle"
                }
            }()
            if let recent = recentActivities.first(where: { $0.kind == .tool || $0.kind == .approval }) {
                let tool = recent.humanizedTitle
                if !Self.isNoiseStatusText(tool) {
                    return "\(status) · \(tool)"
                }
            }
            if !summary.isEmpty, !Self.isNoiseStatusText(summary) {
                return "\(status) · \(summary)"
            }
            return status
        }
        if let recent = recentActivities.first(where: { $0.kind == .tool || $0.kind == .approval }) {
            return recent.humanizedTitle
        }
        if let recent = recentActivities.first {
            let line = recent.humanizedTitle
            if !Self.isNoiseStatusText(line) { return line }
        }
        if !summary.isEmpty, !Self.isNoiseStatusText(summary) {
            return summary
        }
        return ""
    }

    /// Status strings that should not surface as a "live" subtitle.
    public static func isNoiseStatusText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        let exact: Set<String> = [
            "waiting", "waiting…", "idle", "quiet", "listening",
            "working", "working…", "thinking", "thinking…",
            "session started", "session", "grok session", "completed", "cancelled", "unknown",
            "recovered from local codex history", "recovered from local history",
            "recovered from local grok history", "active grok session (local index)",
        ]
        if exact.contains(lower) { return true }
        if lower.hasPrefix("recovered from local") { return true }
        if lower.hasPrefix("unhandled event") { return true }
        return false
    }

    /// True when text looks like system prompt / instructions dump (not a real last signal).
    public static func isSystemDumpText(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<instructions>") || lower.contains("</instructions>") { return true }
        if lower.contains("agents.md") { return true }
        if lower.contains("# agents.md") { return true }
        if lower.contains("you are a") && lower.contains("assistant") && text.count > 200 {
            return true
        }
        if lower.contains("system prompt") { return true }
        if lower.contains("claude.md") || lower.contains("codex.md") { return true }
        // Huge walls of instruction text.
        if text.count > 600 && (lower.contains("must ") || lower.contains("never ") || lower.contains("guideline")) {
            return true
        }
        return false
    }

    /// Compact age from ``updatedAt`` (falls back to ``createdAt``).
    public var ageDescription: String {
        let reference = max(updatedAt, createdAt)
        return Self.formatAge(from: reference, to: Date())
    }

    /// Row meta fragment for tool / file counts (+ tokens/diff when found).
    /// e.g. `"4 tools · 2 files · ↑ 1.2k / 400 · +12 −3"`.
    public var statsMetaLine: String? {
        var parts: [String] = []
        if stats.toolUseCount > 0 {
            parts.append(stats.toolUseCount == 1 ? "1 tool" : "\(stats.toolUseCount) tools")
        }
        if stats.filesTouchedCount > 0 {
            parts.append(stats.filesTouchedCount == 1 ? "1 file" : "\(stats.filesTouchedCount) files")
        }
        if let tokens = stats.tokensMetaLine {
            parts.append(tokens)
        }
        if let diff = stats.diffMetaLine {
            parts.append(diff)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Normalize a tool name for sticky always-allow matching.
    public static func normalizedToolName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Codable (backward-compatible with pre-activity / pre-stats session files)

    private enum CodingKeys: String, CodingKey {
        case id, source, state, title, summary, workingDirectory
        case createdAt, updatedAt, lastEventType
        case pendingApproval, pendingQuestion, jumpBack
        case rawMetadata, recentEventIDs
        case currentActivity, recentActivities
        case stats
        case sessionAlwaysAllowTools
        case transcriptPath
        case detailSnapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionID.self, forKey: .id)
        source = try container.decode(AgentSource.self, forKey: .source)
        state = try container.decode(SessionState.self, forKey: .state)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastEventType = try container.decodeIfPresent(String.self, forKey: .lastEventType)
        pendingApproval = try container.decodeIfPresent(ApprovalRequest.self, forKey: .pendingApproval)
        pendingQuestion = try container.decodeIfPresent(QuestionPrompt.self, forKey: .pendingQuestion)
        jumpBack = try container.decodeIfPresent(JumpBackContext.self, forKey: .jumpBack)
        rawMetadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .rawMetadata) ?? [:]
        recentEventIDs = try container.decodeIfPresent([UUID].self, forKey: .recentEventIDs) ?? []
        currentActivity = try container.decodeIfPresent(SessionActivity.self, forKey: .currentActivity)
        recentActivities = try container.decodeIfPresent([SessionActivity].self, forKey: .recentActivities) ?? []
        stats = try container.decodeIfPresent(SessionStats.self, forKey: .stats) ?? .empty
        if let tools = try container.decodeIfPresent([String].self, forKey: .sessionAlwaysAllowTools) {
            sessionAlwaysAllowTools = Set(tools.map { Session.normalizedToolName($0) }.filter { !$0.isEmpty })
        } else {
            sessionAlwaysAllowTools = []
        }
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        detailSnapshot = try container.decodeIfPresent(SessionDetailSnapshot.self, forKey: .detailSnapshot)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(state, forKey: .state)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastEventType, forKey: .lastEventType)
        try container.encodeIfPresent(pendingApproval, forKey: .pendingApproval)
        try container.encodeIfPresent(pendingQuestion, forKey: .pendingQuestion)
        try container.encodeIfPresent(jumpBack, forKey: .jumpBack)
        try container.encode(rawMetadata, forKey: .rawMetadata)
        try container.encode(recentEventIDs, forKey: .recentEventIDs)
        try container.encodeIfPresent(currentActivity, forKey: .currentActivity)
        try container.encode(recentActivities, forKey: .recentActivities)
        try container.encode(stats, forKey: .stats)
        try container.encode(sessionAlwaysAllowTools.sorted(), forKey: .sessionAlwaysAllowTools)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try container.encodeIfPresent(detailSnapshot, forKey: .detailSnapshot)
    }

    // MARK: - Formatting helpers

    static func formatAge(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
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
