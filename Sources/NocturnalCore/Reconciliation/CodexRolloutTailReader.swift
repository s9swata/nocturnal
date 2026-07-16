import Foundation

/// Bounded, read-only tail reader for Codex rollout JSONL files.
///
/// Live hooks remain authoritative for session lifecycle / approvals.
/// This reader only **enriches** detail (last messages, tool rows, tokens/diff when present).
public struct CodexRolloutTailReader: Sendable {
    public var maxTailBytes: Int
    public var maxLines: Int
    public var maxActivities: Int
    public var maxSnippetChars: Int

    public init(
        maxTailBytes: Int = 256 * 1024,
        maxLines: Int = 400,
        maxActivities: Int = 40,
        maxSnippetChars: Int = 480
    ) {
        self.maxTailBytes = max(4_096, maxTailBytes)
        self.maxLines = max(10, maxLines)
        self.maxActivities = max(1, maxActivities)
        self.maxSnippetChars = max(40, maxSnippetChars)
    }

    /// Read enrichment for one transcript path. Returns nil on missing/unreadable files.
    public func read(
        sessionId: SessionID,
        transcriptPath: String,
        fileManager: FileManager = .default
    ) -> SessionDetailSnapshot? {
        let url = URL(fileURLWithPath: transcriptPath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Self.readTail(of: url, maxBytes: maxTailBytes) else {
            return nil
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).suffix(maxLines)

        var activities: [SessionActivity] = []
        var lastUser: String?
        var lastAssistant: String?
        var tokensIn: Int?
        var tokensOut: Int?
        var diffAdded: Int?
        var diffRemoved: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let root = try? JSONValue.parse(data: lineData).asObject
            else { continue }

            // Token / usage anywhere on the line.
            if let usage = Self.findUsage(in: root) {
                if let v = usage.tokensIn { tokensIn = v }
                if let v = usage.tokensOut { tokensOut = v }
            }
            if let d = Self.findDiff(in: root) {
                if let a = d.added { diffAdded = a }
                if let r = d.removed { diffRemoved = r }
            }

            if let msg = Self.extractMessage(from: root) {
                // Skip system-prompt / AGENTS.md dumps — they are not a useful "last signal".
                guard !Session.isSystemDumpText(msg.text) else { continue }
                switch msg.role {
                case .user:
                    lastUser = Self.clip(msg.text, max: maxSnippetChars)
                case .assistant:
                    lastAssistant = Self.clip(msg.text, max: maxSnippetChars)
                case .tool:
                    if let activity = Self.activityFromToolMessage(msg, root: root) {
                        activities.append(activity)
                    }
                case .other:
                    break
                }
            } else if let activity = Self.activityFromGenericEvent(root) {
                activities.append(activity)
            }
        }

        // Newest first for UI.
        activities = Array(activities.reversed().prefix(maxActivities))

        let hasAnything = lastUser != nil
            || lastAssistant != nil
            || !activities.isEmpty
            || tokensIn != nil
            || tokensOut != nil
            || diffAdded != nil
            || diffRemoved != nil
        guard hasAnything else { return nil }

        return SessionDetailSnapshot(
            sessionId: sessionId,
            lastUserSnippet: lastUser,
            lastAssistantSnippet: lastAssistant,
            recentToolRows: activities,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            diffAdded: diffAdded,
            diffRemoved: diffRemoved,
            source: .jsonl,
            transcriptPath: transcriptPath,
            capturedAt: Date()
        )
    }

    // MARK: - File IO

    /// Read the last `maxBytes` of a file without loading the whole document.
    public static func readTail(of url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size: UInt64
        if #available(macOS 13.0, *) {
            size = try handle.seekToEnd()
        } else {
            size = handle.seekToEndOfFile()
        }
        if size == 0 { return Data() }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        if #available(macOS 13.0, *) {
            try handle.seek(toOffset: start)
            return try handle.readToEnd() ?? Data()
        } else {
            handle.seek(toFileOffset: start)
            return handle.readDataToEndOfFile()
        }
    }

    // MARK: - Parse helpers

    private enum Role { case user, assistant, tool, other }

    private struct Msg {
        var role: Role
        var text: String
        var toolName: String?
    }

    private static func extractMessage(from root: [String: JSONValue]) -> Msg? {
        // Common shapes:
        // { "type":"message", "role":"assistant", "content":"..." }
        // { "type":"event_msg", "payload": { "type":"agent_message", "message":"..." } }
        // { "payload": { "role":"user", "content":[{ "text":"..." }] } }
        let type = EventDecodeHelpers.string(root, "type", "event_type")?.lowercased()
        let payload = root["payload"]?.objectValue ?? root

        if let roleStr = EventDecodeHelpers.string(payload, "role")
            ?? EventDecodeHelpers.string(root, "role")
        {
            let role = mapRole(roleStr)
            if let text = extractText(from: payload) ?? extractText(from: root), !text.isEmpty {
                return Msg(
                    role: role,
                    text: text,
                    toolName: EventDecodeHelpers.string(payload, "tool_name", "name", "tool")
                )
            }
        }

        if let type {
            if type.contains("user") || type == "user_message" {
                if let text = extractText(from: payload) ?? extractText(from: root) {
                    return Msg(role: .user, text: text, toolName: nil)
                }
            }
            if type.contains("assistant") || type.contains("agent_message") || type == "message" {
                if let text = extractText(from: payload) ?? extractText(from: root) {
                    return Msg(role: .assistant, text: text, toolName: nil)
                }
            }
            if type.contains("tool") || type.contains("function_call") {
                if let text = extractText(from: payload) ?? extractText(from: root) {
                    return Msg(
                        role: .tool,
                        text: text,
                        toolName: EventDecodeHelpers.string(payload, "tool_name", "name", "tool")
                    )
                }
            }
        }

        if let message = EventDecodeHelpers.string(payload, "message", "text"), !message.isEmpty {
            let role: Role = {
                if type?.contains("user") == true { return .user }
                if type?.contains("tool") == true { return .tool }
                return .assistant
            }()
            return Msg(role: role, text: message, toolName: EventDecodeHelpers.string(payload, "tool_name", "tool"))
        }
        return nil
    }

    private static func mapRole(_ raw: String) -> Role {
        switch raw.lowercased() {
        case "user", "human": return .user
        case "assistant", "agent", "model": return .assistant
        case "tool", "function": return .tool
        default: return .other
        }
    }

    private static func extractText(from object: [String: JSONValue]) -> String? {
        if let s = EventDecodeHelpers.string(object, "message", "text", "content", "summary") {
            return s
        }
        if case .array(let parts)? = object["content"] {
            var chunks: [String] = []
            for part in parts {
                if case .string(let s) = part {
                    chunks.append(s)
                } else if case .object(let o) = part {
                    if let t = EventDecodeHelpers.string(o, "text", "content", "input") {
                        chunks.append(t)
                    }
                }
            }
            let joined = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func activityFromToolMessage(_ msg: Msg, root: [String: JSONValue]) -> SessionActivity? {
        let payload = root["payload"]?.objectValue ?? root
        let extracted = ToolPayloadExtraction.extract(from: payload)
        let tool = msg.toolName ?? extracted.toolName ?? "tool"
        let detail = extracted.detail ?? Self.clip(msg.text, max: 120)
        return SessionActivity(
            kind: .tool,
            label: tool,
            detail: detail,
            eventType: "jsonl.tool",
            startedAt: Date(),
            endedAt: Date(),
            toolName: tool,
            primaryPath: extracted.path,
            command: extracted.command,
            integration: extracted.integration,
            outcome: extracted.outcome
        )
    }

    private static func activityFromGenericEvent(_ root: [String: JSONValue]) -> SessionActivity? {
        let type = EventDecodeHelpers.string(root, "type", "event_type", "hook_event_name") ?? ""
        let lower = type.lowercased()
        guard lower.contains("tool") || lower.contains("command") || lower.contains("function") else {
            return nil
        }
        let payload = root["payload"]?.objectValue ?? root
        let extracted = ToolPayloadExtraction.extract(from: payload)
        let tool = extracted.toolName ?? type
        return SessionActivity(
            kind: .tool,
            label: tool,
            detail: extracted.detail,
            eventType: type.isEmpty ? "jsonl.event" : type,
            startedAt: Date(),
            endedAt: Date(),
            toolName: extracted.toolName,
            primaryPath: extracted.path,
            command: extracted.command,
            integration: extracted.integration,
            outcome: extracted.outcome
        )
    }

    private static func findUsage(in root: [String: JSONValue]) -> (tokensIn: Int?, tokensOut: Int?)? {
        let candidates: [[String: JSONValue]] = [
            root,
            root["payload"]?.objectValue ?? [:],
            root["usage"]?.objectValue ?? [:],
            root["payload"]?.objectValue?["usage"]?.objectValue ?? [:],
            root["token_usage"]?.objectValue ?? [:],
        ].filter { !$0.isEmpty }

        var tokensIn: Int?
        var tokensOut: Int?
        for obj in candidates {
            let extracted = ToolPayloadExtraction.extract(from: obj)
            if let v = extracted.tokensIn { tokensIn = v }
            if let v = extracted.tokensOut { tokensOut = v }
        }
        if tokensIn == nil && tokensOut == nil { return nil }
        return (tokensIn, tokensOut)
    }

    private static func findDiff(in root: [String: JSONValue]) -> (added: Int?, removed: Int?)? {
        let candidates: [[String: JSONValue]] = [
            root,
            root["payload"]?.objectValue ?? [:],
            root["diff"]?.objectValue ?? [:],
            root["payload"]?.objectValue?["diff"]?.objectValue ?? [:],
        ].filter { !$0.isEmpty }
        var added: Int?
        var removed: Int?
        for obj in candidates {
            let extracted = ToolPayloadExtraction.extract(from: obj)
            if let v = extracted.diffAdded { added = v }
            if let v = extracted.diffRemoved { removed = v }
        }
        if added == nil && removed == nil { return nil }
        return (added, removed)
    }

    private static func clip(_ text: String, max: Int) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > max else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: max - 1)
        return String(collapsed[..<idx]) + "…"
    }
}
