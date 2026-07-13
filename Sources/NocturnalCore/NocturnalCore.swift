import Foundation

/// Module façade and version metadata for NocturnalCore.
public enum NocturnalCore {
    public static let moduleName = "NocturnalCore"
    public static let version = "0.1.0"

    /// Envelope schema version currently emitted/accepted by this build.
    public static var eventSchemaVersion: Int { EventEnvelope.currentSchemaVersion }

    /// Convenience bootstrap for hosts that want paths + store + persistence wired.
    public static func makeRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> NocturnalRuntime {
        let paths = try PersistencePaths.resolve(fileManager: fileManager, environment: environment)
        let persistence = SessionPersistence(paths: paths)
        let settings = SettingsStore(paths: paths)
        let store = SessionStore(
            policy: SessionStorePolicy(autoPersist: true),
            persistence: persistence
        )
        let socket = EventSocketServer(path: paths.socketURL)
        let responses = FileResponseTransport(paths: paths)
        return NocturnalRuntime(
            paths: paths,
            store: store,
            persistence: persistence,
            settings: settings,
            socketServer: socket,
            responseTransport: responses
        )
    }
}

/// Bundled runtime handles for the app host (UI) and tests.
public struct NocturnalRuntime: Sendable {
    public let paths: PersistencePaths
    public let store: SessionStore
    public let persistence: SessionPersistence
    public let settings: SettingsStore
    public let socketServer: EventSocketServer
    public let responseTransport: FileResponseTransport

    public init(
        paths: PersistencePaths,
        store: SessionStore,
        persistence: SessionPersistence,
        settings: SettingsStore,
        socketServer: EventSocketServer,
        responseTransport: FileResponseTransport
    ) {
        self.paths = paths
        self.store = store
        self.persistence = persistence
        self.settings = settings
        self.socketServer = socketServer
        self.responseTransport = responseTransport
    }
}
