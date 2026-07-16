import Foundation
import NocturnalCore

/// Safe hook install / uninstall for Codex, Claude, and OpenCode.
///
/// Uses `NOCTURNAL_CONFIG_ROOT` to redirect config writes for tests.
/// Never prints secrets. Idempotent install/uninstall.
@main
struct SetupMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        let action = args[0]
        let options: SetupCLIOptions
        do {
            options = try SetupCLIOptions.parse(arguments: args)
        } catch {
            fputs("nocturnal-setup: \(error)\n", stderr)
            printUsage()
            exit(2)
        }

        let forwarder = options.forwarderPath ?? resolveForwarderPath()
        let dryRun = options.dryRun
        let mode = options.mode
        let products = options.products

        do {
            let installer = try HookInstaller.resolve(
                forwarderBinaryPath: forwarder,
                mode: mode,
                dryRun: dryRun
            )
            var failures = 0

            for product in products {
                let result: HookInstallResult
                switch action {
                case "install":
                    result = try installer.install(product: product)
                case "uninstall":
                    result = try installer.uninstall(product: product)
                case "status":
                    result = installer.status(product: product)
                case "doctor":
                    var diagnosed = installer.doctor(product: product)
                    if product == .codex {
                        diagnosed.message += "; \(codexVersionSummary())"
                    }
                    result = diagnosed
                case "repair":
                    result = try installer.repair(product: product)
                default:
                    fputs("Unknown action: \(action)\n", stderr)
                    printUsage()
                    exit(2)
                }
                printResult(result)
                if !result.succeeded { failures += 1 }
            }

            exit(failures == 0 ? 0 : 1)
        } catch {
            fputs("nocturnal-setup: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            nocturnal-setup — install/uninstall Nocturnal agent hooks

            Usage:
              nocturnal-setup install [--product codex|claude|opencode|grok|all] [options]
              nocturnal-setup uninstall [--product codex|claude|opencode|grok|all] [options]
              nocturnal-setup status [--product codex|claude|opencode|grok|all] [options]
              nocturnal-setup doctor [--product codex|claude|opencode|grok|all] [options]
              nocturnal-setup repair [--product codex|claude|opencode|grok|all] [options]

            Options:
              --forwarder PATH   Path to nocturnal-hook-forwarder binary
              --mode MODE        merge-native (default) | sidecar
              --dry-run          Print actions without writing files
              --help             Show help

            Environment:
              NOCTURNAL_CONFIG_ROOT   Sandbox root for configs (tests)
              NOCTURNAL_SOCKET        Socket path written into hook config
              NOCTURNAL_APP_SUPPORT   Application Support override

            Notes:
              • Install is idempotent and creates timestamped backups.
              • --product / --forwarder without a value is a usage error (never silent default).
              • Omitting --product installs for all products; omitting --forwarder auto-discovers.
              • Default mode writes Nocturnal-managed sidecars and merges native hooks:
                  $CONFIG_ROOT/.codex/nocturnal-hooks.json
                  $CONFIG_ROOT/.claude/nocturnal-hooks.json
                  $CONFIG_ROOT/.config/opencode/nocturnal-hooks.json
              • Native merge patches (with backup):
                  Codex    → .codex/hooks.json
                  Claude   → .claude/settings.json (hooks key)
                  OpenCode → .config/opencode/plugins/nocturnal-bridge.js
              • OpenCode has no shell hooks; the JS plugin always installs (even with --mode sidecar).
              • --mode sidecar writes descriptors only for Codex/Claude; agents do not consume them.
              • Doctor validates the native schema; repair only replaces Nocturnal handlers.
              • Does not rewrite arbitrary user config without backup.
              • Socket and binary paths in generated commands are shell-quoted (spaces safe).
            """
        )
    }

    private static func codexVersionSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0, !output.isEmpty {
                let verification = output.contains("0.144.1")
                    ? "schema verified"
                    : "schema compatibility unverified"
                return "\(output) (\(verification); adapter target 0.144.1)"
            }
        } catch {}
        return "Codex version unavailable (adapter target 0.144.1)"
    }

    /// Auto-discover forwarder when `--forwarder` is omitted (not when value is missing).
    private static func resolveForwarderPath() -> URL {
        // Prefer sibling binary next to this executable.
        let exec = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = exec.deletingLastPathComponent()
            .appendingPathComponent("nocturnal-hook-forwarder")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        // Packaged app Resources/Helpers path
        let helpers = exec
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("nocturnal-hook-forwarder")
        if FileManager.default.isExecutableFile(atPath: helpers.path) {
            return helpers
        }
        return sibling
    }

    private static func printResult(_ result: HookInstallResult) {
        let status = result.succeeded ? (result.dryRun ? "dry-run" : "ok") : "fail"
        print("[\(status)] \(result.product.rawValue) \(result.action.rawValue): \(result.message)")
        if let path = result.configPath {
            print("  sidecar: \(path)")
        }
        if let native = result.nativeConfigPath {
            print("  native:  \(native)")
        }
        if let backup = result.backupPath {
            print("  backup:  \(backup)")
        }
    }
}
