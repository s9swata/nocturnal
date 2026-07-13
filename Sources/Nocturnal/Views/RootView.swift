import SwiftUI
import NocturnalCore

/// Development / windowed root. Production companion is menu bar + overlay.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var listFocused: Bool

    private var reduceMotion: Bool {
        model.prefersReducedMotion || systemReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            SessionPanelView(model: model, style: .window)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            footer
        }
        .background(NocturnalPalette.bgBase)
        .focusable()
        .focused($listFocused)
        .onAppear { listFocused = true }
        .onKeyPress(.upArrow) {
            model.selectNextSession(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.selectNextSession(delta: 1)
            return .handled
        }
        .onKeyPress(KeyEquivalent("a")) {
            Task { await model.approveSelected(approved: true) }
            return .handled
        }
        .onKeyPress(KeyEquivalent("d")) {
            Task { await model.approveSelected(approved: false) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nocturnal sessions")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.stars.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .accessibilityHidden(true)

            Text("Nocturnal")
                .font(.headline)
                .foregroundStyle(NocturnalPalette.fgPrimary)

            Spacer()

            Text(model.settings.demoMode ? "Demo" : "Live")
                .font(.caption.weight(.medium))
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(NocturnalPalette.bgHighlight, in: Capsule())
                .accessibilityLabel(model.settings.demoMode ? "Demo mode" : "Live mode")
        }
        .padding(NocturnalLayout.contentPadding)
    }

    private var footer: some View {
        Text(model.statusMessage)
            .font(.caption)
            .foregroundStyle(NocturnalPalette.fgSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NocturnalLayout.contentPadding)
            .accessibilityLabel("Status: \(model.statusMessage)")
            .animation(NocturnalMotion.standard(reduceMotion: reduceMotion), value: model.statusMessage)
    }
}
