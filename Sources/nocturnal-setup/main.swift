import Foundation
import NocturnalCore

/// Safe hook install / uninstall for Codex and Claude.
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
        let products = parseProducts(from: args)
        let forwarder = resolveForwarderPath(from: args)
        let dryRun = args.contains("--dry-run")
        let mode = parseMode(from: args)

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
              nocturnal-setup install [--product codex|claude|all] [options]
              nocturnal-setup uninstall [--product codex|claude|all] [options]
              nocturnal-setup status [--product codex|claude|all] [options]

            Options:
              --forwarder PATH   Path to nocturnal-hook-forwarder binary
              --mode MODE        sidecar (default) | merge-native
              --dry-run          Print actions without writing files
              --help             Show help

            Environment:
              NOCTURNAL_CONFIG_ROOT   Sandbox root for configs (tests)
              NOCTURNAL_SOCKET        Socket path written into hook config
              NOCTURNAL_APP_SUPPORT   Application Support override

            Notes:
              • Install is idempotent and creates timestamped backups.
              • Default mode writes only Nocturnal-managed sidecar files:
                  $CONFIG_ROOT/.codex/nocturnal-hooks.json
                  $CONFIG_ROOT/.claude/nocturnal-hooks.json
              • --mode merge-native also patches (with backup):
                  Codex  → .codex/hooks.json
                  Claude → .claude/settings.json (hooks key)
              • Native formats evolve; merge is best-effort. Prefer sidecar for safety.
              • Does not rewrite arbitrary user config without backup.
            """
        )
    }

    private static func parseProducts(from args: [String]) -> [HookProduct] {
        if let idx = args.firstIndex(of: "--product"), args.index(after: idx) < args.endIndex {
            let raw = args[args.index(after: idx)].lowercased()
            switch raw {
            case "all":
                return HookProduct.allCases
            case "codex":
                return [.codex]
            case "claude":
                return [.claude]
            default:
                fputs("Unknown product: \(raw)\n", stderr)
                exit(2)
            }
        }
        return HookProduct.allCases
    }

    private static func parseMode(from args: [String]) -> HookInstallMode {
        guard let idx = args.firstIndex(of: "--mode"), args.index(after: idx) < args.endIndex else {
            return .sidecar
        }
        switch args[args.index(after: idx)].lowercased() {
        case "sidecar":
            return .sidecar
        case "merge-native", "merge", "native":
            return .mergeNative
        default:
            fputs("Unknown mode; using sidecar\n", stderr)
            return .sidecar
        }
    }

    private static func resolveForwarderPath(from args: [String]) -> URL {
        if let idx = args.firstIndex(of: "--forwarder"), args.index(after: idx) < args.endIndex {
            return URL(fileURLWithPath: args[args.index(after: idx)])
        }
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
