import Foundation

/// OpenCode plugin bridge event mapping.
///
/// Phase 1 uses **strategy A**: the plugin preferably emits Codex-shaped lifecycle
/// names (`SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`, …) with
/// `source: "opencode"`. This decoder also accepts native OpenCode bus names
/// (`session.created`, `tool.execute.before`, …) and normalizes them.
///
/// Bidirectional permission reply is **not** implemented here (Phase 2).
public struct OpenCodeEventDecoder: EventDecoding, Sendable {
    /// Lifecycle types understood after native→Codex-shaped normalization.
    public static let implementedEventTypes: Set<String> = {
        var set = CodexEventDecoder.implementedEventTypes
        // Native OpenCode bus / plugin hook names (pre-normalization).
        set.formUnion([
            "session.created",
            "session.idle",
            "session.error",
            "session.status",
            "session.deleted",
            "tool.execute.before",
            "tool.execute.after",
            "permission.asked",
            "permission.replied",
            "file.edited",
        ])
        return set
    }()

    private let codex = CodexEventDecoder()

    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let mappedType = Self.mapEventType(envelope.eventType)
        guard Self.implementedEventTypes.contains(envelope.eventType)
            || CodexEventDecoder.implementedEventTypes.contains(mappedType)
        else {
            var unknown = CompositeEventDecoder.unknownPassthrough(envelope)
            unknown.inferredSource = .opencode
            return unknown
        }

        var mapped = envelope
        mapped.eventType = mappedType
        // Prefer plugin-normalized payload; still lift OpenCode-style `args`.
        mapped.payload = Self.normalizePayload(envelope.payload)

        var result = codex.decode(mapped)
        result.inferredSource = .opencode
        if mappedType == "session.reconciled" {
            if result.summaryHint == "Recovered from local Codex history"
                || result.summaryHint == nil
            {
                result.summaryHint = EventDecodeHelpers.string(
                    mapped.payload,
                    "summary",
                    "message"
                ) ?? "Recovered from local OpenCode history"
            }
        }
        // Tag approval raw so AppModel can attempt OpenCode HTTP reply as backup.
        if var approval = result.approval {
            var raw = approval.raw
            raw["opencode"] = .bool(true)
            raw["source"] = .string("opencode")
            approval.raw = raw
            result.approval = approval
        }
        return result
    }

    /// Map native OpenCode event names to the Codex-shaped types activity mapping knows.
    public static func mapEventType(_ type: String) -> String {
        switch type {
        case "session.created":
            return "SessionStart"
        case "session.idle":
            return "Stop"
        case "session.error":
            return "session.failed"
        case "session.status", "session.updated":
            return "session.updated"
        case "session.deleted":
            return "session.completed"
        case "tool.execute.before":
            return "PreToolUse"
        case "tool.execute.after":
            return "PostToolUse"
        case "permission.asked":
            return "PermissionRequest"
        case "permission.replied":
            return "tool.approval_resolved"
        case "file.edited":
            return "PostToolUse"
        default:
            return type
        }
    }

    /// Flatten OpenCode `args` into fields `ToolPayloadExtraction` already reads.
    public static func normalizePayload(_ payload: [String: JSONValue]) -> [String: JSONValue] {
        var out = payload
        let args = payload["args"]?.objectValue
            ?? payload["arguments"]?.objectValue
            ?? payload["input"]?.objectValue
            ?? payload["tool_input"]?.objectValue

        if out["tool_name"] == nil, out["tool"] == nil, out["name"] == nil {
            if let tool = EventDecodeHelpers.string(payload, "tool", "toolName", "tool_name", "name") {
                out["tool_name"] = .string(tool)
                out["tool"] = .string(tool)
            }
        }

        if let args {
            if out["tool_input"] == nil {
                out["tool_input"] = .object(args)
            }
            if out["command"] == nil,
               let command = EventDecodeHelpers.string(args, "command", "cmd", "script")
            {
                out["command"] = .string(command)
            }
            if out["file_path"] == nil,
               let path = EventDecodeHelpers.string(
                args,
                "filePath",
                "file_path",
                "path",
                "filepath",
                "file",
                "target_file",
                "targetFile"
               )
            {
                out["file_path"] = .string(path)
            }
            if out["detail"] == nil,
               let detail = EventDecodeHelpers.string(
                args,
                "query",
                "url",
                "pattern",
                "description",
                "content"
               )
            {
                out["detail"] = .string(detail)
            }
        }

        // file.edited often only carries a path at the top level.
        if out["tool_name"] == nil, out["file_path"] != nil || out["path"] != nil {
            out["tool_name"] = .string("edit")
            out["tool"] = .string("edit")
        }

        return out
    }
}
