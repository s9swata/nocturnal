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

    public static let currentSchemaVersion = 2

    public static let `default` = AppSettings(
        schemaVersion: currentSchemaVersion,
        reduceMotion: false,
        soundEnabled: false,
        showFloatingPill: true,
        maxVisibleSessions: 12
    )

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        reduceMotion: Bool = false,
        soundEnabled: Bool = false,
        showFloatingPill: Bool = true,
        maxVisibleSessions: Int = 12
    ) {
        self.schemaVersion = schemaVersion
        self.reduceMotion = reduceMotion
        self.soundEnabled = soundEnabled
        self.showFloatingPill = showFloatingPill
        self.maxVisibleSessions = max(1, maxVisibleSessions)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let onDiskVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        showFloatingPill = try container.decodeIfPresent(Bool.self, forKey: .showFloatingPill) ?? true
        maxVisibleSessions = try container.decodeIfPresent(Int.self, forKey: .maxVisibleSessions) ?? 12
        // Obsolete product key `demoMode` is intentionally ignored (tolerant decode).
        // Migrate only older schemas forward. Preserve newer schema versions as-is
        // so a future file is never silently downgraded by this binary.
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
        // demoMode deliberately omitted — old files with the key still decode.
    }
}

public enum SettingsStoreError: Error, Sendable, Equatable {
    /// On-disk settings use a schema newer than this binary; refuse to overwrite.
    case newerSchemaOnDisk(onDisk: Int, supported: Int)
    case encodingFailed
    case ioFailed(String)
}

/// Loads/saves ``AppSettings`` from the persistence root.
///
/// **Load never writes.** Migration of older schemas is applied in-memory only;
/// callers must invoke ``save(_:)`` explicitly if they want to persist a migration.
///
/// **UI contract (required):** never mutate published UI state and then
/// `try? await save(...)`. A refused save (`newerSchemaOnDisk`) must leave UI
/// state unchanged. Prefer ``update(_:)`` which applies the mutation only after
/// a successful write, or catch `SettingsStoreError` and roll back.
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
            // Decode only — never rewrite the file on load (preserves unknown keys
            // and newer schema files until an explicit save from a capable binary).
            let settings = try decoder.decode(AppSettings.self, from: data)
            cached = settings
            return settings
        } catch {
            // Corruption recovery: fall back to defaults without crashing or clobbering disk.
            cached = .default
            return .default
        }
    }

    /// Persist settings. Returns the stamped value that was written (and cached).
    ///
    /// Callers that mutate on a different isolation domain (e.g. `@MainActor` UI)
    /// should load → mutate locally → ``save(_:)`` so they never send a non-`Sendable`
    /// closure into this actor.
    @discardableResult
    public func save(_ settings: AppSettings) throws -> AppSettings {
        try paths.ensureDirectories(fileManager: fileManager)

        // Refuse to downgrade / rewrite a future schema file.
        if let onDiskVersion = try? peekOnDiskSchemaVersion(),
           onDiskVersion > AppSettings.currentSchemaVersion
        {
            throw SettingsStoreError.newerSchemaOnDisk(
                onDisk: onDiskVersion,
                supported: AppSettings.currentSchemaVersion
            )
        }

        var toSave = settings
        // Writes from this binary always stamp the schema we understand.
        // (Blocked above when disk already has a newer schema.)
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

    /// Whether ``save(_:)`` would be allowed against the current on-disk file.
    ///
    /// Returns `false` when disk carries a newer schema this binary must not rewrite.
    public func canSave() throws -> Bool {
        guard let onDiskVersion = try peekOnDiskSchemaVersion() else {
            return true
        }
        return onDiskVersion <= AppSettings.currentSchemaVersion
    }

    /// Mutate and persist settings atomically from the caller's perspective.
    ///
    /// Loads the current value, applies `mutate`, then ``save(_:)``. On any save
    /// failure (including ``SettingsStoreError/newerSchemaOnDisk``) the in-store
    /// cache is unchanged and the error is rethrown — so UI can assign the
    /// returned value only on success.
    ///
    /// `mutate` is `@Sendable` because it runs on this actor. Prefer the
    /// load → local mutate → ``save(_:)`` pattern from `@MainActor` UI code when
    /// the closure would capture non-Sendable state:
    ///
    /// ```swift
    /// // Same-isolation / Sendable mutate:
    /// settings = try await settingsStore.update { $0.soundEnabled = true }
    ///
    /// // @MainActor UI (do NOT try? after optimistic mutate):
    /// var next = try await settingsStore.load()
    /// mutate(&next)
    /// settings = try await settingsStore.save(next)
    /// ```
    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) throws -> AppSettings {
        var next = try load()
        mutate(&next)
        return try save(next)
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

    /// Read schemaVersion from disk without mutating cache or rewriting the file.
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
