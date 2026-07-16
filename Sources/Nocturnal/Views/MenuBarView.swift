import AppKit
import SwiftUI
import NocturnalCore

/// Compact status menu for the macOS menu-bar extra.
///
/// **Not** a second session list — that lives on the notch expand. This surface
/// is for socket status, attention counts, and app controls (settings / quit).
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        model.prefersReducedMotion || systemReduceMotion
    }

    /// Same live definition as the notch (`pillIslandContent.liveCount`).
    private var liveCount: Int {
        model.pillIslandContent.liveCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            statusBlock
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            actionsBlock
            Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            footer
        }
        .frame(width: NocturnalLayout.menuBarWidth)
        .background(NocturnalPalette.bgBase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nocturnal menu")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            BrandOwlMark(size: 16)
                .foregroundStyle(NocturnalPalette.fgSecondary)

            Text("Nocturnal")
                .font(.headline)
                .foregroundStyle(NocturnalPalette.fgPrimary)

            Spacer(minLength: 4)

            Text(model.isSocketRunning ? "Live" : "Idle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(NocturnalPalette.bgHighlight, in: Capsule())
                .accessibilityLabel(model.isSocketRunning ? "Socket live" : "Socket idle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                title: "Sessions",
                value: "\(model.snapshot.sessions.count) total · \(liveCount) live"
            )
            statusRow(
                title: "Attention",
                value: model.attentionCount == 0
                    ? "None"
                    : "\(model.attentionCount) need you",
                valueColor: model.attentionCount > 0
                    ? NocturnalPalette.accentAttention
                    : NocturnalPalette.fgSecondary
            )
            if model.settings.showFloatingPill {
                statusRow(
                    title: "Notch",
                    value: model.isOverlayExpanded ? "Expanded" : "Compact"
                )
            } else {
                statusRow(title: "Notch", value: "Hidden")
            }

            Text(model.statusMessage)
                .font(.caption2)
                .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Status: \(model.statusMessage)")
                .animation(
                    NocturnalMotion.standard(reduceMotion: reduceMotion),
                    value: model.statusMessage
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.settings.showFloatingPill {
                menuButton(
                    title: model.isOverlayExpanded ? "Collapse notch panel" : "Show sessions (notch)",
                    systemImage: model.isOverlayExpanded ? "chevron.up" : "rectangle.topthird.inset.filled"
                ) {
                    model.setOverlayExpanded(!model.isOverlayExpanded)
                }
                .help("Session list lives on the notch — expand it here or click the island.")
            }

            menuButton(title: "Copy setup command", systemImage: "terminal") {
                model.copySetupCommand()
            }

            menuButton(title: "Settings…", systemImage: "gearshape") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Nocturnal") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(NocturnalPalette.fgSecondary)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit Nocturnal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func statusRow(
        title: String,
        value: String,
        valueColor: Color = NocturnalPalette.fgSecondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(NocturnalPalette.fgPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private func menuButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
