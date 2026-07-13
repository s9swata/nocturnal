import Foundation

/// Pure geometry policy for the floating overlay (no AppKit).
///
/// Shared by ``OverlayController`` (UI) and unit tests so clamp constants are
/// not mirrored. Pixel-level AppKit chrome (e.g. `NSPanel.hasShadow = false`)
/// remains a UI configuration concern and is not modeled here.
public enum OverlayGeometry: Sendable {
    /// Compact pill width.
    public static let compactWidth: CGFloat = 228
    /// Compact pill height.
    public static let compactHeight: CGFloat = 36
    /// Ideal expanded panel width before screen clamp.
    public static let idealExpandedWidth: CGFloat = 520
    /// Ideal expanded panel height before screen clamp.
    public static let idealExpandedHeight: CGFloat = 620
    /// Margin reserved inside the visible frame when clamping expanded size.
    public static let panelScreenPadding: CGFloat = 16
    /// Floor for clamped expanded width on very small displays.
    public static let minExpandedWidth: CGFloat = 200
    /// Floor for clamped expanded height on very small displays.
    public static let minExpandedHeight: CGFloat = 240

    public static var compactSize: CGSize {
        CGSize(width: compactWidth, height: compactHeight)
    }

    public static var idealExpandedSize: CGSize {
        CGSize(width: idealExpandedWidth, height: idealExpandedHeight)
    }

    /// Clamp expanded dimensions to a visible frame (multi-display / small screens).
    public static func clampedExpandedSize(visibleFrame: CGRect) -> CGSize {
        let maxW = max(minExpandedWidth, visibleFrame.width - panelScreenPadding)
        let maxH = max(minExpandedHeight, visibleFrame.height - panelScreenPadding)
        return CGSize(
            width: min(idealExpandedWidth, maxW),
            height: min(idealExpandedHeight, maxH)
        )
    }
}
