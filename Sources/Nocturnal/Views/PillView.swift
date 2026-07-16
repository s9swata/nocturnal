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

    /// Only agents with a real decision transport get Deny/Allow in the notch.
    private var canInlineDecide: Bool {
        guard let session = model.primaryLiveSession else { return false }
        return AgentRegistry.profile(for: session).supportsInlinePermissionDecision
    }

    var body: some View {
        Group {
            if isAttention, pendingApproval != nil, canInlineDecide {
                attentionIsland
            } else {
                tappableIsland
            }
        }
        // Panel owns dimensions (OverlayGeometry); fill the host, never force a
        // larger intrinsic width that clips against a clamped NSPanel frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(NocturnalMotion.standard(reduceMotion: reduceMotion), value: content.mode)
        .compositingGroup()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilitySummary)
        .onAppear {
            updatePulse()
            model.refreshPillIslandLayout()
        }
        .onChange(of: content.mode) { _, _ in
            updatePulse()
            model.refreshPillIslandLayout()
        }
        .onChange(of: content.primary) { _, _ in
            model.refreshPillIslandLayout()
        }
        .onChange(of: pendingApproval?.id) { _, _ in
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                HStack(spacing: 8) {
                    leadingMark
                        .fixedSize()
                    centerColumn
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(decisionBusy)
            .layoutPriority(0)

            if showDecisionChips, canInlineDecide, let request = pendingApproval {
                decisionChips(for: request)
                    .fixedSize()
                    .layoutPriority(1)
            } else if isLive || !trailingLiveSessions.isEmpty {
                // Right side: dynamic matrix loaders (dotm-square-1…5), not agent brand marks.
                trailingStrip
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func decisionChips(for request: ApprovalRequest) -> some View {
        HStack(spacing: 5) {
            Button {
                Task { await decide(request, approved: false) }
            } label: {
                Text("Deny")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.accentDanger)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
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
        // Fixed container so attention ring pulse never paints outside clip.
        // Left stays agent/owl brand; live activity matrix lives on the right strip.
        let ringPad: CGFloat = isAttention ? 6 : 0
        let box = markSize + ringPad * 2
        ZStack {
            if isAttention {
                Circle()
                    .strokeBorder(NocturnalPalette.accentAttention.opacity(0.85), lineWidth: 1.5)
                    .frame(width: markSize + ringPad, height: markSize + ringPad)
                    .opacity(markPulse && !reduceMotion ? 0.4 : 1)
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
        .frame(width: box, height: box)
    }

    @ViewBuilder
    private var centerColumn: some View {
        let primaryLine = content.primaryLine ?? HumanizedActivityLine(verb: content.primary)
        let primaryKey = primaryLine.fullLine
        let showSecondary = content.mode == .liveExpanded || content.mode == .attention
        let secondaryText = (showSecondary ? content.secondary : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryKey = (secondaryText?.isEmpty == false) ? (secondaryText ?? "") : ""

        VStack(alignment: .leading, spacing: showSecondary ? 2 : 0) {
            // Identity-keyed so SwiftUI crossfades when the activity title changes
            // (tool → tool, Running → Idle, Approve…, etc.).
            ActivityLineLabel(
                line: primaryLine,
                font: .caption.weight(isAttention ? .semibold : .medium),
                verbColor: primaryColor,
                detailColor: NocturnalPalette.fgSecondary
            )
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
            .id("pill-primary-\(primaryKey)")
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 2)))

            if let secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                    .id("pill-secondary-\(secondaryKey)")
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(NocturnalMotion.titleCrossfade(reduceMotion: reduceMotion), value: primaryKey)
        .animation(NocturnalMotion.titleCrossfade(reduceMotion: reduceMotion), value: secondaryKey)
        .animation(NocturnalMotion.titleCrossfade(reduceMotion: reduceMotion), value: content.mode)
    }

    /// Live sessions shown as matrix loaders on the right (one per agent family, max 3).
    private var trailingLiveSessions: [Session] {
        let live = model.snapshot.sessions
            .filter(PillIslandPresentation.isIslandLiveSession)
            .sorted { $0.updatedAt > $1.updatedAt }

        var out: [Session] = []
        var seen = Set<AgentSource>()
        for session in live {
            let key = session.source == .unknown
                ? AgentSource(parsing: session.id.rawValue)
                : session.source
            // Prefer unique product sources; fall back to session id uniqueness for unknowns.
            if session.source == .unknown {
                if out.contains(where: { $0.id == session.id }) { continue }
                out.append(session)
            } else if seen.insert(key).inserted {
                out.append(session)
            }
            if out.count >= 3 { break }
        }
        if out.isEmpty, let primary = model.primaryLiveSession, isLive {
            return [primary]
        }
        return out
    }

    @ViewBuilder
    private var trailingStrip: some View {
        let sessions = trailingLiveSessions
        HStack(spacing: 5) {
            ForEach(sessions, id: \.id) { session in
                let active = session.state.needsAttention
                    || session.state == .running
                    || session.currentActivity?.isActive == true
                // Pattern rotates on a wall-clock interval — not per tool/command
                // (commands thrash too fast for a readable loader).
                DotmSquareLoader(
                    style: DotmSquareLoader.style(for: session.source),
                    size: trailingMatrixSize,
                    dotSize: max(1.6, trailingMatrixSize / 6.5),
                    color: session.state.needsAttention
                        ? NocturnalPalette.accentAttention
                        : NocturnalPalette.fgPrimary,
                    speed: active ? 1.1 : 0.85,
                    animate: !reduceMotion && active,
                    staticOpacity: 0.5,
                    rotateByTime: true,
                    styleInterval: 6,
                    styleOffset: DotmSquareLoader.styleOffset(forSeed: session.id.rawValue)
                )
                .accessibilityLabel("\(session.source.displayName) activity")
            }
            if content.liveCount > sessions.count {
                Text("+\(content.liveCount - sessions.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary)
            }
        }
        .accessibilityLabel("\(content.liveCount) live sessions")
    }

    private var trailingMatrixSize: CGFloat {
        switch content.mode {
        case .quiet, .listening: return 11
        case .liveCompact: return 12
        case .liveExpanded, .attention: return 13
        }
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
        case .liveExpanded: return 16
        // ≥ bottom radius so corner clip does not eat the leading mark.
        case .attention: return 18
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
        case .liveExpanded: return 11
        case .attention: return 12
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
