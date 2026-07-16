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
        return humanizedLine.fullLine
    }

    /// Structured verb + detail for two-tone UI ("Ran" white · command grey).
    public var humanizedLine: HumanizedActivityLine {
        HumanizedActivityLine.make(from: self)
    }

    /// Human notch/row title: `Read Foo.swift`, `Write Bar.swift`, `Ran git status -sb`.
    public var humanizedTitle: String {
        humanizedLine.fullLine
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
        humanizedLine.verb
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

/// Verb + optional detail for monochrome two-tone activity copy.
///
/// UI maps ``verb`` to primary (white) and ``detail`` to secondary (grey).
public struct HumanizedActivityLine: Sendable, Equatable, Hashable {
    public var verb: String
    public var detail: String?

    public init(verb: String, detail: String? = nil) {
        self.verb = verb
        self.detail = detail.flatMap { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    public var fullLine: String {
        if let detail {
            return "\(verb) \(detail)"
        }
        return verb
    }

    /// Truncate detail first so the verb stays intact.
    public func truncated(limit: Int) -> HumanizedActivityLine {
        guard limit > 0 else { return HumanizedActivityLine(verb: "…") }
        if fullLine.count <= limit { return self }
        guard let detail else {
            return HumanizedActivityLine(verb: Self.clip(verb, limit: limit))
        }
        let verbBudget = verb.count + 1
        if verbBudget >= limit {
            return HumanizedActivityLine(verb: Self.clip(verb, limit: limit))
        }
        // Honor `limit` strictly — never force a 4-char minimum that overruns.
        let detailLimit = limit - verbBudget
        return HumanizedActivityLine(verb: verb, detail: Self.clip(detail, limit: detailLimit))
    }

    public static func make(from activity: SessionActivity) -> HumanizedActivityLine {
        switch activity.kind {
        case .approval:
            return makeApproval(activity)
        case .question:
            // Freeform prompts may contain `/` (URLs, paths in text) — not filenames.
            return HumanizedActivityLine(
                verb: "Question",
                detail: compactCommand(activity.detail ?? activity.label, limit: 42)
            )
        case .turn:
            let label = activity.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.lowercased().contains("think") || label == "Thinking" {
                return HumanizedActivityLine(verb: activity.isActive ? "Thinking" : "Thought")
            }
            if label.lowercased().contains("prompt") {
                return HumanizedActivityLine(
                    verb: "Prompt",
                    detail: compactPathish(activity.detail, limit: 40)
                )
            }
            if label.lowercased().contains("session") {
                return HumanizedActivityLine(verb: "Session")
            }
            return HumanizedActivityLine(
                verb: prettyToken(label.isEmpty ? "Working" : label),
                detail: compactPathish(activity.detail, limit: 40)
            )
        case .notification:
            return HumanizedActivityLine(
                verb: "Notice",
                detail: compactPathish(activity.detail, limit: 40)
            )
        case .session:
            return HumanizedActivityLine(verb: prettyToken(activity.label.isEmpty ? "Session" : activity.label))
        case .tool, .unknown:
            return makeTool(activity)
        }
    }

    private static func makeApproval(_ activity: SessionActivity) -> HumanizedActivityLine {
        let tool = (activity.toolName ?? activity.label).trimmingCharacters(in: .whitespacesAndNewlines)
        let det = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? activity.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let det, !det.isEmpty {
            return HumanizedActivityLine(verb: "Approve", detail: compactCommand(det, limit: 40))
        }
        if !tool.isEmpty {
            return HumanizedActivityLine(verb: "Approve", detail: prettyToken(tool))
        }
        return HumanizedActivityLine(verb: "Approve")
    }

    private static func makeTool(_ activity: SessionActivity) -> HumanizedActivityLine {
        let rawTool = (activity.toolName ?? activity.label).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = rawTool.lowercased()
        let file = activity.primaryPath.map { ($0 as NSString).lastPathComponent }
        let cmd = activity.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let det = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = activity.isActive
        let integration = activity.integration
            ?? ToolPayloadExtraction.classify(
                toolName: rawTool,
                command: cmd,
                path: activity.primaryPath,
                detail: det
            )

        // Shell / terminal
        if isShell(lower: lower, integration: integration) {
            let body = firstNonEmpty(cmd, det.flatMap { $0.lowercased().hasPrefix("finished") ? nil : $0 })
            if let body {
                return HumanizedActivityLine(
                    verb: active ? "Running" : "Ran",
                    detail: compactCommand(body)
                )
            }
            return HumanizedActivityLine(verb: active ? "Running" : "Ran", detail: "shell")
        }

        // Read
        if isRead(lower: lower, integration: integration) {
            let body = firstNonEmpty(file, compactPathish(det))
            return HumanizedActivityLine(
                verb: active ? "Reading" : "Read",
                detail: body
            )
        }

        // Write / edit / patch
        if isEdit(lower: lower, integration: integration) {
            let isWrite = lower.contains("write") && !lower.contains("search")
            let verb: String = {
                if active { return isWrite ? "Writing" : "Editing" }
                return isWrite ? "Wrote" : "Edited"
            }()
            let body = firstNonEmpty(file, compactPathish(det))
            return HumanizedActivityLine(verb: verb, detail: body)
        }

        // Web search
        if isWebSearch(lower: lower, integration: integration) {
            let query = firstNonEmpty(
                extractQuery(from: det),
                extractQuery(from: cmd),
                det.map { compactCommand($0, limit: 40) }
            )
            return HumanizedActivityLine(
                verb: active ? "Searching" : "Searched",
                detail: query
            )
        }

        // Web fetch
        if isWebFetch(lower: lower) {
            let target = firstNonEmpty(
                extractURL(from: det) ?? extractURL(from: cmd),
                file,
                det.map { compactCommand($0, limit: 40) }
            )
            return HumanizedActivityLine(
                verb: active ? "Fetching" : "Fetched",
                detail: target
            )
        }

        // Grep / search in code
        if lower.contains("grep") || lower == "rg" || lower.contains("search") && !isWebSearch(lower: lower, integration: integration) {
            let body = firstNonEmpty(extractQuery(from: det), det.map { compactCommand($0, limit: 36) }, file)
            return HumanizedActivityLine(
                verb: active ? "Grepping" : "Grepped",
                detail: body
            )
        }

        // Glob / list
        if lower.contains("glob") || lower.contains("list_dir") || lower.contains("listdir")
            || lower == "list" || lower == "ls" || integration == .filesystem && file == nil
        {
            let body = firstNonEmpty(file, compactPathish(det), cmd.map { compactCommand($0, limit: 36) })
            return HumanizedActivityLine(
                verb: active ? "Listing" : "Listed",
                detail: body
            )
        }

        // Git (non-shell explicit)
        if lower.contains("git") || integration == .git {
            if let cmd, !cmd.isEmpty {
                return HumanizedActivityLine(
                    verb: active ? "Running" : "Ran",
                    detail: compactCommand(cmd)
                )
            }
            return HumanizedActivityLine(verb: "Git", detail: prettyToken(rawTool))
        }

        // Subagent / task
        if lower.contains("task") || lower.contains("subagent") || lower.contains("spawn") {
            let body = firstNonEmpty(det.map { compactCommand($0, limit: 36) }, prettyToken(rawTool))
            return HumanizedActivityLine(
                verb: "Task",
                detail: body == "Task" ? nil : body
            )
        }

        // MCP
        if lower.contains("mcp") || lower.contains("__") || integration == .mcp {
            let name = rawTool.replacingOccurrences(of: "MCP:", with: "")
                .replacingOccurrences(of: "mcp__", with: "")
                .replacingOccurrences(of: "__", with: " ")
            return HumanizedActivityLine(
                verb: active ? "Calling" : "Called",
                detail: prettyToken(name)
            )
        }

        // Generic tool with command or path
        if let cmd, !cmd.isEmpty, cmd.caseInsensitiveCompare(rawTool) != .orderedSame {
            return HumanizedActivityLine(
                verb: prettyToken(rawTool.isEmpty ? "Tool" : rawTool),
                detail: compactCommand(cmd)
            )
        }
        if let file, !file.isEmpty {
            return HumanizedActivityLine(
                verb: prettyToken(rawTool.isEmpty ? "Tool" : rawTool),
                detail: file
            )
        }
        if let det, !det.isEmpty, det.caseInsensitiveCompare(rawTool) != .orderedSame {
            return HumanizedActivityLine(
                verb: prettyToken(rawTool.isEmpty ? "Tool" : rawTool),
                detail: compactCommand(det)
            )
        }
        return HumanizedActivityLine(verb: prettyToken(rawTool.isEmpty ? "Tool" : rawTool))
    }

    private static func isShell(lower: String, integration: ActivityIntegration) -> Bool {
        if integration == .shell { return true }
        return lower.contains("bash") || lower.contains("shell") || lower == "terminal"
            || lower.contains("run_terminal") || lower.contains("run_command")
            || lower == "cmd" || lower == "exec"
    }

    private static func isRead(lower: String, integration: ActivityIntegration) -> Bool {
        if integration == .read { return true }
        return lower == "read" || lower.hasPrefix("read_") || lower.contains("read_file")
            || lower.contains("readfile") || lower == "cat"
    }

    private static func isEdit(lower: String, integration: ActivityIntegration) -> Bool {
        if integration == .edit { return true }
        return lower.contains("write") || lower == "edit" || lower.contains("apply_patch")
            || lower.contains("search_replace") || lower.contains("strreplace")
            || lower.contains("multiedit") || lower.contains("edit_file")
    }

    private static func isWebSearch(lower: String, integration: ActivityIntegration) -> Bool {
        if integration == .web && (lower.contains("search") || lower == "web" || lower.contains("websearch")) {
            return true
        }
        return lower.contains("web_search") || lower.contains("websearch")
            || lower == "web_search" || lower == "search_web"
    }

    private static func isWebFetch(lower: String) -> Bool {
        lower.contains("web_fetch") || lower.contains("webfetch") || lower.contains("web_browse")
            || lower.contains("browser") || lower == "fetch"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let v {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private static func extractQuery(from raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Avoid treating file paths as queries.
        if t.hasPrefix("/") || t.hasPrefix("~") { return nil }
        return compactCommand(t, limit: 40)
    }

    private static func extractURL(from raw: String?) -> String? {
        guard let raw else { return nil }
        if let range = raw.range(of: #"https?://\S+"#, options: .regularExpression) {
            return compactCommand(String(raw[range]), limit: 36)
        }
        return nil
    }

    /// `run_terminal_command` → `Run terminal command`, `WebSearch` → `Web search`.
    public static func prettyToken(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Tool" }
        if t.contains("__") {
            return t.split(separator: "__").map { prettyToken(String($0)) }.joined(separator: " ")
        }
        // Insert spaces before internal capitals: WebSearch → Web Search
        var spaced = ""
        let chars = Array(t)
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase, chars[i - 1].isLowercase {
                spaced.append(" ")
            }
            spaced.append(ch)
        }
        spaced = spaced
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = spaced.split(whereSeparator: { $0.isWhitespace }).map { word -> String in
            let s = String(word)
            guard let first = s.first else { return s }
            return String(first).uppercased() + s.dropFirst().lowercased()
        }
        return words.joined(separator: " ")
    }

    public static func compactCommand(_ raw: String, limit: Int = 48) -> String {
        let one = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clip(one, limit: limit)
    }

    public static func compactPathish(_ raw: String?, limit: Int = 40) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("/") {
            return clip((t as NSString).lastPathComponent, limit: limit)
        }
        return compactCommand(t, limit: limit)
    }

    private static func clip(_ raw: String, limit: Int) -> String {
        guard raw.count > limit else { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: max(0, limit - 1))
        return String(raw[..<idx]) + "…"
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
