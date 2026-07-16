import Foundation

/// Codex hook event mapping.
///
/// **Implemented** event types (MVP contract — see `docs/HOOK_SCHEMAS.md`):
/// - `session.started` / `session.updated` / `session.completed` / `session.failed`
/// - `session.cancelled`
/// - `tool.approval_required` / `tool.approval_resolved`
/// - `agent.question` / `agent.question_answered`
/// - `agent.turn.started` / `agent.turn.completed`
/// - Codex native lifecycle hooks (`SessionStart`, `PermissionRequest`, etc.)
/// - `session.reconciled` from bounded local transcript metadata catch-up
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
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
        "session.reconciled",
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
        // Range-safe PID conversion — oversized / non-integral / untrusted values
        // must not trap via truncating Int32(Double).
        if let pid = payload["pid"]?.exactInt32Value
            ?? payload["process_id"]?.exactInt32Value
        {
            jump.processIdentifier = pid
        } else if let raw = payload["pid"] ?? payload["process_id"],
                  let text = raw.stringValue ?? raw.numberValue.map({ String($0) })
        {
            // Preserve unparseable pid in jump-back extra for diagnostics.
            jump.extra["pid_raw"] = text
        }
        if jump.workingDirectory != nil
            || jump.terminalBundleID != nil
            || jump.editorURL != nil
            || jump.codexDeepLink != nil
            || jump.processIdentifier != nil
            || !jump.extra.isEmpty
        {
            result.jumpBack = jump
        }

        switch type {
        case "session.started", "SessionStart":
            result.state = .running
            if result.summaryHint == nil {
                result.summaryHint = "Session started"
            }
        case "session.updated", "agent.turn.started", "UserPromptSubmit",
             "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
             "PreCompact", "PostCompact":
            result.state = .running
        case "agent.turn.completed", "Stop":
            result.state = .idle
            if type == "Stop", result.summaryHint == nil {
                // Prefer empty — UI maps idle without a stale "Waiting" subtitle.
                result.summaryHint = nil
            }
        case "session.completed":
            result.state = .completed
        case "session.failed":
            result.state = .failed
            if result.summaryHint == nil {
                result.summaryHint = EventDecodeHelpers.string(payload, "error", "reason") ?? "Failed"
            }
        case "session.cancelled":
            result.state = .cancelled
        case "tool.approval_required", "PermissionRequest":
            let requestId = EventDecodeHelpers.string(
                payload,
                "request_id",
                "id",
                "approval_id",
                "tool_use_id"
            )
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
        case "session.reconciled":
            // Transcript metadata is recovery context, never a live-state claim.
            result.state = .idle
            result.summaryHint = result.summaryHint ?? "Recovered from local Codex history"
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
