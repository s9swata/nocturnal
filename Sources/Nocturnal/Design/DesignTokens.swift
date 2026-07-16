import NocturnalCore
import SwiftUI

/// Vercel-inspired monochrome brand tokens — black, white, neutral grays.
/// Semantic color only for approval / warning / failure / success meaning.
enum NocturnalPalette {
    /// App / panel background — pure near-black.
    static let bgBase = Color(red: 0.039, green: 0.039, blue: 0.039) // #0A0A0A
    /// Elevated surfaces — one step lighter.
    static let bgElevated = Color(red: 0.078, green: 0.078, blue: 0.078) // #141414
    /// Row hover / selection wash.
    static let bgHighlight = Color(red: 0.118, green: 0.118, blue: 0.118) // #1E1E1E
    /// Soft white primary text.
    static let fgPrimary = Color(red: 0.929, green: 0.929, blue: 0.929) // #EDEDED
    /// Mid neutral secondary text.
    static let fgSecondary = Color(red: 0.533, green: 0.533, blue: 0.533) // #888888
    /// Restrained amber — approvals / questions only.
    static let accentAttention = Color(red: 0.78, green: 0.58, blue: 0.28)
    /// Desaturated danger red — failures / deny only.
    static let accentDanger = Color(red: 0.72, green: 0.36, blue: 0.34)
    /// Muted success green — completed only.
    static let accentSuccess = Color(red: 0.42, green: 0.58, blue: 0.44)
    /// Low-contrast neutral hairline.
    static let borderSubtle = Color(red: 0.22, green: 0.22, blue: 0.22) // #383838
    /// Pill fill over desktop (legacy elevated).
    static let pillFill = Color(red: 0.06, green: 0.06, blue: 0.06) // #0F0F0F
    /// Notch-extension fill — matches physical camera housing black.
    static let notchFill = Color.black
}

/// UI layout tokens. Overlay panel/pill sizes are owned by ``OverlayGeometry``.
enum NocturnalLayout {
    /// Baseline live-compact island size (modes override via ``OverlayGeometry/islandSize(for:)``).
    static let pillWidth: CGFloat = OverlayGeometry.islandSize(for: .liveCompact).width
    static let pillHeight: CGFloat = OverlayGeometry.islandSize(for: .liveCompact).height
    /// Expanded overlay target width (clamped to visible screen).
    static let panelWidth: CGFloat = OverlayGeometry.idealExpandedWidth
    /// Expanded overlay target height (clamped to visible screen).
    static let panelHeight: CGFloat = OverlayGeometry.idealExpandedHeight
    static let menuBarWidth: CGFloat = 320
    static let contentPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let cornerRadiusPill: CGFloat = 18
    static let cornerRadiusPanel: CGFloat = 14
    /// Inset from visible screen edges when placing / clamping the panel.
    static let screenEdgeInset: CGFloat = OverlayGeometry.screenEdgeInset
    /// Extra room reserved inside the visible frame when clamping expanded size.
    static let panelScreenPadding: CGFloat = OverlayGeometry.panelScreenPadding
}

enum NocturnalMotion {
    /// Short damped timing for primary UI (~0.2s, no bounce).
    static let standard = Animation.easeInOut(duration: 0.2)
    /// Slightly longer for expand/collapse of the overlay panel.
    static let expand = Animation.easeInOut(duration: 0.22)
    /// Subtle single breath for attention (never aggressive blink).
    static let attentionBreath = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)

    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : standard
    }

    static func expand(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : expand
    }
}
