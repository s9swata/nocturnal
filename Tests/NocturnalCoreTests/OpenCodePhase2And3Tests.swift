import Foundation
import Testing
@testable import NocturnalCore

struct OpenCodePhase2And3Tests {
    // MARK: - Phase 2 permission client

    @Test func permissionResponseMapping() {
        #expect(OpenCodePermissionResponse.from(approved: true, scope: .once) == .once)
        #expect(OpenCodePermissionResponse.from(approved: true, scope: .sessionTool) == .always)
        #expect(OpenCodePermissionResponse.from(approved: false, scope: .once) == .reject)
        #expect(OpenCodePermissionResponse.from(approved: false, scope: .sessionTool) == .reject)
    }

    @Test func denyMapsToRejectBody() throws {
        let data = OpenCodePermissionClient.requestBody(response: .reject)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["response"] as? String == "reject")
        // Plugin maps Nocturnal deny → reject; allow → once.
        #expect(OpenCodePermissionResponse.from(approved: false, scope: .once).rawValue == "reject")
    }

    @Test func brokerDenyCompletesWaiter() async {
        let broker = PermissionBroker()
        let id = "per_deny_test"
        async let waited = broker.wait(for: id, timeoutSeconds: 2)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await broker.complete(approvalRequestId: id, approved: false, message: "nope")
        let result = await waited
        #expect(result.behavior == .deny)
        #expect(result.message == "nope")
    }

    @Test func permissionURLBuildsPath() {
        let base = URL(string: "http://127.0.0.1:4096")!
        let url = OpenCodePermissionClient.permissionURL(
            base: base,
            sessionId: "ses_abc",
            permissionId: "per_1"
        )
        #expect(url?.absoluteString == "http://127.0.0.1:4096/session/ses_abc/permissions/per_1")
    }

    @Test func permissionBodyIsOpenAPIShape() throws {
        let data = OpenCodePermissionClient.requestBody(response: .once)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["response"] as? String == "once")
        let reject = OpenCodePermissionClient.requestBody(response: .reject)
        let obj2 = try JSONSerialization.jsonObject(with: reject) as? [String: Any]
        #expect(obj2?["response"] as? String == "reject")
    }

    @Test func correlationFromApprovalRequest() {
        let req = ApprovalRequest(
            id: "per_99",
            sessionId: SessionID("ses_1"),
            toolName: "bash",
            summary: "run",
            raw: ["opencode": .bool(true)]
        )
        let pair = OpenCodePermissionClient.correlation(from: req)
        #expect(pair?.sessionId == "ses_1")
        #expect(pair?.permissionId == "per_99")
    }

    @Test func openCodeDecoderTagsApprovalRaw() {
        let decoder = OpenCodeEventDecoder()
        let decoded = decoder.decode(EventEnvelope(
            source: .opencode,
            eventType: "PermissionRequest",
            sessionId: "ses_x",
            payload: [
                "request_id": .string("per_1"),
                "tool": .string("bash"),
                "summary": .string("git push"),
            ]
        ))
        #expect(decoded.state == .waitingForApproval)
        #expect(decoded.approval?.raw["opencode"] == .bool(true))
        #expect(decoded.inferredSource == .opencode)
    }

    @Test func pluginSourceMentionsPhase2DecisionPath() {
        let installer = HookInstaller(
            configRoot: URL(fileURLWithPath: "/tmp"),
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/fwd"),
            socketPath: URL(fileURLWithPath: "/tmp/n.sock"),
            backupsDirectory: URL(fileURLWithPath: "/tmp/b")
        )
        let src = installer.openCodePluginSource()
        #expect(src.contains("sendAndWaitDecision") || src.contains("permission.ask"))
        #expect(src.contains("replyOpenCodePermission") || src.contains("postSessionIdPermissionsPermissionId"))
        #expect(src.contains("permission.ask") || src.contains("permission.asked"))
        #expect(src.contains("nocturnalNeedsDecision") || src.contains("PermissionRequest"))
        #expect(src.contains("/tmp/n.sock") || src.contains("SOCKET_PATH"))
    }

    // MARK: - Phase 3 session scanner

    @Test func scanJSONSessionFilesUnderSandbox() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "oc-scan")
        defer { cleanup() }

        let project = temp
            .appendingPathComponent(".local/share/opencode/storage/session/proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionURL = project.appendingPathComponent("ses_test1.json")
        let body: [String: Any] = [
            "id": "ses_test1",
            "title": "Probe session",
            "directory": "/tmp/proj",
            "time": ["created": 1_700_000_000_000.0, "updated": 1_700_000_100_000.0],
            "summary": ["additions": 3, "deletions": 1, "files": 2],
            "tokens": ["input": 100, "output": 20],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])
        try data.write(to: sessionURL)

        let env = [NocturnalEnvironmentKey.configRoot.rawValue: temp.path]
        let scanner = OpenCodeSessionScanner.resolve(environment: env)
        let snaps = try scanner.scan()
        #expect(snaps.count >= 1)
        let first = try #require(snaps.first)
        #expect(first.sessionId == "ses_test1")
        #expect(first.title == "Probe session")
        #expect(first.workingDirectory == "/tmp/proj")
        #expect(first.diffAdded == 3)
        #expect(first.tokensIn == 100)

        let envelope = first.envelope()
        #expect(envelope.source == .opencode)
        #expect(envelope.eventType == "session.reconciled")
        #expect(envelope.payload["cwd"]?.stringValue == "/tmp/proj")
    }

    @Test func storeAppliesOpenCodeReconciledAsIdleRecovery() async throws {
        let store = SessionStore()
        let snap = OpenCodeSessionSnapshot(
            sessionId: "ses_rec",
            title: "Recovered OC",
            workingDirectory: "/Users/demo/app",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            tokensIn: 50,
            tokensOut: 10,
            diffAdded: 4,
            diffRemoved: 2,
            storagePath: "/tmp/fake.db"
        )
        let session = await store.apply(snap.envelope())
        #expect(session.source == .opencode)
        #expect(session.state == .idle)
        #expect(session.title == "Recovered OC")
        #expect(session.workingDirectory == "/Users/demo/app")
        #expect(session.isRecoveryStub == true || session.lastEventType == "session.reconciled")
        #expect(session.stats.tokensIn == 50 || session.stats.tokensOut == 10
            || session.stats.diffAdded == 4)
    }

    @Test func emptyOpenCodeRootReturnsNoSessions() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "oc-empty")
        defer { cleanup() }
        let scanner = OpenCodeSessionScanner(
            dataRoot: temp.appendingPathComponent("missing-opencode"),
            maxSessions: 10
        )
        let snaps = try scanner.scan()
        #expect(snaps.isEmpty)
    }
}
