import Foundation

public enum PersistenceError: Error, Sendable, Equatable {
    case encodingFailed
    case decodingFailed(String)
    case ioFailed(String)
}

/// JSON file persistence for sessions. Actor-isolated for safe concurrent access.
///
/// Corruption recovery: individual unreadable session files are skipped (and
/// optionally quarantined) so one bad file never blocks bootstrap.
///
/// **Legacy path safety:** older builds mapped `/` and `:` to `_`, so distinct
/// IDs such as `a/b` and `a_b` shared `a_b.json`. Every load / migrate / delete
/// of a candidate verifies the decoded ``Session/id`` matches the request
/// before treating the file as owned by that ID.
public actor SessionPersistence {
    private let paths: PersistencePaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let quarantineCorrupt: Bool

    public private(set) var lastLoadSkipped: [String] = []

    public init(
        paths: PersistencePaths,
        fileManager: FileManager = .default,
        quarantineCorrupt: Bool = true
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.quarantineCorrupt = quarantineCorrupt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try EventEnvelopeDateParsing.decode(from: decoder)
        }
        self.decoder = decoder
    }

    public func save(_ session: Session) throws {
        try paths.ensureDirectories(fileManager: fileManager)
        let url = paths.sessionFile(for: session.id)
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw PersistenceError.encodingFailed
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }
        // Drop legacy filename only when its decoded content belongs to this
        // session. Shared legacy names (e.g. a_b.json for both a/b and a_b)
        // must never remove another ID's file.
        let legacy = paths.legacySessionFile(for: session.id)
        if legacy != url {
            removeIfOwned(url: legacy, by: session.id)
        }
    }

    public func load(id: SessionID) throws -> Session? {
        let canonical = paths.sessionFile(for: id)
        for url in paths.sessionFileCandidates(for: id) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw PersistenceError.ioFailed(error.localizedDescription)
            }
            let session: Session
            do {
                session = try decoder.decode(Session.self, from: data)
            } catch {
                throw PersistenceError.decodingFailed(String(describing: error))
            }
            // Filename is only a hint — embedded ID is authoritative.
            // Skip candidates whose content belongs to a different session
            // (legacy sanitize collisions such as a/b vs a_b → a_b.json).
            guard session.id == id else { continue }

            // Migrate matching legacy files onto the canonical path.
            if url != canonical {
                migrateLegacyIfOwned(session: session, from: url, to: canonical, data: data)
            }
            return session
        }
        return nil
    }

    public func loadAll() throws -> [Session] {
        try paths.ensureDirectories(fileManager: fileManager)
        lastLoadSkipped = []
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: paths.sessionsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    return false
                }
                return url.pathExtension == "json"
            }
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }

        var sessions: [Session] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let session = try decoder.decode(Session.self, from: data)
                sessions.append(session)
            } catch {
                lastLoadSkipped.append(url.lastPathComponent)
                if quarantineCorrupt {
                    quarantine(url: url)
                }
                continue
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: SessionID) throws {
        var lastError: Error?
        let canonical = paths.sessionFile(for: id)
        for url in paths.sessionFileCandidates(for: id) {
            guard fileManager.fileExists(atPath: url.path) else { continue }

            let isCanonical = url == canonical
            if isCanonical {
                // Canonical slot for this ID: delete if undecodable (cleanup) or
                // if content matches. Skip only when decodable content is foreign.
                if let foreign = try? decodeSession(at: url), foreign.id != id {
                    continue
                }
            } else {
                // Legacy candidate: never delete unless decoded content is ours.
                guard let owned = try? decodeSession(at: url), owned.id == id else {
                    continue
                }
            }

            do {
                try fileManager.removeItem(at: url)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw PersistenceError.ioFailed(lastError.localizedDescription)
        }
    }

    /// Remove **every** regular file in the sessions directory, including
    /// malformed/unreadable JSON. Directory entries (and the sessions directory
    /// itself) are left alone.
    public func deleteAll() throws {
        try paths.ensureDirectories(fileManager: fileManager)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: paths.sessionsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }

        var firstError: Error?
        for url in urls {
            // Never delete the directory itself or nested directories (metadata/subdirs).
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }

            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw PersistenceError.ioFailed(firstError.localizedDescription)
        }
    }

    // MARK: - Ownership helpers

    /// Decode a session file; throws on I/O or JSON failure.
    private func decodeSession(at url: URL) throws -> Session {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Session.self, from: data)
    }

    /// Remove `url` only when it decodes to a session with `id`.
    private func removeIfOwned(url: URL, by id: SessionID) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let session = try? decodeSession(at: url), session.id == id else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Write matching content to the canonical path, then drop the legacy file
    /// only after a successful write. Caller must already verify
    /// `session.id` equals the requested ID.
    private func migrateLegacyIfOwned(
        session: Session,
        from legacy: URL,
        to canonical: URL,
        data: Data
    ) {
        guard legacy != canonical else { return }
        do {
            if !fileManager.fileExists(atPath: canonical.path) {
                try data.write(to: canonical, options: [.atomic])
            }
            // Only remove legacy after canonical is present with matching ownership.
            if fileManager.fileExists(atPath: canonical.path),
               let onDisk = try? decodeSession(at: canonical),
               onDisk.id == session.id {
                try? fileManager.removeItem(at: legacy)
            }
        } catch {
            // Migration is best-effort; the in-memory load still succeeds.
        }
    }

    private func quarantine(url: URL) {
        let destDir = paths.root.appendingPathComponent("corrupt-sessions", isDirectory: true)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = destDir.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        try? fileManager.moveItem(at: url, to: dest)
    }
}
