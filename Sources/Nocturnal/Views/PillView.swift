import SwiftUI
import NocturnalCore

/// Dynamic Island–style compact notch extension.
///
/// **Chrome:** Nocturnal black top-flush drip (not glass).  
/// **Dynamics:** mode-driven width/height (quiet → live → attention).  
/// **Attention:** inline Deny / Allow so OpenCode (and other agents) can be
/// decided without opening the full panel.
struct PillView: View {
    @Bindable var model: AppModel
    var reduceMotion: Bool

    @State private var markPulse = false
    @State private var decisionBusy = false

    private var content: PillIslandContent {
        PillIslandPresentation.content(
            sessions: model.snapshot.sessions,
            socketRunning: model.isSocketRunning
        )
    }

    private var islandSize: CGSize {
        OverlayGeometry.islandSize(for: content.mode)
    }

    private var isAttention: Bool { content.mode == .attention }
    private var isLive: Bool {
        content.mode == .liveCompact
            || content.mode == .liveExpanded
            || content.mode == .attention
    }

    /// Pending approval on the primary live session (for inline chips).
    private var pendingApproval: ApprovalRequest? {
        model.primaryLiveSession?.pendingApproval
    }

    var body: some View {
        Group {
            if isAttention, pendingApproval != nil {
                attentionIsland
            } else {
                tappableIsland
            }
        }
        .frame(width: islandSize.width, height: islandSize.height)
        .animation(NocturnalMotion.standard(reduceMotion: reduceMotion), value: content.mode)
        .compositingGroup()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilitySummary)
        .onAppear { updatePulse() }
        .onChange(of: content.mode) { _, _ in
            updatePulse()
            model.refreshPillIslandLayout()
        }
        .onChange(of: content.primary) { _, _ in
            model.refreshPillIslandLayout()
        }
        .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    // MARK: - Islands

    /// Default: whole drip opens the session panel.
    private var tappableIsland: some View {
        Button {
            model.setOverlayExpanded(true)
        } label: {
            islandChrome {
                islandBody(showDecisionChips: false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the session panel")
    }

    /// Attention: copy opens panel; Deny/Allow are separate controls.
    private var attentionIsland: some View {
        islandChrome {
            islandBody(showDecisionChips: true)
        }
        .accessibilityHint("Approve or deny from the notch, or open the panel for details")
    }

    private func islandChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background { notchChrome }
            .clipShape(notchShape)
    }

    // MARK: - Body

    @ViewBuilder
    private func islandBody(showDecisionChips: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setOverlayExpanded(true)
            } label: {
                HStack(spacing: 10) {
                    leadingMark
                    centerColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(decisionBusy)

            if showDecisionChips, let request = pendingApproval {
                decisionChips(for: request)
            } else if !content.trailingSources.isEmpty || content.liveCount > 1 {
                trailingStrip
            }
        }
    }

    @ViewBuilder
    private func decisionChips(for request: ApprovalRequest) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await decide(request, approved: false) }
            } label: {
                Text("Deny")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.accentDanger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .strokeBorder(NocturnalPalette.accentDanger.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(decisionBusy)
            .accessibilityLabel("Deny permission")
            .keyboardShortcut("d", modifiers: [])

            Button {
                Task { await decide(request, approved: true) }
            } label: {
                Text("Allow")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.bgBase)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(NocturnalPalette.fgPrimary.opacity(0.92))
                    )
            }
            .buttonStyle(.plain)
            .disabled(decisionBusy)
            .accessibilityLabel("Allow permission")
            .keyboardShortcut("a", modifiers: [])
        }
    }

    private func decide(_ request: ApprovalRequest, approved: Bool) async {
        guard !decisionBusy else { return }
        decisionBusy = true
        defer { decisionBusy = false }
        _ = await model.approve(request, approved: approved, scope: .once)
        model.refreshPillIslandLayout()
    }

    @ViewBuilder
    private var leadingMark: some View {
        ZStack {
            if isAttention {
                Circle()
                    .strokeBorder(NocturnalPalette.accentAttention.opacity(0.85), lineWidth: 1.5)
                    .frame(width: markSize + 8, height: markSize + 8)
                    .opacity(markPulse && !reduceMotion ? 0.45 : 1)
                    .scaleEffect(markPulse && !reduceMotion ? 1.08 : 1)
            }
            if let source = content.source {
                AgentBrandMark(
                    source: source,
                    size: markSize,
                    color: markColor
                )
                .opacity(isLive ? 1 : 0.88)
            } else {
                BrandOwlMark(size: markSize)
                    .foregroundStyle(markColor)
                    .opacity(content.mode == .listening ? (markPulse ? 0.75 : 1) : 0.9)
            }
        }
        .frame(width: markSize + (isAttention ? 8 : 0), height: markSize + (isAttention ? 8 : 0))
    }

    @ViewBuilder
    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: content.mode == .liveExpanded || content.mode == .attention ? 2 : 0) {
            Text(content.primary)
                .font(.caption.weight(isAttention ? .semibold : .medium))
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)

            if let secondary = content.secondary,
               !secondary.isEmpty,
               content.mode == .liveExpanded || content.mode == .attention
            {
                Text(secondary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var trailingStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(content.trailingSources.enumerated()), id: \.offset) { index, source in
                AgentBrandMark(
                    source: source,
                    size: 9,
                    color: index == 0 && isAttention
                        ? NocturnalPalette.accentAttention
                        : NocturnalPalette.fgSecondary.opacity(0.9)
                )
                .opacity(0.95)
            }
            if content.liveCount > content.trailingSources.count {
                Text("+\(content.liveCount - content.trailingSources.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
            }
        }
        .accessibilityLabel("\(content.liveCount) live sessions")
    }

    // MARK: - Style

    private var markSize: CGFloat {
        switch content.mode {
        case .quiet, .listening: return 12
        case .liveCompact: return 13
        case .liveExpanded, .attention: return 14
        }
    }

    private var horizontalPadding: CGFloat {
        switch content.mode {
        case .quiet, .listening: return 14
        case .liveCompact: return 15
        case .liveExpanded, .attention: return 14
        }
    }

    private var topPadding: CGFloat {
        switch content.mode {
        case .quiet: return 10
        case .listening, .liveCompact: return 11
        case .liveExpanded, .attention: return 10
        }
    }

    private var bottomPadding: CGFloat {
        switch content.mode {
        case .quiet: return 8
        case .listening: return 9
        case .liveCompact: return 10
        case .liveExpanded, .attention: return 11
        }
    }

    private var markColor: Color {
        if isAttention { return NocturnalPalette.accentAttention }
        if isLive { return NocturnalPalette.fgPrimary }
        return NocturnalPalette.fgSecondary
    }

    private var primaryColor: Color {
        if isAttention { return NocturnalPalette.accentAttention }
        if content.mode == .quiet || content.mode == .listening {
            return NocturnalPalette.fgSecondary
        }
        return NocturnalPalette.fgPrimary
    }

    private var bottomRadius: CGFloat {
        switch content.mode {
        case .quiet, .listening: return 16
        case .liveCompact: return 18
        case .liveExpanded, .attention: return 20
        }
    }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var notchChrome: some View {
        notchShape
            .fill(NocturnalPalette.notchFill)
            .overlay {
                notchShape
                    .strokeBorder(
                        isAttention
                            ? NocturnalPalette.accentAttention.opacity(0.35)
                            : NocturnalPalette.borderSubtle.opacity(0.45),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.55), radius: isLive ? 14 : 10, x: 0, y: 7)
    }

    private func updatePulse() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { markPulse = false }
        guard !reduceMotion else { return }
        if isAttention || content.mode == .listening {
            withAnimation(NocturnalMotion.attentionBreath) {
                markPulse = true
            }
        }
    }
}
