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

    @Test func multiSourceSessionsCoexist() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "codex-a",
            payload: ["title": .string("Codex work")]
        ))
        _ = await store.apply(EventEnvelope(
            source: .claude,
            eventType: "SessionStart",
            sessionId: "claude-b",
            payload: ["title": .string("Claude work")]
        ))
        let all = await store.allSessions()
        #expect(all.count == 2)
        #expect(all.map(\.source).contains(.codex))
        #expect(all.map(\.source).contains(.claude))
    }

    @Test func questionEnvelopeThenLocalAnswer() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.question",
            sessionId: "q-live",
            payload: [
                "prompt_id": .string("p-live"),
                "prompt": .string("Ship menu-bar only?"),
                "title": .string("Clarify scope"),
            ]
        ))
        let loaded = await store.session(id: SessionID("q-live"))
        #expect(loaded?.state == .waitingForInput)
        #expect(loaded?.pendingQuestion?.id == "p-live")

        let updated = await store.applyLocalResponse(.question(QuestionAnswer(
            promptId: "p-live",
            sessionId: SessionID("q-live"),
            text: "Menu-bar only"
        )))
        #expect(updated?.state == .running)
        #expect(updated?.pendingQuestion == nil)
        #expect(updated?.summary == "Answered")
    }

    @Test func pruneRespectsMaxSessions() async {
        let store = SessionStore(policy: SessionStorePolicy(maxSessions: 2, autoPersist: false))
        for i in 0..<5 {
            _ = await store.apply(EventEnvelope(
                source: .codex,
                eventType: "session.started",
                sessionId: "cap-\(i)",
                payload: ["title": .string("S\(i)")]
            ))
        }
        let all = await store.allSessions()
        #expect(all.count == 2)
    }

    // MARK: - Stale / terminal / response-id / replaceAll

    @Test func olderEventDoesNotReviveTerminalSession() async {
        // Use near-now timestamps so terminalRetention prune does not evict the session.
        let store = SessionStore(
            policy: SessionStorePolicy(terminalRetention: 60 * 60, autoPersist: false)
        )
        let id = "term-1"
        let now = Date()
        let t0 = now.addingTimeInterval(-30)
        let t1 = now.addingTimeInterval(-10)
        let tOld = now.addingTimeInterval(-60)

        let started = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: id,
            timestamp: t0,
            payload: ["title": .string("Done soon")]
        ))
        #expect(started.state == .running)
        #expect(started.updatedAt == t0)

        let completed = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.completed",
            sessionId: id,
            timestamp: t1
        ))
        #expect(completed.state == .completed)
        #expect(completed.updatedAt == t1)
        #expect(await store.session(id: SessionID(id))?.state == .completed)

        // Late/old start must not rewind to running.
        let stale = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: id,
            timestamp: tOld,
            payload: ["title": .string("stale")]
        ))
        #expect(stale.state == .completed)
        #expect(stale.updatedAt == t1)
        let session = await store.session(id: SessionID(id))
        #expect(session?.state == .completed)
        #expect(session?.updatedAt == t1)
    }

    @Test func olderEventDoesNotRewindNewerRunningSession() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        let id = "stale-run"
        let now = Date()
        let newer = now.addingTimeInterval(-5)
        let older = now.addingTimeInterval(-60)

        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: id,
            timestamp: newer,
            payload: ["title": .string("new")]
        ))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.failed",
            sessionId: id,
            timestamp: older,
            payload: ["error": .string("old fail")]
        ))
        let session = await store.session(id: SessionID(id))
        #expect(session?.state == .running)
        #expect(session?.updatedAt == newer)
    }

    @Test func mismatchedApprovalResponseIsNoOp() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "tool.approval_required",
            sessionId: "m-apr",
            payload: [
                "request_id": .string("real-id"),
                "tool": .string("shell"),
                "summary": .string("run"),
            ]
        ))
        let before = await store.session(id: SessionID("m-apr"))
        #expect(before?.state == .waitingForApproval)

        let result = await store.applyLocalResponse(.approval(ApprovalDecision(
            requestId: "wrong-id",
            sessionId: SessionID("m-apr"),
            approved: true
        )))
        #expect(result?.state == .waitingForApproval)
        #expect(result?.pendingApproval?.id == "real-id")
        #expect(result?.summary != "Approved")
    }

    @Test func mismatchedQuestionResponseIsNoOp() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "agent.question",
            sessionId: "m-q",
            payload: [
                "prompt_id": .string("pq-real"),
                "prompt": .string("?"),
            ]
        ))
        let result = await store.applyLocalResponse(.question(QuestionAnswer(
            promptId: "pq-wrong",
            sessionId: SessionID("m-q"),
            text: "nope"
        )))
        #expect(result?.state == .waitingForInput)
        #expect(result?.pendingQuestion?.id == "pq-real")
    }

    @Test func replaceAllHandlesDuplicateIdsLastWinsWithoutTrapping() async {
        let store = SessionStore(policy: SessionStorePolicy(autoPersist: false))
        let first = Session(id: SessionID("dup"), source: .codex, state: .idle, title: "first")
        let second = Session(id: SessionID("dup"), source: .claude, state: .running, title: "second")
        let other = Session(id: SessionID("other"), source: .codex, state: .idle, title: "other")
        await store.replaceAll([first, other, second])

        let all = await store.allSessions()
        #expect(all.count == 2)
        let dup = await store.session(id: SessionID("dup"))
        #expect(dup?.title == "second")
        #expect(dup?.source == .claude)
        #expect(dup?.state == .running)
    }
}
