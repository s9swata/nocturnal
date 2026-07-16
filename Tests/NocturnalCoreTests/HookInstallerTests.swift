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

    @Test func resolveHonorsCodexHomeWithoutAffectingClaudeHome() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-codex-home")
        defer { cleanup() }
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let codexHome = temp.appendingPathComponent("custom-codex", isDirectory: true)
        let appSupport = temp.appendingPathComponent("support", isDirectory: true)
        let installer = try HookInstaller.resolve(
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/fwd"),
            environment: [
                "HOME": home.path,
                "CODEX_HOME": codexHome.path,
                NocturnalEnvironmentKey.appSupport.rawValue: appSupport.path,
            ]
        )
        #expect(installer.nativeConfigURL(for: .codex).path == codexHome.appendingPathComponent("hooks.json").path)
        #expect(installer.nativeConfigURL(for: .claude).path == home.appendingPathComponent(".claude/settings.json").path)
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
        let quotedSocket = HookInstaller.shellQuote(socket.path)
        let quotedBinary = HookInstaller.shellQuote(binary.path)
        // Direct quoted-value check (not environment-dependent prefixes like /Users).
        #expect(command == "NOCTURNAL_SOCKET=\(quotedSocket) \(quotedBinary)")
        #expect(command.contains("Application Support"))
        #expect(quotedSocket.hasPrefix("'") && quotedSocket.hasSuffix("'"))

        _ = try installer.install(product: .codex)
        let body = try String(contentsOf: installer.configURL(for: .codex), encoding: .utf8)
        #expect(body.contains("Application Support"))
        #expect(body.contains("NOCTURNAL_SOCKET="))
    }

    @Test func sidecarJSONEscapesControlCharactersInPaths() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-escape")
        defer { cleanup() }

        // Paths with JSON control characters that break slash/quote-only escaping.
        let socketPath = temp.appendingPathComponent("sock\nwith\tctrl.sock")
        let binaryPath = temp.appendingPathComponent("fwd\"quote\\slash")
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: binaryPath,
            socketPath: socketPath,
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )

        let body = installer.hookConfigJSON(for: .codex)
        let data = try #require(body.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["socket"] as? String == socketPath.path)
        #expect(json["forwarder"] as? String == binaryPath.path)
        #expect((json["command"] as? String)?.contains("NOCTURNAL_SOCKET=") == true)
    }

    @Test func escapeJSONStringContentsHandlesControlsAndQuotes() throws {
        let raw = "line1\nline2\t\"quoted\"\\slash\u{0001}"
        let escaped = HookInstaller.escapeJSONStringContents(raw)
        let wrapped = "\"\(escaped)\""
        let data = try #require(wrapped.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
        #expect(decoded == raw)
        #expect(escaped.contains("\\n"))
        #expect(escaped.contains("\\t"))
        #expect(escaped.contains("\\\""))
        #expect(escaped.contains("\\\\"))
    }

    @Test func mergeNativeBacksUpAndRefusesMalformedCodexHooksJSON() throws {
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

        #expect(throws: HookInstallerError.self) {
            _ = try installer.install(product: .codex)
        }
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.contains("codex-native") })
        let backupBody = try String(contentsOf: backup, encoding: .utf8)
        #expect(backupBody.contains("this is not json"))
        #expect(try String(contentsOf: native, encoding: .utf8) == "this is not json {{{")
    }

    @Test func mergeNativePreservesForeignCurrentSchemaAndIsIdempotent() throws {
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
            "description": "user hooks",
            "hooks": [
                "SessionStart": [[
                    "matcher": "startup",
                    "hooks": [["type": "command", "command": "other-tool --flag"]],
                ]],
            ],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try existingData.write(to: native)

        let result = try installer.install(product: .codex)
        #expect(result.succeeded)
        #expect(result.backupPath != nil)

        let data = try Data(contentsOf: native)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["description"] as? String == "user hooks")
        let hooks = try #require(json["hooks"] as? [String: Any])
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        let commands = sessionStart.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        #expect(commands.contains("other-tool --flag"))
        #expect(commands.filter { $0.contains(HookInstaller.managedCommandMarker) }.count == 1)

        _ = try installer.install(product: .codex)
        let secondData = try Data(contentsOf: native)
        let secondJSON = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        let secondHooks = try #require(secondJSON["hooks"] as? [String: Any])
        for event in HookInstaller.codexLifecycleEvents {
            let groups = try #require(secondHooks[event] as? [[String: Any]])
            let count = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
                .filter { $0.contains(HookInstaller.managedCommandMarker) }
                .count
            #expect(count == 1)
        }
        #expect(Set(secondJSON.keys).isSubset(of: ["description", "hooks"]))
    }

    @Test func repairMigratesObsoleteNocturnalCodexArray() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-migrate")
        defer { cleanup() }
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/nocturnal-hook-forwarder"),
            socketPath: URL(fileURLWithPath: "/tmp/nocturnal.sock"),
            backupsDirectory: temp.appendingPathComponent("backups", isDirectory: true)
        )
        let native = installer.nativeConfigURL(for: .codex)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        let obsolete: [String: Any] = [
            "version": 1,
            HookInstaller.managedKey: true,
            "hooks": [[
                "command": "'/tmp/nocturnal-hook-forwarder'",
                "events": ["session.started"],
                HookInstaller.managedKey: true,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: obsolete).write(to: native)

        let before = installer.doctor(product: .codex)
        #expect(!before.succeeded)
        let repaired = try installer.repair(product: .codex)
        #expect(repaired.succeeded)
        let after = installer.doctor(product: .codex)
        #expect(after.succeeded)

        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: native)) as? [String: Any]
        )
        #expect(Set(root.keys).isSubset(of: ["description", "hooks"]))
        #expect(root["hooks"] is [String: Any])
        let body = try String(contentsOf: native, encoding: .utf8)
        #expect(body.contains("--wrap-source codex"))
    }

    /// Default (sidecar) mode backs up an invalid existing sidecar before overwrite.
    @Test func sidecarBacksUpInvalidFileBeforeOverwrite() throws {
        let (temp, cleanup) = try TestSupport.makeTempRoot(prefix: "nocturnal-hooks-bad-sidecar")
        defer { cleanup() }

        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        let installer = HookInstaller(
            configRoot: temp,
            forwarderBinaryPath: URL(fileURLWithPath: "/tmp/fwd"),
            socketPath: URL(fileURLWithPath: "/tmp/s.sock"),
            backupsDirectory: backups
            // default mode: .sidecar
        )
        #expect(installer.mode == .sidecar)

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
