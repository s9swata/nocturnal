import Foundation

/// Deterministic demo sessions and envelopes for UI development without live agents.
public enum DemoSessions {
    /// Fixed base date for deterministic timestamps (2023-11-14T22:13:20Z).
    public static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    public static let codexSessionID = SessionID("demo-codex-001")
    public static let claudeSessionID = SessionID("demo-claude-001")
    public static let approvalSessionID = SessionID("demo-approval-001")
    public static let questionSessionID = SessionID("demo-question-001")

    /// Seed sessions for demo mode (stable IDs and titles).
    ///
    /// Prefers `Fixtures/demo/seed-sessions.json` when available (bundle / repo),
    /// otherwise returns the built-in deterministic set. Built-in extras (Claude
    /// idle, question awaiting input) are merged when the fixture omits them so
    /// the answer UI can be exercised without NDJSON simulation.
    public static func seedSessions(fileManager: FileManager = .default) -> [Session] {
        if let fromFile = loadSeedSessionsFromFixture(fileManager: fileManager), !fromFile.isEmpty {
            var sessions = fromFile
            let requiredIDs = [claudeSessionID, questionSessionID]
            for id in requiredIDs where !sessions.contains(where: { $0.id == id }) {
                sessions.append(contentsOf: builtInSeedSessions().filter { $0.id == id })
            }
            return sessions.sorted { $0.updatedAt > $1.updatedAt }
        }
        return builtInSeedSessions()
    }

    public static func builtInSeedSessions() -> [Session] {
        let t0 = baseDate
        return [
            Session(
                id: codexSessionID,
                source: .demo,
                state: .running,
                title: "Refactor SessionStore",
                summary: "Applying actor isolation fixes…",
                workingDirectory: "/Users/demo/Projects/nocturnal",
                createdAt: t0,
                updatedAt: t0.addingTimeInterval(120),
                lastEventType: "agent.turn.started",
                jumpBack: JumpBackContext(
                    workingDirectory: "/Users/demo/Projects/nocturnal",
                    terminalBundleID: TerminalAppJumpStrategy.bundleID
                )
            ),
            Session(
                id: claudeSessionID,
                source: .demo,
                state: .idle,
                title: "Docs pass",
                summary: "Waiting for next prompt",
                workingDirectory: "/Users/demo/Projects/nocturnal/docs",
                createdAt: t0.addingTimeInterval(30),
                updatedAt: t0.addingTimeInterval(90),
                lastEventType: "Stop"
            ),
            Session(
                id: approvalSessionID,
                source: .demo,
                state: .waitingForApproval,
                title: "Install deps",
                summary: "Approve shell command?",
                workingDirectory: "/Users/demo/Projects/app",
                createdAt: t0.addingTimeInterval(60),
                updatedAt: t0.addingTimeInterval(150),
                lastEventType: "tool.approval_required",
                pendingApproval: ApprovalRequest(
                    id: "demo-req-42",
                    sessionId: approvalSessionID,
                    toolName: "shell",
                    summary: "Run `swift build`",
                    detail: "swift build -c debug",
                    riskHint: .low,
                    createdAt: t0.addingTimeInterval(150)
                ),
                jumpBack: JumpBackContext(
                    workingDirectory: "/Users/demo/Projects/app",
                    terminalBundleID: ITerm2JumpStrategy.bundleID
                )
            ),
            Session(
                id: questionSessionID,
                source: .demo,
                state: .waitingForInput,
                title: "Clarify scope",
                summary: "Agent needs a decision",
                workingDirectory: "/Users/demo/Projects/nocturnal",
                createdAt: t0.addingTimeInterval(80),
                updatedAt: t0.addingTimeInterval(180),
                lastEventType: "agent.question",
                pendingQuestion: QuestionPrompt(
                    id: "demo-prompt-7",
                    sessionId: questionSessionID,
                    prompt: "Ship as menu-bar only, or include a support window?",
                    placeholder: "menu-bar only / support window",
                    choices: ["Menu-bar only", "Include support window"],
                    allowFreeform: true,
                    createdAt: t0.addingTimeInterval(180)
                ),
                jumpBack: JumpBackContext(
                    workingDirectory: "/Users/demo/Projects/nocturnal",
                    terminalBundleID: TerminalAppJumpStrategy.bundleID
                )
            ),
        ]
    }

    /// Ordered NDJSON simulation envelopes (deterministic).
    public static func simulationEnvelopes() -> [EventEnvelope] {
        let t0 = baseDate
        return [
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                source: .demo,
                eventType: "session.started",
                sessionId: codexSessionID.rawValue,
                timestamp: t0,
                payload: [
                    "title": .string("Refactor SessionStore"),
                    "cwd": .string("/Users/demo/Projects/nocturnal"),
                ]
            ),
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                source: .demo,
                eventType: "agent.turn.started",
                sessionId: codexSessionID.rawValue,
                timestamp: t0.addingTimeInterval(10),
                payload: [
                    "summary": .string("Applying actor isolation fixes…"),
                ]
            ),
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                source: .demo,
                eventType: "tool.approval_required",
                sessionId: approvalSessionID.rawValue,
                timestamp: t0.addingTimeInterval(20),
                payload: [
                    "request_id": .string("demo-req-42"),
                    "tool": .string("shell"),
                    "summary": .string("Run `swift build`"),
                    "detail": .string("swift build -c debug"),
                    "risk": .string("low"),
                    "title": .string("Install deps"),
                    "cwd": .string("/Users/demo/Projects/app"),
                ]
            ),
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                source: .claude,
                eventType: "SessionStart",
                sessionId: claudeSessionID.rawValue,
                timestamp: t0.addingTimeInterval(30),
                payload: [
                    "title": .string("Docs pass"),
                    "cwd": .string("/Users/demo/Projects/nocturnal/docs"),
                ]
            ),
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
                source: .claude,
                eventType: "Stop",
                sessionId: claudeSessionID.rawValue,
                timestamp: t0.addingTimeInterval(40),
                payload: [
                    "summary": .string("Waiting for next prompt"),
                ]
            ),
            EventEnvelope(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
                source: .demo,
                eventType: "agent.question",
                sessionId: questionSessionID.rawValue,
                timestamp: t0.addingTimeInterval(50),
                payload: [
                    "prompt_id": .string("demo-prompt-7"),
                    "prompt": .string("Ship as menu-bar only, or include a support window?"),
                    "placeholder": .string("menu-bar only / support window"),
                    "title": .string("Clarify scope"),
                    "cwd": .string("/Users/demo/Projects/nocturnal"),
                ]
            ),
        ]
    }

    /// Load seed sessions into a store (demo mode entry point).
    public static func load(into store: SessionStore) async {
        await store.replaceAll(seedSessions())
    }

    /// Replay simulation envelopes into a store.
    public static func replaySimulation(into store: SessionStore) async {
        for envelope in simulationEnvelopes() {
            _ = await store.apply(envelope)
        }
    }

    // MARK: - Fixture loading

    private static func loadSeedSessionsFromFixture(fileManager: FileManager) -> [Session]? {
        let candidates = fixtureCandidateURLs()
        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                try EventEnvelopeDateParsing.decode(from: decoder)
            }
            if let sessions = try? decoder.decode([Session].self, from: data) {
                return sessions
            }
        }
        return nil
    }

    private static func fixtureCandidateURLs() -> [URL] {
        var urls: [URL] = []
        // Packaged app resources
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("Fixtures/demo/seed-sessions.json")
        {
            urls.append(resource)
        }
        // Test bundle
        #if DEBUG
        if let test = Bundle.allBundles
            .compactMap({ $0.resourceURL?.appendingPathComponent("Fixtures/demo/seed-sessions.json") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        {
            urls.append(test)
        }
        #endif
        // Repo-relative from CWD (swift run / simulation)
        let cwd = URL(fileURLWithPath: fileManagerCurrentDirectory(), isDirectory: true)
        urls.append(cwd.appendingPathComponent("Fixtures/demo/seed-sessions.json"))
        // Walk up a few levels for .build runs
        var parent = cwd
        for _ in 0..<5 {
            parent = parent.deletingLastPathComponent()
            urls.append(parent.appendingPathComponent("Fixtures/demo/seed-sessions.json"))
        }
        return urls
    }

    private static func fileManagerCurrentDirectory() -> String {
        FileManager.default.currentDirectoryPath
    }
}
