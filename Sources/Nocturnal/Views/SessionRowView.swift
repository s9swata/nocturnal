import AppKit
import SwiftUI
import NocturnalCore

struct SessionRowView: View {
    let session: Session
    var isSelected: Bool
    var style: SessionPanelStyle
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        model.prefersReducedMotion || systemReduceMotion
    }

    private var subtitle: String {
        SessionPresentation.rowSubtitle(for: session)
    }

    private var metaLine: String? {
        SessionPresentation.rowMetaLine(for: session)
    }

    private var jumpBadge: String? {
        SessionPresentation.jumpSurfaceBadge(for: session)
    }

    private var isLive: Bool {
        session.state == .running || session.currentActivity?.isActive == true
    }

    private var isAttention: Bool {
        session.state.needsAttention
    }

    private var isExpanded: Bool {
        model.isSessionDetailExpanded(session.id)
    }

    private var chips: [ActivityIntegration] {
        SessionPresentation.integrationChips(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .top, spacing: 8) {
                Button {
                    model.toggleSessionDetail(session.id)
                } label: {
                    ExpandChevron(isExpanded: isExpanded, reduceMotion: reduceMotion)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse session detail" : "Expand session detail")
                .accessibilityHint("Shows last signal and timeline")

                AgentBrandMark(
                    source: session.source,
                    size: 14,
                    color: AnimatedSymbols.statusColor(for: session)
                )
                .padding(.top, 2)
                .accessibilityLabel("\(session.source.displayName) session")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NocturnalPalette.fgPrimary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectSession(session.id) }

                        Spacer(minLength: 4)

                        StateBadge(state: session.state)
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(
                            isAttention
                                ? NocturnalPalette.accentAttention.opacity(0.95)
                                : NocturnalPalette.fgSecondary
                        )
                        .lineLimit(1)

                    if let metaLine {
                        Text(metaLine)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.8))
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        sourceChip
                        if let jumpBadge {
                            metaChip(jumpBadge)
                        }
                        if let cwd = session.workingDirectory {
                            Text(shortPath(cwd))
                                .font(.caption2.monospaced())
                                .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !chips.isEmpty {
                            ForEach(chips.prefix(3), id: \.self) { chip in
                                Text(chip.chipLabel)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.85))
                            }
                        }
                        Spacer(minLength: 4)
                        actionButtons
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, NocturnalLayout.contentPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectSession(session.id)
            }

            // Inline detail (last signal + timeline) under this row only.
            if isExpanded {
                SessionTimelineView(
                    session: session,
                    compact: true,
                    prefersReducedMotion: reduceMotion
                )
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionPresentation.accessibilityLabel(for: session))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Jump back") {
            Task { await model.jumpBack(to: session) }
        }
        .modifier(ApprovalAccessibilityActions(session: session, model: model))
    }

    private var rowBackground: Color {
        if isAttention {
            return NocturnalPalette.accentAttention.opacity(0.1)
        }
        if isSelected || isExpanded {
            return NocturnalPalette.bgHighlight.opacity(0.9)
        }
        return Color.clear
    }

    private var sourceChip: some View {
        HStack(spacing: 4) {
            AgentBrandMark(
                source: session.source,
                size: 10,
                color: NocturnalPalette.fgSecondary.opacity(0.95)
            )
            Text(session.source.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.95))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule(style: .continuous)
                .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
    }

    private func metaChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.monospaced())
            .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(NocturnalPalette.bgHighlight.opacity(0.75))
            )
    }

    @ViewBuilder
    private var actionButtons: some View {
        if session.jumpBack != nil || session.workingDirectory != nil {
            Button("Jump") {
                Task { await model.jumpBack(to: session) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(NocturnalPalette.fgSecondary)
        }

        if let approval = session.pendingApproval {
            Button("Deny") {
                Task { await model.approve(approval, approved: false) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(NocturnalPalette.accentDanger)

            Button("Approve") {
                Task { await model.approve(approval, approved: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(NocturnalPalette.accentAttention)
            .font(.caption)
        } else if session.pendingQuestion != nil {
            Button("Answer…") {
                model.presentQuestion(for: session)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        let parts = path.split(separator: "/")
        if parts.count > 2 {
            return parts.suffix(2).joined(separator: "/")
        }
        return path
    }
}

struct StateBadge: View {
    let state: SessionState

    var body: some View {
        Text(SessionPresentation.badgeTitle(state))
            .font(.caption2.monospaced())
            .foregroundStyle(SessionPresentation.badgeColor(state))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(SessionPresentation.badgeColor(state).opacity(0.14))
            )
            .accessibilityLabel("State: \(SessionPresentation.badgeTitle(state))")
    }
}

private struct ApprovalAccessibilityActions: ViewModifier {
    let session: Session
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        if let approval = session.pendingApproval {
            content
                .accessibilityAction(named: "Approve") {
                    Task { await model.approve(approval, approved: true) }
                }
                .accessibilityAction(named: "Deny") {
                    Task { await model.approve(approval, approved: false) }
                }
        } else if session.pendingQuestion != nil {
            content
                .accessibilityAction(named: "Answer") {
                    model.presentQuestion(for: session)
                }
        } else {
            content
        }
    }
}
