import Foundation

/// Pure geometry policy for the floating overlay (no AppKit).
///
/// Shared by ``OverlayController`` (UI) and unit tests so clamp constants are
/// not mirrored. Pixel-level AppKit chrome (e.g. `NSPanel.hasShadow = false`)
/// remains a UI configuration concern; host sizing policy that is pure
/// (raw values, dimensions) is documented here for regression tests.
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
    /// Inset from visible screen edges when placing the panel.
    public static let screenEdgeInset: CGFloat = 8

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

    /// Target size for compact or expanded overlay on a given visible frame.
    public static func targetSize(expanded: Bool, visibleFrame: CGRect) -> CGSize {
        if expanded {
            return clampedExpandedSize(visibleFrame: visibleFrame)
        }
        return compactSize
    }

    /// Top-center or notch-safe placement in screen coordinates.
    ///
    /// - Parameters:
    ///   - size: Panel size (already clamped if expanded).
    ///   - screenFrame: Full screen frame (`NSScreen.frame`).
    ///   - visibleFrame: Usable area excluding menu bar / dock.
    ///   - safeAreaTop: Camera housing / notch inset (`safeAreaInsets.top`).
    ///   - gap: Points below menu bar / notch.
    ///   - edgeInset: Horizontal/vertical margin inside `visibleFrame`.
    public static func topCenterFrame(
        size: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        gap: CGFloat = 6,
        edgeInset: CGFloat = screenEdgeInset
    ) -> CGRect {
        // Distance from top of screen to top of visible frame ≈ menu bar.
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)

        // Notch / camera housing: safeAreaTop can exceed menu bar.
        var topInset = menuBarHeight
        if safeAreaTop > 0 {
            topInset = max(menuBarHeight, safeAreaTop)
        }

        let x = visibleFrame.midX - size.width / 2
        let y = screenFrame.maxY - topInset - size.height - gap

        let minY = visibleFrame.minY + edgeInset
        let clampedY = max(minY, min(y, visibleFrame.maxY - size.height - 4))
        let clampedX = min(
            max(x, visibleFrame.minX + edgeInset),
            visibleFrame.maxX - size.width - edgeInset
        )

        return CGRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }
}

// MARK: - Host layout policy (pure contract for UI OverlayController)

/// Pure host-layout contract consumed by the AppKit overlay.
///
/// The live `NSHostingView.sizingOptions` API is AppKit/SwiftUI-only; this type
/// documents the raw OptionSet value and boolean chrome flags that production
/// code must apply so tests can lock the crash-prevention contract without
/// hosting a real window.
public enum OverlayHostLayoutPolicy: Sendable {
    /// Empty `NSHostingSizingOptions` raw value — disables automatic window sizing
    /// from min / intrinsic / max / preferred content size. Non-empty values allow
    /// `NSHostingView.updateAnimatedWindowSize` to mutate the panel frame and can
    /// recurse into Auto Layout until NSGenericException.
    public static let disabledHostingSizingOptionsRawValue: Int = 0

    /// Hosting view must autoresize width and height with the panel content rect.
    public static let autoresizesWidthAndHeight: Bool = true

    public static let panelIsOpaque: Bool = false
    public static let panelHasShadow: Bool = false
    public static let panelBackgroundIsClear: Bool = true
    public static let hostingLayerIsClear: Bool = true

    /// Whether a raw `sizingOptions` value matches the production empty set.
    public static func isAutomaticWindowSizingDisabled(sizingOptionsRawValue: Int) -> Bool {
        sizingOptionsRawValue == disabledHostingSizingOptionsRawValue
    }

    /// Combined production contract check used by configuration helpers / tests.
    public static func matchesProductionContract(
        sizingOptionsRawValue: Int,
        autoresizesWithPanel: Bool,
        panelIsOpaque: Bool,
        panelHasShadow: Bool,
        panelBackgroundIsClear: Bool,
        hostingLayerIsClear: Bool
    ) -> Bool {
        isAutomaticWindowSizingDisabled(sizingOptionsRawValue: sizingOptionsRawValue)
            && autoresizesWithPanel == autoresizesWidthAndHeight
            && panelIsOpaque == Self.panelIsOpaque
            && panelHasShadow == Self.panelHasShadow
            && panelBackgroundIsClear == Self.panelBackgroundIsClear
            && hostingLayerIsClear == Self.hostingLayerIsClear
    }
}
