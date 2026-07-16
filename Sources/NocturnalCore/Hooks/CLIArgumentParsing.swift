import Foundation

/// Result of looking up a flag that requires a value.
public enum CLIFlagValue: Sendable, Equatable {
    /// Flag is not present in the argument list.
    case absent
    /// Flag is present but the next token is missing or is itself a flag.
    case missingValue
    /// Flag is present with a usable value token.
    case value(String)
}

/// Shared CLI flag parsing for hook-forwarder and setup tools.
///
/// Flags that require a value never consume a following flag (`--foo`, `-x`)
/// or an empty remainder as their value.
public enum CLIArgumentParser: Sendable {
    /// Returns the value for `flag` (exact match, e.g. `"--socket"`).
    public static func value(for flag: String, in args: [String]) -> CLIFlagValue {
        guard let idx = args.firstIndex(of: flag) else {
            return .absent
        }
        let next = args.index(after: idx)
        guard next < args.endIndex else {
            return .missingValue
        }
        let candidate = args[next]
        // Empty tokens (e.g. `--forwarder ""`) are not usable values.
        if candidate.isEmpty || isFlagToken(candidate) {
            return .missingValue
        }
        return .value(candidate)
    }

    /// True when `token` looks like a CLI flag rather than a value.
    ///
    /// A bare `-` (stdin convention) is **not** treated as a flag so it can be
    /// a path value if needed. Numeric-looking short tokens like `-0.5` are values.
    public static func isFlagToken(_ token: String) -> Bool {
        if token == "-" { return false }
        if token.hasPrefix("--") { return true }
        if token.hasPrefix("-"), token.count > 1 {
            let body = token.dropFirst()
            // Allow negative numbers as values (e.g. unlikely timeouts).
            if body.allSatisfy({ $0.isNumber || $0 == "." }) {
                return false
            }
            return true
        }
        return false
    }
}

// MARK: - Setup CLI parse (testable)

public enum SetupCLIParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingProductValue
    case unknownProduct(String)
    case missingForwarderValue
    case missingModeValue
    case unknownMode(String)

    public var description: String {
        switch self {
        case .missingProductValue:
            return "missing value for --product (expected codex|claude|opencode|all)"
        case .unknownProduct(let raw):
            return "unknown product: \(raw) (expected codex|claude|opencode|all)"
        case .missingForwarderValue:
            return "missing value for --forwarder (expected path to nocturnal-hook-forwarder)"
        case .missingModeValue:
            return "missing value for --mode (expected sidecar|merge-native)"
        case .unknownMode(let raw):
            return "unknown mode: \(raw) (expected sidecar|merge-native)"
        }
    }
}

/// Parsed options for `nocturnal-setup` (library-testable; no process I/O).
public struct SetupCLIOptions: Sendable, Equatable {
    public var products: [HookProduct]
    /// Explicit `--forwarder` path. `nil` means the CLI may auto-discover.
    public var forwarderPath: URL?
    public var mode: HookInstallMode
    public var dryRun: Bool

    public init(
        products: [HookProduct] = HookProduct.allCases,
        forwarderPath: URL? = nil,
        mode: HookInstallMode = .mergeNative,
        dryRun: Bool = false
    ) {
        self.products = products
        self.forwarderPath = forwarderPath
        self.mode = mode
        self.dryRun = dryRun
    }

    /// Parse option flags from argv (without the executable name).
    ///
    /// - `--product` / `--forwarder` **absent** → product defaults to all, forwarder stays nil.
    /// - `--product` / `--forwarder` **present without a value** → ``SetupCLIParseError`` (never silent default).
    public static func parse(arguments args: [String]) throws -> SetupCLIOptions {
        var options = SetupCLIOptions()
        options.dryRun = args.contains("--dry-run")

        switch CLIArgumentParser.value(for: "--product", in: args) {
        case .absent:
            options.products = HookProduct.allCases
        case .missingValue:
            throw SetupCLIParseError.missingProductValue
        case .value(let raw):
            switch raw.lowercased() {
            case "all":
                options.products = HookProduct.allCases
            case "codex":
                options.products = [.codex]
            case "claude":
                options.products = [.claude]
            case "opencode", "open-code", "open_code":
                options.products = [.opencode]
            default:
                throw SetupCLIParseError.unknownProduct(raw)
            }
        }

        switch CLIArgumentParser.value(for: "--forwarder", in: args) {
        case .absent:
            options.forwarderPath = nil
        case .missingValue:
            throw SetupCLIParseError.missingForwarderValue
        case .value(let path):
            options.forwarderPath = URL(fileURLWithPath: path)
        }

        switch CLIArgumentParser.value(for: "--mode", in: args) {
        case .absent:
            options.mode = .mergeNative
        case .missingValue:
            throw SetupCLIParseError.missingModeValue
        case .value(let raw):
            switch raw.lowercased() {
            case "sidecar":
                options.mode = .sidecar
            case "merge-native", "merge", "native":
                options.mode = .mergeNative
            default:
                throw SetupCLIParseError.unknownMode(raw)
            }
        }

        return options
    }
}

// MARK: - Hook forwarder CLI parse (testable, fail-open friendly)

/// Parsed options for `nocturnal-hook-forwarder`.
///
/// Invalid flag values are recorded in ``warnings`` and ignored so the process
/// can still fail-open with defaults.
public struct HookForwarderCLIOptions: Sendable, Equatable {
    /// Default connect timeout (seconds) when `--timeout` is omitted or invalid.
    public static let defaultTimeout: TimeInterval = 0.5

    /// Maximum connect timeout (seconds) accepted from CLI.
    ///
    /// Downstream `poll` / `setsockopt` paths convert seconds → milliseconds into
    /// `Int32`. Integer division keeps `maxTimeout * 1000` strictly inside Int32
    /// (avoids Double rounding that can push `Double(Int32.max - 1) / 1000 * 1000`
    /// just over the edge).
    public static let maxTimeout: TimeInterval = Double(Int32.max / 1000)

    public var socketPath: String?
    public var wrapSource: AgentSource?
    public var sessionId: String?
    public var timeout: TimeInterval
    /// Optional UI wait for PermissionRequest (seconds).
    public var decisionTimeout: TimeInterval?
    public var helpRequested: Bool
    public var warnings: [String]

    public init(
        socketPath: String? = nil,
        wrapSource: AgentSource? = nil,
        sessionId: String? = nil,
        timeout: TimeInterval = HookForwarderCLIOptions.defaultTimeout,
        decisionTimeout: TimeInterval? = nil,
        helpRequested: Bool = false,
        warnings: [String] = []
    ) {
        self.socketPath = socketPath
        self.wrapSource = wrapSource
        self.sessionId = sessionId
        self.timeout = timeout
        self.decisionTimeout = decisionTimeout
        self.helpRequested = helpRequested
        self.warnings = warnings
    }

    public static func parse(arguments args: [String]) -> HookForwarderCLIOptions {
        var options = HookForwarderCLIOptions()
        options.helpRequested = args.contains("--help") || args.contains("-h")

        switch CLIArgumentParser.value(for: "--socket", in: args) {
        case .absent:
            break
        case .missingValue:
            options.warnings.append("missing value for --socket; using environment/default")
        case .value(let path):
            options.socketPath = path
        }

        switch CLIArgumentParser.value(for: "--wrap-source", in: args) {
        case .absent:
            break
        case .missingValue:
            options.warnings.append("missing value for --wrap-source; not wrapping")
        case .value(let raw):
            switch raw.lowercased() {
            case "codex":
                options.wrapSource = .codex
            case "claude":
                options.wrapSource = .claude
            case "opencode", "open-code", "open_code":
                options.wrapSource = .opencode
            default:
                options.warnings.append("unknown wrap-source \(raw) (use codex|claude|opencode)")
            }
        }

        switch CLIArgumentParser.value(for: "--session-id", in: args) {
        case .absent:
            break
        case .missingValue:
            options.warnings.append("missing value for --session-id; ignoring")
        case .value(let id):
            options.sessionId = id
        }

        switch CLIArgumentParser.value(for: "--timeout", in: args) {
        case .absent:
            break
        case .missingValue:
            options.warnings.append("missing value for --timeout; using default \(defaultTimeout)s")
        case .value(let raw):
            options.timeout = sanitizeTimeout(raw, warnings: &options.warnings)
        }

        switch CLIArgumentParser.value(for: "--decision-timeout", in: args) {
        case .absent:
            break
        case .missingValue:
            options.warnings.append("missing value for --decision-timeout; using default")
        case .value(let raw):
            if let value = TimeInterval(raw), value.isFinite, value > 0 {
                options.decisionTimeout = min(value, HookForwarderOptions.maxDecisionTimeout)
            } else {
                options.warnings.append("invalid --decision-timeout \(raw); ignoring")
            }
        }

        return options
    }

    /// Parse and clamp a timeout token to a positive finite, Int32-ms-safe range.
    ///
    /// Invalid / non-finite / non-positive values fall back to ``defaultTimeout``
    /// with a warning so the forwarder remains fail-open (always exit 0).
    public static func sanitizeTimeout(_ raw: String, warnings: inout [String]) -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite, value > 0 else {
            warnings.append("invalid --timeout \(raw); using default \(defaultTimeout)s")
            return defaultTimeout
        }
        if value > maxTimeout {
            warnings.append("--timeout \(raw) exceeds max \(maxTimeout)s; capped")
            return maxTimeout
        }
        return value
    }
}
