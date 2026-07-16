import Foundation

/// What the agent is doing right now (or just finished), for live UI surfaces.
public enum SessionActivityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case turn
    case tool
    case approval
    case question
    case notification
    case session
    case unknown
}

/// Coarse integration family for monochrome chips (not brand colors).
public enum ActivityIntegration: String, Codable, Sendable, CaseIterable, Hashable {
    case shell
    case filesystem
    case git
    case github
    case web
    case mcp
    case edit
    case read
    case unknown

    public var chipLabel: String {
        switch self {
        case .shell: return "bash"
        case .filesystem: return "fs"
        case .git: return "git"
        case .github: return "github"
        case .web: return "web"
        case .mcp: return "mcp"
        case .edit: return "edit"
        case .read: return "read"
        case .unknown: return "tool"
        }
    }
}

public enum ActivityOutcome: String, Codable, Sendable, CaseIterable, Hashable {
    case success
    case failure
    case unknown
}

/// One live or recent activity line derived from hook events / local log tails.
public struct SessionActivity: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: SessionActivityKind
    public var label: String
    public var detail: String?
    public var eventType: String
    public var startedAt: Date
    public var endedAt: Date?
    public var toolName: String?
    public var primaryPath: String?
    public var command: String?
    public var integration: ActivityIntegration?
    public var outcome: ActivityOutcome?

    public init(
        id: UUID = UUID(),
        kind: SessionActivityKind,
        label: String,
        detail: String? = nil,
        eventType: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        toolName: String? = nil,
        primaryPath: String? = nil,
        command: String? = nil,
        integration: ActivityIntegration? = nil,
        outcome: ActivityOutcome? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.eventType = eventType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.toolName = toolName
        self.primaryPath = primaryPath
        self.command = command
        self.integration = integration
        self.outcome = outcome
    }

    public var isActive: Bool { endedAt == nil }

    public var displayLine: String {
        // Prefer humanized titles for tools so UI stays consistent.
        if kind == .tool || kind == .approval {
            return humanizedTitle
        }
        if let command, !command.isEmpty {
            let tool = (toolName ?? label).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tool.isEmpty, command.caseInsensitiveCompare(tool) != .orderedSame {
                return "\(tool) · \(command)"
            }
            return command
        }
        if let path = primaryPath, !path.isEmpty {
            let tool = (toolName ?? label).trimmingCharacters(in: .whitespacesAndNewlines)
            let short = (path as NSString).lastPathComponent
            if !tool.isEmpty { return "\(tool) · \(short)" }
            return short
        }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDetail.isEmpty {
            if trimmedDetail.caseInsensitiveCompare(label) == .orderedSame {
                return label
            }
            return "\(label) · \(trimmedDetail)"
        }
        return label
    }

    /// Human notch/row title: `read Foo.swift`, `write Bar.swift`, `ran git status -sb`.
    public var humanizedTitle: String {
        let tool = (toolName ?? label).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = tool.lowercased()
        let file = primaryPath.map { ($0 as NSString).lastPathComponent }
        let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let det = detail?.trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.contains("bash") || lower.contains("shell") || lower == "terminal"
            || integration == .shell
        {
            if let cmd, !cmd.isEmpty {
                return "ran \(Self.compactCommand(cmd))"
            }
            if let det, !det.isEmpty, !det.lowercased().hasPrefix("finished") {
                return "ran \(Self.compactCommand(det))"
            }
            return "ran shell"
        }

        if lower == "read" || lower.hasPrefix("read_") || lower.contains("read_file")
            || integration == .read
        {
            if let file, !file.isEmpty { return "read \(file)" }
            if let det, !det.isEmpty { return "read \(Self.compactPathish(det))" }
            return "read"
        }

        if lower.contains("write") || lower == "edit" || lower.contains("apply_patch")
            || integration == .edit
        {
            let verb = lower.contains("write") ? "write" : "edit"
            if let file, !file.isEmpty { return "\(verb) \(file)" }
            if let det, !det.isEmpty { return "\(verb) \(Self.compactPathish(det))" }
            return verb
        }

        if lower.contains("git") || integration == .git {
            if let cmd, !cmd.isEmpty { return "ran \(Self.compactCommand(cmd))" }
            return tool
        }

        if let cmd, !cmd.isEmpty, cmd.caseInsensitiveCompare(tool) != .orderedSame {
            return "\(tool) · \(Self.compactCommand(cmd))"
        }
        if let file, !file.isEmpty {
            return "\(tool) · \(file)"
        }
        if let det, !det.isEmpty, det.caseInsensitiveCompare(tool) != .orderedSame {
            return "\(tool) · \(Self.compactCommand(det))"
        }
        return tool
    }

    private static func compactCommand(_ raw: String, limit: Int = 48) -> String {
        let one = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard one.count > limit else { return one }
        let idx = one.index(one.startIndex, offsetBy: limit - 1)
        return String(one[..<idx]) + "…"
    }

    private static func compactPathish(_ raw: String) -> String {
        if raw.contains("/") {
            return (raw as NSString).lastPathComponent
        }
        return compactCommand(raw, limit: 40)
    }

    public var pillLine: String {
        if let command, !command.isEmpty { return command }
        if let path = primaryPath, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDetail.isEmpty { return trimmedDetail }
        return label
    }

    public var verbToken: String {
        if let toolName, !toolName.isEmpty { return toolName }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.rawValue : trimmed
    }

    public var durationDescription: String? {
        if let endedAt {
            return Self.formatDuration(seconds: max(0, Int(endedAt.timeIntervalSince(startedAt))))
        }
        return Self.formatDuration(seconds: max(0, Int(Date().timeIntervalSince(startedAt))))
    }

    private static func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours)h" }
        return "\(hours)h \(rem)m"
    }
}

public enum SessionActivityPolicy: Sendable {
    public static let maxRecent: Int = 24

    public static func endCurrent(on session: inout Session, at date: Date) {
        guard var current = session.currentActivity else { return }
        if current.endedAt == nil {
            current.endedAt = date
        }
        session.recentActivities.insert(current, at: 0)
        if session.recentActivities.count > maxRecent {
            session.recentActivities = Array(session.recentActivities.prefix(maxRecent))
        }
        session.currentActivity = nil
    }

    public static func setCurrent(_ activity: SessionActivity, on session: inout Session) {
        if let existing = session.currentActivity, existing.isActive {
            if existing.kind == activity.kind,
               existing.label == activity.label,
               existing.eventType == activity.eventType
            {
                var updated = existing
                updated.detail = activity.detail ?? existing.detail
                updated.toolName = activity.toolName ?? existing.toolName
                updated.primaryPath = activity.primaryPath ?? existing.primaryPath
                updated.command = activity.command ?? existing.command
                updated.integration = activity.integration ?? existing.integration
                updated.outcome = activity.outcome ?? existing.outcome
                session.currentActivity = updated
                return
            }
            endCurrent(on: &session, at: activity.startedAt)
        }
        session.currentActivity = activity
    }

    public static func clearCurrent(on session: inout Session) {
        session.currentActivity = nil
    }
}
