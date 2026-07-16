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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                PillView(model: model, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .animation(NocturnalMotion.expand(reduceMotion: reduceMotion), value: model.isOverlayExpanded)
    }
}

// MARK: - Expanded panel chrome

private struct ExpandedOverlayPanel: View {
    @Bindable var model: AppModel
    var reduceMotion: Bool
    @FocusState private var listFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private var totalCount: Int { model.snapshot.sessions.count }
    private var liveCount: Int {
        model.snapshot.sessions.filter {
            $0.state.needsAttention || $0.state == .running || $0.currentActivity?.isActive == true
        }.count
    }

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
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: NocturnalLayout.cornerRadiusPanel,
                bottomTrailingRadius: NocturnalLayout.cornerRadiusPanel,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(NocturnalPalette.bgBase)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: NocturnalLayout.cornerRadiusPanel,
                    bottomTrailingRadius: NocturnalLayout.cornerRadiusPanel,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.7), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: NocturnalLayout.cornerRadiusPanel,
                bottomTrailingRadius: NocturnalLayout.cornerRadiusPanel,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
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
        .sheet(isPresented: $model.isFoldersSheetPresented) {
            FoldersSheet(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nocturnal session panel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BrandOwlMark(size: 15)
                    .foregroundStyle(NocturnalPalette.fgSecondary)

                Text("Sessions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgPrimary)

                Text(headerCountLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(NocturnalPalette.bgHighlight)
                    )
                    .accessibilityLabel(headerCountA11y)

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
                    model.isFoldersSheetPresented = true
                } label: {
                    Image(systemName: "folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Local folders")
                .accessibilityLabel("Open folders")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NocturnalPalette.fgSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Open settings")

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

            Text(model.liveActivityLine)
                .font(.caption)
                .foregroundStyle(
                    model.attentionCount > 0
                        ? NocturnalPalette.accentAttention
                        : NocturnalPalette.fgSecondary
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Live: \(model.liveActivityLine)")
        }
        .padding(.horizontal, NocturnalLayout.contentPadding)
        .padding(.vertical, 10)
    }

    private var headerCountLabel: String {
        if model.recoveryStubCount > 0, !model.showQuietSessions {
            return "\(model.visibleSessions.count)"
        }
        return "\(totalCount)"
    }

    private var headerCountA11y: String {
        if model.recoveryStubCount > 0, !model.showQuietSessions {
            return "\(model.visibleSessions.count) live sessions, \(model.recoveryStubCount) recovered hidden"
        }
        return "\(totalCount) sessions total"
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
