import Foundation
import Testing
@testable import NocturnalCore

struct SessionActivityTests {
    @Test func preToolUseSetsCurrentToolActivity() async {
        let store = SessionStore()
        let session = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PreToolUse",
            sessionId: "act-1",
            payload: [
                "tool_name": .string("shell"),
                "command": .string("npm test"),
            ]
        ))
        #expect(session.state == .running)
        #expect(session.currentActivity?.kind == .tool)
        #expect(session.currentActivity?.label == "shell")
        #expect(session.currentActivity?.detail == "npm test")
        #expect(session.currentActivity?.isActive == true)
        #expect(session.liveStatusLine.contains("npm test"))
    }

    @Test func postToolUseArchivesAndKeepsLastToolVisible() async {
        let store = SessionStore()
        let id = "act-2"
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PreToolUse",
            sessionId: id,
            payload: [
                "tool_name": .string("Bash"),
                "command": .string("ls"),
            ]
        ))
        let after = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PostToolUse",
            sessionId: id,
            payload: ["tool_name": .string("Bash")]
        ))
        #expect(after.recentActivities.first?.label == "Bash")
        #expect(after.recentActivities.first?.endedAt != nil)
        // Must NOT clobber with a "Working" turn — notch should keep last tool.
        #expect(after.currentActivity == nil || after.currentActivity?.kind != .turn)
        #expect(after.liveStatusLine.lowercased().contains("ls") || after.liveStatusLine.lowercased().contains("bash") || after.liveStatusLine.lowercased().contains("ran"))
    }

    @Test func humanizedTitlesForReadWriteShell() {
        let now = Date()
        let read = SessionActivity(
            kind: .tool,
            label: "Read",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "Read",
            primaryPath: "/tmp/Foo.swift",
            integration: .read
        )
        #expect(read.humanizedLine.verb == "Read")
        #expect(read.humanizedLine.detail == "Foo.swift")
        #expect(read.humanizedTitle == "Read Foo.swift")

        let write = SessionActivity(
            kind: .tool,
            label: "Write",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "Write",
            primaryPath: "Sources/App.swift",
            integration: .edit
        )
        #expect(write.humanizedLine.verb == "Wrote")
        #expect(write.humanizedTitle == "Wrote App.swift")

        let shell = SessionActivity(
            kind: .tool,
            label: "Bash",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "Bash",
            command: "git status -sb",
            integration: .shell
        )
        #expect(shell.humanizedLine.verb == "Ran")
        #expect(shell.humanizedLine.detail == "git status -sb")
        #expect(shell.humanizedTitle == "Ran git status -sb")

        let running = SessionActivity(
            kind: .tool,
            label: "Bash",
            eventType: "PreToolUse",
            toolName: "run_terminal_command",
            command: "swift test",
            integration: .shell
        )
        #expect(running.humanizedLine.verb == "Running")
        #expect(running.humanizedLine.detail == "swift test")
    }

    @Test func humanizesWebSearchAndGrepAndMCP() {
        let now = Date()
        let search = SessionActivity(
            kind: .tool,
            label: "WebSearch",
            detail: "cursor hooks web search",
            eventType: "postToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "WebSearch",
            integration: .web
        )
        #expect(search.humanizedLine.verb == "Searched")
        #expect(search.humanizedLine.detail?.contains("cursor") == true)

        let grep = SessionActivity(
            kind: .tool,
            label: "grep",
            detail: "HumanizedActivityLine",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "grep"
        )
        #expect(grep.humanizedLine.verb == "Found")

        let mcp = SessionActivity(
            kind: .tool,
            label: "linear__save_issue",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "linear__save_issue",
            integration: .mcp
        )
        #expect(mcp.humanizedLine.verb == "Called")
        #expect(mcp.humanizedLine.detail != nil)
    }

    @Test func humanizedLineTruncatesDetailNotVerb() {
        let now = Date()
        let long = SessionActivity(
            kind: .tool,
            label: "Bash",
            eventType: "PostToolUse",
            startedAt: now,
            endedAt: now,
            toolName: "Bash",
            command: String(repeating: "a", count: 80),
            integration: .shell
        )
        let clipped = long.humanizedLine.truncated(limit: 20)
        #expect(clipped.verb == "Ran")
        #expect(clipped.fullLine.count <= 20)
        #expect(clipped.detail?.hasSuffix("…") == true)
    }

    @Test func truncateHonorsSmallLimitsWithoutOverrun() {
        let line = HumanizedActivityLine(verb: "Running", detail: "swift test --filter All")
        let tight = line.truncated(limit: 8)
        #expect(tight.fullLine.count <= 8)
        let tiny = line.truncated(limit: 3)
        #expect(tiny.fullLine.count <= 3)
    }

    @Test func questionDetailKeepsSlashText() {
        let now = Date()
        let activity = SessionActivity(
            kind: .question,
            label: "Question",
            detail: "Should we use https://example.com/api?",
            eventType: "question.asked",
            startedAt: now
        )
        let line = activity.humanizedLine
        #expect(line.verb == "Question")
        #expect(line.detail?.contains("https://") == true || line.detail?.contains("example") == true)
        #expect(line.detail != "api?")
    }

    @Test func approvalBecomesCurrentActivity() async {
        let store = SessionStore()
        let session = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: "act-3",
            payload: [
                "request_id": .string("r1"),
                "tool": .string("shell"),
                "summary": .string("rm -rf /tmp/x"),
                "detail": .string("rm -rf /tmp/x"),
            ]
        ))
        #expect(session.currentActivity?.kind == .approval)
        #expect(session.currentActivity?.label == "shell")
        // Humanized shell titles use "ran <command>" when command/detail is present.
        let live = session.liveStatusLine.lowercased()
        #expect(live.contains("shell") || live.contains("ran") || live.contains("rm"))
    }

    @Test func sessionStartIsSessionKindNotTurn() async {
        let store = SessionStore()
        let started = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "act-session-start"
        ))
        #expect(started.currentActivity?.kind == .session)
        #expect(started.currentActivity?.label == "Session")
    }

    @Test func turnLifecycleMapsThinkingThenClears() async {
        let store = SessionStore()
        let id = "act-4"
        let started = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.turn.started",
            sessionId: id
        ))
        #expect(started.currentActivity?.kind == .turn)
        #expect(started.currentActivity?.label == "Thinking")

        let done = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.turn.completed",
            sessionId: id
        ))
        #expect(done.currentActivity == nil)
        #expect(done.recentActivities.first?.label == "Thinking")
    }

    @Test func localApprovalEndsActivity() async {
        let store = SessionStore()
        let id = SessionID("act-5")
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: id.rawValue,
            payload: [
                "request_id": .string("apr"),
                "tool": .string("shell"),
                "summary": .string("run"),
            ]
        ))
        let decision = ApprovalDecision(
            requestId: "apr",
            sessionId: id,
            approved: true,
            decidedAt: Date()
        )
        let updated = await store.applyLocalResponse(.approval(decision))
        #expect(updated?.pendingApproval == nil)
        #expect(updated?.currentActivity?.label == "Approved")
    }

    @Test func sessionDecodeWithoutActivityFieldsSucceeds() throws {
        // Pre-activity persistence shape must still hydrate.
        let json = """
        {
          "id": "legacy-1",
          "source": "codex",
          "state": "running",
          "title": "Legacy",
          "summary": "old",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:01Z",
          "rawMetadata": {},
          "recentEventIDs": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Session.self, from: json)
        #expect(session.currentActivity == nil)
        #expect(session.recentActivities.isEmpty)
        #expect(session.title == "Legacy")
        #expect(session.stats == .empty)
        #expect(session.sessionAlwaysAllowTools.isEmpty)
    }
}
