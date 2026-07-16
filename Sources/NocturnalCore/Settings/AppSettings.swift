import Foundation

/// User preferences persisted locally as JSON. No telemetry, no accounts.
///
/// **Schema policy**
/// - Only **older** schema versions are migrated forward to ``currentSchemaVersion``.
/// - Files from a **newer** schema (e.g. future app builds) are never downgraded
///   or rewritten on load. Callers must not treat ``load()`` as a save trigger.
/// - ``SettingsStore/save(_:)`` refuses to overwrite an on-disk file whose
///   `schemaVersion` is greater than this binary understands.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Schema version for migrations.
    public var schemaVersion: Int
    /// When true, UI must avoid non-essential motion (also respects system Reduce Motion).
    public var reduceMotion: Bool
    /// Soft attention sounds for approvals / questions. Off by default for quiet monochrome feel.
    public var soundEnabled: Bool
    /// Show floating pill overlay (in addition to menu bar).
    public var showFloatingPill: Bool
    /// Maximum sessions retained in the panel list.
    public var maxVisibleSessions: Int
    /// Read local Codex/Claude rollout JSONL tails to enrich detail / tokens / diffs.
    /// Default **on** — local-only, fail-open, bounded reads.
    public var readLocalAgentLogs: Bool
    /// Opt-in scan for local listening ports (servers view). Default **off**.
    public var scanLocalListeners: Bool

    public static let currentSchemaVersion = 3

    public static let `default` = AppSettings(
        schemaVersion: currentSchemaVersion,
        reduceMotion: false,
        soundEnabled: false,
        showFloatingPill: true,
        maxVisibleSessions: 12,
        readLocalAgentLogs: true,
        scanLocalListeners: false
    )

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        reduceMotion: Bool = false,
        soundEnabled: Bool = false,
        showFloatingPill: Bool = true,
        maxVisibleSessions: Int = 12,
        readLocalAgentLogs: Bool = true,
        scanLocalListeners: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.reduceMotion = reduceMotion
        self.soundEnabled = soundEnabled
        self.showFloatingPill = showFloatingPill
        self.maxVisibleSessions = max(1, maxVisibleSessions)
        self.readLocalAgentLogs = readLocalAgentLogs
        self.scanLocalListeners = scanLocalListeners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let onDiskVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        showFloatingPill = try container.decodeIfPresent(Bool.self, forKey: .showFloatingPill) ?? true
        maxVisibleSessions = try container.decodeIfPresent(Int.self, forKey: .maxVisibleSessions) ?? 12
        // Product defaults for new keys when migrating older files.
        readLocalAgentLogs = try container.decodeIfPresent(Bool.self, forKey: .readLocalAgentLogs) ?? true
        scanLocalListeners = try container.decodeIfPresent(Bool.self, forKey: .scanLocalListeners) ?? false
        if onDiskVersion < AppSettings.currentSchemaVersion {
            schemaVersion = AppSettings.currentSchemaVersion
        } else {
            schemaVersion = onDiskVersion
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case reduceMotion
        case soundEnabled
        case showFloatingPill
        case maxVisibleSessions
        case readLocalAgentLogs
        case scanLocalListeners
    }
}

public enum SettingsStoreError: Error, Sendable, Equatable {
    case newerSchemaOnDisk(onDisk: Int, supported: Int)
    case encodingFailed
    case ioFailed(String)
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
            let settings = try decoder.decode(AppSettings.self, from: data)
            cached = settings
            return settings
        } catch {
            cached = .default
            return .default
        }
    }

    @discardableResult
    public func save(_ settings: AppSettings) throws -> AppSettings {
        try paths.ensureDirectories(fileManager: fileManager)

        if let onDiskVersion = try? peekOnDiskSchemaVersion(),
           onDiskVersion > AppSettings.currentSchemaVersion
        {
            throw SettingsStoreError.newerSchemaOnDisk(
                onDisk: onDiskVersion,
                supported: AppSettings.currentSchemaVersion
            )
        }

        var toSave = settings
        toSave.schemaVersion = AppSettings.currentSchemaVersion
        let data: Data
        do {
            data = try encoder.encode(toSave)
        } catch {
            throw SettingsStoreError.encodingFailed
        }
        do {
            try data.write(to: paths.settingsFile, options: [.atomic])
            cached = toSave
            publish(toSave)
            return toSave
        } catch {
            throw SettingsStoreError.ioFailed(error.localizedDescription)
        }
    }

    public func canSave() throws -> Bool {
        guard let onDiskVersion = try peekOnDiskSchemaVersion() else {
            return true
        }
        return onDiskVersion <= AppSettings.currentSchemaVersion
    }

    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) throws -> AppSettings {
        var next = try load()
        mutate(&next)
        return try save(next)
    }

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

    private func peekOnDiskSchemaVersion() throws -> Int? {
        let url = paths.settingsFile
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let int = object["schemaVersion"] as? Int { return int }
        if let num = object["schemaVersion"] as? NSNumber { return num.intValue }
        return nil
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
