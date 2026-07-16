import Foundation

/// Delivers user decisions back toward the agent runtime.
///
/// MVP transport: write JSON files under Application Support `responses/`.
/// Future: reply Unix socket or agent-specific IPC. Hooks / agent plugins
/// can poll or inotify this directory.
///
/// ## On-disk layout (deterministic, collision-free)
///
/// ```
/// responses/
///   records/<encoded-request-id>.json   # ResponseFileEnvelope (canonical)
///   codex/<encoded-request-id>.json     # Codex-ish decision sidecar
///   claude/<encoded-request-id>.json    # Claude-ish permission sidecar
///   answer/<encoded-request-id>.json    # Question answer sidecar
/// ```
///
/// Filenames use ``PathComponentEncoding``. Envelopes live under `records/` so
/// they never share a flat namespace with prior/`n.` layouts or agent sidecars.
/// Sidecars use agent subdirectories so envelope id `codex-x` never collides
/// with the Codex sidecar for id `x`.
public protocol ResponseTransporting: Sendable {
    func submit(_ response: AgentResponse) async throws
}

public struct FileResponseTransport: ResponseTransporting {
    public var paths: PersistencePaths
    /// Optional subdirectory tags for agent-specific consumers.
    public var writeAgentSidecars: Bool

    public init(paths: PersistencePaths, writeAgentSidecars: Bool = true) {
        self.paths = paths
        self.writeAgentSidecars = writeAgentSidecars
    }

    public func submit(_ response: AgentResponse) async throws {
        try paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let fileURL: URL
        let data: Data
        let requestId: String
        switch response {
        case .approval(let decision):
            requestId = decision.requestId
            fileURL = paths.responseFile(for: decision.requestId)
            data = try encoder.encode(ResponseFileEnvelope.approval(decision))
        case .question(let answer):
            requestId = answer.promptId
            fileURL = paths.responseFile(for: answer.promptId)
            data = try encoder.encode(ResponseFileEnvelope.question(answer))
        }

        try data.write(to: fileURL, options: [.atomic])

        if writeAgentSidecars {
            try writeAgentSpecific(response: response, requestId: requestId, encoder: encoder)
        }
    }

    /// Agent-oriented shapes some plugins can consume without learning `ResponseFileEnvelope`.
    ///
    /// Written under `responses/{codex,claude,answer}/` so they never share a
    /// flat filename namespace with envelope files.
    private func writeAgentSpecific(
        response: AgentResponse,
        requestId: String,
        encoder: JSONEncoder
    ) throws {
        let fm = FileManager.default

        switch response {
        case .approval(let decision):
            let codexURL = paths.responseSidecarFile(agent: "codex", requestId: requestId)
            try fm.createDirectory(
                at: codexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let codex: [String: JSONValue] = [
                "request_id": .string(decision.requestId),
                "session_id": .string(decision.sessionId.rawValue),
                "approved": .bool(decision.approved),
                "note": decision.note.map { .string($0) } ?? .null,
                "scope": .string(decision.resolvedScope.rawValue),
                "decided_at": .string(ISO8601DateFormatter().string(from: decision.decidedAt)),
            ]
            try encoder.encode(codex).write(to: codexURL, options: [.atomic])

            let claudeURL = paths.responseSidecarFile(agent: "claude", requestId: requestId)
            try fm.createDirectory(
                at: claudeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let claude: [String: JSONValue] = [
                "tool_use_id": .string(decision.requestId),
                "session_id": .string(decision.sessionId.rawValue),
                "permission": .string(decision.approved ? "allow" : "deny"),
                "note": decision.note.map { .string($0) } ?? .null,
                "scope": .string(decision.resolvedScope.rawValue),
            ]
            try encoder.encode(claude).write(to: claudeURL, options: [.atomic])

        case .question(let answer):
            let url = paths.responseSidecarFile(agent: "answer", requestId: requestId)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload: [String: JSONValue] = [
                "prompt_id": .string(answer.promptId),
                "session_id": .string(answer.sessionId.rawValue),
                "text": .string(answer.text),
                "answered_at": .string(ISO8601DateFormatter().string(from: answer.answeredAt)),
            ]
            try encoder.encode(payload).write(to: url, options: [.atomic])
        }
    }

    /// Read a previously written response (tests / diagnostics).
    /// Tries canonical path first, then legacy flat/sanitized names.
    public func load(requestId: String) throws -> ResponseFileEnvelope? {
        for url in paths.responseFileCandidates(for: requestId) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ResponseFileEnvelope.self, from: data)
        }
        return nil
    }
}

/// On-disk shape for response files.
public enum ResponseFileEnvelope: Codable, Sendable, Equatable {
    case approval(ApprovalDecision)
    case question(QuestionAnswer)

    enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    enum Kind: String, Codable {
        case approval
        case question
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approval(let decision):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(decision, forKey: .payload)
        case .question(let answer):
            try container.encode(Kind.question, forKey: .kind)
            try container.encode(answer, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .approval:
            self = .approval(try container.decode(ApprovalDecision.self, forKey: .payload))
        case .question:
            self = .question(try container.decode(QuestionAnswer.self, forKey: .payload))
        }
    }
}

/// In-memory transport for unit tests.
public actor InMemoryResponseTransport: ResponseTransporting {
    public private(set) var submitted: [AgentResponse] = []

    public init() {}

    public func submit(_ response: AgentResponse) async throws {
        submitted.append(response)
    }

    public func allSubmitted() -> [AgentResponse] {
        submitted
    }

    public func clear() {
        submitted.removeAll()
    }
}

/// Multiplexes to several transports (file + in-memory mirror, etc.).
public struct MultiplexResponseTransport: ResponseTransporting {
    private let transports: [any ResponseTransporting]

    public init(_ transports: [any ResponseTransporting]) {
        self.transports = transports
    }

    public func submit(_ response: AgentResponse) async throws {
        var firstError: Error?
        for transport in transports {
            do {
                try await transport.submit(response)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
