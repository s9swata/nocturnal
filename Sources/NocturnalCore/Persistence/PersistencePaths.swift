import Foundation

/// On-disk layout under Application Support (or test override).
///
/// ```
/// ~/Library/Application Support/Nocturnal/
///   ipc.sock
///   settings.json
///   sessions/
///     <encoded-session-id>.json
///   responses/
///     <encoded-request-id>.json          # ResponseFileEnvelope
///     codex/<encoded-request-id>.json    # agent sidecar (never flat with envelopes)
///     claude/<encoded-request-id>.json
///     answer/<encoded-request-id>.json
///   backups/
///     codex-hooks-*.json
///     claude-hooks-*.json
/// ```
///
/// Session and response filenames use ``PathComponentEncoding`` so arbitrary IDs
/// (`a/b` vs `a_b`, colons, etc.) never collide. Legacy underscore-sanitized
/// names are still recognized for reads/migration.
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

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for dir in [root, sessionsDirectory, responsesDirectory, backupsDirectory] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Session files

    /// Canonical (collision-free) session file path for writes.
    public func sessionFile(for id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encode(id.rawValue)).json"
        )
    }

    /// Legacy underscore-sanitized path used by older builds (`/` and `:` → `_`).
    public func legacySessionFile(for id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(PathComponentEncoding.legacySanitize(id.rawValue)).json"
        )
    }

    /// Candidate paths to try when reading a session (canonical first, then legacy).
    public func sessionFileCandidates(for id: SessionID) -> [URL] {
        let canonical = sessionFile(for: id)
        let legacy = legacySessionFile(for: id)
        if canonical == legacy { return [canonical] }
        return [canonical, legacy]
    }

    // MARK: - Response files

    /// Canonical envelope path for a request / prompt id.
    public func responseFile(for requestId: String) -> URL {
        responsesDirectory.appendingPathComponent(
            "\(PathComponentEncoding.encode(requestId)).json"
        )
    }

    /// Legacy flat envelope path (pre path-encoding).
    public func legacyResponseFile(for requestId: String) -> URL {
        responsesDirectory.appendingPathComponent(
            "\(PathComponentEncoding.legacySanitize(requestId)).json"
        )
    }

    public func responseFileCandidates(for requestId: String) -> [URL] {
        let canonical = responseFile(for: requestId)
        let legacy = legacyResponseFile(for: requestId)
        if canonical == legacy { return [canonical] }
        return [canonical, legacy]
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
/// **Encoding rules**
/// - Unreserved ASCII (`A–Z a–z 0–9 - . ~`) is kept as-is.
/// - Every other UTF-8 byte is percent-encoded (`%XX`, uppercase hex).
///
/// This makes `a/b` → `a%2Fb` and `a_b` → `a_b` distinct, and similarly separates
/// colon-bearing ids from underscore forms.
///
/// **Legacy** builds replaced only `/` and `:` with `_`, which collides
/// (`a/b` vs `a_b`). Readers still accept legacy names for migration.
public enum PathComponentEncoding: Sendable {
    /// Characters that never need escaping in a single filename component.
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(c) }
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        set.insert(UInt8(ascii: "-"))
        set.insert(UInt8(ascii: "."))
        set.insert(UInt8(ascii: "~"))
        return set
    }()

    /// Collision-free encoding for a new write.
    public static func encode(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            if unreserved.contains(byte) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output.append(contentsOf: String(format: "%%%02X", byte))
            }
        }
        // Empty ids still need a stable filename.
        return output.isEmpty ? "_empty" : output
    }

    /// Best-effort reverse of ``encode(_:)``. Returns `nil` if the string is not
    /// valid percent-encoding of UTF-8.
    public static func decode(_ encoded: String) -> String? {
        if encoded == "_empty" { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.utf8.count)
        let utf8 = Array(encoded.utf8)
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
