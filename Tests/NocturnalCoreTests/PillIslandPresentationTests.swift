import Foundation
import Testing
@testable import NocturnalCore

struct PillIslandPresentationTests {
    private let now = Date()

    @Test func quietWhenNoSessionsAndSocketDown() {
        let content = PillIslandPresentation.content(sessions: [], socketRunning: false)
        #expect(content.mode == .quiet)
        #expect(content.primary == "Quiet")
    }

    @Test func listeningWhenSocketUpNoSessions() {
        let content = PillIslandPresentation.content(sessions: [], socketRunning: true)
        #expect(content.mode == .listening)
        #expect(content.primary == "Listening")
    }

    @Test func attentionModeForApproval() {
        var session = Session(
            id: SessionID("s1"),
            source: .codex,
            state: .waitingForApproval,
            title: "Work",
            createdAt: now,
            updatedAt: now
        )
        session.pendingApproval = ApprovalRequest(
            id: "a1",
            sessionId: SessionID("s1"),
            toolName: "bash",
            summary: "git push",
            detail: "git push origin main"
        )
        let content = PillIslandPresentation.content(
            sessions: [session],
            socketRunning: true
        )
        #expect(content.mode == .attention)
        #expect(content.primary.contains("Approve"))
        #expect(content.source == .codex)
        // primaryLine matches primary tool row; command stays on secondary only.
        #expect(content.primaryLine?.verb == "Approve")
        #expect(content.primaryLine?.detail?.lowercased().contains("bash") == true)
        #expect(content.secondary?.contains("git push") == true)
    }

    @Test func attentionModeForQuestionKeepsPromptOnSecondary() {
        var session = Session(
            id: SessionID("s-q"),
            source: .claude,
            state: .waitingForInput,
            title: "Q",
            createdAt: now,
            updatedAt: now
        )
        session.pendingQuestion = QuestionPrompt(
            id: "q1",
            sessionId: SessionID("s-q"),
            prompt: "Which branch should we use?"
        )
        let content = PillIslandPresentation.content(
            sessions: [session],
            socketRunning: true
        )
        #expect(content.mode == .attention)
        #expect(content.primary == "Question")
        #expect(content.primaryLine?.verb == "Question")
        #expect(content.primaryLine?.detail == nil)
        #expect(content.secondary?.contains("branch") == true)
    }

    @Test func idleSessionShowsDoneNotLastToolAsPrimary() {
        var session = Session(
            id: SessionID("s-idle"),
            source: .claude,
            state: .idle,
            title: "Done work",
            workingDirectory: "/Users/demo/Projects/nocturnal",
            createdAt: now,
            updatedAt: now
        )
        session.stats.lastToolName = "write"
        session.recentActivities = [
            SessionActivity(
                kind: .tool,
                label: "write",
                detail: "foo.txt",
                eventType: "PostToolUse",
                startedAt: now,
                endedAt: now,
                toolName: "write",
                primaryPath: "foo.txt"
            ),
        ]
        let content = PillIslandPresentation.content(
            sessions: [session],
            socketRunning: true
        )
        #expect(content.primary == "Idle" || content.primaryLine?.verb == "Idle")
        // Last tool may appear on secondary as context, not as the live primary claim.
        #expect(content.secondary?.lowercased().contains("write") == true
            || content.secondary?.lowercased().contains("foo") == true
            || content.secondary?.lowercased().contains("wrote") == true
            || content.secondary?.lowercased().contains("edited") == true)
    }

    @Test func completedSessionShowsDone() {
        var session = Session(
            id: SessionID("s-done"),
            source: .codex,
            state: .completed,
            title: "Finished",
            createdAt: now,
            updatedAt: now
        )
        session.recentActivities = [
            SessionActivity(
                kind: .tool,
                label: "Bash",
                detail: "swift test",
                eventType: "PostToolUse",
                startedAt: now,
                endedAt: now,
                toolName: "Bash",
                command: "swift test",
                integration: .shell
            ),
        ]
        let content = PillIslandPresentation.content(
            sessions: [session],
            socketRunning: true
        )
        #expect(content.primary == "Done")
        #expect(content.primaryLine?.verb == "Done")
    }

    @Test func liveExpandedWhenToolAndPathPresent() {
        var session = Session(
            id: SessionID("s2"),
            source: .claude,
            state: .running,
            title: "Live",
            workingDirectory: "/Users/demo/Projects/nocturnal",
            createdAt: now,
            updatedAt: now
        )
        session.stats.lastToolName = "write"
        session.recentActivities = [
            SessionActivity(
                kind: .tool,
                label: "write",
                detail: "foo.txt",
                eventType: "PostToolUse",
                startedAt: now,
                endedAt: now,
                toolName: "write",
                primaryPath: "foo.txt"
            ),
        ]
        let content = PillIslandPresentation.content(
            sessions: [session],
            socketRunning: true
        )
        #expect(content.mode == .liveExpanded || content.mode == .liveCompact)
        #expect(content.source == .claude)
        #expect(!content.primary.isEmpty)
        #expect(content.secondary != nil)
    }

    @Test func islandSizesGrowWithMode() {
        let quiet = OverlayGeometry.islandSize(for: .quiet)
        let live = OverlayGeometry.islandSize(for: .liveCompact)
        let expanded = OverlayGeometry.islandSize(for: .liveExpanded)
        let attention = OverlayGeometry.islandSize(for: .attention)
        #expect(quiet.width < live.width)
        #expect(live.width <= expanded.width)
        #expect(expanded.width <= attention.width)
        #expect(quiet.height <= live.height)
        #expect(live.height <= expanded.height)
        // Attention is widest for Deny/Allow chips.
        #expect(attention.width >= 400)
        #expect(OverlayGeometry.islandMaxWidth >= attention.width)
    }

    @Test func attentionIslandIsNotClampedOnTypicalLaptop() {
        // 14" MacBook-class visible width should keep full attention ideal.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let ideal = OverlayGeometry.islandSize(for: .attention)
        let size = OverlayGeometry.clampedIslandSize(for: .attention, visibleFrame: visible)
        #expect(size.width == ideal.width)
        #expect(size.height == ideal.height)
    }

    @Test func clampedIslandNeverExceedsScreenFraction() {
        let narrow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = OverlayGeometry.clampedIslandSize(for: .attention, visibleFrame: narrow)
        #expect(size.width <= 800 * OverlayGeometry.islandMaxScreenFraction + 0.5)
        #expect(size.width >= OverlayGeometry.islandMinWidth)
    }

    @Test func targetSizeUsesIslandModeWhenCompact() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let quiet = OverlayGeometry.targetSize(
            expanded: false,
            visibleFrame: visible,
            islandMode: .quiet
        )
        let attention = OverlayGeometry.targetSize(
            expanded: false,
            visibleFrame: visible,
            islandMode: .attention
        )
        #expect(quiet.width < attention.width)
        #expect(
            OverlayGeometry.targetSize(expanded: true, visibleFrame: visible, islandMode: .quiet)
                == OverlayGeometry.idealExpandedSize
        )
    }
}
