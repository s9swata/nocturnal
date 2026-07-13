import SwiftUI
import NocturnalCore

/// UI-facing presentation helpers for session state (no business mutation).
enum SessionPresentation {
    static func badgeTitle(_ state: SessionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .running: return "Running"
        case .waitingForApproval: return "Approval"
        case .waitingForInput: return "Question"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    static func badgeColor(_ state: SessionState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return NocturnalPalette.accentAttention
        case .failed:
            return NocturnalPalette.accentDanger
        case .completed:
            return NocturnalPalette.accentSuccess
        case .running:
            return NocturnalPalette.fgSecondary
        case .idle, .cancelled, .unknown:
            return NocturnalPalette.fgSecondary.opacity(0.85)
        }
    }

    static func accessibilityLabel(for session: Session) -> String {
        var parts = [
            session.title,
            badgeTitle(session.state),
            session.source.displayName,
        ]
        if !session.summary.isEmpty {
            parts.append(session.summary)
        }
        if session.pendingApproval != nil {
            parts.append("Pending approval")
        }
        if session.pendingQuestion != nil {
            parts.append("Pending question")
        }
        return parts.joined(separator: ", ")
    }

    /// Attention sessions first, then most recently updated.
    static func sortedForDisplay(_ sessions: [Session], limit: Int) -> [Session] {
        let sorted = sessions.sorted { lhs, rhs in
            let lAtt = lhs.state.needsAttention
            let rAtt = rhs.state.needsAttention
            if lAtt != rAtt { return lAtt && !rAtt }
            return lhs.updatedAt > rhs.updatedAt
        }
        return Array(sorted.prefix(max(1, limit)))
    }
}
