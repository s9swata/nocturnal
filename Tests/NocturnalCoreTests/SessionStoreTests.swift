import Foundation
import Testing
@testable import NocturnalCore

struct SessionStoreTests {
    @Test func applyCodexSessionStarted() async {
        let store = SessionStore()
        let envelope = EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "s1",
            payload: [
                "title": .string("Hello"),
                "cwd": .string("/tmp/project"),
            ]
        )
        let session = await store.apply(envelope)
        #expect(session.id.rawValue == "s1")
        #expect(session.state == .running)
        #expect(session.title == "Hello")
        #expect(session.workingDirectory == "/tmp/project")

        let all = await store.allSessions()
        #expect(all.count == 1)
    }

    @Test func unknownEventsPreserveMetadata() async {
        let store = SessionStore()
        let envelope = EventEnvelope(
            source: .codex,
            eventType: "future.widget.exploded",
            sessionId: "s2",
            raw: ["mystery": .string("value")]
        )
        let session = await store.apply(envelope)
        #expect(session.rawMetadata["mystery"] == .string("value"))
        #expect(session.rawMetadata["unhandledEventType"] == .string("future.widget.exploded"))
        #expect(session.state == .idle)

        let snap = await store.currentSnapshot()
        #expect(snap.unknownEventCount == 1)
    }

    @Test func approvalMapsToWaitingState() async {
        let store = SessionStore()
        let envelope = EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: "s3",
            payload: [
                "request_id": .string("r1"),
                "tool": .string("shell"),
                "summary": .string("rm -rf /"),
                "risk": .string("high"),
            ]
        )
        let session = await store.apply(envelope)
        #expect(session.state == .waitingForApproval)
        #expect(session.pendingApproval?.toolName == "shell")
        #expect(session.pendingApproval?.riskHint == .high)

        let snap = await store.currentSnapshot()
        #expect(snap.sessionsNeedingAttention.count == 1)
    }

    @Test func questionMapsToWaitingForInput() async {
        let store = SessionStore()
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.question",
            sessionId: "s-q",
            payload: [
                "prompt_id": .string("pq-1"),
                "prompt": .string("Continue?"),
            ]
        ))
        let session = await store.session(id: SessionID("s-q"))
        #expect(session?.state == .waitingForInput)
        #expect(session?.pendingQuestion?.id == "pq-1")
    }

    @Test func stateTransitionsThroughLifecycle() async {
        let store = SessionStore()
        let id = "life-1"

        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: id,
            payload: ["title": .string("Lifecycle")]
        ))
        #expect(await store.session(id: SessionID(id))?.state == .running)

        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: id,
            payload: [
                "request_id": .string("apr"),
                "tool": .string("shell"),
                "summary": .string("ok?"),
            ]
        ))
        #expect(await store.session(id: SessionID(id))?.state == .waitingForApproval)

        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_resolved",
            sessionId: id,
            payload: ["request_id": .string("apr"), "approved": .bool(true)]
        ))
        let afterResolve = await store.session(id: SessionID(id))
        #expect(afterResolve?.state == .running)
        #expect(afterResolve?.pendingApproval == nil)

        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.completed",
            sessionId: id
        ))
        #expect(await store.session(id: SessionID(id))?.state == .completed)
    }

    @Test func applyLocalResponseClearsApproval() async {
        let store = SessionStore()
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: "resp-1",
            payload: [
                "request_id": .string("req-9"),
                "tool": .string("shell"),
                "summary": .string("doit"),
            ]
        ))

        let updated = await store.applyLocalResponse(.approval(ApprovalDecision(
            requestId: "req-9",
            sessionId: SessionID("resp-1"),
            approved: true
        )))
        #expect(updated?.state == .running)
        #expect(updated?.pendingApproval == nil)
        #expect(updated?.summary == "Approved")
    }

    @Test func applyLocalResponseClearsQuestion() async {
        let store = SessionStore()
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.question",
            sessionId: "resp-2",
            payload: [
                "prompt_id": .string("p-2"),
                "prompt": .string("Name?"),
            ]
        ))

        let updated = await store.applyLocalResponse(.question(QuestionAnswer(
            promptId: "p-2",
            sessionId: SessionID("resp-2"),
            text: "Nocturnal"
        )))
        #expect(updated?.state == .running)
        #expect(updated?.pendingQuestion == nil)
        #expect(updated?.summary == "Answered")
    }

    @Test func demoSeedIsDeterministic() async {
        let store = SessionStore()
        await DemoSessions.load(into: store)
        let sessions = await store.allSessions()
        #expect(sessions.count == 4)
        #expect(sessions.map(\.id).contains(DemoSessions.codexSessionID))
        #expect(sessions.map(\.id).contains(DemoSessions.questionSessionID))

        let store2 = SessionStore()
        await DemoSessions.load(into: store2)
        let sessions2 = await store2.allSessions()
        #expect(sessions.map(\.id) == sessions2.map(\.id))
        #expect(sessions.map(\.title) == sessions2.map(\.title))
    }

    @Test func demoSeedIncludesWaitingForInputQuestion() async {
        let builtIn = DemoSessions.builtInSeedSessions()
        let question = builtIn.first { $0.id == DemoSessions.questionSessionID }
        #expect(question != nil)
        #expect(question?.state == .waitingForInput)
        #expect(question?.pendingQuestion?.id == "demo-prompt-7")
        #expect(question?.pendingQuestion?.prompt.contains("menu-bar") == true)

        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        await DemoSessions.load(into: store)
        let loaded = await store.session(id: DemoSessions.questionSessionID)
        #expect(loaded?.state == .waitingForInput)
        #expect(loaded?.pendingQuestion != nil)

        // Local answer path matches UI sheet without NDJSON simulation.
        let updated = await store.applyLocalResponse(.question(QuestionAnswer(
            promptId: "demo-prompt-7",
            sessionId: DemoSessions.questionSessionID,
            text: "Menu-bar only"
        )))
        #expect(updated?.state == .running)
        #expect(updated?.pendingQuestion == nil)
        #expect(updated?.summary == "Answered")
    }

    @Test func replaySimulationAppliesEnvelopes() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        await DemoSessions.replaySimulation(into: store)
        let sessions = await store.allSessions()
        #expect(sessions.isEmpty == false)
        let question = await store.session(id: DemoSessions.questionSessionID)
        #expect(question?.state == .waitingForInput)
        #expect(question?.pendingQuestion?.id == "demo-prompt-7")
    }

    @Test func pruneRespectsMaxSessions() async {
        let store = SessionStore(policy: SessionStorePolicy(maxSessions: 2, autoPersist: false))
        for i in 0..<5 {
            _ = await store.apply(EventEnvelope(
                source: .demo,
                eventType: "session.started",
                sessionId: "cap-\(i)",
                payload: ["title": .string("S\(i)")]
            ))
        }
        let all = await store.allSessions()
        #expect(all.count == 2)
    }
}
