import Foundation
import Testing
@testable import NocturnalCore

struct CodexTranscriptScannerTests {
    @Test func readsOnlySessionMetaHeaderFromTempCodexHome() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-codex-scan")
        defer { cleanup() }
        let sessions = temp.appendingPathComponent(".codex/sessions/2026/07/13", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-test.jsonl")
        let first = #"{"timestamp":"2026-07-13T10:00:00Z","type":"session_meta","payload":{"id":"session-123","timestamp":"2026-07-13T10:00:00Z","cwd":"/tmp/project","cli_version":"0.144.1"}}"#
        // The body is intentionally invalid JSON and must never be parsed.
        try (first + "\n" + String(repeating: "not-json-body\n", count: 10_000))
            .write(to: rollout, atomically: true, encoding: .utf8)

        let scanner = CodexTranscriptScanner.resolve(environment: [
            NocturnalEnvironmentKey.configRoot.rawValue: temp.path,
        ])
        let snapshots = try scanner.scan()
        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snapshot.sessionId == "session-123")
        #expect(snapshot.workingDirectory == "/tmp/project")
        #expect(snapshot.cliVersion == "0.144.1")

        let envelope = snapshot.envelope()
        #expect(envelope.eventType == "session.reconciled")
        #expect(envelope.source == .codex)
    }

    @Test func skipsSymlinksAndHeadersBeyondBound() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-codex-scan-bound")
        defer { cleanup() }
        let sessions = temp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let oversized = sessions.appendingPathComponent("rollout-large.jsonl")
        try (String(repeating: " ", count: 128) + "\n").write(to: oversized, atomically: true, encoding: .utf8)
        let link = sessions.appendingPathComponent("rollout-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oversized)

        let scanner = CodexTranscriptScanner(
            sessionsRoot: sessions,
            maxFiles: 10,
            maxHeaderBytes: 64
        )
        #expect(try scanner.scan().isEmpty)
    }
}
