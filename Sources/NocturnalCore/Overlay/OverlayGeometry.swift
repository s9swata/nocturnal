import Foundation

/// Pure geometry policy for the floating overlay (no AppKit).
///
/// Shared by ``OverlayController`` (UI) and unit tests so clamp constants are
/// not mirrored. Pixel-level AppKit chrome (e.g. `NSPanel.hasShadow = false`)
/// remains a UI configuration concern; host sizing policy that is pure
/// (raw values, dimensions) is documented here for regression tests.
///
/// ## Notch-hug placement
/// Compact and expanded overlays hang from the **absolute top** of the screen
/// (`screenFrame.maxY`) so the black chrome reads as a camera-housing extension,
/// not a floating card under the menu bar. There is no intentional gap below the
/// notch for compact mode.
public enum OverlayGeometry: Sendable {
    /// Default / legacy compact width (liveCompact baseline).
    public static let compactWidth: CGFloat = 300
    /// Default / legacy compact height.
    public static let compactHeight: CGFloat = 44
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
    /// Inset from screen / visible edges when placing the panel.
    public static let screenEdgeInset: CGFloat = 8
    /// Default gap below screen top when hugging (compact production = 0).
    public static let notchHugGap: CGFloat = 0
    /// Gap used only when `hugTop` is false (legacy below-chrome placement).
    public static let belowChromeGap: CGFloat = 6

    /// Max island width as a fraction of screen width (leave room for menu extras).
    public static let islandMaxScreenFraction: CGFloat = 0.48
    public static let islandMinWidth: CGFloat = 168
    /// Must be ≥ attention ideal so Deny/Allow chips are not panel-clipped.
    public static let islandMaxWidth: CGFloat = 440

    public static var compactSize: CGSize {
        islandSize(for: .liveCompact)
    }

    public static var idealExpandedSize: CGSize {
        CGSize(width: idealExpandedWidth, height: idealExpandedHeight)
    }

    /// Dynamic Island–style compact sizes (Nocturnal black drip chrome).
    public static func islandSize(for mode: PillIslandMode) -> CGSize {
        switch mode {
        case .quiet:
            return CGSize(width: 188, height: 36)
        case .listening:
            return CGSize(width: 216, height: 40)
        case .liveCompact:
            return CGSize(width: 288, height: 44)
        case .liveExpanded:
            return CGSize(width: 328, height: 56)
        case .attention:
            // Mark + two-line copy + Deny/Allow; panel owns this size.
            return CGSize(width: 420, height: 60)
        }
    }

    /// Clamp island size so it never swallows the menu bar on small displays.
    public static func clampedIslandSize(
        for mode: PillIslandMode,
        visibleFrame: CGRect
    ) -> CGSize {
        let ideal = islandSize(for: mode)
        let fractionCap = max(islandMinWidth, visibleFrame.width * islandMaxScreenFraction)
        // Never clamp a mode below its ideal unless the screen fraction forces it.
        let maxW = min(islandMaxWidth, fractionCap)
        return CGSize(
            width: min(ideal.width, maxW),
            height: ideal.height
        )
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
        targetSize(expanded: expanded, visibleFrame: visibleFrame, islandMode: .liveCompact)
    }

    /// Target size with Dynamic Island mode for compact chrome.
    public static func targetSize(
        expanded: Bool,
        visibleFrame: CGRect,
        islandMode: PillIslandMode
    ) -> CGSize {
        if expanded {
            return clampedExpandedSize(visibleFrame: visibleFrame)
        }
        return clampedIslandSize(for: islandMode, visibleFrame: visibleFrame)
    }

    /// Top-center placement. Production uses ``hugTop`` so the panel extends from
    /// the physical top of the display (notch / menu-bar band).
    ///
    /// - Parameters:
    ///   - size: Panel size (already clamped if expanded).
    ///   - screenFrame: Full screen frame (`NSScreen.frame`).
    ///   - visibleFrame: Usable area excluding menu bar / dock.
    ///   - safeAreaTop: Camera housing inset (ignored when `hugTop` is true —
    ///     the extension intentionally occupies that band).
    ///   - gap: Points below screen top (`0` for true notch hug).
    ///   - edgeInset: Horizontal margin inside the placement bounds.
    ///   - hugTop: When true, flush to `screenFrame.maxY` (notch extension).
    ///     When false, place below menu bar / safe area (legacy).
    public static func topCenterFrame(
        size: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        gap: CGFloat = notchHugGap,
        edgeInset: CGFloat = screenEdgeInset,
        hugTop: Bool = true
    ) -> CGRect {
        if hugTop {
            return notchHugFrame(
                size: size,
                screenFrame: screenFrame,
                gap: gap,
                edgeInset: edgeInset
            )
        }

        // Legacy: sit just below menu bar / notch safe area.
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
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

    /// Flush-to-top notch extension frame (centered on the screen).
    public static func notchHugFrame(
        size: CGSize,
        screenFrame: CGRect,
        gap: CGFloat = notchHugGap,
        edgeInset: CGFloat = screenEdgeInset
    ) -> CGRect {
        let x = screenFrame.midX - size.width / 2
        // AppKit: maxY is the top edge. Flush means origin.y = maxY - height - gap.
        let y = screenFrame.maxY - size.height - gap
        let minX = screenFrame.minX + edgeInset
        let maxX = screenFrame.maxX - size.width - edgeInset
        let clampedX: CGFloat = {
            if maxX < minX {
                return screenFrame.midX - size.width / 2
            }
            return min(max(x, minX), maxX)
        }()
        return CGRect(x: clampedX, y: y, width: size.width, height: size.height)
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
