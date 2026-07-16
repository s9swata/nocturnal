import SwiftUI
import NocturnalCore

/// UI-facing presentation helpers for session state (no business mutation).
enum SessionPresentation {
    static func badgeTitle(_ state: SessionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .running: return "Running"
        case .waitingForApproval: return "Approval"
        case .waitingForInput: return "Question"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    static func badgeColor(_ state: SessionState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return NocturnalPalette.accentAttention
        case .failed:
            return NocturnalPalette.accentDanger
        case .completed:
            return NocturnalPalette.accentSuccess
        case .running:
            return NocturnalPalette.fgSecondary
        case .idle, .cancelled, .unknown:
            return NocturnalPalette.fgSecondary.opacity(0.85)
        }
    }

    /// Semantic color for an activity verb (monochrome only — no cyan).
    static func verbColor(for kind: SessionActivityKind, isActive: Bool = true) -> Color {
        switch kind {
        case .approval, .question:
            return NocturnalPalette.accentAttention
        case .tool:
            return isActive ? NocturnalPalette.accentSuccess : NocturnalPalette.fgSecondary
        case .turn:
            return isActive ? NocturnalPalette.fgPrimary : NocturnalPalette.fgSecondary
        case .notification, .session:
            return NocturnalPalette.fgSecondary
        case .unknown:
            return NocturnalPalette.fgSecondary.opacity(0.85)
        }
    }

    /// Verb color for the session currently driving the pill.
    static func pillVerbColor(for session: Session?) -> Color {
        guard let session else { return NocturnalPalette.fgSecondary }
        if session.state.needsAttention {
            if session.pendingApproval != nil || session.state == .waitingForApproval {
                return NocturnalPalette.accentAttention
            }
            if session.pendingQuestion != nil || session.state == .waitingForInput {
                return NocturnalPalette.accentAttention
            }
            if session.state == .failed {
                return NocturnalPalette.accentDanger
            }
        }
        if let activity = session.currentActivity, activity.isActive {
            return verbColor(for: activity.kind, isActive: true)
        }
        if session.state == .running {
            return NocturnalPalette.accentSuccess
        }
        return NocturnalPalette.fgSecondary
    }

    /// Compact notch copy: **agent** (Codex/Claude) + **tool/action** — not project title fluff.
    ///
    /// - verb: agent source display name (or status when idle)
    /// - detail: tool · command/path (or approval/question summary)
    static func pillParts(
        sessions: [Session],
        socketRunning: Bool
    ) -> (verb: String, detail: String) {
        // Never fall back to a recovery stub or a random old OpenCode row when
        // primary selection returns nil — that caused "OpenCode" on the notch
        // while the user was waiting on Codex/Claude.
        guard let session = primaryLiveSession(from: sessions) else {
            return (socketRunning ? "Listening" : "Quiet", "")
        }

        let agent = session.source.displayName // "Codex" / "Claude" / …

        // 1) Approvals / questions — still show agent first.
        if session.state.needsAttention {
            if let approval = session.pendingApproval {
                let tool = approval.toolName
                let cmd = (approval.detail ?? approval.summary)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cmd.isEmpty, cmd.caseInsensitiveCompare(tool) != .orderedSame {
                    return (agent, truncate("Approve \(tool) · \(cmd)", limit: 42))
                }
                return (agent, truncate("Approve \(tool)", limit: 42))
            }
            if let question = session.pendingQuestion {
                return (agent, truncate("Question · \(question.prompt)", limit: 42))
            }
            if session.state == .failed {
                let live = session.liveStatusLine
                return (agent, live.isEmpty ? "Failed" : truncate(live, limit: 42))
            }
        }

        // 2) Active or last tool — humanized (read Foo.swift / ran git status).
        if let toolLine = pillToolDetail(for: session) {
            return (agent, toolLine)
        }

        // 3) Running with no tool payload:
        // - "thinking…" only when a model turn is actively in flight
        // - otherwise "waiting…" (session open, between tools, or waiting on user)
        // Do not call every `.running` session "thinking" — agents often stay running
        // with nothing happening (esp. OpenCode until session.idle).
        if session.state == .running {
            if let activity = session.currentActivity,
               activity.isActive,
               activity.kind == .turn
            {
                return (agent, "thinking…")
            }
            return (agent, "waiting…")
        }

        // 4) Quiet / idle known session.
        if !session.isRecoveryStub {
            return (agent, "Idle")
        }

        return (socketRunning ? "Listening" : "Quiet", "")
    }

    /// Tool-focused detail for the notch. Never returns placeholder "Working".
    private static func pillToolDetail(for session: Session) -> String? {
        // Prefer in-flight **tool** only (skip turn placeholders).
        if let activity = session.currentActivity,
           activity.isActive,
           activity.kind == .tool || activity.kind == .approval
        {
            let title = activity.humanizedTitle
            if !Session.isNoiseStatusText(title) {
                return truncate(title, limit: 46)
            }
        }
        // Most recent finished tool (ignore interspersed "Working" turns).
        if let recent = session.recentActivities.first(where: {
            $0.kind == .tool || $0.kind == .approval
        }) {
            let title = recent.humanizedTitle
            if !Session.isNoiseStatusText(title) {
                return truncate(title, limit: 46)
            }
        }
        // Stats fallback from last PreToolUse.
        if let tool = session.stats.lastToolName, !tool.isEmpty {
            let synthetic = SessionActivity(
                kind: .tool,
                label: tool,
                detail: session.stats.lastCommand,
                eventType: "stats",
                toolName: tool,
                command: session.stats.lastCommand,
                integration: ToolPayloadExtraction.classify(
                    toolName: tool,
                    command: session.stats.lastCommand,
                    path: nil,
                    detail: nil
                )
            )
            return truncate(synthetic.humanizedTitle, limit: 46)
        }
        return nil
    }

    static func accessibilityLabel(for session: Session) -> String {
        var parts = [
            session.title,
            badgeTitle(session.state),
            session.source.displayName,
        ]
        let live = session.liveStatusLine
        if !live.isEmpty {
            parts.append(live)
        } else if !session.summary.isEmpty {
            parts.append(session.summary)
        }
        if let meta = rowMetaLine(for: session) {
            parts.append(meta)
        }
        if session.pendingApproval != nil {
            parts.append("Pending approval")
        }
        if session.pendingQuestion != nil {
            parts.append("Pending question")
        }
        return parts.joined(separator: ", ")
    }

    /// Rank for list ordering (higher = more important).
    private static func rank(_ session: Session) -> Int {
        if session.state.needsAttention { return 400 }
        if session.state == .running || session.currentActivity?.isActive == true { return 300 }
        if !session.isQuiet && !session.isRecoveryStub { return 200 }
        if session.isRecoveryStub { return 0 }
        return 100
    }

    /// Attention / running first. Recovery stubs last (usually filtered out before this).
    static func sortedForDisplay(_ sessions: [Session], limit: Int) -> [Session] {
        let sorted = sessions.sorted { lhs, rhs in
            let lr = rank(lhs)
            let rr = rank(rhs)
            if lr != rr { return lr > rr }
            return lhs.updatedAt > rhs.updatedAt
        }
        return Array(sorted.prefix(max(1, limit)))
    }

    /// Live list: hide recovered idle stubs unless `includeQuiet` is true.
    static func sessionsForDisplay(
        _ sessions: [Session],
        limit: Int,
        includeQuiet: Bool
    ) -> [Session] {
        let filtered: [Session]
        if includeQuiet {
            filtered = sessions
        } else {
            // Keep anything that needs the user or is actively running.
            // Drop pure recovery stubs and other quiet noise.
            filtered = sessions.filter { session in
                if session.state.needsAttention { return true }
                if session.state == .running { return true }
                if session.currentActivity?.isActive == true { return true }
                if session.isRecoveryStub { return false }
                // Keep non-recovery idle only if it has real recent tool activity.
                if session.state == .idle, !session.recentActivities.isEmpty {
                    return true
                }
                if session.state.isTerminal, !session.recentActivities.isEmpty {
                    return session.updatedAt.timeIntervalSinceNow > -3600 * 6 // last 6h
                }
                return !session.isQuiet
            }
        }
        return sortedForDisplay(filtered, limit: limit)
    }

    static func quietSessionCount(in sessions: [Session]) -> Int {
        sessions.filter(\.isQuiet).count
    }

    static func recoveryStubCount(in sessions: [Session]) -> Int {
        sessions.filter(\.isRecoveryStub).count
    }

    /// Session that should drive the notch live line.
    ///
    /// Delegates to ``SessionPrimarySelection`` so multi-agent ranking is tested
    /// in Core (stale OpenCode "running" must not steal the pill from Codex/Claude).
    static func primaryLiveSession(from sessions: [Session]) -> Session? {
        SessionPrimarySelection.primaryLive(from: sessions)
    }

    /// Compact notch text: activity → summary → quiet / listening.
    static func liveActivityLine(sessions: [Session], socketRunning: Bool) -> String {
        let parts = pillParts(sessions: sessions, socketRunning: socketRunning)
        if parts.detail.isEmpty { return parts.verb }
        if parts.verb.isEmpty { return parts.detail }
        return "\(parts.verb) · \(parts.detail)"
    }

    /// Subtitle under a session row title (live activity / summary).
    static func rowSubtitle(for session: Session) -> String {
        if session.state.needsAttention {
            if let approval = session.pendingApproval {
                let detail = approval.detail ?? approval.summary
                if !detail.isEmpty {
                    return "Approve \(approval.toolName) · \(truncate(detail, limit: 48))"
                }
                return "Needs approval · \(approval.toolName)"
            }
            if let q = session.pendingQuestion {
                return "Question · \(truncate(q.prompt, limit: 48))"
            }
            if session.state == .failed {
                let live = session.liveStatusLine
                return live.isEmpty ? "Failed" : live
            }
        }

        let live = session.liveStatusLine
        if !live.isEmpty { return live }

        if session.isRecoveryStub {
            return "Local recovery · not live"
        }

        switch session.state {
        case .idle:
            return "Idle"
        case .running:
            // Match notch: only claim "thinking" when a turn activity is live.
            if let activity = session.currentActivity,
               activity.isActive,
               activity.kind == .turn
            {
                return "Thinking…"
            }
            return "Waiting…"
        case .completed:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .waitingForApproval:
            return "Needs approval"
        case .waitingForInput:
            return "Needs input"
        case .unknown:
            return session.source.displayName
        }
    }

    /// Meta fragment under the subtitle: age · tools · tokens/diff when known.
    /// Omits age-only lines for empty recovery stubs (less visual noise).
    static func rowMetaLine(for session: Session) -> String? {
        var parts: [String] = []
        if !session.isRecoveryStub || session.stats.toolUseCount > 0 {
            parts.append(session.ageDescription)
        }
        if let stats = session.statsMetaLine {
            parts.append(stats)
        }
        guard !parts.isEmpty else { return nil }
        // Recovery with only age is boring — skip.
        if session.isRecoveryStub, parts.count == 1 { return nil }
        return parts.joined(separator: " · ")
    }

    /// Integration chips for a session (from current + recent activities).
    static func integrationChips(for session: Session) -> [ActivityIntegration] {
        var seen = Set<ActivityIntegration>()
        var order: [ActivityIntegration] = []
        let activities = [session.currentActivity].compactMap { $0 } + session.recentActivities
        for activity in activities {
            guard let integration = activity.integration, integration != .unknown else { continue }
            if seen.insert(integration).inserted {
                order.append(integration)
            }
            if order.count >= 4 { break }
        }
        return order
    }

    /// Numbered plan steps when detail looks like a list.
    static func planSteps(from detail: String) -> [String]? {
        let lines = detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let numbered = lines.filter { line in
            if line.first?.isNumber == true { return true }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
            return false
        }
        guard numbered.count >= 2 else { return nil }
        return Array(numbered.prefix(8))
    }

    /// True when detail looks like code / patch (use monospaced block).
    static func looksLikeCode(_ detail: String) -> Bool {
        let sample = detail.prefix(400)
        if sample.contains("```") { return true }
        if sample.contains("func ") || sample.contains("import ") || sample.contains("class ") {
            return true
        }
        if sample.contains("diff --git") || sample.contains("@@ ") { return true }
        let braces = sample.filter { "{}();".contains($0) }.count
        return braces >= 6 && sample.contains("\n")
    }

    /// Short jump-surface badge from known jump-back context.
    static func jumpSurfaceBadge(for session: Session) -> String? {
        guard let jump = session.jumpBack else {
            return session.workingDirectory != nil ? "Finder" : nil
        }
        if jump.codexDeepLink != nil { return "Codex" }
        if let editor = jump.editorURL?.scheme?.lowercased() {
            if editor.contains("cursor") { return "Cursor" }
            if editor.contains("vscode") || editor == "vscode" { return "VS Code" }
            return "Editor"
        }
        if let bundle = jump.terminalBundleID?.lowercased() {
            if bundle.contains("ghostty") { return "Ghostty" }
            if bundle.contains("iterm") { return "iTerm" }
            if bundle.contains("terminal") { return "Terminal" }
            return "Terminal"
        }
        if jump.workingDirectory != nil || session.workingDirectory != nil {
            return "Finder"
        }
        return nil
    }

    /// SF Symbol for a timeline row (generic monochrome mapping).
    static func activitySymbolName(for activity: SessionActivity) -> String {
        let key = (activity.label + " " + (activity.detail ?? "") + " " + activity.eventType)
            .lowercased()
        if key.contains("shell") || key.contains("bash") || key.contains("terminal")
            || key.contains("command") || key.contains("exec")
        {
            return "terminal"
        }
        if key.contains("read") || key.contains("cat") || key.contains("view")
            || key.contains("open")
        {
            return "doc"
        }
        if key.contains("write") || key.contains("edit") || key.contains("patch")
            || key.contains("apply") || key.contains("create")
        {
            return "pencil"
        }
        if key.contains("git") || key.contains("branch") || key.contains("commit") {
            return "arrow.triangle.branch"
        }
        switch activity.kind {
        case .approval:
            return "hand.raised"
        case .question:
            return "questionmark.circle"
        case .turn:
            return "text.bubble"
        case .session:
            return "circle"
        case .notification:
            return "bell"
        case .tool, .unknown:
            return "circle"
        }
    }

    /// Last finished activity / summary for inspector — never system dumps.
    static func lastActivityLine(for session: Session) -> String? {
        if let signal = session.detailSnapshot?.lastSignalLine {
            return signal
        }
        if let recent = session.recentActivities.first {
            let line = recent.displayLine
            if !Session.isNoiseStatusText(line), !Session.isSystemDumpText(line) {
                return line
            }
        }
        if let current = session.currentActivity {
            let line = current.displayLine
            if !Session.isNoiseStatusText(line), !Session.isSystemDumpText(line) {
                return line
            }
        }
        return nil
    }

    /// Timeline rows worth showing (drop pure lifecycle noise when better events exist).
    static func timelineItems(for session: Session) -> [SessionActivity] {
        var list: [SessionActivity] = []
        var seen = Set<UUID>()
        if let current = session.currentActivity, seen.insert(current.id).inserted {
            list.append(current)
        }
        for recent in session.recentActivities where seen.insert(recent.id).inserted {
            list.append(recent)
        }
        if let detailRows = session.detailSnapshot?.recentToolRows {
            for row in detailRows where seen.insert(row.id).inserted {
                list.append(row)
            }
        }

        let meaningful = list.filter { activity in
            if activity.kind == .tool || activity.kind == .approval || activity.kind == .question {
                return true
            }
            if activity.kind == .turn {
                return !Session.isNoiseStatusText(activity.displayLine)
            }
            // Keep session lifecycle only if we have almost nothing else.
            return false
        }
        if meaningful.isEmpty {
            return Array(list.prefix(6))
        }
        return Array(meaningful.prefix(24))
    }

    static func truncate(_ text: String, limit: Int = 42) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<idx]) + "…"
    }
}
