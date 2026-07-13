import Foundation

/// Contract for the fail-open stdin → socket bridge.
///
/// Rules:
/// 1. Always exit 0 from the CLI even when the app is not running (fail-open).
/// 2. Never block the agent longer than a short connect timeout.
/// 3. Pass through raw stdin bytes when possible; optional wrap into ``EventEnvelope``.
public protocol HookForwarding: Sendable {
    /// Forward a single NDJSON line (or raw JSON object) to the socket.
    /// Returns whether the write succeeded. Must not throw to the agent path.
    func forward(line: Data, socketPath: URL) -> HookForwardResult
}

public struct HookForwardResult: Sendable, Equatable {
    public var succeeded: Bool
    public var detail: String

    public init(succeeded: Bool, detail: String) {
        self.succeeded = succeeded
        self.detail = detail
    }
}

/// Options for the fail-open forwarder.
public struct HookForwarderOptions: Sendable, Equatable {
    /// Connect timeout in seconds.
    public var connectTimeout: TimeInterval
    /// When set, non-envelope JSON is wrapped via ``EnvelopeNormalizer`` with this source.
    public var wrapSource: AgentSource?
    /// Optional default session id when wrapping raw hooks that omit one.
    public var defaultSessionId: String?

    public static let `default` = HookForwarderOptions()

    public init(
        connectTimeout: TimeInterval = 0.5,
        wrapSource: AgentSource? = nil,
        defaultSessionId: String? = nil
    ) {
        self.connectTimeout = connectTimeout
        self.wrapSource = wrapSource
        self.defaultSessionId = defaultSessionId
    }
}

/// Default fail-open forwarder implementation.
public struct FailOpenHookForwarder: HookForwarding {
    public var options: HookForwarderOptions

    public init(options: HookForwarderOptions = .default) {
        self.options = options
    }

    public func forward(line: Data, socketPath: URL) -> HookForwardResult {
        let trimmed = line.trimmingCRLFPublic
        guard !trimmed.isEmpty else {
            return HookForwardResult(succeeded: true, detail: "empty line ignored")
        }

        let payload: Data
        if let wrapSource = options.wrapSource {
            let normalizer = EnvelopeNormalizer(
                defaultSource: wrapSource,
                defaultSessionId: options.defaultSessionId
            )
            if let envelope = normalizer.normalize(line: trimmed) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                if let encoded = try? encoder.encode(envelope) {
                    payload = encoded
                } else {
                    payload = trimmed
                }
            } else {
                return HookForwardResult(succeeded: true, detail: "empty after normalize")
            }
        } else {
            // Opportunistic wrap: if it is JSON but not an envelope, still send as-is
            // so the app-side decoder / store can apply EnvelopeNormalizer later if needed.
            payload = trimmed
        }

        do {
            let client = EventSocketClient(path: socketPath, connectTimeout: options.connectTimeout)
            try client.sendRawLine(payload)
            return HookForwardResult(succeeded: true, detail: "sent \(payload.count) bytes")
        } catch {
            // Fail open: agent continues.
            return HookForwardResult(
                succeeded: false,
                detail: "socket unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// Forward many lines; always aggregates without throwing.
    public func forwardAll(lines: [Data], socketPath: URL) -> [HookForwardResult] {
        lines.map { forward(line: $0, socketPath: socketPath) }
    }
}

/// Reads stdin fully (or line-by-line) for the forwarder CLI.
public enum StdinReader: Sendable {
    public static func readAll() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    public static func readLines() -> [Data] {
        let all = readAll()
        guard !all.isEmpty else { return [] }
        // Single non-NDJSON object (no trailing newline) still counts as one line.
        if !all.contains(0x0A) {
            return [all]
        }
        return all.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    }
}
