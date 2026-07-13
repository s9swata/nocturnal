import Foundation

/// Resolves the Unix domain socket path used for hook → app IPC.
///
/// Default (production):
/// `~/Library/Application Support/Nocturnal/ipc.sock`
///
/// Overrides (first match wins):
/// 1. `NOCTURNAL_SOCKET` environment variable
/// 2. Explicit path passed by caller
/// 3. Default Application Support path
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
    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        explicitSocketPath: String? = nil
    ) throws -> SocketPaths {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let nocturnalDir = appSupportRoot.appendingPathComponent("Nocturnal", isDirectory: true)
        try fileManager.createDirectory(at: nocturnalDir, withIntermediateDirectories: true)

        let socketPath: String
        if let explicitSocketPath, !explicitSocketPath.isEmpty {
            socketPath = explicitSocketPath
        } else if let env = environment["NOCTURNAL_SOCKET"], !env.isEmpty {
            socketPath = env
        } else {
            socketPath = nocturnalDir.appendingPathComponent("ipc.sock").path
        }

        return SocketPaths(
            socketURL: URL(fileURLWithPath: socketPath),
            applicationSupportDirectory: nocturnalDir
        )
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
