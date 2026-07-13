import Foundation

/// On-disk layout under Application Support (or test override).
///
/// ```
/// ~/Library/Application Support/Nocturnal/
///   ipc.sock
///   settings.json
///   sessions/
///     records/<encoded-session-id>.json   # canonical writes (disjoint subdir)
///     <prior-or-legacy>.json             # flat candidates for migration only
///   responses/
///     records/<encoded-request-id>.json  # ResponseFileEnvelope (canonical)
///     codex/<encoded-request-id>.json    # agent sidecar (never flat with envelopes)
///     claude/<encoded-request-id>.json
///     answer/<encoded-request-id>.json
///   backups/
///     codex-hooks-*.json
///     claude-hooks-*.json
/// ```
///
/// Session and response filenames use ``PathComponentEncoding`` so arbitrary IDs
/// (`a/b` vs `a_b`, colons, case variants, literal `%XX` / `n.*` ids) never collide.
/// Canonical writes live under the disjoint ``PathComponentEncoding/recordsDirectoryName``
/// subdirectory with a case-stable body. Flat `n.`-prefixed and unprefixed percent
/// layouts plus underscore-sanitized names remain read/migrate candidates only after
/// embedded-ID verification.
public struct PersistencePaths: Sendable, Equatable {
    public var root: URL
    public var settingsFile: URL
    public var sessionsDirectory: URL
    public var responsesDirectory: URL
    public var backupsDirectory: URL
    /// Unix domain socket for hook → app IPC.
    ///
    /// Default is `{root}/ipc.sock`. Production resolve honors `NOCTURNAL_SOCKET`
    /// so hosts (app, setup, runtime) share one source of truth.
    public var socketURL: URL

    public init(root: URL, socketURL: URL? = nil) {
        self.root = root
        self.settingsFile = root.appendingPathComponent("settings.json")
        self.sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        self.responsesDirectory = root.appendingPathComponent("responses", isDirectory: true)
        self.backupsDirectory = root.appendingPathComponent("backups", isDirectory: true)
        self.socketURL = socketURL ?? root.appendingPathComponent("ipc.sock")
    }

    /// Resolve Application Support layout and socket path.
    ///
    /// - `NOCTURNAL_APP_SUPPORT` overrides the data root.
    /// - `NOCTURNAL_SOCKET` overrides the listen/connect socket path (short
    ///   paths under `/tmp` are recommended for simulation; see `SocketPaths`).
    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PersistencePaths {
        let root: URL
        if let override = environment[NocturnalEnvironmentKey.appSupport.rawValue], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            let appSupportRoot = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            root = appSupportRoot.appendingPathComponent("Nocturnal", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let socketOverride = Self.socketURLOverride(from: environment)
        let paths = PersistencePaths(root: root, socketURL: socketOverride)
        try paths.ensureDirectories(fileManager: fileManager)
        return paths
    }

    /// Root under a temporary directory for unit tests (default `{root}/ipc.sock`).
    ///
    /// Does **not** read process environment — tests stay isolated. Pass an
    /// explicit `socketURL` or use ``resolve(fileManager:environment:)`` when
    /// exercising env overrides.
    public static func testing(
        temporaryDirectory: URL,
        socketURL: URL? = nil
    ) throws -> PersistencePaths {
        let root = temporaryDirectory.appendingPathComponent("Nocturnal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = PersistencePaths(root: root, socketURL: socketURL)
        try paths.ensureDirectories()
        return paths
    }

    /// `NOCTURNAL_SOCKET` when set and non-empty; otherwise `nil` (use default under root).
    public static func socketURLOverride(from environment: [String: String]) -> URL? {
        guard let env = environment[NocturnalEnvironmentKey.socket.rawValue], !env.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: env)
    }

    /// Canonical session records directory (`sessions/records/`).
    public var sessionRecordsDirectory: URL {
        sessionsDirectory.appendingPathComponent(
            PathComponentEncoding.recordsDirectoryName,
            isDirectory: true
        )
    }

    /// Canonical response envelope directory (`responses/records/`).
    public var responseRecordsDirectory: URL {
        responsesDirectory.appendingPathComponent(
            PathComponentEncoding.recordsDirectoryName,
            isDirectory: true
        )
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for dir in [
            root,
            sessionsDirectory,
            sessionRecordsDirectory,
            responsesDirectory,
            responseRecordsDirectory,
            backupsDirectory,
        ] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Session files

    /// Canonical (collision-free) session file path for writes (`sessions/records/…`).
    public func sessionFile(for id: SessionID) -> URL {
        sessionRecordsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encode(id.rawValue)).json"
        )
    }

    /// Flat `n.`-prefixed layout kept as an intermediate/prior compatibility read path.
    public func priorPrefixedSessionFile(for id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encodePriorPrefixed(id.rawValue)).json"
        )
    }

    /// Pre-records percent-encoded path (uppercase unreserved, no prefix, flat).
    public func priorEncodedSessionFile(for id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encodePrior(id.rawValue)).json"
        )
    }

    /// Legacy underscore-sanitized path used by older builds (`/` and `:` → `_`).
    public func legacySessionFile(for id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.legacySanitize(id.rawValue)).json"
        )
    }

    /// Candidate paths to try when reading a session.
    /// Order: canonical records/ → prior `n.` flat → prior unprefixed percent → legacy sanitize.
    public func sessionFileCandidates(for id: SessionID) -> [URL] {
        uniqueURLs([
            sessionFile(for: id),
            priorPrefixedSessionFile(for: id),
            priorEncodedSessionFile(for: id),
            legacySessionFile(for: id),
        ])
    }

    // MARK: - Response files

    /// Canonical envelope path for a request / prompt id (`responses/records/…`).
    public func responseFile(for requestId: String) -> URL {
        responseRecordsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encode(requestId)).json"
        )
    }

    /// Flat `n.`-prefixed envelope path (intermediate/prior compatibility layout).
    public func priorPrefixedResponseFile(for requestId: String) -> URL {
        responsesDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encodePriorPrefixed(requestId)).json"
        )
    }

    /// Pre-records percent-encoded envelope path (flat, unprefixed).
    public func priorEncodedResponseFile(for requestId: String) -> URL {
        responsesDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encodePrior(requestId)).json"
        )
    }

    /// Legacy flat envelope path (pre path-encoding).
    public func legacyResponseFile(for requestId: String) -> URL {
        responsesDirectory.appendingPathComponent(
            "\(PathComponentEncoding.legacySanitize(requestId)).json"
        )
    }

    public func responseFileCandidates(for requestId: String) -> [URL] {
        uniqueURLs([
            responseFile(for: requestId),
            priorPrefixedResponseFile(for: requestId),
            priorEncodedResponseFile(for: requestId),
            legacyResponseFile(for: requestId),
        ])
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    /// Agent sidecar path under a dedicated subdirectory (never flat next to envelopes).
    ///
    /// Layout:
    /// - `responses/codex/<encoded>.json`
    /// - `responses/claude/<encoded>.json`
    /// - `responses/answer/<encoded>.json`
    ///
    /// Subdirectories eliminate collisions such as envelope id `codex-x` vs Codex
    /// sidecar for id `x` (previously both `codex-x.json` in the same folder).
    public func responseSidecarFile(agent: String, requestId: String) -> URL {
        let dir = responsesDirectory.appendingPathComponent(agent, isDirectory: true)
        return dir.appendingPathComponent("\(PathComponentEncoding.encode(requestId)).json")
    }
}

// MARK: - Path component encoding

/// Deterministic, collision-free encoding for arbitrary session / request IDs as
/// single path components.
///
/// **Canonical namespace (writes)**
/// - Files live under ``recordsDirectoryName`` (`records/`) so the filename body
///   never shares a flat directory with legacy or prior layouts. This is
///   **provably disjoint** from arbitrary legacy ids such as literal `n.foo`
///   (which previously collided with a flat `n.` filename prefix for id `foo`).
/// - Case-stable body: only lowercase ASCII `a–z`, digits, and `- . ~` are kept
///   unreserved. Uppercase letters and all other bytes are percent-encoded with
///   **uppercase** hex (`%XX`). `Hello` and `hello` therefore map to distinct
///   paths even on case-insensitive volumes (APFS default).
///
/// **Prior / legacy layouts (reads + migration only)**
/// - Flat `n.<body>.json` (intermediate/prior compatibility “prefix” layout)
/// - Flat unprefixed percent-encode (uppercase letters unreserved)
/// - Underscore sanitize (`/` and `:` → `_`), which collides (`a/b` vs `a_b`)
///
/// ``SessionPersistence`` migrates only after verifying the embedded session id
/// and never overwrites a canonical file owned by a different id.
public enum PathComponentEncoding: Sendable {
    /// Disjoint subdirectory for all new canonical session / response records.
    public static let recordsDirectoryName = "records"

    /// Filename marker used by the intermediate/prior flat `n.` layout (reads only).
    public static let priorPrefix = "n."

    /// Characters that never need escaping in a single filename component.
    /// Uppercase ASCII is intentionally **excluded** for case-stable paths.
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        set.insert(UInt8(ascii: "-"))
        set.insert(UInt8(ascii: "."))
        set.insert(UInt8(ascii: "~"))
        return set
    }()

    /// Collision-free encoding for a new write (case-stable body under `records/`).
    public static func encode(_ raw: String) -> String {
        encodeBody(raw)
    }

    /// Case-stable body only. Exposed for tests / diagnostics.
    public static func encodeBody(_ raw: String) -> String {
        encodeWithUnreserved(raw, unreserved: unreserved)
    }

    /// Flat `n.`-prefixed case-stable name (prior layout; not used for new writes).
    public static func encodePriorPrefixed(_ raw: String) -> String {
        priorPrefix + encodeBody(raw)
    }

    /// Pre-records percent encoding kept for read/migration candidates.
    ///
    /// Unreserved includes uppercase `A–Z` (case-**un**stable on APFS) and has no
    /// prefix — intermediate/prior layout before case-stable body encoding.
    public static func encodePrior(_ raw: String) -> String {
        encodeWithUnreserved(raw, unreserved: priorUnreserved)
    }

    private static let priorUnreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(c) }
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        set.insert(UInt8(ascii: "-"))
        set.insert(UInt8(ascii: "."))
        set.insert(UInt8(ascii: "~"))
        return set
    }()

    private static func encodeWithUnreserved(_ raw: String, unreserved: Set<UInt8>) -> String {
        var output = ""
        output.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            if unreserved.contains(byte) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output.append(contentsOf: String(format: "%%%02X", byte))
            }
        }
        return output.isEmpty ? "_empty" : output
    }

    /// Best-effort reverse of ``encode(_:)`` / ``encodeBody(_:)``.
    ///
    /// Does **not** strip ``priorPrefix`` — a body of `n.foo` (literal id) round-trips
    /// as `n.foo`. Use ``decodePriorPrefixed(_:)`` for flat `n.<body>` layout names.
    /// Returns `nil` if the string is not valid percent-encoding of UTF-8.
    public static func decode(_ encoded: String) -> String? {
        decodeBody(encoded)
    }

    /// Reverse of ``encodePriorPrefixed(_:)`` (`n.<body>` → raw id).
    public static func decodePriorPrefixed(_ encoded: String) -> String? {
        guard encoded.hasPrefix(priorPrefix) else { return nil }
        return decodeBody(String(encoded.dropFirst(priorPrefix.count)))
    }

    private static func decodeBody(_ body: String) -> String? {
        if body == "_empty" { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.utf8.count)
        let utf8 = Array(body.utf8)
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            if byte == UInt8(ascii: "%") {
                guard i + 2 < utf8.count else { return nil }
                let hi = utf8[i + 1]
                let lo = utf8[i + 2]
                guard let value = hexByte(hi: hi, lo: lo) else { return nil }
                bytes.append(value)
                i += 3
            } else {
                bytes.append(byte)
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexByte(hi: UInt8, lo: UInt8) -> UInt8? {
        guard let h = hexNibble(hi), let l = hexNibble(lo) else { return nil }
        return (h << 4) | l
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }

    /// Pre-encoding sanitize used by older Nocturnal builds.
    public static func legacySanitize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
