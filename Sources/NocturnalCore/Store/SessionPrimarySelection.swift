import Foundation

/// Picks which session should drive the notch / live line when several agents
/// are present (Codex, Claude, OpenCode).
///
/// ## Why this is strict
/// OpenCode often leaves sessions in ``SessionState/running`` and keeps sending
/// soft events (`session.updated`, status). Ranking by raw `updatedAt` then
/// makes the notch flip to **OpenCode · waiting…** the moment Codex/Claude
/// finish a tool and sit idle between turns — even though the user is still
/// on that other agent.
///
/// Ranking uses **meaningful** activity (tools, turns, approvals), not
/// heartbeat timestamps alone.
public enum SessionPrimarySelection: Sendable {
    /// Bare running with no tools older than this is ignored when another agent
    /// has real tool history.
    public static let bareRunningMaxAge: TimeInterval = 90

    /// Session that should drive the notch live line.
    public static func primaryLive(
        from sessions: [Session],
        now: Date = Date()
    ) -> Session? {
        guard !sessions.isEmpty else { return nil }

        // 1) Needs you (approval / question / fail) — always wins.
        if let attention = best(
            sessions.filter { $0.state.needsAttention },
            by: { $0.updatedAt }
        ) {
            return attention
        }

        // 2) Active tool in flight.
        if let tooling = best(
            sessions.filter {
                $0.currentActivity?.isActive == true
                    && $0.currentActivity?.kind == .tool
            },
            by: { $0.currentActivity?.startedAt ?? $0.updatedAt }
        ) {
            return tooling
        }

        // 3) Active model turn ("thinking") — only when the turn activity is live.
        if let thinking = best(
            sessions.filter {
                $0.currentActivity?.isActive == true
                    && $0.currentActivity?.kind == .turn
            },
            by: { $0.currentActivity?.startedAt ?? $0.updatedAt }
        ) {
            return thinking
        }

        let nonRecovery = sessions.filter { !$0.isRecoveryStub }

        // 4) Most recent **meaningful** work (tool history), idle or running.
        //    Beats OpenCode soft-running heartbeats with no tools.
        if let meaningful = best(
            nonRecovery.filter { lastMeaningfulActivityAt($0) != nil },
            by: { lastMeaningfulActivityAt($0) ?? .distantPast }
        ) {
            return meaningful
        }

        // 5) Bare running (no tool history) — only if nothing better exists.
        //    Prefer non-OpenCode when both are bare shells; OpenCode start shells
        //    are still allowed when they are the only live session.
        let bareRunning = nonRecovery.filter {
            $0.state == .running
                && lastMeaningfulActivityAt($0) == nil
                && now.timeIntervalSince($0.updatedAt) < bareRunningMaxAge
        }
        let barePreferred = bareRunning.filter {
            $0.source != .opencode && !OpenCodeSessionIdentity.isOpenCodeSessionId($0.id.rawValue)
        }
        if let bare = best(
            barePreferred.isEmpty ? bareRunning : barePreferred,
            by: { $0.updatedAt }
        ) {
            return bare
        }

        // 6) Any non-recovery, non-quiet session by recency.
        if let other = best(
            nonRecovery.filter { !$0.isQuiet },
            by: { $0.updatedAt }
        ) {
            return other
        }

        // Never drive the pill from a recovery stub alone.
        return nil
    }

    /// Time of last tool / turn / approval work — **not** soft status heartbeats.
    ///
    /// Returns `nil` when the session has never done real agent work (or only
    /// recovery metadata). Those sessions must not outrank another agent's tools.
    public static func lastMeaningfulActivityAt(_ session: Session) -> Date? {
        if session.state.needsAttention {
            return session.updatedAt
        }
        if let activity = session.currentActivity, activity.isActive {
            switch activity.kind {
            case .tool, .turn, .approval, .question:
                return activity.startedAt
            case .session, .notification, .unknown:
                break
            }
        }
        if let tool = session.recentActivities.first(where: { $0.kind == .tool }) {
            return tool.endedAt ?? tool.startedAt
        }
        if let turn = session.recentActivities.first(where: {
            $0.kind == .turn || $0.kind == .approval
        }) {
            return turn.endedAt ?? turn.startedAt
        }
        // lastToolName without timestamps still counts as "has worked", but
        // use updatedAt only as a weak recency signal — callers prefer sessions
        // that have real activity dates when present.
        if session.stats.lastToolName != nil {
            return session.updatedAt
        }
        return nil
    }

    private static func best(
        _ sessions: [Session],
        by date: (Session) -> Date
    ) -> Session? {
        sessions.max { date($0) < date($1) }
    }
}
