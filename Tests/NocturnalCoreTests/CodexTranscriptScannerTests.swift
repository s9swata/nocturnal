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

    @Test func skipsHeadersBeyondBound() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-codex-scan-bound")
        defer { cleanup() }
        let sessions = temp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let oversized = sessions.appendingPathComponent("rollout-large.jsonl")
        // First line longer than maxHeaderBytes → no newline in the bound → skip.
        try (String(repeating: " ", count: 128) + "\n").write(to: oversized, atomically: true, encoding: .utf8)

        let scanner = CodexTranscriptScanner(
            sessionsRoot: sessions,
            maxFiles: 10,
            maxHeaderBytes: 64
        )
        #expect(try scanner.scan().isEmpty)
    }

    @Test func skipsSymlinksEvenWhenTargetIsValid() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-codex-scan-symlink")
        defer { cleanup() }
        let sessions = temp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let real = sessions.appendingPathComponent("rollout-real.jsonl")
        let first = #"{"timestamp":"2026-07-13T10:00:00Z","type":"session_meta","payload":{"id":"session-symlink","cwd":"/tmp"}}"#
        try (first + "\n").write(to: real, atomically: true, encoding: .utf8)
        let link = sessions.appendingPathComponent("rollout-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scanner = CodexTranscriptScanner(
            sessionsRoot: sessions,
            maxFiles: 10,
            maxHeaderBytes: 64 * 1024
        )
        let snaps = try scanner.scan()
        // Real file only — symlink must not double-count or be followed as a candidate.
        #expect(snaps.count == 1)
        #expect(snaps.first?.sessionId == "session-symlink")
    }

    @Test func skipsMalformedCandidateWithoutAbortingScan() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-codex-scan-malformed")
        defer { cleanup() }
        let sessions = temp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let bad = sessions.appendingPathComponent("rollout-bad.jsonl")
        try "not-json\n".write(to: bad, atomically: true, encoding: .utf8)
        let good = sessions.appendingPathComponent("rollout-good.jsonl")
        let first = #"{"timestamp":"2026-07-13T10:00:00Z","type":"session_meta","payload":{"id":"session-good","cwd":"/tmp"}}"#
        try (first + "\n").write(to: good, atomically: true, encoding: .utf8)

        let scanner = CodexTranscriptScanner(sessionsRoot: sessions, maxFiles: 10)
        let snaps = try scanner.scan()
        #expect(snaps.count == 1)
        #expect(snaps.first?.sessionId == "session-good")
    }
}
