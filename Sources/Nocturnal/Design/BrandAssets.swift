import AppKit
import NocturnalCore
import SwiftUI

/// Centralized brand image loading — never hardcode resource paths in views.
///
/// Bundled source images are cached immutably. Call sites always receive a **copy**
/// before size / template mutations so repeated SwiftUI body evaluations neither
/// re-read resources from disk nor mutate shared named images.
enum BrandAssets {
    static let owlMarkResourceName = "nocturnal-owl-mark"
    static let appIconResourceName = "nocturnal-app-icon"

    /// Codex uses OpenAI’s public mark (Simple Icons CC0); see `Brand/AGENT_ICONS.md`.
    static let codexMarkResourceName = "agent-openai"
    /// Claude Code uses Claude’s public mark (Simple Icons CC0).
    static let claudeMarkResourceName = "agent-claude"
    /// OpenCode square mark (brand-aligned static SVG).
    static let openCodeMarkResourceName = "agent-opencode"
    /// Cursor mark (Simple Icons CC0).
    static let cursorMarkResourceName = "agent-cursor"
    /// Grok Build monochrome spark (original template mark).
    static let grokMarkResourceName = "agent-grok"

    /// Thread-safe immutable source cache. Entries are never mutated after insert.
    private static let sourceCache = ImageSourceCache()

    /// Transparent owl mark as a template-ready `NSImage` (menu bar, monochrome chrome).
    static func owlMarkNSImage(size: CGFloat? = nil) -> NSImage? {
        guard let image = mutableCopyOfSource(named: owlMarkResourceName) else { return nil }
        image.isTemplate = true
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        return image
    }

    /// Full-color / full-bleed app icon source (about surfaces, dock packaging).
    static func appIconNSImage(size: CGFloat? = nil) -> NSImage? {
        guard let image = mutableCopyOfSource(named: appIconResourceName) else { return nil }
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        return image
    }

    /// Monochrome agent product mark for supported coding agents.
    static func agentMarkNSImage(for source: AgentSource, size: CGFloat? = nil) -> NSImage? {
        guard let name = agentMarkResourceName(for: source) else { return nil }
        guard let image = mutableCopyOfSource(named: name) else { return nil }
        image.isTemplate = true
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        return image
    }

    static func agentMarkResourceName(for source: AgentSource) -> String? {
        switch source {
        case .codex: return codexMarkResourceName
        case .claude: return claudeMarkResourceName
        case .opencode: return openCodeMarkResourceName
        case .cursor: return cursorMarkResourceName
        case .grokBuild: return grokMarkResourceName
        case .kimi, .agy, .unknown: return nil
        }
    }

    /// SF Symbol fallback when a brand PNG is missing from the bundle.
    static func agentFallbackSystemImage(for source: AgentSource) -> String {
        switch source {
        case .codex: return "cpu"
        case .claude: return "bubble.left.and.bubble.right"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "curlybraces.square"
        case .kimi: return "moon.stars"
        case .grokBuild: return "sparkle"
        case .agy: return "sparkles"
        case .unknown: return "circle.dashed"
        }
    }

    /// Returns a detached copy of the cached source, or loads and caches once.
    private static func mutableCopyOfSource(named name: String) -> NSImage? {
        guard let source = sourceCache.image(named: name, load: { loadNSImageFromBundle(named: name) })
        else { return nil }
        // Copy before any size / isTemplate mutation so the cache stays pristine.
        guard let copy = source.copy() as? NSImage else {
            // Fallback: re-load a fresh instance rather than mutating the shared cache.
            return loadNSImageFromBundle(named: name)
        }
        return copy
    }

    /// Lock-backed cache for bundled sources (`@unchecked Sendable` via internal mutex).
    private final class ImageSourceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSImage] = [:]

        func image(named name: String, load: () -> NSImage?) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[name] {
                return cached
            }
            guard let loaded = load() else { return nil }
            storage[name] = loaded
            return loaded
        }
    }

    /// Disk / bundle load only — not for direct call sites that mutate the result.
    static func loadNSImage(named name: String) -> NSImage? {
        // Public entry for tests / diagnostics: always returns a fresh copy when cached.
        if let image = mutableCopyOfSource(named: name) {
            return image
        }
        return loadNSImageFromBundle(named: name)
    }

    private static func loadNSImageFromBundle(named name: String) -> NSImage? {
        // SPM resource bundle for the Nocturnal executable target.
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Brand"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        // Packaged app: Resources/Brand or flat Resources.
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Brand"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        // Named lookup last; do not cache NSImage(named:) results without copying at use.
        return NSImage(named: name)
    }
}

/// Owl mark for SwiftUI chrome. Template rendering; tint via `.foregroundStyle`.
struct BrandOwlMark: View {
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let nsImage = BrandAssets.owlMarkNSImage(size: size) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                // Fallback if resources are missing in a bare `swift run` layout.
                Image(systemName: "circle.grid.cross.fill")
                    .font(.system(size: size * 0.75, weight: .medium))
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// App icon mark for about / empty-state hero (full-bleed art when available).
struct BrandAppIcon: View {
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let nsImage = BrandAssets.appIconNSImage(size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                BrandOwlMark(size: size * 0.7)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Product mark for a coding agent (Codex / Claude / OpenCode).
/// Template-tinted monochrome brand SVG→PNG; falls back to an SF Symbol.
struct AgentBrandMark: View {
    let source: AgentSource
    var size: CGFloat = 13
    var color: Color = NocturnalPalette.fgSecondary

    var body: some View {
        Group {
            if let nsImage = BrandAssets.agentMarkNSImage(for: source, size: size) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: BrandAssets.agentFallbackSystemImage(for: source))
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(source.displayName)
    }
}
