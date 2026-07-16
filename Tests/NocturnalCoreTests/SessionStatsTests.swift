import Foundation
import Testing
@testable import NocturnalCore

struct SessionStatsTests {
    @Test func preToolUseIncrementsToolCountPostDoesNot() async {
        let store = SessionStore()
        let id = "stats-tools-1"
        for _ in 0..<3 {
            _ = await store.apply(EventEnvelope(
                source: .codex,
                eventType: "PreToolUse",
                sessionId: id,
                payload: [
                    "tool_name": .string("shell"),
                    "command": .string("echo hi"),
                ]
            ))
            _ = await store.apply(EventEnvelope(
                source: .codex,
                eventType: "PostToolUse",
                sessionId: id,
                payload: ["tool_name": .string("shell")]
            ))
        }
        let session = await store.session(id: SessionID(id))
        #expect(session?.stats.toolUseCount == 3)
        #expect(session?.stats.lastToolName == "shell")
    }

    @Test func sameFilePathCountedOnce() async {
        let store = SessionStore()
        let id = "stats-files-1"
        _ = await store.apply(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: id,
            payload: [
                "tool_name": .string("Read"),
                "file_path": .string("/tmp/a.swift"),
            ]
        ))
        _ = await store.apply(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: id,
            payload: [
                "tool_name": .string("Edit"),
                "tool_input": .object([
                    "file_path": .string("/tmp/a.swift"),
                ]),
            ]
        ))
        let session = await store.session(id: SessionID(id))
        #expect(session?.stats.toolUseCount == 2)
        #expect(session?.stats.filesTouchedCount == 1)
        #expect(session?.stats.touchedPathKeys == ["/tmp/a.swift"])
    }

    @Test func nestedToolInputPathIsRecorded() async {
        let store = SessionStore()
        let session = await store.apply(EventEnvelope(
            source: .claude,
            eventType: "PreToolUse",
            sessionId: "stats-nested",
            payload: [
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "path": .string("Sources/App.swift"),
                ]),
            ]
        ))
        #expect(session.stats.filesTouchedCount == 1)
        #expect(session.stats.touchedPathKeys.contains("Sources/App.swift"))
    }

    @Test func commandIsNotTreatedAsFilePath() async {
        let store = SessionStore()
        let session = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PreToolUse",
            sessionId: "stats-cmd",
            payload: [
                "tool_name": .string("shell"),
                "command": .string("rm -rf /tmp/x"),
            ]
        ))
        #expect(session.stats.toolUseCount == 1)
        #expect(session.stats.filesTouchedCount == 0)
    }

    @Test func unknownEventsDoNotChangeStats() async {
        let store = SessionStore()
        let id = "stats-unknown"
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PreToolUse",
            sessionId: id,
            payload: ["tool_name": .string("Read"), "file_path": .string("/a")]
        ))
        let afterUnknown = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.mystery.v99",
            sessionId: id,
            payload: ["tool_name": .string("shell"), "file_path": .string("/b")]
        ))
        #expect(afterUnknown.stats.toolUseCount == 1)
        #expect(afterUnknown.stats.filesTouchedCount == 1)
        #expect(afterUnknown.stats.touchedPathKeys == ["/a"])
    }

    @Test func sessionJSONWithoutStatsAndAlwaysAllowDecodesEmpty() throws {
        let json = """
        {
          "id": "legacy-stats",
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
        #expect(session.stats == .empty)
        #expect(session.sessionAlwaysAllowTools.isEmpty)
        #expect(session.statsMetaLine == nil)
    }

    @Test func applyLocalResponseSessionToolSticky() async {
        let store = SessionStore()
        let id = SessionID("stats-sticky")
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: id.rawValue,
            payload: [
                "request_id": .string("apr-sticky"),
                "tool": .string("Bash"),
                "summary": .string("run tests"),
            ]
        ))
        let decision = ApprovalDecision(
            requestId: "apr-sticky",
            sessionId: id,
            approved: true,
            scope: .sessionTool,
            decidedAt: Date()
        )
        let updated = await store.applyLocalResponse(.approval(decision))
        #expect(updated?.sessionAlwaysAllowTools.contains("bash") == true)
        #expect(updated?.pendingApproval == nil)
        #expect(updated?.summary == "Approved")
    }

    @Test func applyLocalResponseOnceDoesNotSticky() async {
        let store = SessionStore()
        let id = SessionID("stats-once")
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: id.rawValue,
            payload: [
                "request_id": .string("apr-once"),
                "tool": .string("shell"),
                "summary": .string("run"),
            ]
        ))
        let decision = ApprovalDecision(
            requestId: "apr-once",
            sessionId: id,
            approved: true,
            scope: .once,
            decidedAt: Date()
        )
        let updated = await store.applyLocalResponse(.approval(decision))
        #expect(updated?.sessionAlwaysAllowTools.isEmpty == true)
    }

    @Test func denyWithSessionToolDoesNotSticky() async {
        let store = SessionStore()
        let id = SessionID("stats-deny-sticky")
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: id.rawValue,
            payload: [
                "request_id": .string("apr-deny"),
                "tool": .string("shell"),
                "summary": .string("run"),
            ]
        ))
        let decision = ApprovalDecision(
            requestId: "apr-deny",
            sessionId: id,
            approved: false,
            note: "nope",
            scope: .sessionTool,
            decidedAt: Date()
        )
        let updated = await store.applyLocalResponse(.approval(decision))
        #expect(updated?.sessionAlwaysAllowTools.isEmpty == true)
        #expect(updated?.summary == "Denied")
    }

    @Test func presentationHelpersFormatStatsAndDuration() {
        var session = Session(id: SessionID("helpers"), source: .codex)
        session.stats.toolUseCount = 4
        session.stats.filesTouchedCount = 2
        #expect(session.statsMetaLine == "4 tools · 2 files")

        session.stats.filesTouchedCount = 0
        #expect(session.statsMetaLine == "4 tools")

        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_090)
        let activity = SessionActivity(
            kind: .tool,
            label: "shell",
            detail: "npm test",
            eventType: "PreToolUse",
            startedAt: started,
            endedAt: ended,
            toolName: "shell",
            command: "npm test",
            integration: .shell
        )
        // Humanized shell verbs use past/present tense, not the raw tool name.
        #expect(activity.verbToken == "Ran" || activity.verbToken == "Running")
        #expect(activity.durationDescription == "1m")
        #expect(!session.ageDescription.isEmpty)
    }

    @Test func sessionAlwaysAllowToolsRoundTripsAsSortedArray() throws {
        var session = Session(id: SessionID("rt-allow"), source: .claude)
        session.sessionAlwaysAllowTools = ["write", "bash"]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = object?["sessionAlwaysAllowTools"] as? [String]
        #expect(tools == ["bash", "write"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Session.self, from: data)
        #expect(decoded.sessionAlwaysAllowTools == Set(["bash", "write"]))
    }
}
