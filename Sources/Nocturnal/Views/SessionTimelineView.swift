import SwiftUI
import NocturnalCore

/// Last signal + tool timeline. Shown **inline under a session row** when expanded.
struct SessionTimelineView: View {
    let session: Session
    /// Tighter chrome when nested under a row.
    var compact: Bool = false
    /// Combined app + system reduce-motion preference from the parent row/model.
    var prefersReducedMotion: Bool = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var items: [SessionActivity] {
        SessionPresentation.timelineItems(for: session)
    }

    private var lastLine: String? {
        SessionPresentation.lastActivityLine(for: session)
    }

    private var metricsLine: String? {
        var parts: [String] = []
        if let t = session.stats.tokensMetaLine { parts.append(t) }
        if let d = session.stats.diffMetaLine { parts.append(d) }
        if parts.isEmpty, let detail = session.detailSnapshot {
            var s = SessionStats.empty
            s.mergeMetrics(
                tokensIn: detail.tokensIn,
                tokensOut: detail.tokensOut,
                diffAdded: detail.diffAdded,
                diffRemoved: detail.diffRemoved
            )
            if let t = s.tokensMetaLine { parts.append(t) }
            if let d = s.diffMetaLine { parts.append(d) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if session.isRecoveryStub, lastLine == nil, items.isEmpty {
                Text("Recovered from disk — no live activity.")
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary)
            } else {
                content
            }
        }
        .padding(.horizontal, compact ? 10 : NocturnalLayout.contentPadding)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NocturnalPalette.bgElevated.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(NocturnalPalette.borderSubtle.opacity(0.5), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detail for \(session.title)")
    }

    @ViewBuilder
    private var content: some View {
        if let metricsLine {
            Text(metricsLine)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(NocturnalPalette.fgSecondary)
        }

        if let lastLine {
            VStack(alignment: .leading, spacing: 3) {
                Label("Last signal", systemImage: "text.quote")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.9))
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.hierarchical)

                Text(lastLine)
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgPrimary)
                    .lineLimit(compact ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last signal: \(lastLine)")
        }

        if items.isEmpty {
            if lastLine == nil {
                Text("No tool activity yet")
                    .font(.caption)
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.85))
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Timeline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.9))
                    .textCase(.uppercase)

                ForEach(items) { activity in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if activity.isActive {
                            DotmSquareLoader(
                                style: .square2,
                                size: 14,
                                dotSize: 2,
                                color: NocturnalPalette.accentSuccess,
                                speed: 1.05,
                                animate: !prefersReducedMotion && !systemReduceMotion,
                                rotateByTime: true,
                                styleInterval: 6,
                                styleOffset: DotmSquareLoader.styleOffset(
                                    forSeed: activity.id.uuidString
                                )
                            )
                        } else {
                            AnimatedStatusSymbol(
                                systemName: SessionPresentation.activitySymbolName(for: activity),
                                color: NocturnalPalette.fgSecondary,
                                size: 11,
                                animate: false,
                                mode: .idle
                            )
                        }

                        ActivityLineLabel(
                            line: activity.humanizedLine,
                            font: .caption,
                            verbColor: activity.isActive
                                ? NocturnalPalette.fgPrimary
                                : NocturnalPalette.fgPrimary.opacity(0.92),
                            detailColor: NocturnalPalette.fgSecondary
                        )
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let duration = activity.durationDescription {
                            Text(duration)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(NocturnalPalette.fgSecondary.opacity(0.85))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        activity.durationDescription.map {
                            "\(activity.displayLine), \($0)"
                        } ?? activity.displayLine
                    )
                }
            }
        }
    }
}
