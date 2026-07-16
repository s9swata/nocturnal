import Foundation

/// Heuristics so OpenCode sessions are never filed as Claude/Codex.
///
/// OpenCode uses `ses_*` session ids and titles like
/// `New session - 2026-07-16T13:48:43.347Z`. The plugin also maps to
/// Claude/Codex lifecycle names (`SessionStart`, `PreToolUse`, …). When wire
/// `source` is missing or an older build decoded `"opencode"` as unknown,
/// PascalCase events were inferred as **Claude** and persisted wrong.
public enum OpenCodeSessionIdentity: Sendable {
    /// OpenCode native session id prefix (see storage / plugin).
    public static let sessionIdPrefix = "ses_"

    /// Titles OpenCode generates for new chats.
    private static let newSessionTitleRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^New session\s*-\s*\d{4}-\d{2}-\d{2}T"#,
            options: [.caseInsensitive]
        )
    }()

    /// Soft events that do not prove the agent is still working.
    public static let softEventTypes: Set<String> = [
        "SessionStart",
        "session.started",
        "session.created",
        "session.updated",
        "session.status",
        "session.reconciled",
        "UserPromptSubmit",
        "PostToolUse",
        "Stop",
    ]

    /// Grace after create before a no-tool start shell is soft-idled.
    public static let startShellGraceSeconds: TimeInterval = 90

    /// Running sessions with no active tool/approval older than this → idle.
    /// OpenCode rarely emits a reliable idle; stuck "Running" rows pile up.
    public static let staleRunningSeconds: TimeInterval = 3 * 60

    public static func isOpenCodeSessionId(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix(sessionIdPrefix) { return true }
        if id.hasPrefix("opencode:") { return true }
        return false
    }

    public static func isOpenCodeTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let re = newSessionTitleRegex else { return false }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return re.firstMatch(in: t, options: [], range: range) != nil
    }

    /// True when id/title/source already identify OpenCode.
    public static func looksLikeOpenCode(
        sessionId: String,
        title: String? = nil,
        source: AgentSource? = nil
    ) -> Bool {
        if source == .opencode { return true }
        if isOpenCodeSessionId(sessionId) { return true }
        if let title, isOpenCodeTitle(title) { return true }
        return false
    }

    /// Resolve the product source for an incoming envelope.
    public static func resolveSource(
        sessionId: String,
        title: String? = nil,
        wireSource: AgentSource,
        inferredSource: AgentSource
    ) -> AgentSource {
        if looksLikeOpenCode(sessionId: sessionId, title: title, source: wireSource)
            || looksLikeOpenCode(sessionId: sessionId, title: title, source: inferredSource)
        {
            return .opencode
        }
        if wireSource != .unknown { return wireSource }
        if inferredSource != .unknown { return inferredSource }
        return .unknown
    }

    /// Repair a persisted or in-memory session that was mislabeled / stuck running.
    @discardableResult
    public static func repair(
        _ session: inout Session,
        now: Date = Date()
    ) -> Bool {
        var changed = false
        if looksLikeOpenCode(
            sessionId: session.id.rawValue,
            title: session.title,
            source: session.source
        ), session.source != .opencode
        {
            session.source = .opencode
            changed = true
        }
        if softIdleIfZombie(&session, now: now) {
            changed = true
        }
        // Also clear generic stuck "running" rows (e.g. id=unknown from bad hooks).
        if softIdleStaleRunning(&session, now: now) {
            changed = true
        }
        return changed
    }

    /// Any agent: demote `running` when nothing is active and the row is stale.
    /// Prevents ghost "Running" badges from surviving app restarts.
    @discardableResult
    public static func softIdleStaleRunning(
        _ session: inout Session,
        now: Date = Date(),
        staleAfter: TimeInterval = OpenCodeSessionIdentity.staleRunningSeconds
    ) -> Bool {
        guard session.state == .running else { return false }
        guard session.pendingApproval == nil, session.pendingQuestion == nil else {
            return false
        }
        if let activity = session.currentActivity, activity.isActive {
            switch activity.kind {
            case .tool, .turn, .approval, .question:
                return false
            case .session, .notification, .unknown:
                break
            }
        }
        guard now.timeIntervalSince(session.updatedAt) >= staleAfter else {
            return false
        }
        session.state = .idle
        if session.currentActivity?.isActive == true {
            var activity = session.currentActivity
            activity?.endedAt = now
            session.currentActivity = nil
            _ = activity
        } else {
            session.currentActivity = nil
        }
        return true
    }

    /// Demote stuck `running` OpenCode (and ses_* ) sessions that are not actively working.
    ///
    /// Cases:
    /// 1. Start shell: no tools ever, older than ``startShellGraceSeconds``
    /// 2. Stale work: had tools but `updatedAt` older than ``staleRunningSeconds``
    ///    and nothing is mid-tool / awaiting approval
    @discardableResult
    public static func softIdleIfZombie(
        _ session: inout Session,
        now: Date = Date(),
        startGrace: TimeInterval = OpenCodeSessionIdentity.startShellGraceSeconds,
        staleAfter: TimeInterval = OpenCodeSessionIdentity.staleRunningSeconds
    ) -> Bool {
        guard session.source == .opencode || isOpenCodeSessionId(session.id.rawValue) else {
            return false
        }
        guard session.state == .running else { return false }
        guard session.pendingApproval == nil, session.pendingQuestion == nil else {
            return false
        }
        if let activity = session.currentActivity, activity.isActive {
            switch activity.kind {
            case .tool, .turn, .approval, .question:
                return false
            case .session, .notification, .unknown:
                break
            }
        }

        let hasTools = session.stats.toolUseCount > 0
            || session.stats.lastToolName != nil
            || session.recentActivities.contains { $0.kind == .tool }

        let ageSinceCreate = now.timeIntervalSince(session.createdAt)
        let ageSinceUpdate = now.timeIntervalSince(session.updatedAt)

        let isStartShell = !hasTools && ageSinceCreate >= startGrace
        let isStaleWork = hasTools && ageSinceUpdate >= staleAfter
        // Soft heartbeats with no tools and aged updates (session.updated loop).
        let lastType = session.lastEventType ?? ""
        let isSoftHeartbeat = !hasTools
            && ageSinceUpdate >= startGrace
            && (softEventTypes.contains(lastType) || lastType.isEmpty)

        guard isStartShell || isStaleWork || isSoftHeartbeat else {
            return false
        }

        session.state = .idle
        if session.currentActivity?.isActive == true {
            var activity = session.currentActivity
            activity?.endedAt = now
            if let finished = activity {
                session.recentActivities.insert(finished, at: 0)
                if session.recentActivities.count > 12 {
                    session.recentActivities = Array(session.recentActivities.prefix(12))
                }
            }
            session.currentActivity = nil
        }
        return true
    }
}
