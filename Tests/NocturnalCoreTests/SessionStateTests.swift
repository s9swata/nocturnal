import Testing
@testable import NocturnalCore

struct SessionStateTests {
    @Test func allCasesAreStable() {
        let raw = SessionState.allCases.map(\.rawValue)
        #expect(raw.contains("running"))
        #expect(raw.contains("waitingForApproval"))
        #expect(raw.contains("waitingForInput"))
        #expect(SessionState.waitingForApproval.needsAttention)
        #expect(SessionState.waitingForInput.needsAttention)
        #expect(SessionState.failed.needsAttention)
        #expect(SessionState.completed.isTerminal)
        #expect(SessionState.failed.isTerminal)
        #expect(SessionState.cancelled.isTerminal)
        #expect(SessionState.running.isTerminal == false)
        #expect(SessionState.idle.needsAttention == false)
    }

    @Test(arguments: [
        ("codex", AgentSource.codex),
        ("Codex", AgentSource.codex),
        ("Claude-Code", AgentSource.claude),
        ("claude", AgentSource.claude),
        ("opencode", AgentSource.opencode),
        ("OpenCode", AgentSource.opencode),
        ("cursor", AgentSource.cursor),
        ("kimi-code", AgentSource.kimi),
        ("grok-build", AgentSource.grokBuild),
        ("agy", AgentSource.agy),
        ("demo", AgentSource.unknown),
        ("nocturnal-demo", AgentSource.unknown),
        ("something-else", AgentSource.unknown),
    ])
    func agentSourceParsing(raw: String, expected: AgentSource) {
        #expect(AgentSource(parsing: raw) == expected)
    }
}
