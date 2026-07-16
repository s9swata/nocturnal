import Foundation
import Testing
@testable import NocturnalCore

struct SessionPrimarySelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        id: String,
        source: AgentSource,
        state: SessionState,
        updatedAt: Date,
        lastTool: String? = nil,
        recentToolAt: Date? = nil,
        isRecovery: Bool = false,
        currentTool: Bool = false,
        currentTurn: Bool = false
    ) -> Session {
        var s = Session(
            id: SessionID(id),
            source: source,
            state: state,
            title: id,
            summary: isRecovery ? "Recovered from local OpenCode history" : "",
            createdAt: updatedAt.addingTimeInterval(-100),
            updatedAt: updatedAt,
            lastEventType: isRecovery ? "session.reconciled" : "session.updated"
        )
        if let lastTool {
            s.stats.lastToolName = lastTool
        }
        if let recentToolAt {
            s.recentActivities = [
                SessionActivity(
                    kind: .tool,
                    label: "bash",
                    eventType: "PostToolUse",
                    startedAt: recentToolAt,
                    endedAt: recentToolAt,
                    toolName: "bash"
                ),
            ]
        }
        if currentTool {
            s.currentActivity = SessionActivity(
                kind: .tool,
                label: "read",
                eventType: "PreToolUse",
                startedAt: updatedAt,
                toolName: "read"
            )
        }
        if currentTurn {
            s.currentActivity = SessionActivity(
                kind: .turn,
                label: "Thinking",
                eventType: "agent.turn.started",
                startedAt: updatedAt
            )
        }
        return s
    }

    @Test func softOpenCodeHeartbeatDoesNotBeatClaudeWaitingWithTools() {
        // Repro: Claude finished a tool → "waiting…"; OpenCode still soft-running
        // with fresher session.updated heartbeats and no tools.
        let openCode = session(
            id: "oc-heartbeat",
            source: .opencode,
            state: .running,
            updatedAt: now, // just got session.updated
            lastTool: nil
        )
        let claude = session(
            id: "claude-wait",
            source: .claude,
            state: .running, // still running between tools
            updatedAt: now.addingTimeInterval(-15),
            lastTool: "write",
            recentToolAt: now.addingTimeInterval(-15)
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [openCode, claude],
            now: now
        )
        #expect(primary?.source == .claude)
        #expect(primary?.id.rawValue == "claude-wait")
    }

    @Test func softOpenCodeDoesNotBeatCodexIdleWithTools() {
        let openCode = session(
            id: "oc",
            source: .opencode,
            state: .running,
            updatedAt: now
        )
        let codex = session(
            id: "cx",
            source: .codex,
            state: .idle,
            updatedAt: now.addingTimeInterval(-5),
            lastTool: "shell",
            recentToolAt: now.addingTimeInterval(-5)
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [openCode, codex],
            now: now
        )
        #expect(primary?.source == .codex)
    }

    @Test func freshOpenCodeWithToolsStillWinsOverOldCodex() {
        let openCode = session(
            id: "oc-live",
            source: .opencode,
            state: .running,
            updatedAt: now,
            lastTool: "bash",
            recentToolAt: now.addingTimeInterval(-3)
        )
        let codex = session(
            id: "cx-old",
            source: .codex,
            state: .idle,
            updatedAt: now.addingTimeInterval(-400),
            lastTool: "bash",
            recentToolAt: now.addingTimeInterval(-400)
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [openCode, codex],
            now: now
        )
        #expect(primary?.source == .opencode)
    }

    @Test func activeToolBeatsEverythingExceptAttention() {
        let openCode = session(
            id: "oc",
            source: .opencode,
            state: .running,
            updatedAt: now,
            lastTool: "bash",
            recentToolAt: now
        )
        let claude = session(
            id: "cl",
            source: .claude,
            state: .running,
            updatedAt: now.addingTimeInterval(-1),
            currentTool: true
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [openCode, claude],
            now: now
        )
        #expect(primary?.source == .claude)
    }

    @Test func attentionBeatsActiveTool() {
        let tooling = session(
            id: "oc",
            source: .opencode,
            state: .running,
            updatedAt: now,
            currentTool: true
        )
        var codex = session(
            id: "cx",
            source: .codex,
            state: .waitingForApproval,
            updatedAt: now.addingTimeInterval(-2)
        )
        codex.pendingApproval = ApprovalRequest(
            id: "a1",
            sessionId: SessionID("cx"),
            toolName: "shell",
            summary: "rm"
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [tooling, codex],
            now: now
        )
        #expect(primary?.source == .codex)
        #expect(primary?.state == .waitingForApproval)
    }

    @Test func recoveryStubNeverPrimaryAlone() {
        let recovery = session(
            id: "oc-rec",
            source: .opencode,
            state: .idle,
            updatedAt: now,
            isRecovery: true
        )
        #expect(SessionPrimarySelection.primaryLive(from: [recovery], now: now) == nil)

        let codex = session(
            id: "cx",
            source: .codex,
            state: .idle,
            updatedAt: now.addingTimeInterval(-1),
            lastTool: "read",
            recentToolAt: now.addingTimeInterval(-1)
        )
        let primary = SessionPrimarySelection.primaryLive(
            from: [recovery, codex],
            now: now
        )
        #expect(primary?.source == .codex)
    }

    @Test func bareOpenCodeRunningOnlyWhenNothingElse() {
        let openCode = session(
            id: "oc-bare",
            source: .opencode,
            state: .running,
            updatedAt: now
        )
        let primary = SessionPrimarySelection.primaryLive(from: [openCode], now: now)
        #expect(primary?.source == .opencode)
    }

    @Test func meaningfulActivityIgnoresSoftHeartbeats() {
        let soft = session(
            id: "soft",
            source: .opencode,
            state: .running,
            updatedAt: now
        )
        #expect(SessionPrimarySelection.lastMeaningfulActivityAt(soft) == nil)

        let withTool = session(
            id: "hard",
            source: .claude,
            state: .running,
            updatedAt: now,
            recentToolAt: now.addingTimeInterval(-10)
        )
        let at = SessionPrimarySelection.lastMeaningfulActivityAt(withTool)
        #expect(at != nil)
        #expect(at == now.addingTimeInterval(-10))
    }
}
