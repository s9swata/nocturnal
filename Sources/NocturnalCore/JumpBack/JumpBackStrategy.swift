import Foundation
import AppKit

/// Result of attempting to return the user to the agent surface.
public struct JumpBackResult: Sendable, Equatable {
    public var strategyID: String
    public var succeeded: Bool
    public var detail: String

    public init(strategyID: String, succeeded: Bool, detail: String) {
        self.strategyID = strategyID
        self.succeeded = succeeded
        self.detail = detail
    }
}

/// Pluggable jump-back strategy. Implementations must be fail-soft.
public protocol JumpBackStrategy: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Higher is preferred when multiple strategies apply.
    var priority: Int { get }
    func canHandle(_ context: JumpBackContext) -> Bool
    func perform(_ context: JumpBackContext) async -> JumpBackResult
}

/// Tries strategies in priority order until one succeeds.
///
/// Order (default):
/// 1. Codex deep link  
/// 2. Cursor / VS Code URL schemes  
/// 3. Ghostty / iTerm2 / Terminal.app by bundle id (with optional AppleScript tab focus)  
/// 4. Reveal cwd in Finder (last resort)
public struct JumpBackCoordinator: Sendable {
    public var strategies: [any JumpBackStrategy]

    public init(strategies: [any JumpBackStrategy] = JumpBackCoordinator.defaultStrategies()) {
        self.strategies = strategies.sorted { $0.priority > $1.priority }
    }

    public static func defaultStrategies() -> [any JumpBackStrategy] {
        [
            CodexDeepLinkStrategy(),
            CursorJumpStrategy(),
            VSCodeJumpStrategy(),
            GhosttyJumpStrategy(),
            ITerm2JumpStrategy(),
            TerminalAppJumpStrategy(),
            RevealInFinderStrategy(),
        ]
    }

    /// Strategies that claim they can handle the context (for UI / tests).
    public func applicableStrategies(for context: JumpBackContext) -> [any JumpBackStrategy] {
        strategies.filter { $0.canHandle(context) }
    }

    @discardableResult
    public func jump(using context: JumpBackContext) async -> JumpBackResult {
        let applicable = applicableStrategies(for: context)
        guard !applicable.isEmpty else {
            return JumpBackResult(
                strategyID: "none",
                succeeded: false,
                detail: "No jump-back strategy applicable (missing deep link, editor, terminal, and cwd)"
            )
        }

        var failures: [String] = []
        for strategy in applicable {
            let result = await strategy.perform(context)
            if result.succeeded {
                return result
            }
            failures.append("\(strategy.id): \(result.detail)")
        }
        return JumpBackResult(
            strategyID: "none",
            succeeded: false,
            detail: "No jump-back strategy succeeded — \(failures.joined(separator: "; "))"
        )
    }
}

// MARK: - Strategies

public struct CodexDeepLinkStrategy: JumpBackStrategy {
    public let id = "codex-deeplink"
    public let displayName = "Codex Deep Link"
    public let priority = 100
    /// Documented production scheme candidates. Only these schemes are opened.
    public static let knownSchemes = ["codex", "openai-codex"]

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        guard let url = context.codexDeepLink else { return false }
        return Self.isAllowedScheme(url.scheme)
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        guard let url = context.codexDeepLink else {
            return JumpBackResult(strategyID: id, succeeded: false, detail: "Missing deep link")
        }
        guard Self.isAllowedScheme(url.scheme) else {
            return JumpBackResult(
                strategyID: id,
                succeeded: false,
                detail: "Unsupported deep-link scheme '\(url.scheme ?? "")' (allowed: \(Self.knownSchemes.joined(separator: ", ")))"
            )
        }
        let ok = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        return JumpBackResult(
            strategyID: id,
            succeeded: ok,
            detail: ok ? "Opened \(url.absoluteString)" : "NSWorkspace.open failed for \(url.absoluteString)"
        )
    }

    public static func isAllowedScheme(_ scheme: String?) -> Bool {
        guard let scheme, !scheme.isEmpty else { return false }
        let lowered = scheme.lowercased()
        return knownSchemes.contains { $0.lowercased() == lowered }
    }
}

public struct TerminalAppJumpStrategy: JumpBackStrategy {
    public let id = "terminal-app"
    public let displayName = "Terminal.app"
    public let priority = 40
    public static let bundleID = "com.apple.Terminal"

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        if let bid = context.terminalBundleID {
            return bid == Self.bundleID
        }
        // Low-priority fallback when only cwd is known.
        return context.workingDirectory != nil && context.terminalBundleID == nil
            && context.editorURL == nil && context.codexDeepLink == nil
            && context.extra["editor"] == nil
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        if let tab = context.terminalTabTitle, !tab.isEmpty {
            let scriptResult = await runAppleScript(
                """
                tell application "Terminal"
                  activate
                  set matched to false
                  repeat with w in windows
                    repeat with t in tabs of w
                      try
                        if custom title of t contains "\(escapeAppleScript(tab))" then
                          set selected of t to true
                          set frontmost of w to true
                          set matched to true
                          exit repeat
                        end if
                      end try
                    end repeat
                    if matched then exit repeat
                  end repeat
                  if not matched then
                    -- Fall through: still activate Terminal
                  end if
                end tell
                """
            )
            if scriptResult.succeeded {
                return JumpBackResult(
                    strategyID: id,
                    succeeded: true,
                    detail: "Focused Terminal tab matching \(tab)"
                )
            }
        }
        return await activateBundle(Self.bundleID, strategyID: id, displayName: displayName)
    }
}

public struct ITerm2JumpStrategy: JumpBackStrategy {
    public let id = "iterm2"
    public let displayName = "iTerm2"
    public let priority = 50
    public static let bundleID = "com.googlecode.iterm2"

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        context.terminalBundleID == Self.bundleID
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        if let tab = context.terminalTabTitle, !tab.isEmpty {
            let scriptResult = await runAppleScript(
                """
                tell application "iTerm2"
                  activate
                  set matched to false
                  repeat with w in windows
                    repeat with t in tabs of w
                      try
                        if name of current session of t contains "\(escapeAppleScript(tab))" then
                          select t
                          set matched to true
                          exit repeat
                        end if
                      end try
                    end repeat
                    if matched then exit repeat
                  end repeat
                end tell
                """
            )
            if scriptResult.succeeded {
                return JumpBackResult(
                    strategyID: id,
                    succeeded: true,
                    detail: "Focused iTerm2 tab matching \(tab)"
                )
            }
        }
        return await activateBundle(Self.bundleID, strategyID: id, displayName: displayName)
    }
}

public struct GhosttyJumpStrategy: JumpBackStrategy {
    public let id = "ghostty"
    public let displayName = "Ghostty"
    public let priority = 55
    /// Confirmed public bundle id for Ghostty (mitchellh).
    public static let bundleID = "com.mitchellh.ghostty"

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        context.terminalBundleID == Self.bundleID
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        // Ghostty has limited AppleScript surface; activate / launch is the MVP path.
        await activateBundle(Self.bundleID, strategyID: id, displayName: displayName)
    }
}

public struct VSCodeJumpStrategy: JumpBackStrategy {
    public let id = "vscode"
    public let displayName = "Visual Studio Code"
    public let priority = 70

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        if let url = context.editorURL, url.scheme == "vscode" || url.scheme == "vscode-insiders" {
            return true
        }
        if context.extra["editor"] == "vscode" { return true }
        return false
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        if let url = context.editorURL {
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            return JumpBackResult(
                strategyID: id,
                succeeded: ok,
                detail: ok ? "Opened \(url.absoluteString)" : "Failed to open \(url.absoluteString)"
            )
        }
        if let cwd = context.workingDirectory {
            let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
            let urlString = "vscode://file\(encoded)"
            if let url = URL(string: urlString) {
                let ok = await MainActor.run { NSWorkspace.shared.open(url) }
                return JumpBackResult(
                    strategyID: id,
                    succeeded: ok,
                    detail: ok ? "Opened folder in VS Code" : "Failed to open VS Code URL"
                )
            }
        }
        return JumpBackResult(strategyID: id, succeeded: false, detail: "No VS Code target")
    }
}

public struct CursorJumpStrategy: JumpBackStrategy {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let priority = 75

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        if let url = context.editorURL, url.scheme == "cursor" { return true }
        if context.extra["editor"] == "cursor" { return true }
        return false
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        if let url = context.editorURL {
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            return JumpBackResult(
                strategyID: id,
                succeeded: ok,
                detail: ok ? "Opened \(url.absoluteString)" : "Failed to open \(url.absoluteString)"
            )
        }
        if let cwd = context.workingDirectory {
            let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
            if let url = URL(string: "cursor://file\(encoded)") {
                let ok = await MainActor.run { NSWorkspace.shared.open(url) }
                return JumpBackResult(
                    strategyID: id,
                    succeeded: ok,
                    detail: ok ? "Opened folder in Cursor" : "Failed to open Cursor URL"
                )
            }
        }
        return JumpBackResult(strategyID: id, succeeded: false, detail: "No Cursor target")
    }
}

/// Last-resort: reveal working directory in Finder.
public struct RevealInFinderStrategy: JumpBackStrategy {
    public let id = "finder"
    public let displayName = "Finder"
    public let priority = 10

    public init() {}

    public func canHandle(_ context: JumpBackContext) -> Bool {
        context.workingDirectory != nil
    }

    public func perform(_ context: JumpBackContext) async -> JumpBackResult {
        guard let cwd = context.workingDirectory else {
            return JumpBackResult(strategyID: id, succeeded: false, detail: "No cwd")
        }
        let url = URL(fileURLWithPath: cwd, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: cwd)
        guard exists else {
            return JumpBackResult(
                strategyID: id,
                succeeded: false,
                detail: "Working directory does not exist: \(cwd)"
            )
        }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return JumpBackResult(strategyID: id, succeeded: true, detail: "Revealed \(cwd)")
    }
}

// MARK: - Helpers

@MainActor
private func activateBundle(_ bundleID: String, strategyID: String, displayName: String) async -> JumpBackResult {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if let app = apps.first {
        let ok = app.activate(options: [.activateAllWindows])
        return JumpBackResult(
            strategyID: strategyID,
            succeeded: ok,
            detail: ok ? "Activated \(displayName)" : "activate failed for \(displayName)"
        )
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return JumpBackResult(
            strategyID: strategyID,
            succeeded: false,
            detail: "\(displayName) not installed (bundle \(bundleID))"
        )
    }
    do {
        let config = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return JumpBackResult(strategyID: strategyID, succeeded: true, detail: "Launched \(displayName)")
    } catch {
        return JumpBackResult(
            strategyID: strategyID,
            succeeded: false,
            detail: "Failed to launch \(displayName): \(error.localizedDescription)"
        )
    }
}

private func escapeAppleScript(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Run AppleScript on the main actor. `NSAppleScript` is AppKit-bound and must
/// not run inside `Task.detached` (not Sendable; undefined thread affinity).
@MainActor
private func runAppleScriptOnMainActor(_ source: String) -> JumpBackResult {
    let script = NSAppleScript(source: source)
    var error: NSDictionary?
    _ = script?.executeAndReturnError(&error)
    if let error {
        let message = error[NSAppleScript.errorMessage] as? String ?? String(describing: error)
        return JumpBackResult(strategyID: "applescript", succeeded: false, detail: message)
    }
    return JumpBackResult(strategyID: "applescript", succeeded: true, detail: "ok")
}

private func runAppleScript(_ source: String) async -> JumpBackResult {
    await MainActor.run {
        runAppleScriptOnMainActor(source)
    }
}
