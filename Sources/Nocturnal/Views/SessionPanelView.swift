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

struct EmptySessionsView: View {
    @Bindable var model: AppModel
    var style: SessionPanelStyle

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .accessibilityHidden(true)

            Text("No sessions yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NocturnalPalette.fgPrimary)

            Text(emptyDescription)
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.demoMode {
                Button("Load demo sessions") {
                    Task { await model.reloadDemoFixtures() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Load demo sessions")
            } else {
                Button("Try demo mode") {
                    Task { await model.toggleDemoMode() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Enable demo mode")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NocturnalLayout.contentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sessions. \(emptyDescription)")
    }

    private var emptyDescription: String {
        if model.settings.demoMode {
            return "Demo fixtures can be reloaded anytime from the menu."
        }
        return "Sessions appear when Codex or Claude hooks fire. Install hooks with nocturnal-setup, or try demo mode."
    }
}
