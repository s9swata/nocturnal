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
    private var hasAnySessions: Bool { !model.snapshot.sessions.isEmpty }

    var body: some View {
        Group {
            if !hasAnySessions {
                EmptySessionsView(model: model, style: style)
            } else if sessions.isEmpty {
                QuietSessionsHiddenView(model: model, style: style)
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

    private var attentionApproval: (Session, ApprovalRequest)? {
        // Prefer selected, else first attention approval in visible list.
        if let selected = model.selectedSession, let approval = selected.pendingApproval {
            return (selected, approval)
        }
        for session in sessions {
            if let approval = session.pendingApproval {
                return (session, approval)
            }
        }
        return nil
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            if style == .overlay, let pair = attentionApproval {
                ApprovalRailView(session: pair.0, request: pair.1, model: model)
                Divider().overlay(NocturnalPalette.borderSubtle.opacity(0.5))
            }

            if model.recoveryStubCount > 0, !model.showQuietSessions {
                quietBanner
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sessions) { session in
                        SessionRowView(
                            session: session,
                            isSelected: model.selectedSessionID == session.id,
                            style: style,
                            model: model
                        )
                        .id(session.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Session list, \(sessions.count) sessions")
            .accessibilityHint("Expand a row to see last signal and timeline. Up and Down change selection. A approves, D denies.")
        }
        .background(listBackground)
    }

    private var quietBanner: some View {
        HStack(spacing: 8) {
            Text("\(model.recoveryStubCount) recovered · hidden")
                .font(.caption2)
                .foregroundStyle(NocturnalPalette.fgSecondary)
            Spacer(minLength: 4)
            Button(model.showQuietSessions ? "Hide quiet" : "Show quiet") {
                model.showQuietSessions.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NocturnalPalette.fgSecondary)
        }
        .padding(.horizontal, NocturnalLayout.contentPadding)
        .padding(.vertical, 6)
        .background(NocturnalPalette.bgElevated.opacity(0.4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.recoveryStubCount) recovered sessions hidden")
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

// MARK: - Quiet-only (all recovered stubs hidden)

struct QuietSessionsHiddenView: View {
    @Bindable var model: AppModel
    var style: SessionPanelStyle

    var body: some View {
        VStack(spacing: 12) {
            Text("No live sessions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NocturnalPalette.fgPrimary)
            Text("\(model.recoveryStubCount) recovered from disk are hidden so the list stays useful.")
                .font(.caption)
                .foregroundStyle(NocturnalPalette.fgSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: style == .menuBar ? 260 : 320)
            Button("Show recovered sessions") {
                model.showQuietSessions = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NocturnalLayout.contentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No live sessions. \(model.recoveryStubCount) recovered hidden.")
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
                .accessibilityHint("Copies setup command to the clipboard")
                // Expose the actual command as value so VO/compact menu bar still
                // discover it without painting a second monospaced line in compact UI.
                .accessibilityValue(model.setupInstallCommand)
                .help(model.setupInstallCommand)

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
                    .accessibilityLabel("Setup command")
                    .accessibilityValue(model.setupInstallCommand)
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
