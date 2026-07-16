import Foundation

/// Which agent product's hook config is being managed.
public enum HookProduct: String, Sendable, CaseIterable {
    case codex
    case claude
    case opencode
    /// Grok Build (`~/.grok/hooks/*.json`).
    case grok
}

public enum HookInstallAction: String, Sendable {
    case install
    case uninstall
    case status
    case doctor
    case repair
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

/// Safe, idempotent hook installer for Codex, Claude, OpenCode, and Grok Build.
///
/// **Never** uses real user homes in unit tests. Pass ``configRoot`` pointing
/// at a temporary directory, or set `NOCTURNAL_CONFIG_ROOT`.
///
/// ## Paths (under `configRoot`, default `$HOME`)
///
/// | Product | Sidecar | Native merge target |
/// |---------|---------|---------------------|
/// | Codex | `.codex/nocturnal-hooks.json` | `.codex/hooks.json` (event map with nested command handlers) |
/// | Claude | `.claude/nocturnal-hooks.json` | `.claude/settings.json` (`hooks` key) |
/// | OpenCode | `.config/opencode/nocturnal-hooks.json` | `.config/opencode/plugins/nocturnal-bridge.js` |
/// | Grok | `.grok/nocturnal-hooks.json` | `.grok/hooks/nocturnal.json` (lifecycle command hooks) |
///
/// Native formats evolve; changed files receive a timestamped backup under
/// Application Support `backups/`. The sidecar is a Nocturnal-owned descriptor,
/// but only native product config is consumed by the agents.
public struct HookInstaller: Sendable {
    public static let managedMarkerBegin = "# >>> nocturnal-managed"
    public static let managedMarkerEnd = "# <<< nocturnal-managed"
    public static let managedKey = "nocturnalManaged"
    public static let managedCommandMarker = "nocturnal-hook-forwarder"
    public static let openCodePluginFileName = "nocturnal-bridge.js"
    public static let openCodePluginMarker = "nocturnal-opencode-bridge"
    public static let grokHookFileName = "nocturnal.json"
    public static let grokWrapSourceFlag = "--wrap-source grok-build"

    /// Grok Build lifecycle events installed into `~/.grok/hooks/nocturnal.json`.
    public static let grokLifecycleEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "SessionEnd",
        "Notification",
        "SubagentStart",
        "SubagentStop",
    ]

    public var configRoot: URL
    /// Explicit Codex home (`CODEX_HOME`). Nil means `<configRoot>/.codex`.
    public var codexHome: URL?
    public var forwarderBinaryPath: URL
    public var socketPath: URL
    public var backupsDirectory: URL
    public var mode: HookInstallMode
    public var dryRun: Bool

    /// Codex lifecycle hooks supported by the current native adapter.
    /// The shape is verified against Codex CLI 0.144.1 and the current hooks docs.
    public static let codexLifecycleEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
    ]

    public init(
        configRoot: URL,
        codexHome: URL? = nil,
        forwarderBinaryPath: URL,
        socketPath: URL,
        backupsDirectory: URL,
        mode: HookInstallMode = .sidecar,
        dryRun: Bool = false
    ) {
        self.configRoot = configRoot
        self.codexHome = codexHome
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

        let codexHome: URL? = {
            // Test redirection always wins; never escape NOCTURNAL_CONFIG_ROOT.
            if environment[NocturnalEnvironmentKey.configRoot.rawValue]?.isEmpty == false {
                return nil
            }
            guard let raw = environment["CODEX_HOME"], !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: raw, isDirectory: true)
        }()

        return HookInstaller(
            configRoot: home,
            codexHome: codexHome,
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
            return (codexHome ?? configRoot.appendingPathComponent(".codex", isDirectory: true))
                .appendingPathComponent("nocturnal-hooks.json")
        case .claude:
            return configRoot
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("nocturnal-hooks.json")
        case .opencode:
            return openCodeConfigDirectory()
                .appendingPathComponent("nocturnal-hooks.json")
        case .grok:
            return grokHomeDirectory()
                .appendingPathComponent("nocturnal-hooks.json")
        }
    }

    /// Product-native config path used by ``HookInstallMode/mergeNative``.
    public func nativeConfigURL(for product: HookProduct) -> URL {
        switch product {
        case .codex:
            return (codexHome ?? configRoot.appendingPathComponent(".codex", isDirectory: true))
                .appendingPathComponent("hooks.json")
        case .claude:
            return configRoot
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        case .opencode:
            return openCodePluginsDirectory()
                .appendingPathComponent(Self.openCodePluginFileName)
        case .grok:
            return grokHooksDirectory()
                .appendingPathComponent(Self.grokHookFileName)
        }
    }

    /// Grok Build home: `<configRoot>/.grok` (or `GROK_HOME` when resolving in production).
    public func grokHomeDirectory() -> URL {
        configRoot.appendingPathComponent(".grok", isDirectory: true)
    }

    /// Grok auto-loaded hook JSON directory.
    public func grokHooksDirectory() -> URL {
        grokHomeDirectory().appendingPathComponent("hooks", isDirectory: true)
    }

    /// OpenCode global config root: `<configRoot>/.config/opencode`.
    public func openCodeConfigDirectory() -> URL {
        configRoot
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    /// OpenCode auto-loaded plugin directory.
    public func openCodePluginsDirectory() -> URL {
        openCodeConfigDirectory()
            .appendingPathComponent("plugins", isDirectory: true)
    }

    public func status(product: HookProduct) -> HookInstallResult {
        let url = configURL(for: product)
        let installed = FileManager.default.fileExists(atPath: url.path)
        let native = nativeConfigURL(for: product)
        let nativeHealth = nativeHookHealth(product: product)
        var message = installed ? "sidecar present" : "sidecar missing"
        message += "; \(nativeHealth.message)"
        return HookInstallResult(
            product: product,
            action: .status,
            succeeded: nativeHealth.healthy,
            message: message,
            configPath: url.path,
            nativeConfigPath: native.path,
            dryRun: dryRun
        )
    }

    /// Structural Doctor check. This never writes agent configuration.
    public func doctor(product: HookProduct) -> HookInstallResult {
        var result = status(product: product)
        result.action = .doctor
        return result
    }

    /// Repair the Nocturnal-owned portion of native config, preserving valid
    /// foreign lifecycle handlers. Existing files are backed up before writes.
    public func repair(product: HookProduct) throws -> HookInstallResult {
        var nativeInstaller = self
        nativeInstaller.mode = .mergeNative
        var result = try nativeInstaller.install(product: product)
        result.action = .repair
        return result
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
                    if mode == .mergeNative || product == .opencode || product == .grok {
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

        // OpenCode has no shell hooks — the JS plugin *is* the native integration.
        // Grok's native surface is `~/.grok/hooks/*.json` — always write it.
        // Always install (even in sidecar mode) so observe-only live activity works.
        if mode == .mergeNative || product == .opencode || product == .grok {
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

        if mode == .mergeNative || product == .opencode || product == .grok {
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
        case .opencode:
            return try mergeOpenCodeNative()
        case .grok:
            return try mergeGrokNative()
        }
    }

    private func unmergeNative(product: HookProduct) throws -> MergeOutcome {
        switch product {
        case .codex:
            return try unmergeCodexNative()
        case .claude:
            return try unmergeClaudeNative()
        case .opencode:
            return try unmergeOpenCodeNative()
        case .grok:
            return try unmergeGrokNative()
        }
    }

    /// Codex `hooks.json`: `{ "hooks": { "SessionStart": [{ "hooks": [...] }] } }`.
    ///
    /// Top-level unknown keys are rejected by Codex 0.144.1, so ownership is
    /// identified only by the nested command marker. The sidecar remains an
    /// optional Nocturnal descriptor; Codex does not consume it.
    private func mergeCodexNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .codex)
        let command = codexForwarderCommand()
        let fm = FileManager.default

        if !dryRun {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var backupPath: String?
        var originalRoot: [String: Any]?
        var root: [String: Any] = ["hooks": [String: Any]()]

        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any]
            else {
                if !dryRun {
                    backupPath = try backupExisting(url: url, product: .codex, label: "native").path
                } else {
                    backupPath = "(dry-run backup)"
                }
                throw HookInstallerError.invalidCodexHooks(
                    "hooks.json is not a JSON object; backup created, no rewrite performed"
                )
            }
            originalRoot = object
            do {
                root = try migrateCodexRoot(object)
            } catch {
                if !dryRun {
                    backupPath = try backupExisting(url: url, product: .codex, label: "native").path
                } else {
                    backupPath = "(dry-run backup)"
                }
                throw error
            }
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.codexLifecycleEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap(removingManagedCodexHandlers(from:))
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 1,
                ]],
            ])
            hooks[event] = groups
        }
        root = root.filter { $0.key == "description" || $0.key == "hooks" }
        root["hooks"] = hooks

        if let originalRoot,
           jsonObjectsEqual(originalRoot, root)
        {
            return MergeOutcome(
                message: dryRun
                    ? "Would leave .codex/hooks.json unchanged"
                    : "Native Codex hooks already healthy (idempotent)",
                nativeConfigPath: url.path
            )
        }

        if originalRoot != nil {
            if !dryRun {
                backupPath = try backupExisting(url: url, product: .codex, label: "native").path
            } else {
                backupPath = "(dry-run backup)"
            }
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

        if var root = json as? [String: Any],
           var hooks = root["hooks"] as? [String: Any]
        {
            for event in Array(hooks.keys) {
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                let kept = groups.compactMap(removingManagedCodexHandlers(from:))
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
            root["hooks"] = hooks
            if !dryRun {
                let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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

    // MARK: - OpenCode plugin bridge

    /// Install the TypeScript/JS plugin OpenCode auto-loads from `plugins/`.
    private func mergeOpenCodeNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .opencode)
        let fm = FileManager.default
        let body = openCodePluginSource()

        if !dryRun {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var backupPath: String?
        if fm.fileExists(atPath: url.path) {
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == body {
                return MergeOutcome(
                    message: dryRun
                        ? "Would leave OpenCode plugin unchanged"
                        : "OpenCode plugin already healthy (idempotent)",
                    nativeConfigPath: url.path
                )
            }
            if !dryRun {
                backupPath = try backupExisting(url: url, product: .opencode, label: "plugin").path
            } else {
                backupPath = "(dry-run backup)"
            }
        }

        if !dryRun {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        return MergeOutcome(
            message: dryRun
                ? "Would install OpenCode plugin \(Self.openCodePluginFileName)"
                : "Installed OpenCode plugin \(Self.openCodePluginFileName)",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    private func unmergeOpenCodeNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .opencode)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return MergeOutcome(
                message: "No OpenCode plugin to remove",
                nativeConfigPath: url.path
            )
        }

        // Only remove our managed plugin.
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard existing.contains(Self.openCodePluginMarker) || existing.contains(Self.managedMarkerBegin) else {
            return MergeOutcome(
                message: "OpenCode plugin present but not Nocturnal-managed; left untouched",
                nativeConfigPath: url.path
            )
        }

        var backupPath: String?
        if !dryRun {
            backupPath = try backupExisting(url: url, product: .opencode, label: "plugin").path
            try fm.removeItem(at: url)
        } else {
            backupPath = "(dry-run backup)"
        }

        return MergeOutcome(
            message: dryRun ? "Would remove OpenCode plugin" : "Removed OpenCode plugin",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    /// Grok Build `~/.grok/hooks/nocturnal.json` — dedicated file, fail-open command hooks.
    ///
    /// Grok merges all `hooks/*.json` files; we own only this file so foreign hooks
    /// in other files are never rewritten.
    private func mergeGrokNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .grok)
        let command = grokForwarderCommand()
        let fm = FileManager.default

        if !dryRun {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var backupPath: String?
        if fm.fileExists(atPath: url.path) {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let desired = grokNativeHooksJSON(command: command)
            if existing == desired
                || (existing.contains(Self.managedCommandMarker)
                    && existing.contains(Self.grokWrapSourceFlag)
                    && existing.contains(Self.escapeJSONStringContents(socketPath.path)))
            {
                // Refresh if socket/forwarder path drifted.
                if existing == desired {
                    return MergeOutcome(
                        message: dryRun
                            ? "Would skip Grok hooks (already installed)"
                            : "Grok hooks already installed (idempotent)",
                        nativeConfigPath: url.path
                    )
                }
            }
            if !dryRun {
                backupPath = try backupExisting(url: url, product: .grok, label: "native").path
            } else {
                backupPath = "(dry-run backup)"
            }
        }

        let body = grokNativeHooksJSON(command: command)
        if !dryRun {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        return MergeOutcome(
            message: dryRun
                ? "Would install Grok Build hooks (\(Self.grokHookFileName))"
                : "Installed Grok Build hooks (\(Self.grokHookFileName))",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    private func unmergeGrokNative() throws -> MergeOutcome {
        let url = nativeConfigURL(for: .grok)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return MergeOutcome(
                message: "No Grok hooks file to remove",
                nativeConfigPath: url.path
            )
        }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard existing.contains(Self.managedCommandMarker) || existing.contains(Self.managedKey) else {
            return MergeOutcome(
                message: "Grok hooks file present but not Nocturnal-managed; left untouched",
                nativeConfigPath: url.path
            )
        }

        var backupPath: String?
        if !dryRun {
            backupPath = try backupExisting(url: url, product: .grok, label: "native").path
            try fm.removeItem(at: url)
        } else {
            backupPath = "(dry-run backup)"
        }

        return MergeOutcome(
            message: dryRun ? "Would remove Grok Build hooks" : "Removed Grok Build hooks",
            backupPath: backupPath,
            nativeConfigPath: url.path
        )
    }

    /// JSON body for `~/.grok/hooks/nocturnal.json`.
    public func grokNativeHooksJSON(command: String? = nil) -> String {
        let cmd = command ?? grokForwarderCommand()
        let escaped = Self.escapeJSONStringContents(cmd)
        var eventBlocks: [String] = []
        for event in Self.grokLifecycleEvents {
            eventBlocks.append(
                """
                    "\(event)": [
                      {
                        "\(Self.managedKey)": true,
                        "hooks": [
                          {
                            "type": "command",
                            "command": "\(escaped)",
                            "timeout": 8,
                            "\(Self.managedKey)": true
                          }
                        ]
                      }
                    ]
                """
            )
        }
        return """
        {
          "\(Self.managedKey)": true,
          "description": "Nocturnal Grok Build bridge — fail-open live activity",
          "hooks": {
        \(eventBlocks.joined(separator: ",\n"))
          }
        }
        """
    }

    public func grokForwarderCommand() -> String {
        forwarderCommand() + " \(Self.grokWrapSourceFlag) --timeout 0.5"
    }

    /// Fail-open JS plugin that maps OpenCode events → EventEnvelope NDJSON on the socket.
    ///
    /// Template: ``OpenCodeBridge.plugin.js`` (v3: ``permission.ask`` + ``serverUrl`` + correct SDK name).
    public func openCodePluginSource() -> String {
        let socket = socketPath.path
        let socketJSON: String = {
            if let data = try? JSONSerialization.data(
                withJSONObject: socket,
                options: [.fragmentsAllowed]
            ),
               var quoted = String(data: data, encoding: .utf8)
            {
                quoted = quoted.replacingOccurrences(of: "\\/", with: "/")
                return quoted
            }
            return "\"\(Self.escapeJSONStringContents(socket))\""
        }()

        if let template = Self.loadOpenCodePluginTemplate() {
            // Template uses SOCKET_PATH = "__NOCTURNAL_SOCKET__" as a quoted placeholder.
            return template.replacingOccurrences(
                of: "\"__NOCTURNAL_SOCKET__\"",
                with: socketJSON
            )
        }

        // Emergency stub if template file is missing from the checkout.
        return """
        // \(Self.managedMarkerBegin)
        // \(Self.openCodePluginMarker) v3-fallback — template missing
        // \(Self.managedMarkerEnd)
        const SOCKET_PATH = \(socketJSON)
        export default async () => ({})
        """
    }

    /// Load OpenCodeBridge.plugin.js from the source tree or bundle.
    private static func loadOpenCodePluginTemplate() -> String? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let thisFile = URL(fileURLWithPath: #filePath)
        candidates.append(
            thisFile.deletingLastPathComponent().appendingPathComponent("OpenCodeBridge.plugin.js")
        )
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(
            cwd.appendingPathComponent("Sources/NocturnalCore/Hooks/OpenCodeBridge.plugin.js")
        )
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("OpenCodeBridge.plugin.js"))
        }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains("nocturnal-opencode-bridge")
            {
                return text
            }
        }
        return nil
    }

    private func migrateCodexRoot(_ object: [String: Any]) throws -> [String: Any] {
        if object["hooks"] is [String: Any] {
            return object
        }

        // Migrate Nocturnal's obsolete v1 array without carrying forbidden
        // top-level marker/version keys into Codex's strict schema.
        if let oldHooks = object["hooks"] as? [Any] {
            var migrated: [String: Any] = [:]
            for entry in oldHooks {
                guard let old = entry as? [String: Any] else {
                    throw HookInstallerError.invalidCodexHooks(
                        "obsolete hooks array contains an entry whose lifecycle cannot be preserved"
                    )
                }
                if entryContainsForwarder(old) { continue }
                guard let command = old["command"] as? String,
                      let events = old["events"] as? [String],
                      !events.isEmpty
                else {
                    throw HookInstallerError.invalidCodexHooks(
                        "obsolete foreign hook is missing command/events; no rewrite performed"
                    )
                }
                for event in events {
                    var groups = migrated[event] as? [[String: Any]] ?? []
                    groups.append(["hooks": [["type": "command", "command": command]]])
                    migrated[event] = groups
                }
            }
            var root: [String: Any] = ["hooks": migrated]
            if let description = object["description"] as? String {
                root["description"] = description
            }
            return root
        }

        throw HookInstallerError.invalidCodexHooks(
            "hooks must be an event-keyed object; no rewrite performed"
        )
    }

    private func removingManagedCodexHandlers(from group: [String: Any]) -> [String: Any]? {
        guard let handlers = group["hooks"] as? [[String: Any]] else {
            // Preserve malformed/unknown foreign groups for Doctor to report.
            return group
        }
        var keptGroup = group
        let kept = handlers.filter { !entryContainsForwarder($0) }
        guard !kept.isEmpty else { return nil }
        keptGroup["hooks"] = kept
        return keptGroup
    }

    private func nativeHookHealth(product: HookProduct) -> (healthy: Bool, message: String) {
        let native = nativeConfigURL(for: product)
        guard FileManager.default.fileExists(atPath: native.path) else {
            return (false, "native config missing")
        }

        if product == .opencode {
            guard let text = try? String(contentsOf: native, encoding: .utf8) else {
                return (false, "OpenCode plugin unreadable")
            }
            let managed = text.contains(Self.openCodePluginMarker)
                || text.contains(Self.managedMarkerBegin)
            guard managed else {
                return (false, "OpenCode plugin missing Nocturnal marker")
            }
            let path = socketPath.path
            let socketOk = text.contains(path)
                || text.contains(path.replacingOccurrences(of: "/", with: "\\/"))
                || text.contains(Self.escapeJSONStringContents(path))
            guard socketOk else {
                return (false, "OpenCode plugin socket path mismatch")
            }
            return (true, "OpenCode plugin bridge healthy")
        }

        if product == .grok {
            guard let text = try? String(contentsOf: native, encoding: .utf8) else {
                return (false, "Grok hooks file unreadable")
            }
            let managed = text.contains(Self.managedCommandMarker)
                && text.contains(Self.grokWrapSourceFlag)
            guard managed else {
                return (false, "Grok hooks missing Nocturnal forwarder")
            }
            let path = socketPath.path
            let socketOk = text.contains(path)
                || text.contains(path.replacingOccurrences(of: "/", with: "\\/"))
                || text.contains(Self.escapeJSONStringContents(path))
            guard socketOk else {
                return (false, "Grok hooks socket path mismatch")
            }
            for event in Self.grokLifecycleEvents {
                guard text.contains("\"\(event)\"") else {
                    return (false, "Grok hooks missing \(event)")
                }
            }
            return (true, "Grok Build hooks healthy")
        }

        guard let data = try? Data(contentsOf: native),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return (false, "native config is invalid JSON")
        }

        if product == .claude {
            let present = (try? String(contentsOf: native, encoding: .utf8))?
                .contains(Self.managedCommandMarker) == true
            return (present, present ? "native hook connected" : "native hook missing Nocturnal")
        }

        let unknownTopLevel = Set(root.keys).subtracting(["description", "hooks"])
        guard unknownTopLevel.isEmpty else {
            return (false, "Codex rejects top-level keys: \(unknownTopLevel.sorted().joined(separator: ", "))")
        }
        guard let hooks = root["hooks"] as? [String: Any] else {
            return (false, "Codex hooks must be an event-keyed object (obsolete array detected)")
        }
        for event in Self.codexLifecycleEvents {
            guard let groups = hooks[event] as? [[String: Any]] else {
                return (false, "missing Codex lifecycle hook \(event)")
            }
            let managedCount = groups.reduce(into: 0) { count, group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return }
                count += handlers.filter { handler in
                    handler["type"] as? String == "command"
                        && (handler["command"] as? String)?.contains(Self.managedCommandMarker) == true
                        && (handler["command"] as? String)?.contains("--wrap-source codex") == true
                }.count
            }
            guard managedCount == 1 else {
                return (false, "\(event) has \(managedCount) Nocturnal handlers; expected 1")
            }
        }
        return (true, "native Codex lifecycle hooks healthy (0.144.1 schema)")
    }

    private func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else { return false }
        return left == right
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

    public func codexForwarderCommand() -> String {
        forwarderCommand() + " --wrap-source codex --timeout 0.35"
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
          "notes": "Nocturnal-managed descriptor. Agents consume their native hook configuration."
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
        case .opencode:
            events = OpenCodeEventDecoder.implementedEventTypes.sorted()
        case .grok:
            events = GrokEventDecoder.implementedEventTypes.sorted()
        }
        let quoted = events.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[\(quoted)]"
    }
}

public enum HookInstallerError: Error, Sendable, Equatable, LocalizedError {
    case invalidCodexHooks(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCodexHooks(let detail):
            return "Cannot safely repair Codex hooks: \(detail)"
        }
    }
}
