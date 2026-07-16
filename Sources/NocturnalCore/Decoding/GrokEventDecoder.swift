import Foundation

/// Grok Build hook event mapping.
///
/// Grok hooks use Claude-compatible lifecycle names (`SessionStart`, `PreToolUse`, …)
/// and also accept Cursor camelCase / snake_case `hookEventName` values on stdin.
/// Raw stdin is wrapped by ``EnvelopeNormalizer`` with `--wrap-source grok-build`.
///
/// **Live activity only (Tier B):** PreToolUse does **not** open Nocturnal
/// Deny/Allow — Grok still owns permission UI. Fail-open forwarder never blocks
/// the agent when Nocturnal is down.
public struct GrokEventDecoder: EventDecoding, Sendable {
    public static let implementedEventTypes: Set<String> = [
        // PascalCase (Grok / Claude hook config keys)
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
        "Notification",
        "SubagentStart",
        "SubagentStop",
        "PermissionDenied",
        "PreCompact",
        "PostCompact",
        // snake_case hookEventName from Grok runner
        "session_start",
        "session_end",
        "user_prompt_submit",
        "pre_tool_use",
        "post_tool_use",
        "post_tool_use_failure",
        "stop",
        "stop_failure",
        "notification",
        "subagent_start",
        "subagent_stop",
        "permission_denied",
        "pre_compact",
        "post_compact",
        // NAP + fixture aliases
        "session.started",
        "session.completed",
        "session.failed",
        "session.reconciled",
        "turn.started",
        "turn.completed",
        "tool.started",
        "tool.completed",
    ]

    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let type = Self.normalizeEventType(envelope.eventType)
        guard Self.implementedEventTypes.contains(envelope.eventType)
            || Self.implementedEventTypes.contains(type)
        else {
            return CompositeEventDecoder.unknownPassthrough(envelope)
        }

        let payload = Self.enrichedPayload(envelope)
        var result = DecodedEvent(inferredSource: .grokBuild, isUnknown: false)

        result.titleHint = EventDecodeHelpers.string(
            payload,
            "title",
            "generated_title",
            "session_summary",
            "sessionTitle"
        )
        result.summaryHint = EventDecodeHelpers.string(
            payload,
            "message",
            "summary",
            "notification",
            "text",
            "reason"
        )
        result.workingDirectory = EventDecodeHelpers.string(
            payload,
            "cwd",
            "working_directory",
            "workspaceRoot",
            "workspace_root"
        )
            ?? EventDecodeHelpers.nestedString(payload, "workspace", "path")
            ?? EventDecodeHelpers.nestedString(payload, "cwd", "path")

        if let cwd = result.workingDirectory {
            result.jumpBack = JumpBackContext(workingDirectory: cwd)
        }

        switch type {
        case "SessionStart", "session.started", "UserPromptSubmit", "turn.started":
            result.state = .running
            if result.summaryHint == nil {
                if type == "UserPromptSubmit" {
                    result.summaryHint = EventDecodeHelpers.string(payload, "prompt") ?? "User prompt"
                } else {
                    result.summaryHint = "Grok session"
                }
            }

        case "PreToolUse", "tool.started":
            result.state = .running
            let tool = Self.toolName(from: payload) ?? "tool"
            result.summaryHint = result.summaryHint ?? "Tool: \(tool)"
            if result.titleHint == nil {
                result.titleHint = tool
            }

        case "PostToolUse", "tool.completed":
            result.state = .running
            let tool = Self.toolName(from: payload) ?? "tool"
            result.summaryHint = result.summaryHint ?? "Finished \(tool)"

        case "PostToolUseFailure", "PermissionDenied", "StopFailure":
            result.state = .running
            let tool = Self.toolName(from: payload) ?? "tool"
            result.summaryHint = result.summaryHint
                ?? (type == "PermissionDenied" ? "Denied \(tool)" : "Failed \(tool)")

        case "Stop", "SubagentStop", "turn.completed":
            result.state = .idle
            result.summaryHint = result.summaryHint ?? "Turn complete"

        case "SessionEnd", "session.completed":
            result.state = .completed
            result.summaryHint = result.summaryHint ?? "Session ended"

        case "session.failed":
            result.state = .failed

        case "session.reconciled":
            // Local history catch-up — never a live-state claim.
            result.state = .idle
            result.summaryHint = result.summaryHint ?? "Recovered from local Grok history"

        case "Notification":
            result.state = nil
            if result.summaryHint == nil {
                result.summaryHint = "Notification"
            }

        case "SubagentStart":
            result.state = .running
            result.summaryHint = result.summaryHint ?? "Subagent started"

        case "PreCompact", "PostCompact":
            result.state = .running
            result.summaryHint = result.summaryHint
                ?? (type == "PreCompact" ? "Compacting…" : "Compacted")

        default:
            result.isUnknown = true
        }

        return result
    }

    /// Map Grok / Cursor snake_case and camelCase to PascalCase lifecycle names.
    public static func normalizeEventType(_ raw: String) -> String {
        switch raw {
        case "session_start", "sessionStart": return "SessionStart"
        case "session_end", "sessionEnd": return "SessionEnd"
        case "user_prompt_submit", "beforeSubmitPrompt", "userPromptSubmit": return "UserPromptSubmit"
        case "pre_tool_use", "preToolUse",
             "beforeShellExecution", "beforeMCPExecution", "beforeReadFile":
            return "PreToolUse"
        case "post_tool_use", "postToolUse",
             "afterShellExecution", "afterMCPExecution", "afterFileEdit",
             "afterAgentResponse", "afterAgentThought":
            return "PostToolUse"
        case "post_tool_use_failure", "postToolUseFailure": return "PostToolUseFailure"
        case "stop", "stop_failure", "stopFailure": return raw == "stopFailure" || raw == "stop_failure"
            ? "StopFailure" : "Stop"
        case "notification": return "Notification"
        case "subagent_start", "subagentStart": return "SubagentStart"
        case "subagent_stop", "subagentStop", "SubagentEnd", "subagent_end": return "SubagentStop"
        case "permission_denied", "permissionDenied": return "PermissionDenied"
        case "pre_compact", "preCompact": return "PreCompact"
        case "post_compact", "postCompact": return "PostCompact"
        default: return raw
        }
    }

    private static func toolName(from payload: [String: JSONValue]) -> String? {
        EventDecodeHelpers.string(payload, "toolName", "tool_name", "tool", "name")
    }

    /// Flatten common Grok stdin fields into payload when the normalizer left them in raw only.
    private static func enrichedPayload(_ envelope: EventEnvelope) -> [String: JSONValue] {
        var payload = envelope.payload
        let raw = envelope.raw
        let keys = [
            "cwd", "workspaceRoot", "workspace_root", "toolName", "tool_name",
            "toolInput", "tool_input", "prompt", "message", "title", "sessionId",
            "session_id", "timestamp", "hookEventName", "hook_event_name",
        ]
        for key in keys {
            if payload[key] == nil, let value = raw[key] {
                payload[key] = value
            }
        }
        // Prefer camelCase tool fields Grok sends.
        if payload["tool_name"] == nil, let name = payload["toolName"] {
            payload["tool_name"] = name
        }
        if payload["tool_input"] == nil, let input = payload["toolInput"] {
            payload["tool_input"] = input
        }
        if payload["cwd"] == nil, let root = payload["workspaceRoot"] ?? payload["workspace_root"] {
            payload["cwd"] = root
        }
        return payload
    }
}
