import Foundation

/// Dynamic Island–style modes for the compact notch extension.
///
/// Visual chrome stays Nocturnal (black top-flush drip). Modes only drive
/// **size + information density**, not glass/neon skins.
public enum PillIslandMode: String, Sendable, Equatable, CaseIterable {
    /// App quiet, socket down.
    case quiet
    /// Socket live, no primary session.
    case listening
    /// One-line live activity.
    case liveCompact
    /// Two-line live activity (agent + tool / path).
    case liveExpanded
    /// Approval or question needs the user.
    case attention
}

/// Structured content for the notch island (pure; UI maps to SwiftUI).
public struct PillIslandContent: Sendable, Equatable {
    public var mode: PillIslandMode
    public var source: AgentSource?
    public var primary: String
    public var secondary: String?
    /// When set, UI renders ``HumanizedActivityLine/verb`` in primary color and
    /// ``HumanizedActivityLine/detail`` in secondary grey.
    public var primaryLine: HumanizedActivityLine?
    public var trailingSources: [AgentSource]
    public var liveCount: Int
    public var attentionCount: Int
    public var sessionId: String?

    public init(
        mode: PillIslandMode,
        source: AgentSource? = nil,
        primary: String,
        secondary: String? = nil,
        primaryLine: HumanizedActivityLine? = nil,
        trailingSources: [AgentSource] = [],
        liveCount: Int = 0,
        attentionCount: Int = 0,
        sessionId: String? = nil
    ) {
        self.mode = mode
        self.source = source
        self.primary = primary
        self.secondary = secondary
        self.primaryLine = primaryLine
        self.trailingSources = trailingSources
        self.liveCount = liveCount
        self.attentionCount = attentionCount
        self.sessionId = sessionId
    }

    public var accessibilitySummary: String {
        var parts = ["Nocturnal", primary]
        if let secondary, !secondary.isEmpty { parts.append(secondary) }
        if attentionCount > 0 { parts.append("\(attentionCount) need attention") }
        if liveCount > 1 { parts.append("\(liveCount) live") }
        return parts.joined(separator: ", ")
    }
}

/// Builds island content from the session store (testable, no SwiftUI).
public enum PillIslandPresentation: Sendable {
    public static func content(
        sessions: [Session],
        socketRunning: Bool
    ) -> PillIslandContent {
        let attentionCount = sessions.filter(\.state.needsAttention).count
        let liveSessions = sessions.filter {
            !$0.isRecoveryStub
                && (
                    $0.state.needsAttention
                        || $0.state == .running
                        || $0.currentActivity?.isActive == true
                        || ($0.stats.lastToolName != nil && !$0.isQuiet)
                )
        }
        let liveCount = liveSessions.count
        let trailing = Array(
            liveSessions
                .map(\.source)
                .filter { $0 != .unknown }
                .reduce(into: [AgentSource]()) { acc, src in
                    if !acc.contains(src) { acc.append(src) }
                }
                .prefix(3)
        )

        guard let session = SessionPrimarySelection.primaryLive(from: sessions) else {
            if socketRunning {
                return PillIslandContent(
                    mode: .listening,
                    primary: "Listening",
                    liveCount: 0,
                    attentionCount: 0
                )
            }
            return PillIslandContent(
                mode: .quiet,
                primary: "Quiet",
                liveCount: 0,
                attentionCount: 0
            )
        }

        let agent = session.source.displayName
        let pathShort = shortPath(session.workingDirectory)

        if session.state.needsAttention {
            let primary: String
            let secondary: String?
            let primaryLine: HumanizedActivityLine?
            if let approval = session.pendingApproval {
                let tool = approval.toolName
                let detail = (approval.detail ?? approval.summary)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty, detail.caseInsensitiveCompare(tool) != .orderedSame {
                    primary = "Approve \(HumanizedActivityLine.prettyToken(tool))"
                    secondary = truncate(detail, 42)
                    primaryLine = HumanizedActivityLine(
                        verb: "Approve",
                        detail: HumanizedActivityLine.compactCommand(detail, limit: 36)
                    )
                } else {
                    primary = "Approve \(HumanizedActivityLine.prettyToken(tool))"
                    secondary = agent
                    primaryLine = HumanizedActivityLine(
                        verb: "Approve",
                        detail: HumanizedActivityLine.prettyToken(tool)
                    )
                }
            } else if let question = session.pendingQuestion {
                primary = "Question"
                secondary = truncate(question.prompt, 42)
                primaryLine = HumanizedActivityLine(
                    verb: "Question",
                    detail: truncate(question.prompt, 42)
                )
            } else if session.state == .failed {
                let live = session.liveStatusLine
                primary = live.isEmpty ? "Failed" : truncate(live, 40)
                secondary = agent
                primaryLine = HumanizedActivityLine(verb: primary)
            } else {
                primary = "Needs you"
                secondary = agent
                primaryLine = HumanizedActivityLine(verb: "Needs you")
            }
            return PillIslandContent(
                mode: .attention,
                source: session.source,
                primary: primary,
                secondary: secondary,
                primaryLine: primaryLine,
                trailingSources: trailing,
                liveCount: max(liveCount, 1),
                attentionCount: attentionCount,
                sessionId: session.id.rawValue
            )
        }

        // Live tool / waiting / idle-with-history.
        if let line = toolLine(for: session) {
            let useExpanded = pathShort != nil || liveCount > 1
            return PillIslandContent(
                mode: useExpanded ? .liveExpanded : .liveCompact,
                source: session.source,
                primary: line.fullLine,
                secondary: useExpanded
                    ? [agent, pathShort].compactMap { $0 }.joined(separator: " · ")
                    : agent,
                primaryLine: line,
                trailingSources: trailing,
                liveCount: max(liveCount, 1),
                attentionCount: attentionCount,
                sessionId: session.id.rawValue
            )
        }

        if session.state == .running {
            let primary: String
            let primaryLine: HumanizedActivityLine
            if let activity = session.currentActivity,
               activity.isActive,
               activity.kind == .turn
            {
                primary = "Thinking…"
                primaryLine = HumanizedActivityLine(verb: "Thinking…")
            } else {
                primary = "Waiting…"
                primaryLine = HumanizedActivityLine(verb: "Waiting…")
            }
            return PillIslandContent(
                mode: .liveExpanded,
                source: session.source,
                primary: primary,
                secondary: [agent, pathShort].compactMap { $0 }.joined(separator: " · "),
                primaryLine: primaryLine,
                trailingSources: trailing,
                liveCount: max(liveCount, 1),
                attentionCount: attentionCount,
                sessionId: session.id.rawValue
            )
        }

        // Idle but still primary (recent tools).
        return PillIslandContent(
            mode: .liveCompact,
            source: session.source,
            primary: "Idle",
            secondary: agent,
            primaryLine: HumanizedActivityLine(verb: "Idle"),
            trailingSources: trailing,
            liveCount: liveCount,
            attentionCount: attentionCount,
            sessionId: session.id.rawValue
        )
    }

    private static func toolLine(for session: Session) -> HumanizedActivityLine? {
        if let activity = session.currentActivity,
           activity.isActive,
           activity.kind == .tool || activity.kind == .approval
        {
            let line = activity.humanizedLine.truncated(limit: 46)
            if !Session.isNoiseStatusText(line.fullLine) {
                return line
            }
        }
        if let recent = session.recentActivities.first(where: {
            $0.kind == .tool || $0.kind == .approval
        }) {
            let line = recent.humanizedLine.truncated(limit: 46)
            if !Session.isNoiseStatusText(line.fullLine) {
                return line
            }
        }
        if let tool = session.stats.lastToolName, !tool.isEmpty {
            let synthetic = SessionActivity(
                kind: .tool,
                label: tool,
                detail: session.stats.lastCommand,
                eventType: "stats",
                startedAt: session.updatedAt,
                endedAt: session.updatedAt, // finished tool — past-tense "Ran" not "Running"
                toolName: tool,
                command: session.stats.lastCommand,
                integration: ToolPayloadExtraction.classify(
                    toolName: tool,
                    command: session.stats.lastCommand,
                    path: nil,
                    detail: nil
                )
            )
            let line = synthetic.humanizedLine.truncated(limit: 46)
            if !Session.isNoiseStatusText(line.fullLine) {
                return line
            }
        }
        return nil
    }

    private static func shortPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= limit { return t }
        let idx = t.index(t.startIndex, offsetBy: max(0, limit - 1))
        return String(t[..<idx]) + "…"
    }
}
