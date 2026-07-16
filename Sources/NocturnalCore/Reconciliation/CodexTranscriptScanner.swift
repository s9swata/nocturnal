import Foundation

/// Minimal, non-authoritative metadata recovered from a local Codex rollout.
/// Nocturnal intentionally does not parse conversation or tool transcript bodies.
public struct CodexTranscriptSnapshot: Sendable, Equatable {
    public var sessionId: String
    public var timestamp: Date
    public var workingDirectory: String?
    public var cliVersion: String?
    public var transcriptPath: String

    public init(
        sessionId: String,
        timestamp: Date,
        workingDirectory: String? = nil,
        cliVersion: String? = nil,
        transcriptPath: String
    ) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.cliVersion = cliVersion
        self.transcriptPath = transcriptPath
    }

    public func envelope() -> EventEnvelope {
        var payload: [String: JSONValue] = [
            "summary": .string("Recovered from local Codex history"),
            "transcript_path": .string(transcriptPath),
        ]
        if let workingDirectory {
            payload["cwd"] = .string(workingDirectory)
            let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !name.isEmpty { payload["title"] = .string(name) }
        }
        if let cliVersion { payload["cli_version"] = .string(cliVersion) }

        return EventEnvelope(
            source: .codex,
            eventType: "session.reconciled",
            sessionId: sessionId,
            timestamp: timestamp,
            payload: payload,
            raw: ["reconciledFrom": .string(transcriptPath)]
        )
    }
}

/// Bounded, read-only scanner for the first `session_meta` line in recent Codex
/// rollout JSONL files. Live hooks remain the source of truth for session state.
public struct CodexTranscriptScanner: Sendable {
    public var sessionsRoot: URL
    public var maxFiles: Int
    public var maxHeaderBytes: Int
    public var maxDirectoryEntries: Int

    public init(
        sessionsRoot: URL,
        maxFiles: Int = 100,
        maxHeaderBytes: Int = 256 * 1024,
        maxDirectoryEntries: Int = 5_000
    ) {
        self.sessionsRoot = sessionsRoot
        self.maxFiles = max(0, maxFiles)
        self.maxHeaderBytes = max(1, maxHeaderBytes)
        self.maxDirectoryEntries = max(1, maxDirectoryEntries)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CodexTranscriptScanner {
        let codexHome: URL
        if let testRoot = environment[NocturnalEnvironmentKey.configRoot.rawValue],
           !testRoot.isEmpty
        {
            codexHome = URL(fileURLWithPath: testRoot, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        } else if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else if let home = environment["HOME"], !home.isEmpty {
            codexHome = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        } else {
            codexHome = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return CodexTranscriptScanner(
            sessionsRoot: codexHome.appendingPathComponent("sessions", isDirectory: true)
        )
    }

    public func scan(fileManager: FileManager = .default) throws -> [CodexTranscriptSnapshot] {
        guard maxFiles > 0,
              fileManager.fileExists(atPath: sessionsRoot.path),
              let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
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
            if visited > maxDirectoryEntries { break }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "jsonl"
            else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        return try candidates
            .sorted { $0.modified > $1.modified }
            .prefix(maxFiles)
            .compactMap { try snapshot(at: $0.url) }
    }

    private func snapshot(at url: URL) throws -> CodexTranscriptSnapshot? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: maxHeaderBytes),
              !header.isEmpty,
              let newline = header.firstIndex(of: 0x0A)
        else { return nil }

        let firstLine = Data(header[..<newline])
        let root = try JSONValue.parse(data: firstLine).asObject
        guard root["type"]?.stringValue == "session_meta",
              case .object(let payload)? = root["payload"],
              let sessionId = EventDecodeHelpers.string(payload, "session_id", "id")
        else { return nil }

        let timestamp = parseDate(payload["timestamp"])
            ?? parseDate(root["timestamp"])
            ?? .distantPast
        return CodexTranscriptSnapshot(
            sessionId: sessionId,
            timestamp: timestamp,
            workingDirectory: EventDecodeHelpers.string(payload, "cwd"),
            cliVersion: EventDecodeHelpers.string(payload, "cli_version"),
            transcriptPath: url.path
        )
    }

    private func parseDate(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let number = value.numberValue {
            return EventEnvelopeDateParsing.parseEpoch(number)
        }
        guard let string = value.stringValue else { return nil }
        return EventEnvelopeDateParsing.parse(string)
            ?? Double(string).flatMap(EventEnvelopeDateParsing.parseEpoch)
    }
}
