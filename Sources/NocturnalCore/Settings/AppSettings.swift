import Foundation

/// User preferences persisted locally as JSON. No telemetry, no accounts.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Schema version for migrations.
    public var schemaVersion: Int
    /// When true, UI must avoid non-essential motion (also respects system Reduce Motion).
    public var reduceMotion: Bool
    /// Soft attention sounds for approvals / questions. Off by default for quiet nocturnal feel.
    public var soundEnabled: Bool
    /// Launch with deterministic demo sessions instead of live socket.
    public var demoMode: Bool
    /// Show floating pill overlay (in addition to menu bar).
    public var showFloatingPill: Bool
    /// Maximum sessions retained in the panel list.
    public var maxVisibleSessions: Int

    public static let currentSchemaVersion = 1

    public static let `default` = AppSettings(
        schemaVersion: currentSchemaVersion,
        reduceMotion: false,
        soundEnabled: false,
        demoMode: false,
        showFloatingPill: true,
        maxVisibleSessions: 12
    )

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        reduceMotion: Bool = false,
        soundEnabled: Bool = false,
        demoMode: Bool = false,
        showFloatingPill: Bool = true,
        maxVisibleSessions: Int = 12
    ) {
        self.schemaVersion = schemaVersion
        self.reduceMotion = reduceMotion
        self.soundEnabled = soundEnabled
        self.demoMode = demoMode
        self.showFloatingPill = showFloatingPill
        self.maxVisibleSessions = max(1, maxVisibleSessions)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        demoMode = try container.decodeIfPresent(Bool.self, forKey: .demoMode) ?? false
        showFloatingPill = try container.decodeIfPresent(Bool.self, forKey: .showFloatingPill) ?? true
        maxVisibleSessions = try container.decodeIfPresent(Int.self, forKey: .maxVisibleSessions) ?? 12
        // Migrate forward: stamp current schema after load.
        if schemaVersion < AppSettings.currentSchemaVersion {
            schemaVersion = AppSettings.currentSchemaVersion
        }
    }
}

/// Loads/saves ``AppSettings`` from the persistence root.
public actor SettingsStore {
    private let paths: PersistencePaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cached: AppSettings?
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(paths: PersistencePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() throws -> AppSettings {
        if let cached { return cached }
        let url = paths.settingsFile
        guard fileManager.fileExists(atPath: url.path) else {
            cached = .default
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            var settings = try decoder.decode(AppSettings.self, from: data)
            // Ensure migrated schema is written back eventually by callers of save.
            if settings.schemaVersion != AppSettings.currentSchemaVersion {
                settings.schemaVersion = AppSettings.currentSchemaVersion
            }
            cached = settings
            return settings
        } catch {
            // Corruption recovery: fall back to defaults without crashing.
            cached = .default
            return .default
        }
    }

    public func save(_ settings: AppSettings) throws {
        try paths.ensureDirectories(fileManager: fileManager)
        var toSave = settings
        toSave.schemaVersion = AppSettings.currentSchemaVersion
        let data: Data
        do {
            data = try encoder.encode(toSave)
        } catch {
            throw PersistenceError.encodingFailed
        }
        do {
            try data.write(to: paths.settingsFile, options: [.atomic])
            cached = toSave
            publish(toSave)
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }
    }

    /// Stream of settings updates (current value first).
    public func updates() -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        continuations[id] = continuation
        if let cached {
            continuation.yield(cached)
        } else if let loaded = try? load() {
            continuation.yield(loaded)
        }
        continuation.onTermination = { _ in
            Task { await self.removeContinuation(id) }
        }
        return stream
    }

    private func publish(_ settings: AppSettings) {
        for continuation in continuations.values {
            continuation.yield(settings)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
