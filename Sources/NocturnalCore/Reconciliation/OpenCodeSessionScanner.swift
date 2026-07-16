import Foundation
import SQLite3

/// Minimal, non-authoritative metadata recovered from local OpenCode storage.
/// Live plugin events remain the source of truth for running state.
public struct OpenCodeSessionSnapshot: Sendable, Equatable {
    public var sessionId: String
    public var title: String?
    public var workingDirectory: String?
    public var timestamp: Date
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var diffAdded: Int?
    public var diffRemoved: Int?
    public var filesTouched: Int?
    public var storagePath: String

    public init(
        sessionId: String,
        title: String? = nil,
        workingDirectory: String? = nil,
        timestamp: Date,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        filesTouched: Int? = nil,
        storagePath: String
    ) {
        self.sessionId = sessionId
        self.title = title
        self.workingDirectory = workingDirectory
        self.timestamp = timestamp
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.filesTouched = filesTouched
        self.storagePath = storagePath
    }

    public func envelope() -> EventEnvelope {
        var payload: [String: JSONValue] = [
            "summary": .string("Recovered from local OpenCode history"),
        ]
        if let title, !title.isEmpty {
            payload["title"] = .string(title)
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            payload["cwd"] = .string(workingDirectory)
            payload["working_directory"] = .string(workingDirectory)
            if title == nil || title?.isEmpty == true {
                let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
                if !name.isEmpty { payload["title"] = .string(name) }
            }
        }
        if let tokensIn { payload["tokens_in"] = .number(Double(tokensIn)) }
        if let tokensOut { payload["tokens_out"] = .number(Double(tokensOut)) }
        if let diffAdded { payload["additions"] = .number(Double(diffAdded)) }
        if let diffRemoved { payload["deletions"] = .number(Double(diffRemoved)) }
        if let filesTouched { payload["files"] = .number(Double(filesTouched)) }

        return EventEnvelope(
            source: .opencode,
            eventType: "session.reconciled",
            sessionId: sessionId,
            timestamp: timestamp,
            payload: payload,
            raw: [
                "reconciledFrom": .string(storagePath),
                "source": .string("opencode"),
            ]
        )
    }
}

/// Bounded, read-only recovery of recent OpenCode sessions.
///
/// Prefer SQLite (`~/.local/share/opencode/opencode.db`); fall back to JSON
/// under `storage/session/<project>/<session>.json`.
public struct OpenCodeSessionScanner: Sendable {
    public var dataRoot: URL
    public var maxSessions: Int

    public init(dataRoot: URL, maxSessions: Int = 80) {
        self.dataRoot = dataRoot
        self.maxSessions = max(0, maxSessions)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> OpenCodeSessionScanner {
        let root: URL
        if let testRoot = environment[NocturnalEnvironmentKey.configRoot.rawValue],
           !testRoot.isEmpty
        {
            // Sandbox: <configRoot>/.local/share/opencode
            root = URL(fileURLWithPath: testRoot, isDirectory: true)
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            root = URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else if let home = environment["HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return OpenCodeSessionScanner(dataRoot: root)
    }

    public func scan(fileManager: FileManager = .default) throws -> [OpenCodeSessionSnapshot] {
        guard maxSessions > 0 else { return [] }
        let dbURL = dataRoot.appendingPathComponent("opencode.db")
        if fileManager.fileExists(atPath: dbURL.path),
           let fromDB = try? scanSQLite(dbURL: dbURL),
           !fromDB.isEmpty
        {
            return fromDB
        }
        return try scanJSONFiles(fileManager: fileManager)
    }

    // MARK: - SQLite

    private func scanSQLite(dbURL: URL) throws -> [OpenCodeSessionSnapshot] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        // Read-only safety for concurrent writers.
        _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        // Core columns only — metric column names vary across OpenCode builds.
        // A prepare failure here used to silently skip the entire SQLite path.
        let sql = """
        SELECT id, title, directory, time_updated
        FROM session
        WHERE time_archived IS NULL OR time_archived = 0
        ORDER BY time_updated DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let limit = Int32(clamping: maxSessions)
        sqlite3_bind_int(stmt, 1, max(0, limit))

        var out: [OpenCodeSessionSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let directory = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let updatedMs = sqlite3_column_int64(stmt, 3)

            let ts = EventEnvelopeDateParsing.parseEpoch(Double(updatedMs)) ?? Date()
            out.append(
                OpenCodeSessionSnapshot(
                    sessionId: id,
                    title: title,
                    workingDirectory: directory,
                    timestamp: ts,
                    tokensIn: nil,
                    tokensOut: nil,
                    diffAdded: nil,
                    diffRemoved: nil,
                    filesTouched: nil,
                    storagePath: dbURL.path
                )
            )
        }
        return out
    }

    // MARK: - JSON fallback

    private func scanJSONFiles(fileManager: FileManager) throws -> [OpenCodeSessionSnapshot] {
        let root = dataRoot
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 8_000 { break }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json"
            else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        // Fail-open per file: one corrupt session must not hide the rest.
        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(maxSessions)
            .compactMap { try? snapshotFromJSON(at: $0.url) }
    }

    private func snapshotFromJSON(at url: URL) throws -> OpenCodeSessionSnapshot? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Bound read size
        guard data.count < 512 * 1024 else { return nil }
        let root = try JSONValue.parse(data: data).asObject
        guard let sessionId = EventDecodeHelpers.string(root, "id", "sessionID", "session_id"),
              !sessionId.isEmpty
        else { return nil }

        let title = EventDecodeHelpers.string(root, "title", "slug")
        let directory = EventDecodeHelpers.string(root, "directory", "cwd", "workdir")
        let timeObj = root["time"]?.objectValue
        let updated = timeObj?["updated"]?.numberValue
            ?? root["time_updated"]?.numberValue
            ?? root["updated"]?.numberValue
        let ts = updated.flatMap(EventEnvelopeDateParsing.parseEpoch) ?? .distantPast

        let summary = root["summary"]?.objectValue
        let tokens = root["tokens"]?.objectValue
        return OpenCodeSessionSnapshot(
            sessionId: sessionId,
            title: title,
            workingDirectory: directory,
            timestamp: ts,
            tokensIn: intField(tokens, "input") ?? intField(root, "tokens_input"),
            tokensOut: intField(tokens, "output") ?? intField(root, "tokens_output"),
            diffAdded: intField(summary, "additions") ?? intField(root, "summary_additions"),
            diffRemoved: intField(summary, "deletions") ?? intField(root, "summary_deletions"),
            filesTouched: intField(summary, "files") ?? intField(root, "summary_files"),
            storagePath: url.path
        )
    }

    private func intField(_ obj: [String: JSONValue]?, _ key: String) -> Int? {
        guard let obj else { return nil }
        if let n = obj[key]?.exactIntValue { return n }
        if let d = obj[key]?.numberValue, d >= 0, d == d.rounded() { return Int(d) }
        return nil
    }
}
