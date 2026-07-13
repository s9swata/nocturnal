import Foundation

/// Pure helpers for building shell-safe setup commands shown in UI.
///
/// Packaged helper paths may contain spaces (`…/My App/…/nocturnal-setup`).
/// Always single-quote such paths before embedding them in copy-paste commands.
public enum SetupCommandFormatting: Sendable {
    /// Bare binary name used for unpackaged / PATH-based development runs.
    public static let bareBinaryName = "nocturnal-setup"

    /// Suffix for the default “install all products” command.
    public static let installAllArguments = "install --product all"

    /// Build `nocturnal-setup install --product all`, quoting a packaged path when needed.
    ///
    /// - When `binaryPath` is empty or the bare name, returns an unquoted bare command
    ///   so development installs via `PATH` still work.
    /// - Otherwise single-quotes the path so spaces and shell metacharacters are safe.
    public static func installAllCommand(binaryPath: String) -> String {
        let path = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == bareBinaryName {
            return "\(bareBinaryName) \(installAllArguments)"
        }
        return "\(shellSingleQuoted(path)) \(installAllArguments)"
    }

    /// POSIX single-quote escaping for one shell argument.
    ///
    /// Delegates to ``HookInstaller/shellQuote(_:)`` so setup UI and hook install
    /// share one escaping rule (spaces, embedded quotes).
    public static func shellSingleQuoted(_ value: String) -> String {
        HookInstaller.shellQuote(value)
    }

    /// Whether a UI path display is a real filesystem path (not a placeholder).
    ///
    /// `AppModel` uses `"—"` until `PersistencePaths.resolve()` succeeds.
    public static func isAvailablePathDisplay(_ display: String) -> Bool {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "—"
    }
}
