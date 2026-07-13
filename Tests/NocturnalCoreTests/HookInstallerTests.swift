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
}
