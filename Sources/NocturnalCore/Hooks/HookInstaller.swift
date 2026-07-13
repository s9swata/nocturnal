import Foundation

/// Which agent product's hook config is being managed.
public enum HookProduct: String, Sendable, CaseIterable {
    case codex
    case claude
}

public enum HookInstallAction: String, Sendable {
    case install
    case uninstall
    case status
}

/// How aggressively to write agent config.
public enum HookInstallMode: String, Sendable, CaseIterable {
    /// Only write Nocturnal-managed sidecar files (`nocturnal-hooks.json`).
    case sidecar
    /// Sidecar + best-effort merge into product-native config files (backed up first).
    case mergeNative
}

public struct HookInstallResult: Sendable, Equatable {
    public var product: HookProduct
    public var action: HookInstallAction
    public var succeeded: Bool
    public var message: String
    public var backupPath: String?
    public var configPath: String?
    public var nativeConfigPath: String?
    public var dryRun: Bool

    public init(
        product: HookProduct,
        action: HookInstallAction,
        succeeded: Bool,
        message: String,
        backupPath: String? = nil,
        configPath: String? = nil,
        nativeConfigPath: String? = nil,
        dryRun: Bool = false
    ) {
        self.product = product
        self.action = action
        self.succeeded = succeeded
        self.message = message
        self.backupPath = backupPath
        self.configPath = configPath
        self.nativeConfigPath = nativeConfigPath
        self.dryRun = dryRun
    }
}

/// Safe, idempotent hook installer for Codex + Claude.
///
/// **Never** uses real user homes in unit tests. Pass ``configRoot`` pointing
/// at a temporary directory, or set `NOCTURNAL_CONFIG_ROOT`.
///
/// ## Paths (under `configRoot`, default `$HOME`)
///
/// | Product | Sidecar | Native merge target |
/// |---------|---------|---------------------|
/// | Codex | `.codex/nocturnal-hooks.json` | `.codex/hooks.json` (JSON array/object of hook commands) |
/// | Claude | `.claude/nocturnal-hooks.json` | `.claude/settings.json` (`hooks` key) |
///
/// Native formats evolve; merge is best-effort and always preceded by a timestamped
/// backup under Application Support `backups/`. Sidecar remains the authoritative
/// Nocturnal-owned descriptor.
public struct HookInstaller: Sendable {
    public static let managedMarkerBegin = "# >>> nocturnal-managed"
    public static let managedMarkerEnd = "# <<< nocturnal-managed"
    public static let managedKey = "nocturnalManaged"
    public static let managedCommandMarker = "nocturnal-hook-forwarder"

    public var configRoot: URL
    public var forwarderBinaryPath: URL
    public var socketPath: URL
    public var backupsDirectory: URL
    public var mode: HookInstallMode
    public var dryRun: Bool

    public init(
        configRoot: URL,
        forwarderBinaryPath: URL,
        socketPath: URL,
        backupsDirectory: URL,
        mode: HookInstallMode = .sidecar,
        dryRun: Bool = false
    ) {
        self.configRoot = configRoot
        self.forwarderBinaryPath = forwarderBinaryPath
        self.socketPath = socketPath
        self.backupsDirectory = backupsDirectory
        self.mode = mode
        self.dryRun = dryRun
    }

    /// Resolve installer using environment (production) or explicit root (tests).
    public static func resolve(
        forwarderBinaryPath: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        mode: HookInstallMode = .sidecar,
        dryRun: Bool = false
    ) throws -> HookInstaller {
        let home: URL
        if let root = environment[NocturnalEnvironmentKey.configRoot.rawValue], !root.isEmpty {
            home = URL(fileURLWithPath: root, isDirectory: true)
        } else if let homeEnv = environment["HOME"], !homeEnv.isEmpty {
            home = URL(fileURLWithPath: homeEnv, isDirectory: true)
        } else {
            home = fileManager.homeDirectoryForCurrentUser
        }

        // Socket resolution lives in PersistencePaths (NOCTURNAL_SOCKET + default).
        let paths = try PersistencePaths.resolve(fileManager: fileManager, environment: environment)

        return HookInstaller(
            configRoot: home,
            forwarderBinaryPath: forwarderBinaryPath,
            socketPath: paths.socketURL,
            backupsDirectory: paths.backupsDirectory,
            mode: mode,
            dryRun: dryRun
        )
    }

    public func configURL(for product: HookProduct) -> URL {
        switch product {
        case .codex:
            return configRoot
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("nocturnal-hooks.json")
        case .claude:
            return configRoot
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("nocturnal-hooks.json")
        }
    }

    /// Product-native config path used by ``HookInstallMode/mergeNative``.
    public func nativeConfigURL(for product: HookProduct) -> URL {
        switch product {
        case .codex:
            return configRoot
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks.json")
        case .claude:
            return configRoot
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
    }

    public func status(product: HookProduct) -> HookInstallResult {
        let url = configURL(for: product)
        let installed = FileManager.default.fileExists(atPath: url.path)
        let native = nativeConfigURL(for: product)
        let nativeHasManaged = (try? String(contentsOf: native, encoding: .utf8))?.contains(Self.managedCommandMarker) == true
        var message = installed ? "Nocturnal hooks present (sidecar)" : "Nocturnal hooks not installed"
        if nativeHasManaged {
            message += "; native config references forwarder"
        }
        return HookInstallResult(
            product: product,
            action: .status,
            succeeded: true,
            message: message,
            configPath: url.path,
            nativeConfigPath: native.path,
            dryRun: dryRun
        )
    }

    @discardableResult
    public func install(product: HookProduct) throws -> HookInstallResult {
        let fm = FileManager.default
        let url = configURL(for: product)
        let dir = url.deletingLastPathComponent()

        if !dryRun {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var backupPath: String?
        if fm.fileExists(atPath: url.path) {
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               existing.contains(Self.managedKey) || existing.contains(Self.managedMarkerBegin)
            {
                // Idempotent: refresh content only if forwarder/socket changed.
                let body = hookConfigJSON(for: product)
                if existing == body {
                    var result = HookInstallResult(
                        product: product,
                        action: .install,
                        succeeded: true,
                        message: dryRun ? "Would skip (already installed, identical)" : "Already installed (idempotent)",
                        configPath: url.path,
                        dryRun: dryRun
                    )
                    if mode == .mergeNative {
                        let merge = try mergeNative(product: product)
                        result.backupPath = merge.backupPath
                        result.nativeConfigPath = merge.nativeConfigPath
                        result.message += "; \(merge.message)"
                    }
                    return result
                }
            }
            // Backup before overwriting any existing file (managed refresh, foreign, or invalid).
            if !dryRun {
                backupPath = try backupExisting(url: url, product: product, label: "sidecar").path
            } else {
                backupPath = "(dry-run backup)"
            }
        }

        let body = hookConfigJSON(for: product)
        if !dryRun {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        var message = dryRun ? "Would install Nocturnal hooks (sidecar)" : "Installed Nocturnal hooks"
        var nativePath: String?
        var mergeBackup: String?

        if mode == .mergeNative {
            let merge = try mergeNative(product: product)
            message += "; \(merge.message)"
            nativePath = merge.nativeConfigPath
            mergeBackup = merge.backupPath ?? backupPath
            backupPath = mergeBackup ?? backupPath
        }

        return HookInstallResult(
            product: product,
            action: .install,
            succeeded: true,
            message: message,
            backupPath: backupPath,
            configPath: url.path,
            nativeConfigPath: nativePath,
            dryRun: dryRun
        )
    }

    @discardableResult
    public func uninstall(product: HookProduct) throws -> HookInstallResult {
        let fm = FileManager.default
        let url = configURL(for: product)
        var backupPath: String?
        var messages: [String] = []

        if fm.fileExists(atPath: url.path) {
            if !dryRun {
                backupPath = try backupExisting(url: url, product: product, label: "sidecar").path
                try fm.removeItem(at: url)
            } else {
                backupPath = "(dry-run backup)"
            }
            messages.append(dryRun ? "Would remove sidecar" : "Removed sidecar")
        } else {
            messages.append("Nothing to uninstall (sidecar)")
        }

        if mode == .mergeNative {
            let unmerge = try unmergeNative(product: product)
            messages.append(unmerge.message)
            if backupPath == nil { backupPath = unmerge.backupPath }
        }

        return HookInstallResult(
            product: product,
            action: .uninstall,
            succeeded: true,
            message: messages.joined(separator: "; "),
            backupPath: backupPath,
            configPath: url.path,
            nativeConfigPath: nativeConfigURL(for: product).path,
            dryRun: dryRun
        )
    }

    // MARK: - Native merge

    private struct MergeOutcome {
        var message: String
        var backupPath: String?
        var nativeConfigPath: String?
    }

    private func mergeNative(product: HookProduct) throws -> MergeOutcome {
        switch product {
        case .codex:
            return try mergeCodexNative()
        case .claude:
            return try mergeClaudeNative()
        }
    }

    private func unmergeNative(product: HookProduct) throws -> MergeOutcome {
        switch product {
        case .codex:
            return try unmergeCodexNative()
        case .claude:
            return try unmergeClaudeNative()
        }
    }

    /// Codex `hooks.json`: object with `hooks` array of command strings/objects, or a bare array.
    private func mergeCodexNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .codex)
        let command = forwarderCommand()
        let fm = FileManager.default

        if !dryRun {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var backupPath: String?
        let managedEntry: [String: Any] = [
            "command": command,
            Self.managedKey: true,
            "events": Array(CodexEventDecoder.implementedEventTypes).sorted(),
        ]
        var root: [String: Any] = [
            Self.managedKey: true,
            "version": 1,
            "hooks": [managedEntry],
        ]

        if fm.fileExists(atPath: url.path) {
            // Always backup existing native config before overwrite — including malformed JSON.
            if !dryRun {
                backupPath = try backupExisting(url: url, product: .codex, label: "native").path
            } else {
                backupPath = "(dry-run backup)"
            }

            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data)
            {
                if var obj = json as? [String: Any] {
                    var hooks = codexHooksArray(from: obj["hooks"])
                    hooks.removeAll { isManagedCodexHookEntry($0) }
                    hooks.append(managedEntry)
                    obj["hooks"] = hooks
                    obj[Self.managedKey] = true
                    root = obj
                } else if let arr = json as? [Any] {
                    var hooks = arr
                    hooks.removeAll { isManagedCodexHookEntry($0) }
                    hooks.append(managedEntry)
                    // Prefer object shape going forward; preserve non-managed entries (incl. strings).
                    root = [Self.managedKey: true, "hooks": hooks]
                }
                // else: unparseable shape after JSONSerialization — use fresh managed root
            }
            // else: invalid JSON — backup already taken; write fresh managed root
        }

        if !dryRun {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
        }

        return MergeOutcome(
            message: dryRun ? "Would merge into .codex/hooks.json" : "Merged into .codex/hooks.json",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    private func unmergeCodexNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .codex)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return MergeOutcome(message: "No native Codex hooks to unmerge", nativeConfigPath: url.path)
        }

        var backupPath: String?
        if !dryRun {
            backupPath = try backupExisting(url: url, product: .codex, label: "native").path
        }

        if var obj = json as? [String: Any] {
            var hooks = codexHooksArray(from: obj["hooks"])
            hooks.removeAll { isManagedCodexHookEntry($0) }
            obj["hooks"] = hooks
            obj.removeValue(forKey: Self.managedKey)
            if !dryRun {
                let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: url, options: [.atomic])
            }
        } else if let arr = json as? [Any] {
            let hooks = arr.filter { !isManagedCodexHookEntry($0) }
            if !dryRun {
                let out = try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: url, options: [.atomic])
            }
        }

        return MergeOutcome(
            message: dryRun ? "Would unmerge Codex native hooks" : "Unmerged Codex native hooks",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    /// Claude `settings.json`: merge a `hooks` map with command entries.
    private func mergeClaudeNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .claude)
        let command = forwarderCommand() + " --wrap-source claude"
        let fm = FileManager.default

        if !dryRun {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var backupPath: String?
        var root: [String: Any] = [:]

        if fm.fileExists(atPath: url.path) {
            // Always backup before overwrite — including malformed JSON.
            if !dryRun {
                backupPath = try backupExisting(url: url, product: .claude, label: "native").path
            } else {
                backupPath = "(dry-run backup)"
            }

            if let data = try? Data(contentsOf: url),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                root = obj
            }
            // else: invalid JSON → write managed hooks into a fresh root after backup
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let eventNames = [
            "SessionStart", "SessionEnd", "Notification",
            "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop",
        ]
        for event in eventNames {
            var list = hooks[event] as? [[String: Any]] ?? []
            list.removeAll { entryContainsForwarder($0) }
            list.append([
                Self.managedKey: true,
                "hooks": [[
                    "type": "command",
                    "command": command,
                    Self.managedKey: true,
                ]],
            ])
            hooks[event] = list
        }
        root["hooks"] = hooks
        root[Self.managedKey] = true

        if !dryRun {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
        }

        return MergeOutcome(
            message: dryRun ? "Would merge into .claude/settings.json" : "Merged into .claude/settings.json",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    private func unmergeClaudeNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .claude)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return MergeOutcome(message: "No native Claude settings to unmerge", nativeConfigPath: url.path)
        }

        var backupPath: String?
        if !dryRun {
            backupPath = try backupExisting(url: url, product: .claude, label: "native").path
        }

        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if var list = hooks[key] as? [[String: Any]] {
                    list.removeAll { entryContainsForwarder($0) }
                    if list.isEmpty {
                        hooks.removeValue(forKey: key)
                    } else {
                        hooks[key] = list
                    }
                }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
        }
        root.removeValue(forKey: Self.managedKey)

        if !dryRun {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: [.atomic])
        }

        return MergeOutcome(
            message: dryRun ? "Would unmerge Claude native hooks" : "Unmerged Claude native hooks",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    private func entryContainsForwarder(_ entry: [String: Any]) -> Bool {
        if entry[Self.managedKey] as? Bool == true { return true }
        if let command = entry["command"] as? String, command.contains(Self.managedCommandMarker) {
            return true
        }
        if let nested = entry["hooks"] as? [[String: Any]] {
            return nested.contains { entryContainsForwarder($0) }
        }
        return false
    }

    /// Preserve string-format Codex hook entries when merging (do not drop them).
    private func codexHooksArray(from value: Any?) -> [Any] {
        guard let value else { return [] }
        if let arr = value as? [Any] {
            return arr
        }
        // Single string or object under "hooks" — wrap.
        if value is String || value is [String: Any] {
            return [value]
        }
        return []
    }

    private func isManagedCodexHookEntry(_ entry: Any) -> Bool {
        if let command = entry as? String {
            return command.contains(Self.managedCommandMarker)
        }
        if let hook = entry as? [String: Any] {
            if hook[Self.managedKey] as? Bool == true { return true }
            if let command = hook["command"] as? String, command.contains(Self.managedCommandMarker) {
                return true
            }
        }
        return false
    }

    // MARK: - Shared

    private func backupExisting(url: URL, product: HookProduct, label: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = backupsDirectory.appendingPathComponent("\(product.rawValue)-\(label)-\(stamp).json")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: url, to: dest)
        return dest
    }

    /// POSIX single-quote shell escaping for paths that may contain spaces
    /// (e.g. default Application Support).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for embedding inside a JSON double-quoted string value.
    ///
    /// Handles backslash, quotes, and all JSON control characters (`\n`, `\r`,
    /// `\t`, `\u0000`–`\u001F`, etc.). Incomplete escaping (slash/quote only)
    /// produces invalid sidecar JSON when forwarder/socket paths contain those
    /// characters.
    public static func escapeJSONStringContents(_ value: String) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        ),
           let quoted = String(data: data, encoding: .utf8),
           quoted.count >= 2,
           quoted.first == "\"",
           quoted.last == "\""
        {
            return String(quoted.dropFirst().dropLast())
        }
        // Fallback: manual RFC 8259 string content escaping.
        var out = ""
        out.reserveCapacity(value.utf8.count + 8)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\"" // "
            case 0x5C: out += "\\\\" // \
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public func forwarderCommand() -> String {
        let socket = Self.shellQuote(socketPath.path)
        let binary = Self.shellQuote(forwarderBinaryPath.path)
        return "NOCTURNAL_SOCKET=\(socket) \(binary)"
    }

    /// Minimal hook command config pointing at the forwarder.
    /// Real Codex/Claude integration details are documented in HOOK_SCHEMAS.md;
    /// this file is a Nocturnal-managed sidecar the setup CLI owns.
    public func hookConfigJSON(for product: HookProduct) -> String {
        let command = forwarderCommand()
        let escaped = Self.escapeJSONStringContents(command)
        let forwarderEscaped = Self.escapeJSONStringContents(forwarderBinaryPath.path)
        let socketEscaped = Self.escapeJSONStringContents(socketPath.path)
        let productEscaped = Self.escapeJSONStringContents(product.rawValue)

        return """
        {
          "\(Self.managedKey)": true,
          "product": "\(productEscaped)",
          "version": 1,
          "forwarder": "\(forwarderEscaped)",
          "socket": "\(socketEscaped)",
          "command": "\(escaped)",
          "events": \(implementedEventsJSON(for: product)),
          "notes": "Nocturnal-managed sidecar. Use --mode merge-native to also patch product configs."
        }
        """
    }

    private func implementedEventsJSON(for product: HookProduct) -> String {
        let events: [String]
        switch product {
        case .codex:
            events = CodexEventDecoder.implementedEventTypes.sorted()
        case .claude:
            events = ClaudeEventDecoder.implementedEventTypes.sorted()
        }
        let quoted = events.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[\(quoted)]"
    }
}
