import Foundation
import Testing
@testable import NocturnalCore

struct AgentIntegrationTests {
    @Test func firstPartyProfilesSupportInlineDecisions() {
        #expect(AgentRegistry.codex.supportsInlinePermissionDecision)
        #expect(AgentRegistry.claude.supportsInlinePermissionDecision)
        #expect(AgentRegistry.opencode.supportsInlinePermissionDecision)
        #expect(AgentRegistry.codex.decisionTransport == .stdoutJSON)
        #expect(AgentRegistry.opencode.decisionTransport == .http)
    }

    @Test func tierATargetsDoNotShowFakePermissionChips() {
        for profile in [AgentRegistry.cursor, AgentRegistry.kimi, AgentRegistry.grokBuild, AgentRegistry.agy] {
            #expect(profile.capabilities.liveActivity)
            #expect(!profile.supportsInlinePermissionDecision)
            #expect(profile.decisionTransport == .none)
            #expect(!profile.isSetupInstallable)
        }
    }

    @Test func installableMatchesHookProducts() {
        let products = AgentRegistry.installable.compactMap { AgentRegistry.hookProduct(for: $0) }
        #expect(Set(products) == Set(HookProduct.allCases))
    }

    @Test func parsingAliases() {
        #expect(AgentRegistry.profile(parsing: "cursor-agent").id == "cursor")
        #expect(AgentRegistry.profile(parsing: "kimi-code").source == .kimi)
        #expect(AgentRegistry.profile(parsing: "grok").source == .grokBuild)
        #expect(AgentRegistry.profile(parsing: "OpenCode").source == .opencode)
        #expect(AgentSource(parsing: "agy").displayName == "Agy")
    }

    @Test func adHocSourceGetsEnvelopeBridge() {
        let profile = AgentRegistry.profile(parsing: "my-custom-agent")
        #expect(profile.id == "my-custom-agent")
        #expect(profile.capabilities.liveActivity)
        #expect(!profile.supportsInlinePermissionDecision)
    }

    @Test func adapterCatalogRoutesSources() {
        #expect(AgentAdapterCatalog.adapter(for: .codex) is CodexAgentAdapter)
        #expect(AgentAdapterCatalog.adapter(for: .claude) is ClaudeAgentAdapter)
        #expect(AgentAdapterCatalog.adapter(for: .opencode) is OpenCodeAgentAdapter)
        #expect(AgentAdapterCatalog.adapter(for: .cursor).profile.id == "cursor")
    }

    @Test func openCodeHTTPAdapterDetectsSesSessions() {
        let adapter = OpenCodeAgentAdapter()
        let request = ApprovalRequest(
            id: "p1",
            sessionId: SessionID("ses_abc123"),
            toolName: "bash",
            summary: "ls",
            detail: "ls",
            raw: ["permission": .string("perm_1")]
        )
        #expect(adapter.shouldDeliverHTTPPermission(for: request))
    }

    @Test func canonicalNormalizeMapsNativeNames() {
        #expect(CanonicalAgentEvent.normalize("PermissionRequest") == "permission.asked")
        #expect(CanonicalAgentEvent.normalize("PreToolUse") == "tool.started")
        #expect(CanonicalAgentEvent.normalize("agent.turn.started") == "turn.started")
        #expect(CanonicalAgentEvent.normalize("custom.event") == "custom.event")
    }

    @Test func sessionProfileLookup() {
        let now = Date()
        let session = Session(
            id: SessionID("c1"),
            source: .cursor,
            state: .running,
            title: "Work",
            createdAt: now,
            updatedAt: now
        )
        #expect(AgentRegistry.profile(for: session).id == "cursor")
        #expect(session.source.profile.capabilities.liveActivity)
    }

    @Test func sourceDisplayNamesComeFromRegistry() {
        #expect(AgentSource.codex.displayName == "Codex")
        #expect(AgentSource.kimi.displayName == "Kimi Code")
        #expect(AgentSource.grokBuild.displayName == "Grok Build")
    }
}
