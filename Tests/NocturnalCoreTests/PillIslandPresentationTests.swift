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
        #expect(attention.width >= 380)
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
