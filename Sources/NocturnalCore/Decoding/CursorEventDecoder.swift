import Foundation

/// Cursor Agent hooks (`~/.cursor/hooks.json`) mapping.
///
/// Cursor emits camelCase `hook_event_name` values (`sessionStart`, `preToolUse`, …)
/// plus `conversation_id`, `workspace_roots`, `tool_name`, `tool_input`. Raw stdin is
/// wrapped by ``EnvelopeNormalizer`` with `--wrap-source cursor`.
///
/// **Tier B live activity only** — permissions stay in Cursor (`permission: allow|deny`
/// is not driven by Nocturnal). Fail-open: missing Nocturnal never blocks the agent.
public struct CursorEventDecoder: EventDecoding, Sendable {
    public static let implementedEventTypes: Set<String> = {
        var set = GrokEventDecoder.implementedEventTypes
        // Cursor-native names (subset already covered by Grok normalize + aliases).
        set.formUnion([
            "sessionStart", "sessionEnd",
            "preToolUse", "postToolUse", "postToolUseFailure",
            "beforeShellExecution", "afterShellExecution",
            "beforeMCPExecution", "afterMCPExecution",
            "beforeReadFile", "afterFileEdit",
            "beforeSubmitPrompt", "preCompact", "stop",
            "afterAgentResponse", "afterAgentThought",
            "subagentStart", "subagentStop",
            "beforeTabFileRead", "afterTabFileEdit",
            "workspaceOpen",
        ])
        return set
    }()

    private let grok = GrokEventDecoder()

    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        // Reuse Grok lifecycle mapping (Cursor names normalize to the same set),
        // then force Cursor identity and fill Cursor-specific cwd fields.
        var env = envelope
        env.payload = Self.enrichedPayload(envelope)
        if env.eventType == "unknown" || env.eventType.isEmpty {
            env.eventType = EventDecodeHelpers.string(
                env.payload,
                "hook_event_name",
                "hookEventName"
            ) ?? env.eventType
        }

        var result = grok.decode(env)
        if result.isUnknown,
           Self.implementedEventTypes.contains(envelope.eventType)
            || Self.implementedEventTypes.contains(
                GrokEventDecoder.normalizeEventType(envelope.eventType)
            )
        {
            // Force a minimal running/idle decode for recognized Cursor events.
            result = grok.decode(
                EventEnvelope(
                    id: env.id,
                    schemaVersion: env.schemaVersion,
                    source: .cursor,
                    eventType: GrokEventDecoder.normalizeEventType(env.eventType),
                    sessionId: env.sessionId,
                    timestamp: env.timestamp,
                    payload: env.payload,
                    raw: env.raw,
                    sourceRaw: env.sourceRaw
                )
            )
        }

        result.inferredSource = .cursor
        if result.workingDirectory == nil {
            result.workingDirectory = Self.workspaceRoot(from: env.payload)
                ?? Self.workspaceRoot(from: env.raw)
        }
        if result.workingDirectory != nil, result.jumpBack == nil {
            result.jumpBack = JumpBackContext(workingDirectory: result.workingDirectory)
        }
        if result.summaryHint == nil || result.summaryHint == "Grok session" {
            switch GrokEventDecoder.normalizeEventType(env.eventType) {
            case "SessionStart":
                result.summaryHint = "Cursor session"
            case "UserPromptSubmit":
                result.summaryHint = EventDecodeHelpers.string(env.payload, "prompt")
                    ?? "Prompt"
            default:
                break
            }
        }
        return result
    }

    private static func workspaceRoot(from object: [String: JSONValue]) -> String? {
        if let cwd = EventDecodeHelpers.string(object, "cwd", "working_directory", "workspaceRoot") {
            return cwd
        }
        if let roots = object["workspace_roots"]?.arrayValue {
            for root in roots {
                if let s = root.stringValue, !s.isEmpty { return s }
            }
        }
        return nil
    }

    private static func enrichedPayload(_ envelope: EventEnvelope) -> [String: JSONValue] {
        var payload = envelope.payload
        let raw = envelope.raw
        let keys = [
            "cwd", "tool_name", "toolName", "tool_input", "toolInput",
            "command", "file_path", "filePath", "prompt", "conversation_id",
            "session_id", "sessionId", "hook_event_name", "hookEventName",
            "workspace_roots", "generation_id", "model",
        ]
        for key in keys {
            if payload[key] == nil, let value = raw[key] {
                payload[key] = value
            }
        }
        if payload["tool_name"] == nil, let name = payload["toolName"] {
            payload["tool_name"] = name
        }
        if payload["tool_input"] == nil, let input = payload["toolInput"] {
            payload["tool_input"] = input
        }
        let normalized = GrokEventDecoder.normalizeEventType(envelope.eventType)
        // Shell hooks use top-level `command`.
        if payload["tool_name"] == nil,
           payload["command"] != nil,
           normalized == "PreToolUse"
            || envelope.eventType == "beforeShellExecution"
            || envelope.eventType == "afterShellExecution"
        {
            payload["tool_name"] = .string("Shell")
        }
        // File edit / read hooks expose `file_path`.
        if payload["tool_name"] == nil {
            switch envelope.eventType {
            case "afterFileEdit", "afterTabFileEdit":
                payload["tool_name"] = .string("Write")
            case "beforeReadFile", "beforeTabFileRead":
                payload["tool_name"] = .string("Read")
            default:
                break
            }
        }
        if payload["file_path"] == nil, let path = payload["filePath"] {
            payload["file_path"] = path
        }
        if payload["cwd"] == nil, let root = workspaceRoot(from: payload) ?? workspaceRoot(from: raw) {
            payload["cwd"] = .string(root)
        }
        return payload
    }
}
