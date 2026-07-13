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

        let codexSide = paths.responseSidecarFile(agent: "codex", requestId: "req-approve-1")
        let claudeSide = paths.responseSidecarFile(agent: "claude", requestId: "req-approve-1")
        #expect(FileManager.default.fileExists(atPath: codexSide.path))
        #expect(FileManager.default.fileExists(atPath: claudeSide.path))
        // Sidecars live under subdirs — never flat next to envelopes.
        #expect(codexSide.path.contains("/codex/"))
        #expect(claudeSide.path.contains("/claude/"))

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

        let side = paths.responseSidecarFile(agent: "answer", requestId: "prompt-9")
        #expect(FileManager.default.fileExists(atPath: side.path))
        #expect(side.path.contains("/answer/"))
    }

    /// Envelope id `codex-x` and Codex sidecar for id `x` must never share a path.
    @Test func envelopeAndSidecarNamespacesDoNotCollide() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-resp-ns")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let transport = FileResponseTransport(paths: paths, writeAgentSidecars: true)

        // Sidecar for request "x" → responses/codex/<encoded x>.json
        try await transport.submit(.approval(ApprovalDecision(
            requestId: "x",
            sessionId: SessionID("s"),
            approved: true
        )))

        // Envelope for request "codex-x" → responses/<encoded codex-x>.json
        try await transport.submit(.approval(ApprovalDecision(
            requestId: "codex-x",
            sessionId: SessionID("s"),
            approved: false
        )))

        let envelopeX = paths.responseFile(for: "x")
        let envelopeCodexX = paths.responseFile(for: "codex-x")
        let sidecarX = paths.responseSidecarFile(agent: "codex", requestId: "x")
        let sidecarCodexX = paths.responseSidecarFile(agent: "codex", requestId: "codex-x")

        // All four paths must be distinct.
        let all = [envelopeX.path, envelopeCodexX.path, sidecarX.path, sidecarCodexX.path]
        #expect(Set(all).count == 4)

        // Older flat layout would have collided: codex-x.json for both.
        let legacyFlatCollision = paths.responsesDirectory
            .appendingPathComponent("codex-x.json").path
        #expect(sidecarX.path != legacyFlatCollision || envelopeCodexX.path != legacyFlatCollision)
        #expect(sidecarX.path != envelopeCodexX.path)

        let loadedX = try transport.load(requestId: "x")
        let loadedCodexX = try transport.load(requestId: "codex-x")
        guard case .approval(let dx)? = loadedX else {
            Issue.record("expected approval for x")
            return
        }
        guard case .approval(let dcx)? = loadedCodexX else {
            Issue.record("expected approval for codex-x")
            return
        }
        #expect(dx.approved == true)
        #expect(dcx.approved == false)

        // Sidecar contents must match their own request ids (no overwrite).
        let sideData = try Data(contentsOf: sidecarX)
        let sideJSON = try JSONSerialization.jsonObject(with: sideData) as? [String: Any]
        #expect(sideJSON?["request_id"] as? String == "x")
        #expect(sideJSON?["approved"] as? Bool == true)

        let sideCodexXData = try Data(contentsOf: sidecarCodexX)
        let sideCodexXJSON = try JSONSerialization.jsonObject(with: sideCodexXData) as? [String: Any]
        #expect(sideCodexXJSON?["request_id"] as? String == "codex-x")
        #expect(sideCodexXJSON?["approved"] as? Bool == false)
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
