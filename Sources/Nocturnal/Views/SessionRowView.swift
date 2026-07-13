import AppKit
import SwiftUI
import NocturnalCore

struct SessionRowView: View {
    let session: Session
    var isSelected: Bool
    var style: SessionPanelStyle
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                StateBadge(state: session.state)
            }

            if !session.summary.isEmpty {
                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(session.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.9))

                if let cwd = session.workingDirectory {
                    Text(shortPath(cwd))
                        .font(.caption2.monospaced())
                        .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                actionButtons
            }
        }
        .padding(.horizontal, NocturnalLayout.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? NocturnalPalette.bgHighlight.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectSession(session.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionPresentation.accessibilityLabel(for: session))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Jump back") {
            Task { await model.jumpBack(to: session) }
        }
        .modifier(ApprovalAccessibilityActions(session: session, model: model))
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
            .help("Return to the agent surface")
            .accessibilityLabel("Jump back to \(session.title)")
        }

        if let approval = session.pendingApproval {
            // Bare A/D shortcuts live on the overlay / app command layer only —
            // per-row shortcuts would collide when multiple rows are visible.
            Button("Deny") {
                Task { await model.approve(approval, approved: false) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(NocturnalPalette.accentDanger)
            .accessibilityLabel("Deny \(approval.toolName)")

            Button("Approve") {
                Task { await model.approve(approval, approved: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(NocturnalPalette.accentAttention)
            .font(.caption)
            .accessibilityLabel("Approve \(approval.toolName)")
            .help(approval.summary)
        } else if let prompt = session.pendingQuestion {
            Button("Answer…") {
                model.presentQuestion(for: session)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .accessibilityLabel("Answer question for \(session.title)")
            .help(prompt.prompt)
        } else if session.state == .waitingForApproval {
            Button("Review…") {
                model.presentApproval(for: session)
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

// MARK: - State badge

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

// MARK: - Accessibility action helper

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
