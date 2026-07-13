import SwiftUI
import NocturnalCore

/// Compact top-of-screen indicator. Expands into the session panel on click.
struct PillView: View {
    @Bindable var model: AppModel
    var reduceMotion: Bool

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
            return model.settings.demoMode ? "Demo · no sessions" : "Quiet"
        }
        if model.settings.demoMode {
            return "Demo · \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
        }
        return "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    var body: some View {
        Button {
            model.setOverlayExpanded(true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        attentionCount > 0
                            ? NocturnalPalette.accentAttention
                            : NocturnalPalette.fgSecondary
                    )
                    .accessibilityHidden(true)

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
                        .opacity(attentionGlow || reduceMotion ? 1 : 0.55)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(NocturnalPalette.pillFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.85), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            )
        }
        .buttonStyle(.plain)
        .frame(width: NocturnalLayout.pillWidth, height: NocturnalLayout.pillHeight)
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
        } else if model.settings.demoMode {
            parts.append("Demo mode")
        }
        return parts.joined(separator: ", ")
    }

    private func updateGlow() {
        guard attentionCount > 0, !reduceMotion else {
            attentionGlow = attentionCount > 0
            return
        }
        attentionGlow = true
        withAnimation(NocturnalMotion.attentionBreath) {
            attentionGlow = true
        }
    }
}
