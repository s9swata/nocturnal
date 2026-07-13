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
    }

    public func load(id: SessionID) throws -> Session? {
        let url = paths.sessionFile(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }
        do {
            return try decoder.decode(Session.self, from: data)
        } catch {
            throw PersistenceError.decodingFailed(String(describing: error))
        }
    }

    public func loadAll() throws -> [Session] {
        try paths.ensureDirectories(fileManager: fileManager)
        lastLoadSkipped = []
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: paths.sessionsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
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
        let url = paths.sessionFile(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw PersistenceError.ioFailed(error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        let sessions = try loadAll()
        for session in sessions {
            try delete(id: session.id)
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
