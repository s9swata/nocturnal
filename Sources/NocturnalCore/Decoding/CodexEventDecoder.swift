import Foundation

/// Codex hook event mapping.
///
/// **Implemented** event types (MVP contract — see `docs/HOOK_SCHEMAS.md`):
/// - `session.started` / `session.updated` / `session.completed` / `session.failed`
/// - `session.cancelled`
/// - `tool.approval_required` / `tool.approval_resolved`
/// - `agent.question` / `agent.question_answered`
/// - `agent.turn.started` / `agent.turn.completed`
///
/// Anything else is treated as unknown: raw metadata preserved, no crash.
public struct CodexEventDecoder: EventDecoding, Sendable {
    public static let implementedEventTypes: Set<String> = [
        "session.started",
        "session.updated",
        "session.completed",
        "session.failed",
        "session.cancelled",
        "tool.approval_required",
        "tool.approval_resolved",
        "agent.question",
        "agent.question_answered",
        "agent.turn.started",
        "agent.turn.completed",
    ]

    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        let type = envelope.eventType
        guard Self.implementedEventTypes.contains(type) else {
            return CompositeEventDecoder.unknownPassthrough(envelope)
        }

        let payload = envelope.payload
        let sessionId = SessionID(envelope.sessionId)
        var result = DecodedEvent(inferredSource: .codex, isUnknown: false)

        result.titleHint = EventDecodeHelpers.string(payload, "title", "session_title", "name")
        result.summaryHint = EventDecodeHelpers.string(payload, "summary", "message", "status_text")
        result.workingDirectory = EventDecodeHelpers.string(
            payload,
            "cwd",
            "working_directory",
            "workdir",
            "workspace_root"
        )

        // Terminal / editor hints for jump-back
        var jump = JumpBackContext(workingDirectory: result.workingDirectory)
        if let bid = EventDecodeHelpers.string(payload, "terminal_bundle_id", "terminalBundleId") {
            jump.terminalBundleID = bid
        }
        if let tab = EventDecodeHelpers.string(payload, "terminal_tab_title", "tab_title") {
            jump.terminalTabTitle = tab
        }
        if let editor = EventDecodeHelpers.string(payload, "editor_url", "editorURL"),
           let url = URL(string: editor)
        {
            jump.editorURL = url
        }
        if let deep = EventDecodeHelpers.string(payload, "codex_url", "deep_link", "deeplink"),
           let url = URL(string: deep)
        {
            jump.codexDeepLink = url
        }
        if let pid = payload["pid"]?.numberValue ?? payload["process_id"]?.numberValue {
            jump.processIdentifier = Int32(pid)
        }
        if jump.workingDirectory != nil
            || jump.terminalBundleID != nil
            || jump.editorURL != nil
            || jump.codexDeepLink != nil
        {
            result.jumpBack = jump
        }

        switch type {
        case "session.started":
            result.state = .running
            if result.summaryHint == nil {
                result.summaryHint = "Session started"
            }
        case "session.updated", "agent.turn.started":
            result.state = .running
        case "agent.turn.completed":
            result.state = .idle
        case "session.completed":
            result.state = .completed
        case "session.failed":
            result.state = .failed
            if result.summaryHint == nil {
                result.summaryHint = EventDecodeHelpers.string(payload, "error", "reason") ?? "Failed"
            }
        case "session.cancelled":
            result.state = .cancelled
        case "tool.approval_required":
            let requestId = EventDecodeHelpers.string(payload, "request_id", "id", "approval_id")
                ?? envelope.id.uuidString
            let tool = EventDecodeHelpers.string(payload, "tool", "tool_name", "name") ?? "tool"
            let summary = EventDecodeHelpers.string(payload, "summary", "description", "title")
                ?? "Approval required"
            result.approval = ApprovalRequest(
                id: requestId,
                sessionId: sessionId,
                toolName: tool,
                summary: summary,
                detail: EventDecodeHelpers.string(payload, "detail", "command", "input"),
                riskHint: riskHint(from: payload),
                createdAt: envelope.timestamp,
                raw: payload
            )
            result.state = .waitingForApproval
            result.summaryHint = result.summaryHint ?? summary
        case "tool.approval_resolved":
            result.clearApproval = true
            result.state = .running
            if let approved = EventDecodeHelpers.bool(payload, "approved", "ok") {
                result.summaryHint = approved ? "Approval granted" : "Approval denied"
            }
        case "agent.question":
            let promptId = EventDecodeHelpers.string(payload, "prompt_id", "id", "question_id")
                ?? envelope.id.uuidString
            let prompt = EventDecodeHelpers.string(payload, "prompt", "question", "text")
                ?? "Agent needs input"
            result.question = QuestionPrompt(
                id: promptId,
                sessionId: sessionId,
                prompt: prompt,
                placeholder: EventDecodeHelpers.string(payload, "placeholder"),
                choices: EventDecodeHelpers.stringArray(payload["choices"]),
                allowFreeform: EventDecodeHelpers.bool(payload, "allow_freeform", "allowFreeform") ?? true,
                createdAt: envelope.timestamp,
                raw: payload
            )
            result.state = .waitingForInput
            result.summaryHint = result.summaryHint ?? prompt
        case "agent.question_answered":
            result.clearQuestion = true
            result.state = .running
        default:
            result.isUnknown = true
        }

        return result
    }

    private func riskHint(from payload: [String: JSONValue]) -> ApprovalRiskHint {
        guard let raw = EventDecodeHelpers.string(payload, "risk", "risk_hint", "riskHint")
        else {
            return .unknown
        }
        return ApprovalRiskHint(rawValue: raw.lowercased()) ?? .unknown
    }
}
