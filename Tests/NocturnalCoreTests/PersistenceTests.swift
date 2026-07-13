import Foundation
import Testing
@testable import NocturnalCore

struct PersistenceTests {
    @Test func saveAndLoadRoundTrip() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-persist")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)
        let session = Session(
            id: SessionID("persist-1"),
            source: .codex,
            state: .running,
            title: "Persist me",
            summary: "hello",
            workingDirectory: "/tmp/work"
        )
        try await persistence.save(session)
        let loaded = try await persistence.load(id: session.id)
        #expect(loaded?.title == "Persist me")
        #expect(loaded?.state == .running)
        #expect(loaded?.workingDirectory == "/tmp/work")
        #expect(loaded?.source == .codex)
    }

    @Test func loadAllSkipsAndQuarantinesCorruption() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-corrupt")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths, quarantineCorrupt: true)

        let good = Session(
            id: SessionID("good-1"),
            source: .claude,
            state: .idle,
            title: "Good"
        )
        try await persistence.save(good)

        let badURL = paths.sessionFile(for: SessionID("bad-1"))
        try Data("not-json{{{{".utf8).write(to: badURL, options: [.atomic])
        #expect(FileManager.default.fileExists(atPath: badURL.path))

        let loaded = try await persistence.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == SessionID("good-1"))

        let skipped = await persistence.lastLoadSkipped
        #expect(skipped.contains(where: { $0.contains("bad-1") }))

        // Corrupt file should be quarantined (moved out of sessions/).
        #expect(FileManager.default.fileExists(atPath: badURL.path) == false)
        let quarantineDir = paths.root.appendingPathComponent("corrupt-sessions", isDirectory: true)
        let quarantined = (try? FileManager.default.contentsOfDirectory(
            at: quarantineDir,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(quarantined.contains(where: { $0.lastPathComponent.contains("bad-1") }))
    }

    @Test func storeHydrateAndAutoPersist() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hydrate")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let store = SessionStore(
            policy: SessionStorePolicy(autoPersist: true),
            persistence: persistence
        )
        _ = await store.apply(EventEnvelope(
            source: .codex,
            eventType: "session.started",
            sessionId: "hyd-1",
            payload: ["title": .string("Hydrated")]
        ))

        let store2 = SessionStore(
            policy: SessionStorePolicy(autoPersist: false),
            persistence: persistence
        )
        let merged = await store2.hydrate(from: persistence)
        #expect(merged >= 1)
        let session = await store2.session(id: SessionID("hyd-1"))
        #expect(session?.title == "Hydrated")
    }

    @Test func deleteRemovesSessionFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-delete")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)
        let session = Session(id: SessionID("del-1"), source: .codex, state: .completed, title: "Bye")
        try await persistence.save(session)
        try await persistence.delete(id: session.id)
        let loaded = try await persistence.load(id: session.id)
        #expect(loaded == nil)
    }

    @Test func settingsStoreRoundTrip() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-settings")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let store = SettingsStore(paths: paths)
        var settings = AppSettings.default
        settings.maxVisibleSessions = 7
        settings.soundEnabled = true
        settings.reduceMotion = true
        try await store.save(settings)

        let store2 = SettingsStore(paths: paths)
        let loaded = try await store2.load()
        #expect(loaded.maxVisibleSessions == 7)
        #expect(loaded.soundEnabled)
        #expect(loaded.reduceMotion)
        #expect(loaded.schemaVersion == AppSettings.currentSchemaVersion)
    }

    /// Old settings JSON with obsolete `demoMode` must still decode without surfacing the key.
    @Test func settingsDecodeToleratesObsoleteDemoModeKey() throws {
        let json = Data(
            #"""
            {
              "schemaVersion": 1,
              "reduceMotion": false,
              "soundEnabled": true,
              "demoMode": true,
              "showFloatingPill": false,
              "maxVisibleSessions": 9
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.soundEnabled)
        #expect(decoded.showFloatingPill == false)
        #expect(decoded.maxVisibleSessions == 9)
        #expect(decoded.schemaVersion == AppSettings.currentSchemaVersion)

        let encoded = try JSONEncoder().encode(decoded)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["demoMode"] == nil)
    }

    /// Regression: custom date strategies must not call `decode(Date.self)` (stack overflow / SIGBUS).
    @Test func customDateStrategyDoesNotRecurse() throws {
        let json = Data(#""2023-11-14T22:13:20Z""#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try EventEnvelopeDateParsing.decode(from: $0) }
        let date = try decoder.decode(Date.self, from: json)
        #expect(abs(date.timeIntervalSince1970 - 1_700_000_000) < 1)
    }

    /// Core is the single source of truth for `NOCTURNAL_SOCKET` + app-support root.
    @Test func resolveHonorsExplicitSocketOverride() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-env")
        defer { cleanup() }

        let shortRoot = try SocketPaths.makeShortTestingRoot(prefix: "nse")
        defer { try? FileManager.default.removeItem(at: shortRoot) }
        let socketPath = SocketPaths.testingSocketPath(in: shortRoot, name: "e.sock")
        #expect(socketPath.path.utf8.count < 100)

        let env: [String: String] = [
            NocturnalEnvironmentKey.appSupport.rawValue: temp.path,
            NocturnalEnvironmentKey.socket.rawValue: socketPath.path,
        ]
        let paths = try PersistencePaths.resolve(environment: env)
        #expect(paths.root.path == temp.path)
        #expect(paths.socketURL.path == socketPath.path)
        #expect(paths.socketURL.path != paths.root.appendingPathComponent("ipc.sock").path)
    }

    @Test func resolveDefaultsSocketUnderAppSupportRoot() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-default")
        defer { cleanup() }

        let env: [String: String] = [
            NocturnalEnvironmentKey.appSupport.rawValue: temp.path,
        ]
        let paths = try PersistencePaths.resolve(environment: env)
        #expect(paths.root.path == temp.path)
        #expect(paths.socketURL.path == temp.appendingPathComponent("ipc.sock").path)
        #expect(PersistencePaths.socketURLOverride(from: env) == nil)
    }

    @Test func testingHelperIgnoresProcessEnvironment() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-test")
        defer { cleanup() }

        // Even if process env has NOCTURNAL_SOCKET, testing() must stay isolated.
        let paths = try PersistencePaths.testing(temporaryDirectory: temp)
        #expect(paths.socketURL.path == paths.root.appendingPathComponent("ipc.sock").path)

        let custom = temp.appendingPathComponent("custom.sock")
        let paths2 = try PersistencePaths.testing(temporaryDirectory: temp, socketURL: custom)
        #expect(paths2.socketURL.path == custom.path)
    }
}
