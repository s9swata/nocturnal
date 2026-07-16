import Foundation

/// Maps decoded hook events into ``Session/currentActivity`` updates.
///
/// Pure helpers used by ``SessionStore`` — no I/O. Unknown events leave activity alone
/// unless a summary hint is useful for first-run visibility.
public enum SessionActivityMapping: Sendable {
    public static func apply(
        to session: inout Session,
        envelope: EventEnvelope,
        decoded: DecodedEvent,
        allowLifecycleMutation: Bool
    ) {
        guard allowLifecycleMutation else { return }

        // Grok (and Cursor-compat) emit snake_case / camelCase hookEventName;
        // product decoders accept those, but activity mapping historically only
        // matched PascalCase — so Grok tools never became "meaningful" and stale
        // OpenCode tool rows kept owning the notch.
        let type = normalizeEventType(envelope.eventType)
        // Prefer decoder-enriched payload (raw-only tool fields, Shell/Read/Write aliases).
        let payload = decoded.activityPayload ?? envelope.payload
        let at = envelope.timestamp
        let extracted = ToolPayloadExtraction.extract(from: payload)

        if let approval = decoded.approval {
            let detail = truncate(approval.detail ?? approval.summary)
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .approval,
                    label: approval.toolName,
                    detail: detail,
                    eventType: type,
                    startedAt: at,
                    toolName: approval.toolName,
                    primaryPath: extracted.path,
                    command: extracted.command,
                    integration: ToolPayloadExtraction.classify(
                        toolName: approval.toolName,
                        command: extracted.command,
                        path: extracted.path,
                        detail: detail
                    )
                ),
                on: &session
            )
            return
        }
        if let question = decoded.question {
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .question,
                    label: "Question",
                    detail: truncate(question.prompt),
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )
            return
        }

        if decoded.clearApproval || decoded.clearQuestion {
            SessionActivityPolicy.endCurrent(on: &session, at: at)
        }

        switch type {
        case "PreToolUse":
            // `tool.started` is normalized to PreToolUse before the switch.
            let tool = extracted.toolName ?? "tool"
            applyToolStart(to: &session, tool: tool, extracted: extracted, eventType: type, at: at)
            session.stats.toolUseCount += 1
            session.stats.lastToolName = tool
            if let command = extracted.command {
                session.stats.lastCommand = command
            }
            if let path = extracted.path {
                session.stats.recordTouchedPath(path)
            }
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )

        case "PostToolUse", "PostToolUseFailure":
            // `tool.completed` normalizes to PostToolUse.
            let defaultOutcome: ActivityOutcome =
                type == "PostToolUseFailure" ? .failure : .success
            if let path = extracted.path {
                session.stats.recordTouchedPath(path)
            }
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )
            if var current = session.currentActivity, current.kind == .tool {
                let completedName = extracted.toolName.map(Session.normalizedToolName)
                let currentName = Session.normalizedToolName(current.toolName ?? current.label)
                // Overlapping tools: only end the current activity when names match
                // (or completion lacks a name). Mismatched completions archive alone.
                let namesMatch = completedName == nil
                    || completedName?.isEmpty == true
                    || completedName == currentName
                if namesMatch {
                    current.outcome = extracted.outcome ?? defaultOutcome
                    current.endedAt = at
                    if current.command == nil { current.command = extracted.command }
                    if current.primaryPath == nil { current.primaryPath = extracted.path }
                    session.currentActivity = current
                    SessionActivityPolicy.endCurrent(on: &session, at: at)
                } else if let tool = extracted.toolName {
                    let finished = SessionActivity(
                        kind: .tool,
                        label: tool,
                        detail: extracted.detail ?? "Finished",
                        eventType: type,
                        startedAt: at,
                        endedAt: at,
                        toolName: tool,
                        primaryPath: extracted.path,
                        command: extracted.command,
                        integration: extracted.integration,
                        outcome: extracted.outcome ?? defaultOutcome
                    )
                    session.recentActivities.insert(finished, at: 0)
                    if session.recentActivities.count > SessionActivityPolicy.maxRecent {
                        session.recentActivities = Array(
                            session.recentActivities.prefix(SessionActivityPolicy.maxRecent)
                        )
                    }
                }
            } else if let tool = extracted.toolName {
                let finished = SessionActivity(
                    kind: .tool,
                    label: tool,
                    detail: extracted.detail ?? "Finished",
                    eventType: type,
                    startedAt: at,
                    endedAt: at,
                    toolName: tool,
                    primaryPath: extracted.path,
                    command: extracted.command,
                    integration: extracted.integration,
                    outcome: extracted.outcome ?? defaultOutcome
                )
                session.recentActivities.insert(finished, at: 0)
                if session.recentActivities.count > SessionActivityPolicy.maxRecent {
                    session.recentActivities = Array(
                        session.recentActivities.prefix(SessionActivityPolicy.maxRecent)
                    )
                }
            }
            // Intentionally do not set currentActivity to "Working" — that hid the
            // last tool title on the notch between tools.

        case "tool.approval_required", "PermissionRequest", "permission.asked":
            if session.currentActivity?.kind != .approval {
                let tool = extracted.toolName
                    ?? EventDecodeHelpers.string(payload, "tool", "tool_name", "name")
                    ?? "tool"
                SessionActivityPolicy.setCurrent(
                    SessionActivity(
                        kind: .approval,
                        label: tool,
                        detail: extracted.detail ?? truncate(
                            EventDecodeHelpers.string(payload, "summary", "description", "command")
                        ),
                        eventType: type,
                        startedAt: at,
                        toolName: tool,
                        primaryPath: extracted.path,
                        command: extracted.command,
                        integration: extracted.integration
                    ),
                    on: &session
                )
            }

        case "tool.approval_resolved", "permission.resolved", "agent.question_answered", "question.answered":
            SessionActivityPolicy.endCurrent(on: &session, at: at)
            // Leave current empty so UI keeps showing last tool / prompt, not "Working".

        case "agent.turn.started", "UserPromptSubmit", "turn.started":
            let detail = EventDecodeHelpers.string(payload, "prompt", "text", "message")
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .turn,
                    label: type == "UserPromptSubmit" ? "Prompt" : "Thinking",
                    detail: truncate(detail),
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut
            )

        case "agent.turn.completed", "turn.completed":
            // Mid-session turn end — clear active activity; keep last tool in recent.
            SessionActivityPolicy.endCurrent(on: &session, at: at)
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )

        case "Stop", "SubagentStop":
            SessionActivityPolicy.endCurrent(on: &session, at: at)
            // Explicit stop: leave a finished "Idle" breadcrumb so the island
            // can prefer stop status over the last tool as primary live copy.
            // SessionEnd still owns the stronger "Completed" label.
            if type == "Stop" {
                SessionActivityPolicy.setCurrent(
                    SessionActivity(
                        kind: .session,
                        label: "Idle",
                        detail: extracted.detail ?? decoded.summaryHint,
                        eventType: type,
                        startedAt: at,
                        endedAt: at
                    ),
                    on: &session
                )
                SessionActivityPolicy.endCurrent(on: &session, at: at)
            }
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )

        case "session.started", "SessionStart":
            // Lifecycle shell only — not a model turn. Keeps notch tier-3
            // (active turn) free for real agent.turn.started / thinking work.
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .session,
                    label: "Session",
                    detail: decoded.titleHint,
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )

        case "session.completed", "SessionEnd":
            SessionActivityPolicy.endCurrent(on: &session, at: at)
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .session,
                    label: "Completed",
                    eventType: type,
                    startedAt: at,
                    endedAt: at
                ),
                on: &session
            )
            SessionActivityPolicy.endCurrent(on: &session, at: at)

        case "session.failed":
            SessionActivityPolicy.endCurrent(on: &session, at: at)
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .session,
                    label: "Failed",
                    detail: truncate(decoded.summaryHint),
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )
            SessionActivityPolicy.endCurrent(on: &session, at: at)

        case "session.cancelled":
            SessionActivityPolicy.endCurrent(on: &session, at: at)

        case "session.updated":
            if let summary = decoded.summaryHint, !summary.isEmpty {
                SessionActivityPolicy.setCurrent(
                    SessionActivity(
                        kind: .turn,
                        label: "Working",
                        detail: truncate(summary),
                        eventType: type,
                        startedAt: at
                    ),
                    on: &session
                )
            }
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )

        case "Notification":
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .notification,
                    label: "Notification",
                    detail: truncate(decoded.summaryHint),
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )

        case "SubagentStart":
            SessionActivityPolicy.setCurrent(
                SessionActivity(
                    kind: .turn,
                    label: "Subagent",
                    detail: truncate(decoded.summaryHint),
                    eventType: type,
                    startedAt: at
                ),
                on: &session
            )

        case "session.reconciled":
            // Offline recovery: identity + best-effort metrics only (never live state).
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )

        default:
            if decoded.state == .running,
               let summary = decoded.summaryHint,
               !summary.isEmpty,
               session.currentActivity == nil
            {
                SessionActivityPolicy.setCurrent(
                    SessionActivity(
                        kind: .unknown,
                        label: truncate(summary) ?? summary,
                        eventType: type,
                        startedAt: at
                    ),
                    on: &session
                )
            } else if decoded.state?.isTerminal == true {
                SessionActivityPolicy.endCurrent(on: &session, at: at)
            }
            session.stats.mergeMetrics(
                tokensIn: extracted.tokensIn,
                tokensOut: extracted.tokensOut,
                diffAdded: extracted.diffAdded,
                diffRemoved: extracted.diffRemoved
            )
        }

        if let state = decoded.state, state.isTerminal {
            if session.currentActivity?.isActive == true {
                SessionActivityPolicy.endCurrent(on: &session, at: at)
            }
        }
    }

    private static func applyToolStart(
        to session: inout Session,
        tool: String,
        extracted: ToolPayloadExtraction.Extracted,
        eventType: String,
        at: Date
    ) {
        SessionActivityPolicy.setCurrent(
            SessionActivity(
                kind: .tool,
                label: tool,
                detail: extracted.detail,
                eventType: eventType,
                startedAt: at,
                toolName: tool,
                primaryPath: extracted.path,
                command: extracted.command,
                integration: extracted.integration
            ),
            on: &session
        )
    }

    private static func truncate(_ text: String?, limit: Int = 96) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<idx]) + "…"
    }

    /// Map Grok/Cursor/NAP wire names onto the cases this mapper owns.
    ///
    /// Uses ``CanonicalAgentEvent/normalize(_:)`` so NAP producers (e.g.
    /// `permission.resolved`) reach the same paths as native aliases.
    public static func normalizeEventType(_ raw: String) -> String {
        // Preserve product Stop / OpenCode session.idle as `Stop` so the Idle
        // breadcrumb is not collapsed into SessionEnd → "Completed".
        let grokFirst = GrokEventDecoder.normalizeEventType(raw)
        if raw == "Stop" || raw == "stop" || raw == "session.idle" || grokFirst == "Stop" {
            return "Stop"
        }
        if raw == "SubagentStop" || grokFirst == "SubagentStop" {
            return "SubagentStop"
        }
        let nap = CanonicalAgentEvent.normalize(raw)
        switch nap {
        case CanonicalAgentEvent.toolStarted.rawValue: return "PreToolUse"
        case CanonicalAgentEvent.toolCompleted.rawValue: return "PostToolUse"
        case CanonicalAgentEvent.turnStarted.rawValue: return "agent.turn.started"
        // Keep turn rest distinct from product `Stop` (which adds an Idle breadcrumb).
        case CanonicalAgentEvent.turnCompleted.rawValue: return "agent.turn.completed"
        case CanonicalAgentEvent.sessionStarted.rawValue: return "SessionStart"
        case CanonicalAgentEvent.sessionCompleted.rawValue: return "SessionEnd"
        case CanonicalAgentEvent.permissionAsked.rawValue: return "PermissionRequest"
        case CanonicalAgentEvent.permissionResolved.rawValue: return "permission.resolved"
        case CanonicalAgentEvent.questionAsked.rawValue: return "agent.question"
        case CanonicalAgentEvent.questionAnswered.rawValue: return "question.answered"
        default:
            switch grokFirst {
            case "tool.started": return "PreToolUse"
            case "tool.completed": return "PostToolUse"
            default: return grokFirst
            }
        }
    }
}
