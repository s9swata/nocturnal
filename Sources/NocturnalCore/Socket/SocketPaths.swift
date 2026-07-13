import Foundation

/// Resolves the Unix domain socket path used for hook → app IPC.
///
/// Default (production):
/// `~/Library/Application Support/Nocturnal/ipc.sock`
///
/// **Precedence** (first match wins):
/// 1. Explicit path passed by the caller (`explicitSocketPath`)
/// 2. `NOCTURNAL_SOCKET` environment variable
/// 3. Default under Application Support / `NOCTURNAL_APP_SUPPORT`
///
/// **Side effects:** when an explicit or env socket override is usable, this
/// resolver does **not** eagerly create the Application Support tree — only the
/// parent directory of the chosen socket path is ensured by the listener on bind.
/// Application Support is created only when it is needed as the data root
/// (default socket path, or when resolving app-support for persistence).
///
/// Development / CI may use `/tmp/nocturnal-$UID.sock` via the env var.
public struct SocketPaths: Sendable, Equatable {
    public var socketURL: URL
    public var applicationSupportDirectory: URL

    public init(socketURL: URL, applicationSupportDirectory: URL) {
        self.socketURL = socketURL
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    /// Resolve paths using process environment and standard FileManager locations.
    ///
    /// - Parameters:
    ///   - explicitSocketPath: Caller override; **wins over** `NOCTURNAL_SOCKET`.
    ///   - environment: Injectable env for tests (`NOCTURNAL_SOCKET`, `NOCTURNAL_APP_SUPPORT`).
    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        explicitSocketPath: String? = nil
    ) throws -> SocketPaths {
        let appSupportDir = try resolveApplicationSupportDirectory(
            fileManager: fileManager,
            environment: environment,
            create: false
        )

        let socketPath: String
        let hasExplicit = explicitSocketPath.map { !$0.isEmpty } ?? false
        let envSocket = environment[NocturnalEnvironmentKey.socket.rawValue]
        let hasEnvSocket = envSocket.map { !$0.isEmpty } ?? false

        if hasExplicit, let explicitSocketPath {
            // 1. Explicit caller override — no need to create App Support.
            socketPath = explicitSocketPath
        } else if hasEnvSocket, let envSocket {
            // 2. Environment override — still no eager App Support create.
            socketPath = envSocket
        } else {
            // 3. Default under app support — ensure the directory exists.
            let ensured = try resolveApplicationSupportDirectory(
                fileManager: fileManager,
                environment: environment,
                create: true
            )
            socketPath = ensured.appendingPathComponent("ipc.sock").path
            return SocketPaths(
                socketURL: URL(fileURLWithPath: socketPath),
                applicationSupportDirectory: ensured
            )
        }

        return SocketPaths(
            socketURL: URL(fileURLWithPath: socketPath),
            applicationSupportDirectory: appSupportDir
        )
    }

    /// Resolve Application Support / `NOCTURNAL_APP_SUPPORT` directory.
    ///
    /// - Parameter create: When `false`, returns the path without creating it
    ///   (used when a socket override makes the default tree unnecessary).
    public static func resolveApplicationSupportDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        create: Bool
    ) throws -> URL {
        if let override = environment[NocturnalEnvironmentKey.appSupport.rawValue], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            if create {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            }
            return root
        }
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let nocturnalDir = appSupportRoot.appendingPathComponent("Nocturnal", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: nocturnalDir, withIntermediateDirectories: true)
        }
        return nocturnalDir
    }

    /// Convenience path string for CLIs and docs.
    public var socketPath: String {
        socketURL.path
    }

    /// Suggested ephemeral path for automated tests (does not create files).
    ///
    /// Prefer a short directory (e.g. under `/tmp`) — macOS `sun_path` is ~104
    /// bytes; deep UUID temp paths often exceed it.
    public static func testingSocketPath(in temporaryDirectory: URL, name: String = "ipc.sock") -> URL {
        temporaryDirectory.appendingPathComponent(name)
    }

    /// Short AF_UNIX-safe root under `/tmp` for socket tests and local sim.
    /// Caller owns cleanup of the created directory.
    public static func makeShortTestingRoot(prefix: String = "noc") throws -> URL {
        let short = String(UUID().uuidString.prefix(8))
        let url = URL(fileURLWithPath: "/tmp/\(prefix)-\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Well-known environment variable names used across app and CLIs.
public enum NocturnalEnvironmentKey: String, Sendable {
    case socket = "NOCTURNAL_SOCKET"
    case appSupport = "NOCTURNAL_APP_SUPPORT"
    case homeOverride = "NOCTURNAL_HOME"
    /// When set to `1`, setup CLI operates only under a sandbox root (tests).
    case configRoot = "NOCTURNAL_CONFIG_ROOT"
}
