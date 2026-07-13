import Foundation
import Testing
@testable import NocturnalCore

/// Pure helpers for shell-safe setup commands and path-display availability.
struct SetupCommandFormattingTests {

    // MARK: - Shell single-quoting

    @Test func shellQuotesSimplePath() {
        let quoted = SetupCommandFormatting.shellSingleQuoted("/usr/local/bin/nocturnal-setup")
        #expect(quoted == "'/usr/local/bin/nocturnal-setup'")
    }

    @Test func shellQuotesPathWithSpaces() {
        let path = "/Applications/My Apps/Nocturnal.app/Contents/MacOS/nocturnal-setup"
        let quoted = SetupCommandFormatting.shellSingleQuoted(path)
        #expect(quoted == "'\(path)'")
        // Round-trip shape: starts and ends with single quotes, no unescaped interior.
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
    }

    @Test func shellEscapesEmbeddedSingleQuotes() {
        let path = "/tmp/it's-app/nocturnal-setup"
        let quoted = SetupCommandFormatting.shellSingleQuoted(path)
        #expect(quoted == "'/tmp/it'\\''s-app/nocturnal-setup'")
    }

    @Test func shellQuotesEmptyString() {
        #expect(SetupCommandFormatting.shellSingleQuoted("") == "''")
    }

    // MARK: - Install command construction

    @Test func bareBinaryKeepsUnquotedCommand() {
        let command = SetupCommandFormatting.installAllCommand(
            binaryPath: SetupCommandFormatting.bareBinaryName
        )
        #expect(command == "nocturnal-setup install --product all")
        #expect(!command.contains("'"))
    }

    @Test func emptyBinaryFallsBackToBare() {
        let command = SetupCommandFormatting.installAllCommand(binaryPath: "   ")
        #expect(command == "nocturnal-setup install --product all")
    }

    @Test func packagedPathWithSpacesIsQuotedAndExecutableShape() {
        let path = "/Users/me/Library/Developer/Xcode/DerivedData/Nocturnal App/Helpers/nocturnal-setup"
        let command = SetupCommandFormatting.installAllCommand(binaryPath: path)
        #expect(command == "'\(path)' install --product all")
        #expect(command.hasSuffix(" install --product all"))
    }

    @Test func packagedPathWithoutSpacesIsStillQuoted() {
        // Always quote non-bare paths so shell metacharacters never slip through.
        let path = "/opt/nocturnal/nocturnal-setup"
        let command = SetupCommandFormatting.installAllCommand(binaryPath: path)
        #expect(command == "'/opt/nocturnal/nocturnal-setup' install --product all")
    }

    // MARK: - Path display availability (Reveal App Support guard)

    @Test func placeholderPathIsUnavailable() {
        #expect(!SetupCommandFormatting.isAvailablePathDisplay("—"))
        #expect(!SetupCommandFormatting.isAvailablePathDisplay(""))
        #expect(!SetupCommandFormatting.isAvailablePathDisplay("   "))
    }

    @Test func resolvedPathIsAvailable() {
        #expect(SetupCommandFormatting.isAvailablePathDisplay(
            "/Users/me/Library/Application Support/Nocturnal"
        ))
    }
}
