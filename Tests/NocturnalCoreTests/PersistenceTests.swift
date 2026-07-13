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

    // MARK: - deleteAll

    @Test func deleteAllRemovesMalformedAndReadableFiles() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-delete-all")
        defer { cleanup() }

        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths, quarantineCorrupt: false)

        try await persistence.save(Session(
            id: SessionID("good"),
            source: .codex,
            state: .idle,
            title: "Good"
        ))
        // Malformed JSON that loadAll would skip.
        let bad = paths.sessionsDirectory.appendingPathComponent("garbage.json")
        try Data("{not-json".utf8).write(to: bad)
        // Non-json noise file.
        let noise = paths.sessionsDirectory.appendingPathComponent("readme.txt")
        try Data("hi".utf8).write(to: noise)
        // Nested directory must survive (metadata safety).
        let nested = paths.sessionsDirectory.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("keep.txt"))

        try await persistence.deleteAll()

        let remaining = try FileManager.default.contentsOfDirectory(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        #expect(remaining.allSatisfy { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        })
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("keep.txt").path))
        #expect(try await persistence.loadAll().isEmpty)
    }

    // MARK: - Path encoding collisions

    @Test func pathEncodingSeparatesSlashAndUnderscoreIds() {
        let aSlashB = PathComponentEncoding.encode("a/b")
        let aUnderB = PathComponentEncoding.encode("a_b")
        #expect(aSlashB != aUnderB)
        #expect(aSlashB == "a%2Fb")
        #expect(aUnderB == "a%5Fb" || aUnderB == "a_b") // `_` is not unreserved → percent
        #expect(PathComponentEncoding.decode(aSlashB) == "a/b")
        #expect(PathComponentEncoding.decode(aUnderB) == "a_b")
    }

    @Test func pathEncodingSeparatesColonCases() {
        let colon = PathComponentEncoding.encode("a:b")
        let under = PathComponentEncoding.encode("a_b")
        let legacyColon = PathComponentEncoding.legacySanitize("a:b")
        #expect(colon != under)
        #expect(colon == "a%3Ab")
        // Legacy collides — documenting why encoding is required.
        #expect(legacyColon == PathComponentEncoding.legacySanitize("a_b")
            || legacyColon == "a_b")
        #expect(legacyColon == "a_b")
    }

    @Test func sessionFilesDoNotCollideForAmbiguousIds() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-path-coll")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)

        let slash = paths.sessionFile(for: SessionID("a/b"))
        let under = paths.sessionFile(for: SessionID("a_b"))
        let colon = paths.sessionFile(for: SessionID("a:b"))
        #expect(slash.path != under.path)
        #expect(colon.path != under.path)
        #expect(Set([slash.path, under.path, colon.path]).count == 3)
    }

    @Test func loadPrefersCanonicalAndFallsBackToLegacy() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-legacy-sess")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        // Write using legacy filename for id with colon (old sanitize).
        let id = SessionID("proj:main")
        let session = Session(id: id, source: .codex, state: .running, title: "Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: paths.legacySessionFile(for: id), options: [.atomic])

        let loaded = try await persistence.load(id: id)
        #expect(loaded?.title == "Legacy")
        #expect(loaded?.id == id)

        // Matching legacy load migrates onto the canonical path.
        let canonical = paths.sessionFile(for: id)
        let legacy = paths.legacySessionFile(for: id)
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
    }

    // MARK: - Legacy filename collision (a/b vs a_b → a_b.json)

    /// Shared legacy name for both IDs under the pre-encoding sanitize.
    private static let ambiguousLegacyName = "a_b.json"

    /// Plant a legacy `a_b.json` whose embedded session id is `a/b`.
    private func plantLegacySlashSession(
        paths: PersistencePaths,
        title: String = "Slash owner"
    ) throws -> (Session, URL) {
        let slashID = SessionID("a/b")
        let session = Session(
            id: slashID,
            source: .codex,
            state: .running,
            title: title
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        // Both a/b and a_b legacy-sanitize to a_b.json.
        let legacyURL = paths.legacySessionFile(for: slashID)
        #expect(legacyURL.lastPathComponent == Self.ambiguousLegacyName)
        #expect(paths.legacySessionFile(for: SessionID("a_b")).path == legacyURL.path)
        try data.write(to: legacyURL, options: [.atomic])
        return (session, legacyURL)
    }

    @Test func loadUnderscoreIdDoesNotClaimForeignLegacySlashFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-leg-claim")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let (slashSession, legacyURL) = try plantLegacySlashSession(paths: paths)
        let before = try Data(contentsOf: legacyURL)

        // load(a_b) must not return, migrate, or rewrite the a/b file.
        let underID = SessionID("a_b")
        let loaded = try await persistence.load(id: underID)
        #expect(loaded == nil)

        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        let after = try Data(contentsOf: legacyURL)
        #expect(after == before)

        // Canonical path for a_b must not appear (no false migration).
        let underCanonical = paths.sessionFile(for: underID)
        #expect(FileManager.default.fileExists(atPath: underCanonical.path) == false)

        // Canonical path for a/b must also remain absent until load(a/b).
        let slashCanonical = paths.sessionFile(for: slashSession.id)
        #expect(FileManager.default.fileExists(atPath: slashCanonical.path) == false)
    }

    @Test func deleteUnderscoreIdDoesNotRemoveForeignLegacySlashFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-leg-del")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let (_, legacyURL) = try plantLegacySlashSession(paths: paths, title: "Keep me")
        let before = try Data(contentsOf: legacyURL)

        try await persistence.delete(id: SessionID("a_b"))

        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        let after = try Data(contentsOf: legacyURL)
        #expect(after == before)

        // Owner can still load via a/b.
        let owned = try await persistence.load(id: SessionID("a/b"))
        #expect(owned?.title == "Keep me")
        #expect(owned?.id == SessionID("a/b"))
    }

    @Test func loadSlashIdMigratesMatchingLegacyFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-leg-mig")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let (slashSession, legacyURL) = try plantLegacySlashSession(paths: paths, title: "Migrate me")
        let slashID = slashSession.id

        let loaded = try await persistence.load(id: slashID)
        #expect(loaded?.id == slashID)
        #expect(loaded?.title == "Migrate me")

        let canonical = paths.sessionFile(for: slashID)
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)

        // Re-load from canonical; underscore id still sees nothing of this file.
        let again = try await persistence.load(id: slashID)
        #expect(again?.title == "Migrate me")
        #expect(try await persistence.load(id: SessionID("a_b")) == nil)
    }

    @Test func saveUnderscoreIdDoesNotDropForeignLegacySlashFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-leg-save")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let (_, legacyURL) = try plantLegacySlashSession(paths: paths, title: "Foreign")
        let before = try Data(contentsOf: legacyURL)

        let under = Session(
            id: SessionID("a_b"),
            source: .claude,
            state: .idle,
            title: "Underscore"
        )
        try await persistence.save(under)

        // Canonical for a_b exists; foreign legacy a_b.json untouched.
        #expect(FileManager.default.fileExists(atPath: paths.sessionFile(for: under.id).path))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try Data(contentsOf: legacyURL) == before)

        let foreign = try await persistence.load(id: SessionID("a/b"))
        #expect(foreign?.title == "Foreign")
        let own = try await persistence.load(id: SessionID("a_b"))
        #expect(own?.title == "Underscore")
    }

    @Test func deleteSlashIdConsumesMatchingLegacyFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-leg-del-ok")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let (_, legacyURL) = try plantLegacySlashSession(paths: paths)
        try await persistence.delete(id: SessionID("a/b"))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        #expect(try await persistence.load(id: SessionID("a/b")) == nil)
    }

    @Test func canonicalSaveAndLoadStillWorksAlongsideLegacySafety() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-can-ok")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)
        let persistence = SessionPersistence(paths: paths)

        let slash = Session(id: SessionID("a/b"), source: .codex, state: .running, title: "Slash")
        let under = Session(id: SessionID("a_b"), source: .claude, state: .idle, title: "Under")
        try await persistence.save(slash)
        try await persistence.save(under)

        #expect(paths.sessionFile(for: slash.id).path != paths.sessionFile(for: under.id).path)
        #expect(try await persistence.load(id: slash.id)?.title == "Slash")
        #expect(try await persistence.load(id: under.id)?.title == "Under")

        try await persistence.delete(id: under.id)
        #expect(try await persistence.load(id: under.id) == nil)
        #expect(try await persistence.load(id: slash.id)?.title == "Slash")
    }

    // MARK: - AppSettings schema protection

    @Test func settingsNeverDowngradeSchema99() throws {
        let json = Data(
            #"""
            {
              "schemaVersion": 99,
              "reduceMotion": true,
              "soundEnabled": true,
              "showFloatingPill": false,
              "maxVisibleSessions": 3,
              "futureOnlyKey": "keep-me"
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.schemaVersion == 99)
        #expect(decoded.reduceMotion)
        #expect(decoded.maxVisibleSessions == 3)
    }

    @Test func settingsLoadDoesNotRewriteNewerSchemaFile() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-settings-99")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)

        let original = Data(
            #"""
            {
              "schemaVersion": 99,
              "reduceMotion": true,
              "soundEnabled": false,
              "showFloatingPill": true,
              "maxVisibleSessions": 4,
              "futureOnlyKey": "preserved"
            }
            """#.utf8
        )
        try original.write(to: paths.settingsFile, options: [.atomic])

        let store = SettingsStore(paths: paths)
        let loaded = try await store.load()
        #expect(loaded.schemaVersion == 99)

        // On-disk bytes must be unchanged after load (no save-on-load rewrite).
        let after = try Data(contentsOf: paths.settingsFile)
        #expect(after == original)
        let object = try JSONSerialization.jsonObject(with: after) as? [String: Any]
        #expect(object?["futureOnlyKey"] as? String == "preserved")
        #expect(object?["schemaVersion"] as? Int == 99)
    }

    @Test func settingsSaveRefusesToOverwriteNewerSchema() async throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-settings-refuse")
        defer { cleanup() }
        let paths = try TestSupport.makePaths(in: temp)

        let original = Data(
            #"{"schemaVersion":99,"reduceMotion":false,"soundEnabled":false,"showFloatingPill":true,"maxVisibleSessions":12,"futureOnlyKey":"x"}"#.utf8
        )
        try original.write(to: paths.settingsFile, options: [.atomic])

        let store = SettingsStore(paths: paths)
        var threw = false
        do {
            try await store.save(AppSettings.default)
        } catch let error as SettingsStoreError {
            threw = true
            guard case .newerSchemaOnDisk(let onDisk, let supported) = error else {
                Issue.record("unexpected SettingsStoreError \(error)")
                return
            }
            #expect(onDisk == 99)
            #expect(supported == AppSettings.currentSchemaVersion)
        }
        #expect(threw)
        let after = try Data(contentsOf: paths.settingsFile)
        #expect(after == original)
    }

    // MARK: - SocketPaths matrix

    @Test func socketPathsPrecedenceExplicitOverEnv() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-prec")
        defer { cleanup() }
        let short = try SocketPaths.makeShortTestingRoot(prefix: "nsp")
        defer { try? FileManager.default.removeItem(at: short) }

        let explicit = SocketPaths.testingSocketPath(in: short, name: "explicit.sock")
        let envSock = SocketPaths.testingSocketPath(in: short, name: "env.sock")
        let appSupport = temp.appendingPathComponent("as", isDirectory: true)

        let env: [String: String] = [
            NocturnalEnvironmentKey.socket.rawValue: envSock.path,
            NocturnalEnvironmentKey.appSupport.rawValue: appSupport.path,
        ]
        let paths = try SocketPaths.resolve(
            environment: env,
            explicitSocketPath: explicit.path
        )
        #expect(paths.socketURL.path == explicit.path)
        #expect(paths.applicationSupportDirectory.path == appSupport.path)
    }

    @Test func socketPathsHonorsAppSupportEnv() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-as")
        defer { cleanup() }
        let appSupport = temp.appendingPathComponent("custom-support", isDirectory: true)
        let env: [String: String] = [
            NocturnalEnvironmentKey.appSupport.rawValue: appSupport.path,
        ]
        let paths = try SocketPaths.resolve(environment: env)
        #expect(paths.applicationSupportDirectory.path == appSupport.path)
        #expect(paths.socketURL.path == appSupport.appendingPathComponent("ipc.sock").path)
        #expect(FileManager.default.fileExists(atPath: appSupport.path))
    }

    @Test func socketPathsOverrideDoesNotCreateAppSupport() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-sock-noside")
        defer { cleanup() }
        let short = try SocketPaths.makeShortTestingRoot(prefix: "nso")
        defer { try? FileManager.default.removeItem(at: short) }

        let socket = SocketPaths.testingSocketPath(in: short, name: "only.sock")
        // Point app support at a path that must NOT be created when socket is overridden.
        let appSupport = temp.appendingPathComponent("must-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: appSupport.path) == false)

        let env: [String: String] = [
            NocturnalEnvironmentKey.appSupport.rawValue: appSupport.path,
            NocturnalEnvironmentKey.socket.rawValue: socket.path,
        ]
        let paths = try SocketPaths.resolve(environment: env)
        #expect(paths.socketURL.path == socket.path)
        #expect(paths.applicationSupportDirectory.path == appSupport.path)
        #expect(FileManager.default.fileExists(atPath: appSupport.path) == false)
    }
}
