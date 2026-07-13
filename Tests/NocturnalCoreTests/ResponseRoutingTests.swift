import Foundation
import Testing
@testable import NocturnalCore

struct ResponseRoutingTests {
    @Test func fileTransportWritesApprovalAndSidecars() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-resp")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let transport = FileResponseTransport(paths: paths, writeAgentSidecars: true)
        let decision = ApprovalDecision(
            requestId: "req-approve-1",
            sessionId: SessionID("sess-1"),
            approved: true,
            note: "ok"
        )
        try await transport.submit(.approval(decision))

        let loaded = try transport.load(requestId: "req-approve-1")
        guard case .approval(let roundTripped)? = loaded else {
            Issue.record("Expected approval envelope on disk")
            return
        }
        #expect(roundTripped.requestId == "req-approve-1")
        #expect(roundTripped.approved)
        #expect(roundTripped.note == "ok")

        let codexSide = paths.responsesDirectory.appendingPathComponent("codex-req-approve-1.json")
        let claudeSide = paths.responsesDirectory.appendingPathComponent("claude-req-approve-1.json")
        #expect(FileManager.default.fileExists(atPath: codexSide.path))
        #expect(FileManager.default.fileExists(atPath: claudeSide.path))

        let codexData = try Data(contentsOf: codexSide)
        let codexJSON = try JSONSerialization.jsonObject(with: codexData) as? [String: Any]
        #expect(codexJSON?["approved"] as? Bool == true)
        #expect(codexJSON?["request_id"] as? String == "req-approve-1")

        let claudeData = try Data(contentsOf: claudeSide)
        let claudeJSON = try JSONSerialization.jsonObject(with: claudeData) as? [String: Any]
        #expect(claudeJSON?["permission"] as? String == "allow")
    }

    @Test func fileTransportWritesQuestionAnswer() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-resp-q")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let transport = FileResponseTransport(paths: paths, writeAgentSidecars: true)
        let answer = QuestionAnswer(
            promptId: "prompt-9",
            sessionId: SessionID("sess-2"),
            text: "use main"
        )
        try await transport.submit(.question(answer))

        let loaded = try transport.load(requestId: "prompt-9")
        guard case .question(let roundTripped)? = loaded else {
            Issue.record("Expected question envelope on disk")
            return
        }
        #expect(roundTripped.text == "use main")
        #expect(roundTripped.promptId == "prompt-9")

        let side = paths.responsesDirectory.appendingPathComponent("answer-prompt-9.json")
        #expect(FileManager.default.fileExists(atPath: side.path))
    }

    @Test func inMemoryTransportRecordsSubmissions() async throws {
        let transport = InMemoryResponseTransport()
        try await transport.submit(.approval(ApprovalDecision(
            requestId: "r",
            sessionId: SessionID("s"),
            approved: false
        )))
        try await transport.submit(.question(QuestionAnswer(
            promptId: "p",
            sessionId: SessionID("s"),
            text: "no"
        )))
        let all = await transport.allSubmitted()
        #expect(all.count == 2)
    }

    @Test func multiplexForwardsToAllTransports() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-mux")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let file = FileResponseTransport(paths: paths, writeAgentSidecars: false)
        let memory = InMemoryResponseTransport()
        let mux = MultiplexResponseTransport([file, memory])

        try await mux.submit(.approval(ApprovalDecision(
            requestId: "mux-1",
            sessionId: SessionID("s"),
            approved: true
        )))

        #expect(try file.load(requestId: "mux-1") != nil)
        let submitted = await memory.allSubmitted()
        #expect(submitted.count == 1)
    }

    @Test func endToEndApprovalRouteClearsStoreState() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-e2e-resp")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: "e2e-1",
            payload: [
                "request_id": .string("e2e-req"),
                "tool": .string("shell"),
                "summary": .string("run"),
            ]
        ))

        let decision = ApprovalDecision(
            requestId: "e2e-req",
            sessionId: SessionID("e2e-1"),
            approved: false,
            note: "nope"
        )
        let transport = FileResponseTransport(paths: paths)
        try await transport.submit(.approval(decision))
        let updated = await store.applyLocalResponse(.approval(decision))

        #expect(updated?.state == .running)
        #expect(updated?.pendingApproval == nil)
        #expect(updated?.summary == "Denied")
        #expect(try transport.load(requestId: "e2e-req") != nil)
    }
}
