import Foundation
@testable import NocturnalCore

/// Shared helpers for isolated temp-dir tests.
///
/// **Never** points at real `~/.codex` or `~/.claude`. Every config / app-support
/// root is under `FileManager.default.temporaryDirectory`.
enum TestSupport {
    /// Creates a unique temp directory and returns a cleanup closure.
    static func makeTempRoot(prefix: String = "nocturnal-test") throws -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, {
            try? FileManager.default.removeItem(at: url)
        })
    }

    static func makePaths(in temp: URL) throws -> PersistencePaths {
        try PersistencePaths.testing(temporaryDirectory: temp)
    }

    /// Short AF_UNIX-safe socket directory under `/tmp` (macOS `sun_path` is ~104 bytes).
    /// Do not use deep UUID paths from `temporaryDirectory` for socket tests.
    static func makeShortSocketRoot(prefix: String = "noc") throws -> (url: URL, cleanup: () -> Void) {
        let url = try SocketPaths.makeShortTestingRoot(prefix: prefix)
        return (url, {
            try? FileManager.default.removeItem(at: url)
        })
    }

    static func isoDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func isoEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Load repo-root `Fixtures/` by walking up from this source file.
    /// (SPM resource `.copy` of `../../Fixtures` is unreliable under CLT.)
    static func fixtureData(relativePath: String) throws -> Data {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("Fixtures")
                .appendingPathComponent(relativePath)
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                return data
            }
            dir = dir.deletingLastPathComponent()
        }
        // CWD fallback when tests run from package root.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
        if let data = try? Data(contentsOf: cwd), !data.isEmpty {
            return data
        }
        throw FixtureError.notFound(relativePath)
    }

    static func fixtureLines(relativePath: String) throws -> [Data] {
        let data = try fixtureData(relativePath: relativePath)
        return data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
            .map { line -> Data in
                var d = line
                while let last = d.last, last == 0x0D || last == 0x0A { d.removeLast() }
                return d
            }
            .filter { !$0.isEmpty }
    }

    static func decodeEnvelopes(from lines: [Data]) throws -> [EventEnvelope] {
        let decoder = isoDecoder()
        return try lines.map { try decoder.decode(EventEnvelope.self, from: $0) }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        var description: String {
            switch self {
            case .notFound(let path): return "Fixture not found: \(path)"
            }
        }
    }
}
