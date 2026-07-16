import Foundation

/// Minimal, non-authoritative metadata recovered from local Grok Build storage.
/// Live hooks remain the source of truth for running state.
public struct GrokSessionSnapshot: Sendable, Equatable {
    public var sessionId: String
    public var title: String?
    public var workingDirectory: String?
    public var timestamp: Date
    public var modelId: String?
    public var storagePath: String
    public var isActive: Bool

    public init(
        sessionId: String,
        title: String? = nil,
        workingDirectory: String? = nil,
        timestamp: Date,
        modelId: String? = nil,
        storagePath: String,
        isActive: Bool = false
    ) {
        self.sessionId = sessionId
        self.title = title
        self.workingDirectory = workingDirectory
        self.timestamp = timestamp
        self.modelId = modelId
        self.storagePath = storagePath
        self.isActive = isActive
    }

    public func envelope() -> EventEnvelope {
        var payload: [String: JSONValue] = [
            "summary": .string(
                isActive
                    ? "Active Grok session (local index)"
                    : "Recovered from local Grok history"
            ),
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
        if let modelId, !modelId.isEmpty {
            payload["model"] = .string(modelId)
        }

        return EventEnvelope(
            source: .grokBuild,
            eventType: "session.reconciled",
            sessionId: sessionId,
            timestamp: timestamp,
            payload: payload,
            raw: [
                "reconciledFrom": .string(storagePath),
                "source": .string("grok-build"),
                "active": .bool(isActive),
            ]
        )
    }
}

/// Bounded, read-only recovery of recent Grok Build sessions.
///
/// Sources (under ``grokHome``, default `~/.grok`):
/// 1. `active_sessions.json` — currently open sessions (still injected as idle
///    recovery stubs; live hooks upgrade them when events arrive)
/// 2. `sessions/<encoded-cwd>/<session-id>/summary.json` — recent history
///
/// All reads are size- and entry-capped so a corrupted or huge local tree
/// cannot spike memory at launch (mirrors ``CodexTranscriptScanner``).
public struct GrokSessionScanner: Sendable {
    public var grokHome: URL
    public var maxSessions: Int
    /// Reject `active_sessions.json` larger than this (bytes).
    public var maxActiveSessionsBytes: Int
    /// Reject each `summary.json` larger than this (bytes).
    public var maxSummaryBytes: Int
    /// Max directory entries visited while walking `sessions/`.
    public var maxDirectoryEntries: Int

    public init(
        grokHome: URL,
        maxSessions: Int = 80,
        maxActiveSessionsBytes: Int = 512 * 1024,
        maxSummaryBytes: Int = 256 * 1024,
        maxDirectoryEntries: Int = 5_000
    ) {
        self.grokHome = grokHome
        self.maxSessions = max(0, maxSessions)
        self.maxActiveSessionsBytes = max(1, maxActiveSessionsBytes)
        self.maxSummaryBytes = max(1, maxSummaryBytes)
        self.maxDirectoryEntries = max(1, maxDirectoryEntries)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> GrokSessionScanner {
        let home: URL
        if let testRoot = environment[NocturnalEnvironmentKey.configRoot.rawValue],
           !testRoot.isEmpty
        {
            home = URL(fileURLWithPath: testRoot, isDirectory: true)
                .appendingPathComponent(".grok", isDirectory: true)
        } else if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            home = URL(fileURLWithPath: grokHome, isDirectory: true)
        } else if let homeEnv = environment["HOME"], !homeEnv.isEmpty {
            home = URL(fileURLWithPath: homeEnv, isDirectory: true)
                .appendingPathComponent(".grok", isDirectory: true)
        } else {
            home = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
        }
        return GrokSessionScanner(grokHome: home)
    }

    public func scan(fileManager: FileManager = .default) throws -> [GrokSessionSnapshot] {
        guard maxSessions > 0 else { return [] }
        var byId: [String: GrokSessionSnapshot] = [:]

        for snap in scanActiveSessions(fileManager: fileManager) {
            byId[snap.sessionId] = snap
        }
        for snap in scanSummaries(fileManager: fileManager) {
            if let existing = byId[snap.sessionId] {
                // Prefer active flag; fill missing title/cwd from summary.
                byId[snap.sessionId] = GrokSessionSnapshot(
                    sessionId: snap.sessionId,
                    title: existing.title ?? snap.title,
                    workingDirectory: existing.workingDirectory ?? snap.workingDirectory,
                    timestamp: max(existing.timestamp, snap.timestamp),
                    modelId: existing.modelId ?? snap.modelId,
                    storagePath: snap.storagePath,
                    isActive: existing.isActive || snap.isActive
                )
            } else {
                byId[snap.sessionId] = snap
            }
        }

        return Array(byId.values)
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxSessions)
            .map { $0 }
    }

    // MARK: - active_sessions.json

    private func scanActiveSessions(fileManager: FileManager) -> [GrokSessionSnapshot] {
        let url = grokHome.appendingPathComponent("active_sessions.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = Self.readBoundedFile(url, maxBytes: maxActiveSessionsBytes, fileManager: fileManager),
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }

        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let array = object["sessions"] as? [[String: Any]]
        {
            rows = array
        } else {
            return []
        }

        var out: [GrokSessionSnapshot] = []
        for row in rows {
            let id = (row["session_id"] as? String)
                ?? (row["sessionId"] as? String)
                ?? (row["id"] as? String)
            guard let id, !id.isEmpty else { continue }
            let cwd = (row["cwd"] as? String) ?? (row["working_directory"] as? String)
            let opened = parseDate(row["opened_at"] ?? row["openedAt"] ?? row["updated_at"])
                ?? Date()
            out.append(
                GrokSessionSnapshot(
                    sessionId: id,
                    title: nil,
                    workingDirectory: cwd,
                    timestamp: opened,
                    modelId: nil,
                    storagePath: url.path,
                    isActive: true
                )
            )
        }
        return out
    }

    // MARK: - summary.json under sessions/

    private func scanSummaries(fileManager: FileManager) -> [GrokSessionSnapshot] {
        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return [] }

        var candidates: [(url: URL, mtime: Date)] = []
        var visited = 0
        guard let cwdDirs = try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for cwdDir in cwdDirs {
            visited += 1
            if visited > maxDirectoryEntries { break }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: cwdDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // Skip non-session files like session_search.sqlite / prompt_history.
            guard let sessionDirs = try? fileManager.contentsOfDirectory(
                at: cwdDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for sessionDir in sessionDirs {
                visited += 1
                if visited > maxDirectoryEntries { break }
                var sessionIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: sessionDir.path, isDirectory: &sessionIsDir),
                      sessionIsDir.boolValue
                else { continue }
                let summary = sessionDir.appendingPathComponent("summary.json")
                guard fileManager.fileExists(atPath: summary.path) else { continue }
                let values = try? summary.resourceValues(forKeys: [.contentModificationDateKey])
                let mtime = values?.contentModificationDate ?? Date.distantPast
                candidates.append((summary, mtime))
            }
            if visited > maxDirectoryEntries { break }
        }

        // Newest first; cap before parsing large trees.
        candidates.sort { $0.mtime > $1.mtime }
        // Saturating cap: avoid `maxSessions * 2` overflow for huge maxSessions.
        let doubleCap = maxSessions > Int.max / 2 ? Int.max : maxSessions * 2
        let limited = candidates.prefix(max(doubleCap, 40))

        var out: [GrokSessionSnapshot] = []
        out.reserveCapacity(limited.count)
        for item in limited {
            if let snap = parseSummary(url: item.url, mtime: item.mtime, fileManager: fileManager) {
                out.append(snap)
            }
        }
        return out
    }

    private func parseSummary(url: URL, mtime: Date, fileManager: FileManager) -> GrokSessionSnapshot? {
        guard let data = Self.readBoundedFile(url, maxBytes: maxSummaryBytes, fileManager: fileManager),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }

        let info = root["info"] as? [String: Any]
        let id = (info?["id"] as? String)
            ?? (root["id"] as? String)
            ?? url.deletingLastPathComponent().lastPathComponent
        guard !id.isEmpty else { return nil }

        let cwd = (info?["cwd"] as? String)
            ?? (root["cwd"] as? String)
            ?? (root["git_root_dir"] as? String)

        let title = (root["generated_title"] as? String)
            ?? (root["session_summary"] as? String)
            ?? (root["title"] as? String)

        let model = root["current_model_id"] as? String
        let updated = parseDate(root["last_active_at"] ?? root["updated_at"] ?? root["created_at"])
            ?? mtime

        let normalizedCwd: String? = {
            guard var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
            else { return nil }
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }()

        return GrokSessionSnapshot(
            sessionId: id,
            title: title,
            workingDirectory: normalizedCwd,
            timestamp: updated,
            modelId: model,
            storagePath: url.path,
            isActive: false
        )
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = value as? Double {
            // Heuristic: ms vs s
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = value as? Int {
            let d = Double(n)
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
        }
        return nil
    }

    /// Load a regular file only when its size is within `maxBytes`.
    ///
    /// Uses a bounded `FileHandle` read (maxBytes+1) so a concurrent writer that
    /// enlarges the file after `stat` cannot force a full unbounded allocation.
    private static func readBoundedFile(
        _ url: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), !data.isEmpty else {
            return nil
        }
        // Exactly maxBytes+1 means the file is larger than the recovery limit.
        guard data.count <= maxBytes else { return nil }
        return data
    }
}
