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
        // Drop prior/legacy filenames only when decoded content belongs to this
        // session. Shared legacy names (e.g. a_b.json for both a/b and a_b)
        // must never remove another ID's file.
        for candidate in paths.sessionFileCandidates(for: session.id) where candidate != url {
            removeIfOwned(url: candidate, by: session.id)
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
            // Canonical records/ plus any flat prior/legacy files under sessions/.
            urls = try Self.sessionJSONFiles(
                under: paths.sessionsDirectory,
                recordsDirectory: paths.sessionRecordsDirectory,
                fileManager: fileManager
            )
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }

        // Prefer canonical `records/` content when the same id appears mid-migration.
        var sessionsByID: [SessionID: (session: Session, fromCanonical: Bool)] = [:]
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let session = try decoder.decode(Session.self, from: data)
                let canonicalPath = paths.sessionFile(for: session.id).standardizedFileURL.path
                let isCanonical = url.standardizedFileURL.path == canonicalPath
                if let existing = sessionsByID[session.id] {
                    if isCanonical {
                        sessionsByID[session.id] = (session, true)
                    } else if !existing.fromCanonical, session.updatedAt >= existing.session.updatedAt {
                        sessionsByID[session.id] = (session, false)
                    }
                } else {
                    sessionsByID[session.id] = (session, isCanonical)
                }
            } catch {
                lastLoadSkipped.append(url.lastPathComponent)
                if quarantineCorrupt {
                    quarantine(url: url)
                }
                continue
            }
        }
        return sessionsByID.values.map(\.session).sorted { $0.updatedAt > $1.updatedAt }
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

    /// Remove **regular non-symlink files** under `sessions/` and `sessions/records/`,
    /// including malformed/unreadable JSON. Directories, symlinks, FIFOs, sockets, and
    /// other special nodes are left alone so a mis-placed `ipc.sock` / FIFO is never unlinked.
    public func deleteAll() throws {
        try paths.ensureDirectories(fileManager: fileManager)
        var firstError: Error?
        for directory in [paths.sessionsDirectory, paths.sessionRecordsDirectory] {
            let urls: [URL]
            do {
                urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: []
                )
            } catch {
                throw PersistenceError.ioFailed(error.localizedDescription)
            }

            for url in urls {
                guard Self.isRemovableSessionFile(url, fileManager: fileManager) else { continue }

                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError {
            throw PersistenceError.ioFailed(firstError.localizedDescription)
        }
    }

    /// Regular files only — never directories, symlinks, FIFOs, or sockets.
    private static func isRemovableSessionFile(_ url: URL, fileManager: FileManager) -> Bool {
        if let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) {
            if values.isDirectory == true { return false }
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == true { return true }
            return false
        }
        // Fallback when resource values are unavailable: POSIX mode check.
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeRegular
    }

    /// JSON session candidates: flat files under `sessions/` plus files in `records/`.
    private static func sessionJSONFiles(
        under sessionsDirectory: URL,
        recordsDirectory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func appendJSON(from directory: URL) throws {
            guard fileManager.fileExists(atPath: directory.path) else { return }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }
                guard url.pathExtension == "json" else { continue }
                let key = url.standardizedFileURL.path
                if seen.insert(key).inserted {
                    result.append(url)
                }
            }
        }

        try appendJSON(from: sessionsDirectory)
        try appendJSON(from: recordsDirectory)
        return result
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
    ///
    /// Never overwrites a canonical file that already belongs to a **different**
    /// session id (embedded ID is authoritative).
    private func migrateLegacyIfOwned(
        session: Session,
        from legacy: URL,
        to canonical: URL,
        data: Data
    ) {
        guard legacy != canonical else { return }
        do {
            try fileManager.createDirectory(
                at: canonical.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: canonical.path) {
                // Refuse to clobber another record that already occupies this slot.
                if let onDisk = try? decodeSession(at: canonical), onDisk.id != session.id {
                    return
                }
            } else {
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
