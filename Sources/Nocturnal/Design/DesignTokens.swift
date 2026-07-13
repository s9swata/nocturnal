import SwiftUI

/// Quiet nocturnal brand tokens — warm near-black, no neon or glassmorphism.
enum NocturnalPalette {
    /// App / panel background — warm near-black (hsl ~30 8% 8%).
    static let bgBase = Color(red: 0.10, green: 0.09, blue: 0.08)
    /// Elevated surfaces — slightly lighter warm charcoal.
    static let bgElevated = Color(red: 0.14, green: 0.13, blue: 0.12)
    /// Row hover / selection wash.
    static let bgHighlight = Color(red: 0.18, green: 0.16, blue: 0.14)
    /// Soft warm off-white primary text.
    static let fgPrimary = Color(red: 0.93, green: 0.91, blue: 0.88)
    /// Muted warm gray secondary text.
    static let fgSecondary = Color(red: 0.62, green: 0.58, blue: 0.54)
    /// Soft amber / copper attention accent.
    static let accentAttention = Color(red: 0.82, green: 0.58, blue: 0.32)
    /// Desaturated danger red.
    static let accentDanger = Color(red: 0.72, green: 0.38, blue: 0.34)
    /// Muted sage success.
    static let accentSuccess = Color(red: 0.48, green: 0.62, blue: 0.48)
    /// Low-contrast warm hairline.
    static let borderSubtle = Color(red: 0.28, green: 0.25, blue: 0.22)
    /// Pill / panel fill with slight elevation over desktop.
    static let pillFill = Color(red: 0.12, green: 0.11, blue: 0.10)
}

enum NocturnalLayout {
    static let pillWidth: CGFloat = 228
    static let pillHeight: CGFloat = 36
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 440
    static let menuBarWidth: CGFloat = 320
    static let contentPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let cornerRadiusPill: CGFloat = 18
    static let cornerRadiusPanel: CGFloat = 14
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
