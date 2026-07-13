import SwiftUI
import NocturnalCore

enum SessionPanelStyle {
    case menuBar
    case overlay
    case window
}

/// Expandable session list with stable identity, attention sorting, and actions.
struct SessionPanelView: View {
    @Bindable var model: AppModel
    var style: SessionPanelStyle = .menuBar

    private var sessions: [Session] { model.visibleSessions }

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptySessionsView(model: model, style: style)
            } else {
                sessionList
            }
        }
        .sheet(item: approvalBinding) { session in
            if let approval = session.pendingApproval {
                ApprovalSheet(session: session, request: approval, model: model)
            }
        }
        .sheet(item: questionBinding) { session in
            if let prompt = session.pendingQuestion {
                QuestionSheet(session: session, prompt: prompt, model: model)
            }
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionRowView(
                        session: session,
                        isSelected: model.selectedSessionID == session.id,
                        style: style,
                        model: model
                    )
                    .id(session.id)

                    if session.id != sessions.last?.id {
                        Divider()
                            .overlay(NocturnalPalette.borderSubtle.opacity(0.45))
                            .padding(.leading, NocturnalLayout.contentPadding)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(listBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session list, \(sessions.count) sessions")
    }

    @ViewBuilder
    private var listBackground: some View {
        switch style {
        case .overlay:
            NocturnalPalette.bgBase
        case .menuBar, .window:
            Color.clear
        }
    }

    private var approvalBinding: Binding<Session?> {
        Binding(
            get: { model.approvalSheetSession },
            set: { newValue in
                model.approvalSheetSessionID = newValue?.id
            }
        )
    }

    private var questionBinding: Binding<Session?> {
        Binding(
            get: { model.questionSheetSession },
            set: { newValue in
                model.questionSheetSessionID = newValue?.id
            }
        )
    }
}

// MARK: - Empty state

/// First-run / no-session surface — owl mark, concise hook copy, working actions.
struct EmptySessionsView: View {
    @Bindable var model: AppModel
    var style: SessionPanelStyle
    @Environment(\.openSettings) private var openSettings

    private var isCompact: Bool {
        style == .menuBar
    }

    var body: some View {
        VStack(spacing: isCompact ? 10 : 14) {
            BrandOwlMark(size: isCompact ? 28 : 40)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .opacity(0.9)

            Text("No sessions yet")
                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(NocturnalPalette.fgPrimary)

            Text(emptyDescription)
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: isCompact ? 260 : 360)

            VStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: isCompact ? nil : 200)
                }
                .buttonStyle(.bordered)
                .controlSize(isCompact ? .small : .regular)
                .accessibilityLabel("Open settings")
                .accessibilityHint("Shows hook setup and local paths")

                Button {
                    model.copySetupCommand()
                } label: {
                    Text("Copy setup command")
                        .frame(maxWidth: isCompact ? nil : 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(NocturnalPalette.fgPrimary)
                .foregroundStyle(NocturnalPalette.bgBase)
                .controlSize(isCompact ? .small : .regular)
                .accessibilityLabel("Copy setup command")
                .accessibilityHint(model.setupInstallCommand)

                if !isCompact {
                    Button {
                        model.revealSetupHelper()
                    } label: {
                        Text("Reveal nocturnal-setup")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .accessibilityLabel("Reveal nocturnal-setup in Finder")
                }
            }
            .padding(.top, 2)

            if !isCompact {
                Text(model.setupInstallCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.85))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .accessibilityLabel("Setup command: \(model.setupInstallCommand)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NocturnalLayout.contentPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No sessions. \(emptyDescription)")
    }

    private var emptyDescription: String {
        "Codex and Claude sessions appear here after hooks are connected."
    }
}
