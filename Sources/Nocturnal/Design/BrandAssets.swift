import AppKit
import SwiftUI

/// Centralized brand image loading — never hardcode resource paths in views.
enum BrandAssets {
    static let owlMarkResourceName = "nocturnal-owl-mark"
    static let appIconResourceName = "nocturnal-app-icon"

    /// Transparent owl mark as a template-ready `NSImage` (menu bar, monochrome chrome).
    static func owlMarkNSImage(size: CGFloat? = nil) -> NSImage? {
        guard let image = loadNSImage(named: owlMarkResourceName) else { return nil }
        image.isTemplate = true
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        return image
    }

    /// Full-color / full-bleed app icon source (about surfaces, dock packaging).
    static func appIconNSImage(size: CGFloat? = nil) -> NSImage? {
        guard let image = loadNSImage(named: appIconResourceName) else { return nil }
        if let size {
            image.size = NSSize(width: size, height: size)
        }
        return image
    }

    static func loadNSImage(named name: String) -> NSImage? {
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
