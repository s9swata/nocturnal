import Foundation
import Testing
@testable import NocturnalCore

struct OpenCodeIdentityTests {
    @Test func detectsSesPrefixAndTitles() {
        #expect(OpenCodeSessionIdentity.isOpenCodeSessionId("ses_094d0302dffe1fPl1bx5PAnl7q"))
        #expect(OpenCodeSessionIdentity.isOpenCodeSessionId("opencode:/tmp/proj"))
        #expect(!OpenCodeSessionIdentity.isOpenCodeSessionId("019f6af5-1a0e-7b61-8a7b-425ac003f50b"))
        #expect(OpenCodeSessionIdentity.isOpenCodeTitle("New session - 2026-07-16T13:48:43.347Z"))
        #expect(!OpenCodeSessionIdentity.isOpenCodeTitle("Wire SessionStore"))
    }

    @Test func resolveSourceForcesOpenCodeForSesIdsEvenWhenInferredClaude() {
        let source = OpenCodeSessionIdentity.resolveSource(
            sessionId: "ses_abc123",
            title: nil,
            wireSource: .unknown,
            inferredSource: .claude
        )
        #expect(source == .opencode)
    }

    @Test func resolveSourceForcesOpenCodeForNewSessionTitle() {
        let source = OpenCodeSessionIdentity.resolveSource(
            sessionId: "random-id",
            title: "New session - 2026-07-16T13:48:43.347Z",
            wireSource: .claude,
            inferredSource: .claude
        )
        #expect(source == .opencode)
    }

    @Test func storeApplyRelabelsSesSessionFromClaudeWireToOpenCode() async {
        let store = SessionStore()
        // Simulate poisoned/old path: wire claimed claude but id is OpenCode.
        let session = await store.apply(EventEnvelope(
            source: .claude,
            eventType: "SessionStart",
            sessionId: "ses_mislabel_test",
            payload: [
                "title": .string("New session - 2026-07-16T13:48:43.347Z"),
                "cwd": .string("/tmp/proj"),
            ]
        ))
        #expect(session.source == .opencode)
        #expect(session.title.contains("New session"))
    }

    @Test func storeApplyOpenCodeToolsStayOpenCodeNotClaude() async {
        let store = SessionStore()
        let id = "ses_probe_tools"
        _ = await store.apply(EventEnvelope(
            source: .opencode,
            eventType: "SessionStart",
            sessionId: id,
            payload: ["title": .string("New session - 2026-07-16T13:48:43.347Z")]
        ))
        let afterTool = await store.apply(EventEnvelope(
            source: .unknown, // would historically become Claude
            eventType: "PreToolUse",
            sessionId: id,
            payload: [
                "tool_name": .string("write"),
                "file_path": .string("/tmp/nocturnal-opencode-probe.txt"),
            ]
        ))
        #expect(afterTool.source == .opencode)
        #expect(afterTool.stats.lastToolName == "write" || afterTool.currentActivity?.toolName == "write")
    }

    @Test func softIdleDemotesAgedOpenCodeStartShell() {
        var zombie = Session(
            id: SessionID("ses_zombie"),
            source: .claude, // mislabeled
            state: .running,
            title: "Greeting",
            createdAt: Date().addingTimeInterval(-600),
            updatedAt: Date().addingTimeInterval(-500),
            lastEventType: "SessionStart"
        )
        zombie.currentActivity = SessionActivity(
            kind: .session,
            label: "Session started",
            eventType: "SessionStart",
            startedAt: Date().addingTimeInterval(-600)
        )
        #expect(OpenCodeSessionIdentity.repair(&zombie))
        #expect(zombie.source == .opencode)
        #expect(zombie.state == .idle)
        #expect(zombie.currentActivity == nil)
    }

    @Test func softIdleKeepsFreshOpenCodeStartRunning() {
        var fresh = Session(
            id: SessionID("ses_fresh"),
            source: .opencode,
            state: .running,
            title: "Greeting",
            createdAt: Date().addingTimeInterval(-10),
            updatedAt: Date().addingTimeInterval(-5),
            lastEventType: "SessionStart"
        )
        #expect(OpenCodeSessionIdentity.softIdleIfZombie(&fresh) == false)
        #expect(fresh.state == .running)
    }

    @Test func softIdleDoesNotTouchSessionsWithRecentTools() {
        var busy = Session(
            id: SessionID("ses_busy"),
            source: .opencode,
            state: .running,
            title: "Work",
            createdAt: Date().addingTimeInterval(-600),
            updatedAt: Date(), // still fresh
            lastEventType: "PostToolUse"
        )
        busy.stats.lastToolName = "bash"
        busy.stats.toolUseCount = 3
        #expect(OpenCodeSessionIdentity.softIdleIfZombie(&busy) == false)
        #expect(busy.state == .running)
    }

    @Test func softIdleDemotesStaleOpenCodeWithOldTools() {
        var stale = Session(
            id: SessionID("ses_stale_tools"),
            source: .claude, // mislabeled
            state: .running,
            title: "New session - 2026-07-16T13:48:43.347Z",
            createdAt: Date().addingTimeInterval(-3600),
            updatedAt: Date().addingTimeInterval(-600), // 10 min stale
            lastEventType: "session.updated"
        )
        stale.stats.lastToolName = "write"
        stale.stats.toolUseCount = 5
        #expect(OpenCodeSessionIdentity.repair(&stale))
        #expect(stale.source == .opencode)
        #expect(stale.state == .idle)
    }

    @Test func compositeUnknownSesIdRoutesToOpenCodeNotClaude() {
        let decoder = CompositeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .unknown,
            eventType: "PreToolUse",
            sessionId: "ses_route_test",
            payload: ["tool_name": .string("bash")]
        ))
        #expect(decoded.inferredSource == .opencode)
        #expect(decoded.isUnknown == false)
    }

    @Test func primaryIgnoresBareOpenCodeRunningWhenClaudeHasTools() {
        let now = Date()
        var openCode = Session(
            id: SessionID("ses_bare"),
            source: .opencode,
            state: .running,
            title: "Greeting",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now,
            lastEventType: "session.updated"
        )
        var claude = Session(
            id: SessionID("claude-1"),
            source: .claude,
            state: .running,
            title: "real",
            createdAt: now.addingTimeInterval(-50),
            updatedAt: now.addingTimeInterval(-5),
            lastEventType: "PostToolUse"
        )
        claude.stats.lastToolName = "write"
        claude.recentActivities = [
            SessionActivity(
                kind: .tool,
                label: "write",
                eventType: "PostToolUse",
                startedAt: now.addingTimeInterval(-5),
                endedAt: now.addingTimeInterval(-5),
                toolName: "write"
            ),
        ]
        let primary = SessionPrimarySelection.primaryLive(
            from: [openCode, claude],
            now: now
        )
        #expect(primary?.source == .claude)
        _ = openCode
    }
}
