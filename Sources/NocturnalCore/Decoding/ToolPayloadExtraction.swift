import Foundation

/// Best-effort extraction of tool command / path / integration from hook payloads.
public enum ToolPayloadExtraction: Sendable {
    public struct Extracted: Sendable, Equatable {
        public var toolName: String?
        public var command: String?
        public var path: String?
        public var detail: String?
        public var integration: ActivityIntegration
        public var tokensIn: Int?
        public var tokensOut: Int?
        public var diffAdded: Int?
        public var diffRemoved: Int?
        public var outcome: ActivityOutcome?

        public init(
            toolName: String? = nil,
            command: String? = nil,
            path: String? = nil,
            detail: String? = nil,
            integration: ActivityIntegration = .unknown,
            tokensIn: Int? = nil,
            tokensOut: Int? = nil,
            diffAdded: Int? = nil,
            diffRemoved: Int? = nil,
            outcome: ActivityOutcome? = nil
        ) {
            self.toolName = toolName
            self.command = command
            self.path = path
            self.detail = detail
            self.integration = integration
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.diffAdded = diffAdded
            self.diffRemoved = diffRemoved
            self.outcome = outcome
        }
    }

    public static func extract(from payload: [String: JSONValue]) -> Extracted {
        let tool = EventDecodeHelpers.string(payload, "tool_name", "tool", "name", "toolName")
        // OpenCode plugin hooks use `args`; Codex/Claude use tool_input / input.
        let toolInput = payload["tool_input"]?.objectValue
            ?? payload["input"]?.objectValue
            ?? payload["arguments"]?.objectValue
            ?? payload["args"]?.objectValue

        var command = EventDecodeHelpers.string(payload, "command", "cmd")
        if command == nil, let toolInput {
            command = EventDecodeHelpers.string(toolInput, "command", "cmd", "script")
        }

        var path = EventDecodeHelpers.string(
            payload,
            "file_path",
            "filePath",
            "path",
            "filepath",
            "file",
            "filename"
        )
        if path == nil, let toolInput {
            path = EventDecodeHelpers.string(
                toolInput,
                "file_path",
                "filePath",
                "path",
                "filepath",
                "file",
                "filename",
                "target_file",
                "targetFile"
            )
        }
        // Some Read tools put the path as a bare string tool_input.
        if path == nil, case .string(let s)? = payload["tool_input"] ?? payload["input"] {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("/") || t.hasSuffix(".swift") || t.hasSuffix(".md") || t.hasSuffix(".json") {
                path = t
            }
        }

        var detail = EventDecodeHelpers.string(
            payload,
            "detail",
            "description",
            "summary",
            "message"
        )
        if detail == nil {
            if let command { detail = command }
            else if let path { detail = path }
            else if case .string(let s)? = payload["tool_input"] {
                detail = s
            } else if let toolInput {
                // Compact object for display when no clear command/path.
                if let nested = EventDecodeHelpers.string(toolInput, "query", "url", "pattern", "content") {
                    detail = nested
                }
            }
        }

        let integration = classify(toolName: tool, command: command, path: path, detail: detail)

        let tokensIn = intValue(payload, "tokens_in", "input_tokens", "prompt_tokens")
            ?? (toolInput.flatMap { intValue($0, "tokens_in", "input_tokens") })
        let tokensOut = intValue(payload, "tokens_out", "output_tokens", "completion_tokens")
            ?? (toolInput.flatMap { intValue($0, "tokens_out", "output_tokens") })
        // Nested usage object
        let usage = payload["usage"]?.objectValue ?? payload["token_usage"]?.objectValue
        let tokensInFinal = tokensIn ?? usage.flatMap { intValue($0, "input_tokens", "prompt_tokens", "input") }
        let tokensOutFinal = tokensOut ?? usage.flatMap { intValue($0, "output_tokens", "completion_tokens", "output") }

        let diffAdded = intValue(payload, "additions", "diff_added", "lines_added", "insertions")
        let diffRemoved = intValue(payload, "deletions", "diff_removed", "lines_removed", "deletions_count")

        var outcome: ActivityOutcome?
        if let ok = EventDecodeHelpers.bool(payload, "success", "ok", "approved") {
            outcome = ok ? .success : .failure
        } else if let status = EventDecodeHelpers.string(payload, "status", "result")?.lowercased() {
            if ["ok", "success", "succeeded", "completed"].contains(status) {
                outcome = .success
            } else if ["error", "failed", "failure"].contains(status) {
                outcome = .failure
            }
        }

        return Extracted(
            toolName: tool,
            command: truncate(command),
            path: path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            detail: truncate(detail),
            integration: integration,
            tokensIn: tokensInFinal,
            tokensOut: tokensOutFinal,
            diffAdded: diffAdded,
            diffRemoved: diffRemoved,
            outcome: outcome
        )
    }

    public static func classify(
        toolName: String?,
        command: String?,
        path: String?,
        detail: String?
    ) -> ActivityIntegration {
        // Prefer explicit tool names first (avoid path false-positives).
        if let tool = toolName?.lowercased() {
            if tool.contains("github") || tool == "gh" { return .github }
            if tool.contains("bash") || tool.contains("shell") || tool == "terminal" {
                return .shell
            }
            if tool.contains("write") || tool.contains("edit") || tool.contains("apply_patch")
                || tool == "patch" || tool == "apply_patch"
            {
                return .edit
            }
            if tool == "read" || tool.hasPrefix("read_") { return .read }
            if tool == "glob" || tool == "grep" || tool == "list" || tool == "ls" {
                return .filesystem
            }
            if tool.contains("web") || tool.contains("fetch") || tool.contains("browser")
                || tool == "webfetch" || tool == "websearch"
            {
                return .web
            }
            if tool.contains("mcp") { return .mcp }
            if tool.contains("git") { return .git }
            if tool == "task" || tool == "skill" || tool == "lsp" { return .unknown }
        }

        let blob = [command, detail]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if blob.contains("github") || blob.contains("gh ") { return .github }
        // Word-ish git signals (avoid matching random path segments).
        if blob.contains("git ") || blob.contains("git\t") || blob.hasPrefix("git")
            || blob.contains(" commit") || blob.contains("diff --")
        {
            return .git
        }
        if blob.contains("bash") || blob.contains("shell") || blob.contains("npm ")
            || blob.contains("swift test") || blob.contains("swift build")
        {
            return .shell
        }
        if blob.contains("http://") || blob.contains("https://") || blob.contains("web_search") {
            return .web
        }
        if blob.contains("apply_patch") || blob.contains("write file") { return .edit }
        if path != nil { return .filesystem }
        return .unknown
    }

    private static func intValue(_ payload: [String: JSONValue], _ keys: String...) -> Int? {
        for key in keys {
            if let n = payload[key]?.exactIntValue { return n }
            if let d = payload[key]?.numberValue, d >= 0, d == d.rounded() {
                return Int(d)
            }
            if let s = payload[key]?.stringValue, let n = Int(s) { return n }
        }
        return nil
    }

    private static func truncate(_ text: String?, limit: Int = 120) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<idx]) + "…"
    }
}

