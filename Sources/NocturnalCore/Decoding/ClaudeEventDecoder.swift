import Foundation

/// Claude Code hook event mapping.
///
/// **Implemented** event types (MVP contract — see `docs/HOOK_SCHEMAS.md`):
/// - `SessionStart` / `SessionEnd`
/// - `Notification` (mapped as summary update when present)
/// - `PreToolUse` (when permission is required — treated as approval gate)
/// - `PostToolUse`
/// - `UserPromptSubmit` (informational)
/// - `Stop` / `SubagentStop`
///
/// Claude's real hook payload shapes evolve; this decoder is intentionally
/// narrow. Unknown types keep raw metadata only.
///
/// Raw Claude stdin (non-envelope) should be wrapped first via
/// ``EnvelopeNormalizer`` (used by the fail-open forwarder with `--wrap-source claude`).
public struct ClaudeEventDecoder: EventDecoding, Sendable {
    public static let implementedEventTypes: Set<String> = [
        "SessionStart",
        "SessionEnd",
        "Notification",
        "PreToolUse",
        "PostToolUse",
        "UserPromptSubmit",
        "Stop",
        "SubagentStop",
        // Normalized aliases used by fixtures / simulator
        "session.started",
        "session.completed",
        "session.failed",
        "tool.approval_required",
        "tool.approval_resolved",
        "agent.question",
        "agent.question_answered",
    ]

    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let type = envelope.eventType
        guard Self.implementedEventTypes.contains(type) else {
            return CompositeEventDecoder.unknownPassthrough(envelope)
        }

        let payload = envelope.payload
        let sessionId = SessionID(envelope.sessionId)
        var result = DecodedEvent(inferredSource: .claude, isUnknown: false)

        result.titleHint = EventDecodeHelpers.string(payload, "title", "session_id", "sessionId")
        result.summaryHint = EventDecodeHelpers.string(
            payload,
            "message",
            "summary",
            "notification",
            "text"
        )
        result.workingDirectory = EventDecodeHelpers.string(payload, "cwd", "working_directory")
            ?? EventDecodeHelpers.nestedString(payload, "workspace", "path")
            ?? EventDecodeHelpers.nestedString(payload, "cwd", "path")

        if let cwd = result.workingDirectory {
            result.jumpBack = JumpBackContext(workingDirectory: cwd)
        }

        switch type {
        case "SessionStart", "session.started", "UserPromptSubmit":
            result.state = .running
            if result.summaryHint == nil, type == "UserPromptSubmit" {
                result.summaryHint = EventDecodeHelpers.string(payload, "prompt") ?? "User prompt"
            }
        case "PostToolUse":
            result.state = .running
            if result.summaryHint == nil {
                let tool = EventDecodeHelpers.string(payload, "tool_name", "tool") ?? "tool"
                result.summaryHint = "Finished \(tool)"
            }
        case "SessionEnd", "session.completed":
            result.state = .completed
        case "Stop", "SubagentStop":
            result.state = .idle
        case "session.failed":
            result.state = .failed
        case "PreToolUse", "tool.approval_required":
            // Permission matrix:
            // - requires_permission / requiresPermission == true → approval
            // - permission / permission_mode present → approval
            // - normalized alias tool.approval_required → always approval
            // - otherwise running + tool summary
            let requiresPermission = EventDecodeHelpers.bool(
                payload,
                "requires_permission",
                "requiresPermission",
                "needs_permission"
            ) == true
                || type == "tool.approval_required"
                || EventDecodeHelpers.string(payload, "permission", "permission_mode") != nil

            if requiresPermission {
                let requestId = EventDecodeHelpers.string(
                    payload,
                    "tool_use_id",
                    "toolUseId",
                    "id",
                    "request_id"
                ) ?? envelope.id.uuidString
                let tool = EventDecodeHelpers.string(payload, "tool_name", "tool", "name") ?? "tool"
                let summary = EventDecodeHelpers.string(payload, "summary", "description")
                    ?? "Approve \(tool)?"
                let detail = EventDecodeHelpers.string(payload, "input", "detail", "command")
                    ?? stringifyJSON(payload["tool_input"])
                result.approval = ApprovalRequest(
                    id: requestId,
                    sessionId: sessionId,
                    toolName: tool,
                    summary: summary,
                    detail: detail,
                    riskHint: riskHint(from: payload),
                    createdAt: envelope.timestamp,
                    raw: payload
                )
                result.state = .waitingForApproval
                result.summaryHint = result.summaryHint ?? summary
            } else {
                result.state = .running
                let tool = EventDecodeHelpers.string(payload, "tool_name", "tool") ?? "unknown"
                result.summaryHint = result.summaryHint ?? "Tool: \(tool)"
            }
        case "tool.approval_resolved":
            result.clearApproval = true
            result.state = .running
        case "Notification":
            result.state = nil // summary only
            if result.summaryHint == nil {
                result.summaryHint = "Notification"
            }
        case "agent.question":
            let promptId = EventDecodeHelpers.string(payload, "id", "prompt_id") ?? envelope.id.uuidString
            let prompt = EventDecodeHelpers.string(payload, "prompt", "question", "message")
                ?? "Agent needs input"
            result.question = QuestionPrompt(
                id: promptId,
                sessionId: sessionId,
                prompt: prompt,
                placeholder: EventDecodeHelpers.string(payload, "placeholder"),
                choices: EventDecodeHelpers.stringArray(payload["choices"]),
                allowFreeform: EventDecodeHelpers.bool(payload, "allow_freeform") ?? true,
                createdAt: envelope.timestamp,
                raw: payload
            )
            result.state = .waitingForInput
        case "agent.question_answered":
            result.clearQuestion = true
            result.state = .running
        default:
            result.isUnknown = true
        }

        return result
    }

    private func riskHint(from payload: [String: JSONValue]) -> ApprovalRiskHint {
        guard let raw = EventDecodeHelpers.string(payload, "risk", "risk_hint") else {
            return .unknown
        }
        return ApprovalRiskHint(rawValue: raw.lowercased()) ?? .unknown
    }

    private func stringifyJSON(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s
        case .null: return nil
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string
        }
    }
}
