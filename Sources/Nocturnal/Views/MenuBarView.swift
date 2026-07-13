import AppKit
import SwiftUI
import NocturnalCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var panelFocused: Bool

    private var reduceMotion: Bool {
        model.prefersReducedMotion || systemReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            SessionPanelView(model: model, style: .menuBar)
                .frame(width: NocturnalLayout.menuBarWidth, height: 280)
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            footer
        }
        .frame(width: NocturnalLayout.menuBarWidth)
        .background(NocturnalPalette.bgBase)
        .focusable()
        .focused($panelFocused)
        .onAppear { panelFocused = true }
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
        .accessibilityLabel("Nocturnal menu")
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

            if model.settings.demoMode {
                Text("Demo")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(NocturnalPalette.bgHighlight, in: Capsule())
                    .accessibilityLabel("Demo mode active")
            }

            Spacer(minLength: 4)

            Text(model.attentionCount, format: .number)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(
                    model.attentionCount > 0
                        ? NocturnalPalette.accentAttention
                        : NocturnalPalette.fgSecondary
                )
                .accessibilityLabel(
                    "\(model.attentionCount) sessions need attention"
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusMessage)
                .font(.caption2)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Status: \(model.statusMessage)")
                .animation(NocturnalMotion.standard(reduceMotion: reduceMotion), value: model.statusMessage)

            HStack(spacing: 12) {
                Button(model.settings.demoMode ? "Exit Demo" : "Demo Mode") {
                    Task { await model.toggleDemoMode() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NocturnalPalette.fgPrimary)
                .accessibilityLabel(model.settings.demoMode ? "Exit demo mode" : "Enter demo mode")

                if model.settings.demoMode {
                    Button("Reload") {
                        Task { await model.reloadDemoFixtures() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .accessibilityLabel("Reload demo fixtures")
                }

                Spacer()

                Button("Settings…") {
                    openSettings()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Open settings")

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit Nocturnal")
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
