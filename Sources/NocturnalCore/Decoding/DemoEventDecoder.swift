import Foundation

/// Decoder for deterministic demo / simulation envelopes (`source: demo`).
public struct DemoEventDecoder: EventDecoding, Sendable {
    public init() {}

    public func decode(_ envelope: EventEnvelope) -> DecodedEvent {
        // Reuse Codex normalized event names for demo fixtures.
        var decoded = CodexEventDecoder().decode(envelope)
        decoded.inferredSource = .demo
        if decoded.isUnknown {
            // Allow free-form demo state injection: payload.state = "waitingForApproval"
            if let stateRaw = EventDecodeHelpers.string(envelope.payload, "state"),
               let state = SessionState(rawValue: stateRaw)
            {
                decoded.state = state
                decoded.isUnknown = false
                decoded.summaryHint = decoded.summaryHint
                    ?? EventDecodeHelpers.string(envelope.payload, "summary", "message")
            }
        }
        // Demo payloads may also set terminal / editor jump targets directly.
        if decoded.jumpBack == nil {
            var jump = JumpBackContext(
                workingDirectory: EventDecodeHelpers.string(envelope.payload, "cwd", "working_directory")
            )
            if let bid = EventDecodeHelpers.string(envelope.payload, "terminal_bundle_id") {
                jump.terminalBundleID = bid
            }
            if let editor = EventDecodeHelpers.string(envelope.payload, "editor"),
               ["vscode", "cursor"].contains(editor)
            {
                jump.extra["editor"] = editor
            }
            if jump.workingDirectory != nil || jump.terminalBundleID != nil || !jump.extra.isEmpty {
                decoded.jumpBack = jump
            }
        }
        return decoded
    }
}
