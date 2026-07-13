import Foundation
import Testing
@testable import NocturnalCore

struct HookInstallerTests {
    @Test func installUninstallIdempotentInTempRoot() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks")
        defer { cleanup() }

        // Guard: never resolve against the real home for this test.
        #expect(temp.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/nocturnal-test.sock"),
            backupsDirectory: backups
        )

        let first = try installer.install(product: .codex)
        #expect(first.succeeded)
        let configPath = try #require(first.configPath)
        #expect(FileManager.default.fileExists(atPath: configPath))
        #expect(configPath.contains(temp.path))
        #expect(configPath.contains(".codex"))

        let second = try installer.install(product: .codex)
        #expect(second.succeeded)
        #expect(second.message.contains("idempotent") || second.message.contains("Installed") || second.message.contains("unchanged") || second.message.lowercased().contains("already"))

        let status = installer.status(product: .codex)
        #expect(status.message.contains("present"))

        let removed = try installer.uninstall(product: .codex)
        #expect(removed.succeeded)
        #expect(FileManager.default.fileExists(atPath: installer.configURL(for: .codex).path) == false)

        let removedAgain = try installer.uninstall(product: .codex)
        #expect(removedAgain.succeeded)
    }

    @Test func installBothProductsUnderTempRootOnly() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-both")
        defer { cleanup() }

        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "\(temp.path)/ipc.sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )

        for product in HookProduct.allCases {
            let result = try installer.install(product: product)
            #expect(result.succeeded)
            let path = installer.configURL(for: product).path
            #expect(path.hasPrefix(temp.path))
            #expect(FileManager.default.fileExists(atPath: path))
            // Never touch real agent homes.
            #expect(path.contains(NSHomeDirectory() + "/.codex") == false || path.hasPrefix(temp.path))
            #expect(path.contains(NSHomeDirectory() + "/.claude") == false || path.hasPrefix(temp.path))
        }
    }

    @Test func dryRunDoesNotWriteSidecar() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-dry")
        defer { cleanup() }

        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/x.sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true),
            mode: .sidecar,
            dryRun: true
        )
        let result = try installer.install(product: .claude)
        #expect(result.succeeded)
        #expect(result.dryRun)
        #expect(FileManager.default.fileExists(atPath: installer.configURL(for: .claude).path) == false)
    }

    @Test func resolveHonorsConfigRootEnvironment() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-env")
        defer { cleanup() }
        let appSupport = temp.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let env = [
            NocturnalEnvironmentKey.configRoot.rawValue: temp.path,
            NocturnalEnvironmentKey.appSupport.rawValue: appSupport.path,
            NocturnalEnvironmentKey.socket.rawValue: temp.appendingPathComponent("ipc.sock").path,
        ]
        let installer = try HookInstaller.resolve(
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/fwd"),
            environment: env
        )
        #expect(installer.configRoot.path == temp.path)
        #expect(installer.configURL(for: .codex).path.hasPrefix(temp.path))
        // Socket comes from PersistencePaths (single source for NOCTURNAL_SOCKET).
        #expect(installer.socketPath.path == temp.appendingPathComponent("ipc.sock").path)
    }

    @Test func sidecarJSONMentionsForwarder() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-json")
        defer { cleanup() }

        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/opt/nocturnal/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )
        _ = try installer.install(product: .codex)
        let body = try String(contentsOf: installer.configURL(for: .codex), encoding: .utf8)
        #expect(body.contains(HookInstaller.managedKey) || body.contains("nocturnalManaged"))
        #expect(body.contains("nocturnal-hook-forwarder"))
    }

    @Test func shellQuoteWrapsSpacesAndEscapesSingleQuotes() {
        #expect(HookInstaller.shellQuote("/tmp/simple") == "'/tmp/simple'")
        let spaced = "/Users/me/Library/Application Support/Nocturnal/ipc.sock"
        #expect(HookInstaller.shellQuote(spaced) == "'\(spaced)'")
        #expect(HookInstaller.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func forwarderCommandQuotesSpacedPaths() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-space")
        defer { cleanup() }

        let appSupport = temp.appendingPathComponent("Application Support/Nocturnal", isDirectory: true)
        let binary = temp.appendingPathComponent("Helpers/nocturnal-hook-forwarder")
        let socket = appSupport.appendingPathComponent("ipc.sock")
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: binary,
            socketPath: socket,
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )

        let command = installer.forwarderCommand()
        #expect(command.contains("NOCTURNAL_SOCKET='"))
        #expect(command.contains("Application Support"))
        #expect(command.contains("'\(binary.path)'") || command.contains(HookInstaller.shellQuote(binary.path)))
        // Unquoted space would break shell tokenization of Application Support.
        #expect(command.contains("SOCKET=/Users") == false)

        _ = try installer.install(product: .codex)
        let body = try String(contentsOf: installer.configURL(for: .codex), encoding: .utf8)
        #expect(body.contains("Application Support"))
        #expect(body.contains("NOCTURNAL_SOCKET="))
    }

    @Test func mergeNativeBacksUpMalformedCodexHooksJSON() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-malformed")
        defer { cleanup() }

        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/n.sock"),
            backupsDirectory: backups,
            mode: .mergeNative
        )

        let native = installer.nativeConfigURL(for: .codex)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "this is not json {{{".write(to: native, atomically: true, encoding: .utf8)

        let result = try installer.install(product: .codex)
        #expect(result.succeeded)
        #expect(result.backupPath != nil)

        let backup = try #require(result.backupPath)
        #expect(FileManager.default.fileExists(atPath: backup))
        let backupBody = try String(contentsOfFile: backup, encoding: .utf8)
        #expect(backupBody.contains("this is not json"))

        let rewritten = try String(contentsOf: native, encoding: .utf8)
        #expect(rewritten.contains(HookInstaller.managedCommandMarker))
        #expect(rewritten.contains(HookInstaller.managedKey))
    }

    @Test func mergeNativePreservesStringFormatCodexHooks() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-strings")
        defer { cleanup() }

        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/opt/bin/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/sock"),
            backupsDirectory: backups,
            mode: .mergeNative
        )

        let native = installer.nativeConfigURL(for: .codex)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "hooks": [
                "echo user-hook",
                ["command": "other-tool --flag", "events": ["session.started"]],
            ] as [Any],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try existingData.write(to: native)

        let result = try installer.install(product: .codex)
        #expect(result.succeeded)
        #expect(result.backupPath != nil)

        let data = try Data(contentsOf: native)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [Any])

        let stringHooks = hooks.compactMap { $0 as? String }
        #expect(stringHooks.contains("echo user-hook"))

        let objectCommands = hooks.compactMap { entry -> String? in
            (entry as? [String: Any])?["command"] as? String
        }
        #expect(objectCommands.contains("other-tool --flag"))
        #expect(objectCommands.contains { $0.contains(HookInstaller.managedCommandMarker) })
        // User string entry must not have been dropped by object-only merge.
        #expect(hooks.count >= 3)
    }

    @Test func mergeNativeBacksUpInvalidSidecarBeforeOverwrite() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-bad-sidecar")
        defer { cleanup() }

        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/fwd"),
            socketPath: URL(fileURLWithPath: "/tmp/s.sock"),
            backupsDirectory: backups
        )

        let sidecar = installer.configURL(for: .claude)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-valid-json".write(to: sidecar, atomically: true, encoding: .utf8)

        let result = try installer.install(product: .claude)
        #expect(result.succeeded)
        let backup = try #require(result.backupPath)
        #expect(FileManager.default.fileExists(atPath: backup))
        let backupBody = try String(contentsOfFile: backup, encoding: .utf8)
        #expect(backupBody.contains("{not-valid-json"))

        let body = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(body.contains(HookInstaller.managedKey))
    }
}
