import Foundation

/// On-disk layout under Application Support (or test override).
///
/// ```
/// ~/Library/Application Support/Nocturnal/
///   ipc.sock
///   settings.json
///   sessions/
///     <session-id>.json
///   responses/
///     <request-id>.json
///   backups/
///     codex-hooks-*.json
///     claude-hooks-*.json
/// ```
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

    public func sessionFile(for id: SessionID) -> URL {
        // Sanitize path component
        let safe = id.rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sessionsDirectory.appendingPathComponent("\(safe).json")
    }

    public func responseFile(for requestId: String) -> URL {
        let safe = requestId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return responsesDirectory.appendingPathComponent("\(safe).json")
    }
}
