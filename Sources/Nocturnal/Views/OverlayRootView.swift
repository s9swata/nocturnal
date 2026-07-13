import SwiftUI
import NocturnalCore

/// SwiftUI content hosted inside the non-activating AppKit overlay panel.
struct OverlayRootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        model.prefersReducedMotion || systemReduceMotion
    }

    var body: some View {
        Group {
            if model.isOverlayExpanded {
                ExpandedOverlayPanel(model: model, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                PillView(model: model, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity)
            }
        }
        .frame(
            width: model.isOverlayExpanded ? NocturnalLayout.panelWidth : NocturnalLayout.pillWidth,
            height: model.isOverlayExpanded ? NocturnalLayout.panelHeight : NocturnalLayout.pillHeight
        )
        .animation(NocturnalMotion.expand(reduceMotion: reduceMotion), value: model.isOverlayExpanded)
    }
}

// MARK: - Expanded panel chrome

private struct ExpandedOverlayPanel: View {
    @Bindable var model: AppModel
    var reduceMotion: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.6))
            SessionPanelView(model: model, style: .overlay)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.6))
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: NocturnalLayout.cornerRadiusPanel, style: .continuous)
                .fill(NocturnalPalette.bgBase)
                .overlay(
                    RoundedRectangle(cornerRadius: NocturnalLayout.cornerRadiusPanel, style: .continuous)
                        .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.7), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: NocturnalLayout.cornerRadiusPanel, style: .continuous))
        .focusable()
        .focused($listFocused)
        .onKeyPress(.escape) {
            model.collapseOverlay()
            return .handled
        }
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
        .onAppear { listFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nocturnal session panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.stars.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .accessibilityHidden(true)

            Text("Sessions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NocturnalPalette.fgPrimary)

            if model.settings.demoMode {
                Text("Demo")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(NocturnalPalette.bgHighlight, in: Capsule())
            }

            Spacer(minLength: 4)

            if model.attentionCount > 0 {
                Text("\(model.attentionCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NocturnalPalette.bgBase)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(NocturnalPalette.accentAttention, in: Capsule())
                    .accessibilityLabel("\(model.attentionCount) need attention")
            }

            Button {
                model.collapseOverlay()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse panel")
            .accessibilityLabel("Collapse session panel")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, NocturnalLayout.contentPadding)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Text(model.statusMessage)
            .font(.caption2)
            .foregroundStyle(NocturnalPalette.fgSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NocturnalLayout.contentPadding)
            .padding(.vertical, 8)
            .accessibilityLabel("Status: \(model.statusMessage)")
    }
}
