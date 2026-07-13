import SwiftUI
import NocturnalCore

/// Compact top-of-screen indicator. Expands into the session panel on click.
///
/// Visual is a **capsule only**: fill, hairline stroke, and soft capsule shadow.
/// The hosting `NSPanel` must not draw a rectangular window shadow (see OverlayController).
struct PillView: View {
    @Bindable var model: AppModel
    var reduceMotion: Bool

    /// When true, attention dot is fully opaque; animation breathes opacity only.
    @State private var attentionGlow = false

    private var attentionCount: Int { model.attentionCount }
    private var sessionCount: Int { model.snapshot.sessions.count }

    private var statusLine: String {
        if attentionCount > 0 {
            return attentionCount == 1
                ? "1 needs attention"
                : "\(attentionCount) need attention"
        }
        if sessionCount == 0 {
            return "Quiet"
        }
        return "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    /// Opacity-only attention cue — never changes layout metrics.
    private var attentionDotOpacity: Double {
        if attentionCount == 0 { return 0 }
        if reduceMotion { return 1 }
        return attentionGlow ? 1.0 : 0.55
    }

    var body: some View {
        Button {
            model.setOverlayExpanded(true)
        } label: {
            HStack(spacing: 8) {
                BrandOwlMark(size: 13)
                    .foregroundStyle(
                        attentionCount > 0
                            ? NocturnalPalette.accentAttention
                            : NocturnalPalette.fgSecondary
                    )

                Text("Nocturnal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                    .lineLimit(1)

                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)

                if attentionCount > 0 {
                    Circle()
                        .fill(NocturnalPalette.accentAttention)
                        .frame(width: 6, height: 6)
                        .opacity(attentionDotOpacity)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(NocturnalPalette.pillFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.9), lineWidth: 1)
                    )
                    // Capsule-shaped shadow only — not a rectangular window halo.
                    .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 3)
            }
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: NocturnalLayout.pillWidth, height: NocturnalLayout.pillHeight)
        // Ensure the hosting view does not paint outside the capsule.
        .compositingGroup()
        .accessibilityLabel(pillAccessibilityLabel)
        .accessibilityHint("Shows the session panel")
        .onAppear { updateGlow() }
        .onChange(of: attentionCount) { _, _ in updateGlow() }
        .onChange(of: reduceMotion) { _, _ in updateGlow() }
    }

    private var pillAccessibilityLabel: String {
        var parts = ["Nocturnal", statusLine]
        if model.isSocketRunning {
            parts.append("Listening")
        }
        return parts.joined(separator: ", ")
    }

    /// Drive a real opacity transition when attention is active and motion is allowed.
    private func updateGlow() {
        guard attentionCount > 0 else {
            // Drop animation transaction when quiet so we do not leave a forever timer.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                attentionGlow = false
            }
            return
        }
        guard !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                attentionGlow = true
            }
            return
        }
        // Seed the dim endpoint first so withAnimation has a real false → true change.
        // repeatForever(autoreverses:) then breathes opacity without geometry changes.
        var seed = Transaction()
        seed.disablesAnimations = true
        withTransaction(seed) {
            attentionGlow = false
        }
        withAnimation(NocturnalMotion.attentionBreath) {
            attentionGlow = true
        }
    }
}
