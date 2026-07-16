import Darwin
import Foundation

/// Contract for the fail-open stdin → socket bridge.
///
/// Rules:
/// 1. Always exit 0 from the CLI even when the app is not running (fail-open).
/// 2. Never block the agent longer than a short connect timeout.
/// 3. Normalize raw stdin into a canonical ``EventEnvelope`` before socket send.
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
    /// Connect timeout upper bound (seconds) safe for Int32 millisecond conversion.
    public static let maxConnectTimeout: TimeInterval = HookForwarderCLIOptions.maxTimeout
    /// Max seconds to wait for a Nocturnal UI decision on PermissionRequest.
    public static let maxDecisionTimeout: TimeInterval = 600
    /// Default UI wait for permission decisions (Codex hook timeout is often 600s).
    public static let defaultDecisionTimeout: TimeInterval = 120

    /// Connect timeout in seconds (always positive, finite, ≤ ``maxConnectTimeout``).
    public var connectTimeout: TimeInterval
    /// Hint for ``EnvelopeNormalizer`` when wrapping non-envelope JSON.
    public var wrapSource: AgentSource?
    /// Optional default session id when wrapping raw hooks that omit one.
    public var defaultSessionId: String?
    /// How long to block waiting for Allow/Deny in Nocturnal (decision mode).
    public var decisionTimeout: TimeInterval
    /// When true, timeout / app-down → deny instead of defer (fail-closed).
    public var failClosedOnTimeout: Bool

    public static let `default` = HookForwarderOptions()

    public init(
        connectTimeout: TimeInterval = HookForwarderCLIOptions.defaultTimeout,
        wrapSource: AgentSource? = nil,
        defaultSessionId: String? = nil,
        decisionTimeout: TimeInterval = HookForwarderOptions.defaultDecisionTimeout,
        failClosedOnTimeout: Bool = false
    ) {
        // Clamp so downstream EventSocketClient poll/setsockopt never trap on
        // Int32(timeout * 1000) with huge or non-finite values.
        if connectTimeout.isFinite, connectTimeout > 0 {
            self.connectTimeout = min(connectTimeout, Self.maxConnectTimeout)
        } else {
            self.connectTimeout = HookForwarderCLIOptions.defaultTimeout
        }
        self.wrapSource = wrapSource
        self.defaultSessionId = defaultSessionId
        if decisionTimeout.isFinite, decisionTimeout > 0 {
            self.decisionTimeout = min(decisionTimeout, Self.maxDecisionTimeout)
        } else {
            self.decisionTimeout = Self.defaultDecisionTimeout
        }
        self.failClosedOnTimeout = failClosedOnTimeout
    }
}

/// Result of a decision-mode forward (includes agent stdout body).
public struct HookForwardDecisionOutcome: Sendable, Equatable {
    public var forward: HookForwardResult
    /// Exact JSON to print on stdout for the agent hook (allow / deny / {}).
    public var stdoutJSON: String

    public init(forward: HookForwardResult, stdoutJSON: String) {
        self.forward = forward
        self.stdoutJSON = stdoutJSON
    }
}

/// Default fail-open forwarder implementation.
public struct FailOpenHookForwarder: HookForwarding {
    public var options: HookForwarderOptions

    public init(options: HookForwarderOptions = .default) {
        self.options = options
    }

    /// Legacy send-only path: never blocks on permission UI.
    ///
    /// Callers that need agent-facing Allow/Deny stdout must use
    /// ``forwardWithDecision(line:socketPath:)`` (CLI does).
    public func forward(line: Data, socketPath: URL) -> HookForwardResult {
        forwardInternal(line: line, socketPath: socketPath, requestDecision: false).forward
    }

    /// Forward one line; for permission events, waits for Nocturnal UI decision.
    public func forwardWithDecision(line: Data, socketPath: URL) -> HookForwardDecisionOutcome {
        forwardInternal(line: line, socketPath: socketPath, requestDecision: true)
    }

    private func forwardInternal(
        line: Data,
        socketPath: URL,
        requestDecision: Bool
    ) -> HookForwardDecisionOutcome {
        let trimmed = line.trimmingCRLFPublic
        guard !trimmed.isEmpty else {
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(succeeded: true, detail: "empty line ignored"),
                stdoutJSON: "{}"
            )
        }

        let normalizer = EnvelopeNormalizer(
            defaultSource: options.wrapSource ?? .unknown,
            defaultSessionId: options.defaultSessionId
        )
        guard var envelope = normalizer.normalize(line: trimmed) else {
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(succeeded: true, detail: "empty after normalize"),
                stdoutJSON: "{}"
            )
        }

        let needsDecision = requestDecision
            && HookDecisionTranslator.shouldRequestDecision(
                eventType: envelope.eventType,
                source: envelope.source,
                payload: envelope.payload
            )

        if needsDecision {
            envelope = HookDecisionTranslator.stampForDecision(
                envelope,
                timeoutSec: options.decisionTimeout
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(envelope) else {
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(succeeded: false, detail: "envelope encode failed"),
                stdoutJSON: failOpenStdout(needsDecision: needsDecision, envelope: envelope)
            )
        }

        let maxFrameBytes = StdinReader.defaultMaxBytes
        if payload.count > maxFrameBytes {
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(
                    succeeded: false,
                    detail:
                        "normalized envelope exceeds socket frame limit (\(payload.count) > \(maxFrameBytes) bytes)"
                ),
                stdoutJSON: failOpenStdout(needsDecision: needsDecision, envelope: envelope)
            )
        }

        let client = EventSocketClient(path: socketPath, connectTimeout: options.connectTimeout)

        if needsDecision {
            do {
                let reply = try client.sendAndReceiveDecision(
                    envelope,
                    receiveTimeout: options.decisionTimeout + 5
                )
                var result = reply.result
                if result.behavior == .defer, options.failClosedOnTimeout {
                    result = .denied("Nocturnal decision timed out")
                }
                let stdout = HookDecisionTranslator.stdoutJSON(for: envelope, result: result)
                return HookForwardDecisionOutcome(
                    forward: HookForwardResult(
                        succeeded: true,
                        detail: "decision \(result.behavior.rawValue)"
                    ),
                    stdoutJSON: stdout
                )
            } catch {
                return HookForwardDecisionOutcome(
                    forward: HookForwardResult(
                        succeeded: false,
                        detail: "decision socket unavailable: \(error.localizedDescription)"
                    ),
                    stdoutJSON: failOpenStdout(needsDecision: true, envelope: envelope)
                )
            }
        }

        do {
            try client.sendRawLine(payload)
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(succeeded: true, detail: "sent \(payload.count) bytes"),
                stdoutJSON: "{}"
            )
        } catch {
            return HookForwardDecisionOutcome(
                forward: HookForwardResult(
                    succeeded: false,
                    detail: "socket unavailable: \(error.localizedDescription)"
                ),
                stdoutJSON: "{}"
            )
        }
    }

    private func failOpenStdout(needsDecision: Bool, envelope: EventEnvelope) -> String {
        guard needsDecision else { return "{}" }
        if options.failClosedOnTimeout {
            return HookDecisionTranslator.stdoutJSON(
                for: envelope,
                result: .denied("Nocturnal unavailable")
            )
        }
        return "{}"
    }

    /// Forward many lines; always aggregates without throwing.
    public func forwardAll(lines: [Data], socketPath: URL) -> [HookForwardResult] {
        lines.map { forward(line: $0, socketPath: socketPath) }
    }
}

/// Bounded, timeout-aware stdin reader for hook processes.
///
/// Hooks must not hang the agent on a stuck pipe. Reads stop at EOF, ``maxBytes``,
/// or ``timeout`` — whichever comes first. Failures yield whatever was read
/// (possibly empty); the CLI still exits 0.
public enum StdinReader: Sendable {
    /// Default cap matches the socket server line limit (1 MiB).
    public static let defaultMaxBytes: Int = 1_048_576
    /// Hooks should finish writing promptly; 2s is generous for local pipes.
    public static let defaultTimeout: TimeInterval = 2.0

    public static func readAll(
        maxBytes: Int = defaultMaxBytes,
        timeout: TimeInterval = defaultTimeout
    ) -> Data {
        read(from: FileHandle.standardInput, maxBytes: maxBytes, timeout: timeout)
    }

    public static func readLines(
        maxBytes: Int = defaultMaxBytes,
        timeout: TimeInterval = defaultTimeout
    ) -> [Data] {
        let all = readAll(maxBytes: maxBytes, timeout: timeout)
        guard !all.isEmpty else { return [] }
        // Single non-NDJSON object (no trailing newline) still counts as one line.
        if !all.contains(0x0A) {
            return [all]
        }
        return all.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    }

    /// Read from an arbitrary handle (tests inject pipes).
    public static func read(
        from handle: FileHandle,
        maxBytes: Int = defaultMaxBytes,
        timeout: TimeInterval = defaultTimeout
    ) -> Data {
        let fd = handle.fileDescriptor
        guard fd >= 0, maxBytes > 0 else { return Data() }

        let previousFlags = fcntl(fd, F_GETFL)
        if previousFlags >= 0 {
            _ = fcntl(fd, F_SETFL, previousFlags | O_NONBLOCK)
        }
        defer {
            if previousFlags >= 0 {
                _ = fcntl(fd, F_SETFL, previousFlags)
            }
        }

        var result = Data()
        result.reserveCapacity(min(maxBytes, 64 * 1024))
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while result.count < maxBytes {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(min(max(remaining * 1000.0, 1.0), Double(Int32.max - 1)))
            let pr = poll(&pfd, 1, waitMs)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 {
                break // timeout with no data
            }

            let toRead = min(buffer.count, maxBytes - result.count)
            let n = Darwin.read(fd, &buffer, toRead)
            if n > 0 {
                result.append(buffer, count: n)
            } else if n == 0 {
                break // EOF
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                break
            }
        }

        return result
    }
}
