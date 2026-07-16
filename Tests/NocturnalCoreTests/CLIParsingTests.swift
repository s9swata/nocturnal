import Foundation
import Testing
@testable import NocturnalCore

struct CLIParsingTests {
    @Test func flagValueRejectsFollowingFlag() {
        let args = ["install", "--product", "--dry-run"]
        #expect(CLIArgumentParser.value(for: "--product", in: args) == .missingValue)
    }

    @Test func flagValueRejectsMissingTrailingValue() {
        let args = ["install", "--forwarder"]
        #expect(CLIArgumentParser.value(for: "--forwarder", in: args) == .missingValue)
    }

    @Test func flagValueAcceptsNormalValue() {
        let args = ["--socket", "/tmp/n.sock", "--timeout", "1.5"]
        #expect(CLIArgumentParser.value(for: "--socket", in: args) == .value("/tmp/n.sock"))
        #expect(CLIArgumentParser.value(for: "--timeout", in: args) == .value("1.5"))
    }

    @Test func flagValueRejectsEmptyToken() {
        #expect(CLIArgumentParser.value(for: "--forwarder", in: ["--forwarder", ""]) == .missingValue)
        #expect(CLIArgumentParser.value(for: "--socket", in: ["--socket", ""]) == .missingValue)
        #expect(CLIArgumentParser.value(for: "--timeout", in: ["--timeout", ""]) == .missingValue)
    }

    @Test func flagValueAbsentWhenNotPresent() {
        #expect(CLIArgumentParser.value(for: "--socket", in: ["--help"]) == .absent)
    }

    @Test func isFlagTokenRecognizesLongAndShortFlags() {
        #expect(CLIArgumentParser.isFlagToken("--product"))
        #expect(CLIArgumentParser.isFlagToken("-h"))
        #expect(CLIArgumentParser.isFlagToken("-") == false)
        #expect(CLIArgumentParser.isFlagToken("/tmp/path") == false)
        #expect(CLIArgumentParser.isFlagToken("codex") == false)
    }

    @Test func setupParseDefaultsWhenFlagsOmitted() throws {
        let options = try SetupCLIOptions.parse(arguments: ["install"])
        #expect(options.products == HookProduct.allCases)
        #expect(options.forwarderPath == nil)
        #expect(options.mode == .mergeNative)
        #expect(options.dryRun == false)
    }

    @Test func setupParseProductAndForwarderValues() throws {
        let options = try SetupCLIOptions.parse(arguments: [
            "install",
            "--product", "claude",
            "--forwarder", "/opt/nocturnal/nocturnal-hook-forwarder",
            "--mode", "merge-native",
            "--dry-run",
        ])
        #expect(options.products == [.claude])
        #expect(options.forwarderPath?.path == "/opt/nocturnal/nocturnal-hook-forwarder")
        #expect(options.mode == .mergeNative)
        #expect(options.dryRun)
    }

    @Test func setupMissingProductValueIsError() {
        #expect(throws: SetupCLIParseError.missingProductValue) {
            _ = try SetupCLIOptions.parse(arguments: ["install", "--product"])
        }
        #expect(throws: SetupCLIParseError.missingProductValue) {
            _ = try SetupCLIOptions.parse(arguments: ["install", "--product", "--dry-run"])
        }
    }

    @Test func setupMissingForwarderValueIsError() {
        #expect(throws: SetupCLIParseError.missingForwarderValue) {
            _ = try SetupCLIOptions.parse(arguments: ["status", "--forwarder"])
        }
        #expect(throws: SetupCLIParseError.missingForwarderValue) {
            _ = try SetupCLIOptions.parse(arguments: ["status", "--forwarder", "--product", "codex"])
        }
        // Explicit empty token must not be accepted as a path.
        #expect(throws: SetupCLIParseError.missingForwarderValue) {
            _ = try SetupCLIOptions.parse(arguments: ["status", "--forwarder", ""])
        }
    }

    @Test func setupUnknownProductIsError() {
        #expect(throws: SetupCLIParseError.unknownProduct("gemini")) {
            _ = try SetupCLIOptions.parse(arguments: ["install", "--product", "gemini"])
        }
    }

    @Test func forwarderCLIDoesNotConsumeFollowingFlagAsSocket() {
        let parsed = HookForwarderCLIOptions.parse(arguments: [
            "--socket", "--timeout", "1",
        ])
        #expect(parsed.socketPath == nil)
        #expect(parsed.warnings.contains { $0.contains("--socket") })
        // --timeout was not consumed as socket value; still parsed.
        #expect(parsed.timeout == 1)
    }

    @Test func forwarderCLIMissingTimeoutKeepsDefault() {
        let parsed = HookForwarderCLIOptions.parse(arguments: ["--timeout", "--wrap-source", "claude"])
        #expect(parsed.timeout == 0.5)
        #expect(parsed.wrapSource == .claude)
        #expect(parsed.warnings.contains { $0.contains("--timeout") })
    }

    @Test func forwarderCLIParsesValidOptions() {
        let parsed = HookForwarderCLIOptions.parse(arguments: [
            "--socket", "/tmp/x.sock",
            "--wrap-source", "codex",
            "--session-id", "s1",
            "--timeout", "0.25",
        ])
        #expect(parsed.socketPath == "/tmp/x.sock")
        #expect(parsed.wrapSource == .codex)
        #expect(parsed.sessionId == "s1")
        #expect(parsed.timeout == 0.25)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func forwarderCLIRejectsEmptySocketToken() {
        let parsed = HookForwarderCLIOptions.parse(arguments: ["--socket", ""])
        #expect(parsed.socketPath == nil)
        #expect(parsed.warnings.contains { $0.contains("--socket") })
    }

    @Test func forwarderCLICapsHugeTimeout() {
        let parsed = HookForwarderCLIOptions.parse(arguments: ["--timeout", "1e20"])
        #expect(parsed.timeout == HookForwarderCLIOptions.maxTimeout)
        #expect(parsed.timeout.isFinite)
        // Millisecond conversion must fit Int32 without trapping.
        let millis = (parsed.timeout * 1000).rounded(.up)
        #expect(millis <= Double(Int32.max))
        #expect(Int32(millis) >= 0)
        #expect(parsed.warnings.contains { $0.contains("capped") })
    }

    @Test func forwarderCLIRejectsNonfiniteTimeout() {
        for raw in ["nan", "inf", "-inf", "Infinity", "0", "-1", "not-a-number"] {
            let parsed = HookForwarderCLIOptions.parse(arguments: ["--timeout", raw])
            #expect(parsed.timeout == HookForwarderCLIOptions.defaultTimeout, "raw=\(raw)")
            #expect(parsed.warnings.contains { $0.contains("--timeout") }, "raw=\(raw)")
        }
    }

    @Test func hookForwarderOptionsClampsNonfiniteAndHugeTimeout() {
        let huge = HookForwarderOptions(connectTimeout: 1e300)
        #expect(huge.connectTimeout == HookForwarderOptions.maxConnectTimeout)

        let nan = HookForwarderOptions(connectTimeout: .nan)
        #expect(nan.connectTimeout == HookForwarderCLIOptions.defaultTimeout)

        let inf = HookForwarderOptions(connectTimeout: .infinity)
        #expect(inf.connectTimeout == HookForwarderCLIOptions.defaultTimeout)
    }
}
