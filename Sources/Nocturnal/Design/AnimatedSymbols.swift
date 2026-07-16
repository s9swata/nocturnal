import SwiftUI
import NocturnalCore

/// Animated SF Symbols for live status (built into the system — no third-party pack).
///
/// **Source:** Apple SF Symbols app + `symbolEffect` APIs (macOS 14+ / SF Symbols 5+).
/// Browse symbols: open **SF Symbols** app from [developer.apple.com/sf-symbols](https://developer.apple.com/sf-symbols/)
/// or Xcode → Editor → Add Symbol Effect.
///
/// Effects used here (monochrome-safe):
/// - `.pulse` — attention / waiting
/// - `.variableColor.iterative` / `.variableColor` — running work
/// - `.bounce` — one-shot on appear for state changes (optional)
///
/// Always respect Reduce Motion: pass `animate: false` and effects become static.
enum AnimatedSymbols {
    /// SF Symbol name for session / activity state.
    static func statusSymbol(for session: Session) -> String {
        if session.state.needsAttention {
            if session.pendingApproval != nil || session.state == .waitingForApproval {
                return "hand.raised.fill"
            }
            if session.pendingQuestion != nil || session.state == .waitingForInput {
                return "questionmark.circle.fill"
            }
            if session.state == .failed {
                return "exclamationmark.triangle.fill"
            }
        }
        if let activity = session.currentActivity, activity.isActive {
            return SessionPresentation.activitySymbolName(for: activity)
        }
        switch session.state {
        case .running:
            return "ellipsis.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .cancelled:
            return "xmark.circle"
        case .idle:
            return session.isRecoveryStub ? "archivebox" : "moon.zzz"
        case .unknown:
            return "circle.dashed"
        default:
            return "circle.fill"
        }
    }

    static func pillSymbol(for session: Session?, socketRunning: Bool) -> String {
        guard let session else {
            return socketRunning ? "dot.radiowaves.left.and.right" : "moon.zzz"
        }
        return statusSymbol(for: session)
    }

    static func statusColor(for session: Session) -> Color {
        if session.state.needsAttention {
            return SessionPresentation.badgeColor(session.state)
        }
        if session.state == .running || session.currentActivity?.isActive == true {
            return NocturnalPalette.accentSuccess
        }
        if session.state == .completed {
            return NocturnalPalette.accentSuccess.opacity(0.85)
        }
        return NocturnalPalette.fgSecondary
    }
}

/// Status SF Symbol with optional system animation.
struct AnimatedStatusSymbol: View {
    let systemName: String
    var color: Color = NocturnalPalette.fgSecondary
    var size: CGFloat = 12
    /// When false, no symbol effects (Reduce Motion / quiet).
    var animate: Bool = true
    /// Pulse for attention; variable color for running.
    var mode: Mode = .idle

    enum Mode {
        case idle
        case running
        case attention
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
            .modifier(SymbolAnimationModifier(mode: mode, animate: animate))
            .accessibilityHidden(true)
    }
}

private struct SymbolAnimationModifier: ViewModifier {
    var mode: AnimatedStatusSymbol.Mode
    var animate: Bool

    func body(content: Content) -> some View {
        if !animate {
            content
        } else {
            switch mode {
            case .idle:
                content
            case .running:
                content
                    .symbolEffect(.variableColor.iterative, options: .repeating, value: true)
            case .attention:
                content
                    .symbolEffect(.pulse, options: .repeating, value: true)
            }
        }
    }
}

/// Chevron that rotates when a row expands (last signal / timeline).
struct ExpandChevron: View {
    var isExpanded: Bool
    var reduceMotion: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NocturnalPalette.fgSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}
