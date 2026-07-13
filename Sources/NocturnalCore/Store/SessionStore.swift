import Foundation

/// Snapshot of store contents suitable for UI observation (Sendable value).
public struct SessionStoreSnapshot: Sendable, Equatable {
    public var sessions: [Session]
    public var revision: UInt64
    public var unknownEventCount: UInt64

    public init(
        sessions: [Session] = [],
        revision: UInt64 = 0,
        unknownEventCount: UInt64 = 0
    ) {
        self.sessions = sessions
        self.revision = revision
        self.unknownEventCount = unknownEventCount
    }

    public var sessionsNeedingAttention: [Session] {
        sessions.filter { $0.state.needsAttention }
    }
}

/// Policy for bounding in-memory session growth.
public struct SessionStorePolicy: Sendable, Equatable {
    /// Hard cap on sessions retained in memory (after pruning preference order).
    public var maxSessions: Int
    /// Terminal sessions older than this are eligible for prune first.
    public var terminalRetention: TimeInterval
    /// When true, auto-persist after each mutation if a persistence actor is attached.
    public var autoPersist: Bool

    public static let `default` = SessionStorePolicy(
        maxSessions: 64,
        terminalRetention: 60 * 60 * 24,
        autoPersist: true
    )

    public init(
        maxSessions: Int = 64,
        terminalRetention: TimeInterval = 60 * 60 * 24,
        autoPersist: Bool = true
    ) {
        self.maxSessions = max(1, maxSessions)
        self.terminalRetention = max(0, terminalRetention)
        self.autoPersist = autoPersist
    }
}

/// Actor-owned source of truth for live and recent sessions.
///
/// All mutations enter through ``apply(_:)`` or explicit CRUD helpers.
/// UI layers should subscribe via ``snapshots`` / ``currentSnapshot()`` and
/// never hold mutable session state of their own.
public actor SessionStore {
    public static let defaultRecentEventLimit = 64

    private var sessionsByID: [SessionID: Session] = [:]
    private var order: [SessionID] = []
    private var revision: UInt64 = 0
    private var unknownEventCount: UInt64 = 0
    private let recentEventLimit: Int
    private let decoder: EventDecoding
    private var policy: SessionStorePolicy
    private var persistence: SessionPersistence?
    private var continuations: [UUID: AsyncStream<SessionStoreSnapshot>.Continuation] = [:]

    public init(
        recentEventLimit: Int = SessionStore.defaultRecentEventLimit,
        decoder: EventDecoding = CompositeEventDecoder(),
        policy: SessionStorePolicy = .default,
        persistence: SessionPersistence? = nil
    ) {
        self.recentEventLimit = max(1, recentEventLimit)
        self.decoder = decoder
        self.policy = policy
        self.persistence = persistence
    }

    // MARK: - Configuration

    public func setPolicy(_ policy: SessionStorePolicy) {
        self.policy = policy
        pruneToPolicy(now: Date())
        bumpAndPublish()
    }

    public func attachPersistence(_ persistence: SessionPersistence?) {
        self.persistence = persistence
    }

    /// Load sessions from disk. Existing in-memory sessions with the same id are
    /// replaced only when the disk copy is newer (by `updatedAt`).
    @discardableResult
    public func hydrate(from persistence: SessionPersistence? = nil) async -> Int {
        let store = persistence ?? self.persistence
        guard let store else { return 0 }
        let loaded: [Session]
        do {
            loaded = try await store.loadAll()
        } catch {
            return 0
        }
        var merged = 0
        for session in loaded {
            if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
            if !order.contains(session.id) {
                order.append(session.id)
            }
            merged += 1
        }
        // Keep most-recently updated first.
        order.sort { lhs, rhs in
            let l = sessionsByID[lhs]?.updatedAt ?? .distantPast
            let r = sessionsByID[rhs]?.updatedAt ?? .distantPast
            return l > r
        }
        pruneToPolicy(now: Date())
        bumpAndPublish()
        return merged
    }

    // MARK: - Reads

    public func currentSnapshot() -> SessionStoreSnapshot {
        SessionStoreSnapshot(
            sessions: orderedSessions(),
            revision: revision,
            unknownEventCount: unknownEventCount
        )
    }

    public func session(id: SessionID) -> Session? {
        sessionsByID[id]
    }

    public func allSessions() -> [Session] {
        orderedSessions()
    }

    /// Async stream of snapshots. New subscribers receive the current snapshot first.
    public func snapshots() -> AsyncStream<SessionStoreSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionStoreSnapshot>.makeStream()
        continuations[id] = continuation
        continuation.yield(currentSnapshot())
        continuation.onTermination = { _ in
            Task { await self.removeContinuation(id) }
        }
        return stream
    }

    // MARK: - Mutations

    /// Decode and apply an envelope. Unknown events update metadata without crashing.
    ///
    /// **Stale-event policy:** envelopes older than the session's `updatedAt` never
    /// rewind state or revive a terminal session. Metadata / title / jump-back may
    /// still merge when useful, but lifecycle state is left alone.
    @discardableResult
    public func apply(_ envelope: EventEnvelope) async -> Session {
        let decoded = decoder.decode(envelope)
        if decoded.isUnknown {
            unknownEventCount &+= 1
        }

        let sessionID = SessionID(envelope.sessionId)
        let source: AgentSource = {
            if envelope.source != .unknown { return envelope.source }
            return decoded.inferredSource
        }()

        var session = sessionsByID[sessionID] ?? Session(
            id: sessionID,
            source: source,
            state: .idle,
            title: decoded.titleHint ?? "",
            createdAt: envelope.timestamp,
            updatedAt: envelope.timestamp
        )

        let isExisting = sessionsByID[sessionID] != nil
        let isStaleEvent = isExisting && envelope.timestamp < session.updatedAt
        let isTerminal = session.state.isTerminal
        // Older events must not rewind or revive terminal / newer sessions.
        let allowLifecycleMutation = !isStaleEvent && !(isTerminal && envelope.timestamp <= session.updatedAt)

        // Prefer a known source over unknown when we learn more.
        if session.source == .unknown, source != .unknown {
            session.source = source
        }

        if let title = decoded.titleHint, !title.isEmpty {
            session.title = title
        }
        if let summary = decoded.summaryHint, allowLifecycleMutation || !isTerminal {
            // Allow summary refresh on non-lifecycle stale events only when not terminal revival.
            if allowLifecycleMutation || !isStaleEvent {
                session.summary = summary
            }
        }
        if let cwd = decoded.workingDirectory {
            session.workingDirectory = cwd
            var jump = session.jumpBack ?? JumpBackContext()
            jump.workingDirectory = cwd
            session.jumpBack = jump
        }

        if allowLifecycleMutation {
            if let state = decoded.state {
                session.state = state
            }
            if let approval = decoded.approval {
                session.pendingApproval = approval
                session.state = .waitingForApproval
            }
            if let question = decoded.question {
                session.pendingQuestion = question
                session.state = .waitingForInput
            }
            if decoded.clearApproval {
                session.pendingApproval = nil
                if session.state == .waitingForApproval {
                    session.state = decoded.state ?? .running
                }
            }
            if decoded.clearQuestion {
                session.pendingQuestion = nil
                if session.state == .waitingForInput {
                    session.state = decoded.state ?? .running
                }
            }
        }

        if let jump = decoded.jumpBack {
            var merged = session.jumpBack ?? JumpBackContext()
            if let cwd = jump.workingDirectory { merged.workingDirectory = cwd }
            if let bid = jump.terminalBundleID { merged.terminalBundleID = bid }
            if let tab = jump.terminalTabTitle { merged.terminalTabTitle = tab }
            if let editor = jump.editorURL { merged.editorURL = editor }
            if let deep = jump.codexDeepLink { merged.codexDeepLink = deep }
            if let pid = jump.processIdentifier { merged.processIdentifier = pid }
            if !jump.extra.isEmpty {
                merged.extra.merge(jump.extra) { _, new in new }
            }
            session.jumpBack = merged
        }

        // Merge raw metadata for unknown / partial events.
        for (key, value) in envelope.raw {
            session.rawMetadata[key] = value
        }
        for (key, value) in decoded.extraMetadata {
            session.rawMetadata[key] = value
        }
        if let sourceRaw = envelope.sourceRaw {
            session.rawMetadata["sourceRaw"] = .string(sourceRaw)
        }

        session.lastEventType = envelope.eventType
        // Never move updatedAt backwards.
        if envelope.timestamp >= session.updatedAt {
            session.updatedAt = envelope.timestamp
        }
        session.recentEventIDs.append(envelope.id)
        if session.recentEventIDs.count > recentEventLimit {
            session.recentEventIDs.removeFirst(session.recentEventIDs.count - recentEventLimit)
        }

        await upsert(session, persist: true)
        return session
    }

    /// Apply a local user response (approval / answer) and optionally clear pending prompts.
    ///
    /// **ID match required:** mismatched `requestId` / `promptId` is a no-op (does not
    /// force the session to `.running` or clear a different pending prompt).
    @discardableResult
    public func applyLocalResponse(_ response: AgentResponse) async -> Session? {
        switch response {
        case .approval(let decision):
            guard var session = sessionsByID[decision.sessionId] else { return nil }
            guard session.pendingApproval?.id == decision.requestId else {
                // Mismatched id — leave state untouched.
                return session
            }
            session.pendingApproval = nil
            session.state = .running
            session.summary = decision.approved ? "Approved" : "Denied"
            session.updatedAt = decision.decidedAt
            await upsert(session, persist: true)
            return session
        case .question(let answer):
            guard var session = sessionsByID[answer.sessionId] else { return nil }
            guard session.pendingQuestion?.id == answer.promptId else {
                return session
            }
            session.pendingQuestion = nil
            session.state = .running
            session.summary = "Answered"
            session.updatedAt = answer.answeredAt
            await upsert(session, persist: true)
            return session
        }
    }

    public func upsert(_ session: Session) async {
        await upsert(session, persist: true)
    }

    public func remove(id: SessionID) async {
        guard sessionsByID.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        if let persistence, policy.autoPersist {
            try? await persistence.delete(id: id)
        }
        bumpAndPublish()
    }

    /// Replace all sessions. Duplicate ids are resolved **last-wins** without trapping.
    public func replaceAll(_ sessions: [Session]) async {
        var map: [SessionID: Session] = [:]
        var seenOrder: [SessionID] = []
        for session in sessions {
            let isNew = map[session.id] == nil
            map[session.id] = session
            if isNew {
                seenOrder.append(session.id)
            }
            // Last-wins: keep first-seen order position; value is the last occurrence.
        }
        sessionsByID = map
        order = seenOrder
        pruneToPolicy(now: Date())
        if let persistence, policy.autoPersist {
            // Best-effort full rewrite: delete missing, save current.
            if let existing = try? await persistence.loadAll() {
                let keep = Set(map.keys)
                for old in existing where !keep.contains(old.id) {
                    try? await persistence.delete(id: old.id)
                }
            }
            for session in orderedSessions() {
                try? await persistence.save(session)
            }
        }
        bumpAndPublish()
    }

    public func reset() async {
        let ids = order
        sessionsByID = [:]
        order = []
        if let persistence, policy.autoPersist {
            for id in ids {
                try? await persistence.delete(id: id)
            }
        }
        bumpAndPublish()
    }

    /// Force-save all in-memory sessions.
    public func persistAll() async {
        guard let persistence else { return }
        for session in orderedSessions() {
            try? await persistence.save(session)
        }
    }

    // MARK: - Private

    private func upsert(_ session: Session, persist: Bool) async {
        let isNew = sessionsByID[session.id] == nil
        sessionsByID[session.id] = session
        if isNew {
            order.insert(session.id, at: 0)
        } else if let idx = order.firstIndex(of: session.id), idx != 0 {
            order.remove(at: idx)
            order.insert(session.id, at: 0)
        }
        pruneToPolicy(now: Date())
        if persist, policy.autoPersist, let persistence {
            try? await persistence.save(session)
        }
        bumpAndPublish()
    }

    private func orderedSessions() -> [Session] {
        order.compactMap { sessionsByID[$0] }
    }

    /// Prefer keeping attention-needed and non-terminal sessions.
    private func pruneToPolicy(now: Date) {
        // Drop aged terminal sessions first.
        if policy.terminalRetention > 0 {
            let cutoff = now.addingTimeInterval(-policy.terminalRetention)
            let staleTerminal = order.filter { id in
                guard let s = sessionsByID[id] else { return false }
                return s.state.isTerminal && s.updatedAt < cutoff
            }
            for id in staleTerminal {
                sessionsByID.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
        }

        guard order.count > policy.maxSessions else { return }

        // Evict least important: terminal first (oldest), then idle/unknown, never attention.
        func evictionScore(_ id: SessionID) -> (Int, Date) {
            guard let s = sessionsByID[id] else { return (0, .distantPast) }
            let tier: Int
            if s.state.needsAttention {
                tier = 100
            } else if s.state == .running {
                tier = 80
            } else if s.state == .idle || s.state == .unknown {
                tier = 40
            } else if s.state.isTerminal {
                tier = 10
            } else {
                tier = 50
            }
            return (tier, s.updatedAt)
        }

        while order.count > policy.maxSessions {
            guard let victim = order.min(by: { lhs, rhs in
                let l = evictionScore(lhs)
                let r = evictionScore(rhs)
                if l.0 != r.0 { return l.0 < r.0 }
                return l.1 < r.1
            }) else { break }
            // Never prune the only attention session if everything needs attention —
            // still respect hard cap by removing oldest attention as last resort.
            sessionsByID.removeValue(forKey: victim)
            order.removeAll { $0 == victim }
        }
    }

    private func bumpAndPublish() {
        revision &+= 1
        let snapshot = currentSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

/// Result of mapping an ``EventEnvelope`` into session fields.
public struct DecodedEvent: Sendable, Equatable {
    public var inferredSource: AgentSource
    public var state: SessionState?
    public var titleHint: String?
    public var summaryHint: String?
    public var workingDirectory: String?
    public var approval: ApprovalRequest?
    public var question: QuestionPrompt?
    public var clearApproval: Bool
    public var clearQuestion: Bool
    public var jumpBack: JumpBackContext?
    public var extraMetadata: [String: JSONValue]
    /// True when the event type is not in the implemented schema set.
    public var isUnknown: Bool

    public init(
        inferredSource: AgentSource = .unknown,
        state: SessionState? = nil,
        titleHint: String? = nil,
        summaryHint: String? = nil,
        workingDirectory: String? = nil,
        approval: ApprovalRequest? = nil,
        question: QuestionPrompt? = nil,
        clearApproval: Bool = false,
        clearQuestion: Bool = false,
        jumpBack: JumpBackContext? = nil,
        extraMetadata: [String: JSONValue] = [:],
        isUnknown: Bool = false
    ) {
        self.inferredSource = inferredSource
        self.state = state
        self.titleHint = titleHint
        self.summaryHint = summaryHint
        self.workingDirectory = workingDirectory
        self.approval = approval
        self.question = question
        self.clearApproval = clearApproval
        self.clearQuestion = clearQuestion
        self.jumpBack = jumpBack
        self.extraMetadata = extraMetadata
        self.isUnknown = isUnknown
    }
}
