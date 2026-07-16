import Foundation
import Testing
@testable import NocturnalCore

struct ToolPayloadAndDetailTests {
    @Test func extractsCommandAndPathFromToolInput() {
        let payload: [String: JSONValue] = [
            "tool_name": .string("Bash"),
            "tool_input": .object([
                "command": .string("npm test -- --watch=false"),
            ]),
        ]
        let extracted = ToolPayloadExtraction.extract(from: payload)
        #expect(extracted.toolName == "Bash")
        #expect(extracted.command?.contains("npm test") == true)
        #expect(extracted.integration == .shell)
    }

    @Test func bareStringToolInputCamelCaseBecomesDetail() {
        let payload: [String: JSONValue] = [
            "tool_name": .string("web_search"),
            "toolInput": .string("nocturnal dynamic island"),
        ]
        let extracted = ToolPayloadExtraction.extract(from: payload)
        #expect(extracted.detail == "nocturnal dynamic island")
    }

    @Test func extractsPathAndEditIntegration() {
        let payload: [String: JSONValue] = [
            "tool_name": .string("Edit"),
            "tool_input": .object([
                "file_path": .string("/tmp/project/Sources/App.swift"),
            ]),
        ]
        let extracted = ToolPayloadExtraction.extract(from: payload)
        #expect(extracted.path?.contains("App.swift") == true)
        #expect(extracted.integration == .edit || extracted.integration == .filesystem)
    }

    @Test func extractsTokensWhenPresent() {
        let payload: [String: JSONValue] = [
            "usage": .object([
                "input_tokens": .number(1200),
                "output_tokens": .number(340),
            ]),
        ]
        let extracted = ToolPayloadExtraction.extract(from: payload)
        #expect(extracted.tokensIn == 1200)
        #expect(extracted.tokensOut == 340)
    }

    @Test func preToolUseSetsRichActivityAndStats() async {
        let store = SessionStore()
        let session = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "PreToolUse",
            sessionId: "rich-1",
            payload: [
                "tool_name": .string("shell"),
                "tool_input": .object([
                    "command": .string("swift test"),
                ]),
                "usage": .object([
                    "input_tokens": .number(500),
                    "output_tokens": .number(20),
                ]),
            ]
        ))
        #expect(session.currentActivity?.command?.contains("swift test") == true)
        #expect(session.stats.toolUseCount == 1)
        #expect(session.stats.tokensIn == 500)
        #expect(session.stats.tokensMetaLine != nil)
        #expect(session.statsMetaLine?.contains("1 tool") == true)
    }

    @Test func statsOmitTokensWhenMissing() {
        var stats = SessionStats.empty
        stats.toolUseCount = 2
        #expect(stats.tokensMetaLine == nil)
        #expect(stats.diffMetaLine == nil)
        stats.mergeMetrics(tokensIn: 10, tokensOut: 2, diffAdded: 5, diffRemoved: 1)
        #expect(stats.tokensMetaLine != nil)
        #expect(stats.diffMetaLine == "+5 −1")
    }

    @Test func rolloutTailReaderParsesFixtureFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nocturnal-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"s-tail"}}"#,
            #"{"type":"message","role":"user","content":"Please run tests"}"#,
            #"{"type":"message","role":"assistant","content":"Running the suite now."}"#,
            #"{"type":"tool","tool_name":"shell","payload":{"command":"swift test","usage":{"input_tokens":99,"output_tokens":11}}}"#,
            #"{"type":"event","diff":{"additions":3,"deletions":1}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let reader = CodexRolloutTailReader()
        let detail = reader.read(sessionId: SessionID("s-tail"), transcriptPath: url.path)
        #expect(detail != nil)
        #expect(detail?.lastUserSnippet?.contains("tests") == true)
        #expect(detail?.lastAssistantSnippet?.contains("Running") == true)
        #expect(detail?.tokensIn == 99 || detail?.recentToolRows.isEmpty == false)
    }

    @Test func applyDetailSnapshotMergesMetrics() async {
        let store = SessionStore()
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "detail-1",
            payload: ["transcript_path": .string("/tmp/fake.jsonl")]
        ))
        let detail = SessionDetailSnapshot(
            sessionId: SessionID("detail-1"),
            lastAssistantSnippet: "Done.",
            recentToolRows: [
                SessionActivity(
                    kind: .tool,
                    label: "shell",
                    detail: "echo hi",
                    eventType: "jsonl.tool",
                    command: "echo hi",
                    integration: .shell
                ),
            ],
            tokensIn: 42,
            tokensOut: 7,
            diffAdded: 2,
            diffRemoved: 0,
            source: .jsonl,
            transcriptPath: "/tmp/fake.jsonl"
        )
        let updated = await store.applyDetailSnapshot(detail)
        #expect(updated?.detailSnapshot?.lastAssistantSnippet == "Done.")
        #expect(updated?.stats.tokensIn == 42)
        #expect(updated?.stats.diffAdded == 2)
        #expect(updated?.transcriptPath == "/tmp/fake.jsonl")
    }

    @Test func settingsDefaultsMatchProductChoices() {
        let settings = AppSettings.default
        #expect(settings.readLocalAgentLogs == true)
        #expect(settings.scanLocalListeners == false)
        #expect(settings.schemaVersion == 3)
    }

    @Test func settingsMigrateMissingEnrichmentKeys() throws {
        let json = """
        {"schemaVersion":2,"reduceMotion":false,"soundEnabled":false,"showFloatingPill":true,"maxVisibleSessions":12}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.readLocalAgentLogs == true)
        #expect(decoded.scanLocalListeners == false)
        #expect(decoded.schemaVersion == 3)
    }
}
