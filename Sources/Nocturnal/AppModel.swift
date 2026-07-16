import AppKit
import Foundation
import Observation
import SwiftUI
import NocturnalCore

/// UI-facing observable façade over ``SessionStore`` and settings.
///
/// Core owns mutation; this type only mirrors snapshots for SwiftUI and
/// orchestrates overlay / sound lifecycle.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = SessionStoreSnapshot()
    private(set) var settings = AppSettings.default
    private(set) var statusMessage: String = "Starting…"
    private(set) var isSocketRunning = false
    private(set) var socketPathDisplay: String = "—"
    private(set) var appSupportPathDisplay: String = "—"
    private(set) var isBootstrapped = false

    /// Floating overlay expanded into the session panel.
    var isOverlayExpanded = false
    /// Selected session for keyboard navigation and detail focus.
    var selectedSessionID: SessionID?
    /// Session currently presenting an approval sheet (menu bar / window).
    var approvalSheetSessionID: SessionID?
    /// Session currently presenting a question sheet.
    var questionSheetSessionID: SessionID?
    /// Folders / local roots sheet (overlay header).
    var isFoldersSheetPresented = false
    /// When false (default), recovered idle stubs stay out of the main list.
    var showQuietSessions = false
    /// Session rows expanded to show last signal + timeline (UI-only).
    var expandedDetailSessionIDs: Set<SessionID> = []

    let store = SessionStore()
    private var settingsStore: SettingsStore?
    private var sessionPersistence: SessionPersistence?
    private var persistencePaths: PersistencePaths?
    private var socketServer: EventSocketServer?
    private var permissionBroker: PermissionBroker?
    private var observeTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var autoAllowTask: Task<Void, Never>?
    private var detailEnrichmentTask: Task<Void, Never>?
    private let jumpBack = JumpBackCoordinator()
    private var responseTransport: (any ResponseTransporting)?
    private let overlay = OverlayController()
    private var lastAttentionCount = 0
    private var systemReduceMotion = false
    /// Request ids already auto-allowed this process (avoid re-entry loops).
    private var autoAllowedRequestIDs: Set<String> = []
    /// Session ids recently enriched from local logs (throttle).
    private var lastDetailEnrichmentAt: [SessionID: Date] = [:]
    private let detailReader = CodexRolloutTailReader()

    /// Combined reduce-motion: user setting OR system accessibility preference.
    var prefersReducedMotion: Bool {
        settings.reduceMotion || systemReduceMotion
    }

    /// Sessions for list surfaces: live / attention first; recovery stubs hidden by default.
    var visibleSessions: [Session] {
        SessionPresentation.sessionsForDisplay(
            snapshot.sessions,
            limit: settings.maxVisibleSessions,
            includeQuiet: showQuietSessions
        )
    }

    var quietSessionCount: Int {
        SessionPresentation.quietSessionCount(in: snapshot.sessions)
    }

    func isSessionDetailExpanded(_ id: SessionID) -> Bool {
        expandedDetailSessionIDs.contains(id)
    }

    func toggleSessionDetail(_ id: SessionID) {
        if expandedDetailSessionIDs.contains(id) {
            expandedDetailSessionIDs.remove(id)
        } else {
            expandedDetailSessionIDs.insert(id)
            // Selecting for keyboard / approval rail consistency.
            selectedSessionID = id
        }
    }

    var recoveryStubCount: Int {
        SessionPresentation.recoveryStubCount(in: snapshot.sessions)
    }

    var attentionCount: Int {
        snapshot.sessionsNeedingAttention.count
    }

    var liveSessionCount: Int {
        snapshot.sessions.filter { !$0.isQuiet && !$0.isRecoveryStub || $0.state.needsAttention || $0.state == .running }.count
    }

    /// Session that drives the compact notch live line (attention → running → newest).
    var primaryLiveSession: Session? {
        SessionPresentation.primaryLiveSession(from: snapshot.sessions)
    }

    /// Compact pill / live status text.
    var liveActivityLine: String {
        SessionPresentation.liveActivityLine(
            sessions: snapshot.sessions,
            socketRunning: isSocketRunning
        )
    }

    /// Dynamic Island content for the compact notch.
    var pillIslandContent: PillIslandContent {
        PillIslandPresentation.content(
            sessions: snapshot.sessions,
            socketRunning: isSocketRunning
        )
    }

    /// Morph the compact island when mode / activity changes.
    func refreshPillIslandLayout() {
        guard settings.showFloatingPill, !isOverlayExpanded else { return }
        overlay.refreshIslandLayout(reduceMotion: prefersReducedMotion, animated: true)
    }

    var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return snapshot.sessions.first { $0.id == selectedSessionID }
    }

    var approvalSheetSession: Session? {
        guard let approvalSheetSessionID else { return nil }
        return snapshot.sessions.first { $0.id == approvalSheetSessionID }
    }

    var questionSheetSession: Session? {
        guard let questionSheetSessionID else { return nil }
        return snapshot.sessions.first { $0.id == questionSheetSessionID }
    }

    /// Path to bundled `nocturnal-setup` when packaged; otherwise bare command name.
    var setupBinaryDisplayPath: String {
        if let url = Bundle.main.url(
            forResource: "nocturnal-setup",
            withExtension: nil,
            subdirectory: "Helpers"
        ) {
            return url.path
        }
        if let url = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("nocturnal-setup"),
           FileManager.default.isExecutableFile(atPath: url.path)
        {
            return url.path
        }
        return SetupCommandFormatting.bareBinaryName
    }

    /// Canonical setup command shown in empty state / settings.
    /// Packaged helper paths are shell-quoted so spaces remain executable.
    var setupInstallCommand: String {
        SetupCommandFormatting.installAllCommand(binaryPath: setupBinaryDisplayPath)
    }

    /// True once bootstrap resolved Application Support (not the `"—"` placeholder).
    var canRevealAppSupport: Bool {
        persistencePaths != nil
            && SetupCommandFormatting.isAvailablePathDisplay(appSupportPathDisplay)
    }

    init() {
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Bootstrap asynchronously so `@main` stays light.
        Task { await self.bootstrap() }
    }

    /// Lightweight status line update for UI-only feedback (clipboard, etc.).
    func noteStatus(_ message: String) {
        statusMessage = message
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        observeSystemReduceMotion()

        do {
            // Core owns NOCTURNAL_SOCKET / app-support resolution.
            let paths = try PersistencePaths.resolve()
            persistencePaths = paths
            appSupportPathDisplay = paths.root.path
            socketPathDisplay = paths.socketURL.path

            let persistence = SessionPersistence(paths: paths)
            sessionPersistence = persistence
            await store.attachPersistence(persistence)
            settingsStore = SettingsStore(paths: paths)
            settings = try await settingsStore?.load() ?? .default
            responseTransport = FileResponseTransport(paths: paths)

            _ = await store.hydrate(from: persistence)
            // Relabel ses_* misfiled as Claude and soft-idle stuck Running rows.
            let repaired = await store.repairAllOpenCodeSessions()
            await store.setPolicy(SessionStorePolicy(autoPersist: true))
            statusMessage = repaired > 0
                ? "Listening… (repaired \(repaired) OpenCode sessions)"
                : "Listening…"
            await startSocket(path: paths.socketURL)

            // Live hooks are ready before optional disk catch-up begins.
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                await self?.reconcileLocalAgentSessions()
                // Re-repair after recovery injects old OpenCode rows.
                _ = await self?.store.repairAllOpenCodeSessions()
            }
        } catch {
            statusMessage = "Startup error: \(error.localizedDescription)"
            isSocketRunning = false
        }

        observeTask?.cancel()
        observeTask = Task { [store] in
            let stream = await store.snapshots()
            for await snap in stream {
                await MainActor.run {
                    self.handleSnapshot(snap)
                }
            }
        }

        isBootstrapped = true

        // Local layout probe only (simulation / packaged verification). Not a user setting.
        // Example: NOCTURNAL_OVERLAY_EXPANDED=1 open build/Nocturnal.app
        if ProcessInfo.processInfo.environment["NOCTURNAL_OVERLAY_EXPANDED"] == "1" {
            isOverlayExpanded = true
        }

        syncOverlayVisibility()
    }

    /// Recover session identity from local Codex / OpenCode / Grok storage.
    /// Lifecycle hooks / plugin remain authoritative for live state.
    private func reconcileLocalAgentSessions() async {
        await reconcileLocalCodexSessions()
        await reconcileLocalOpenCodeSessions()
        await reconcileLocalGrokSessions()
    }

    private func reconcileLocalCodexSessions() async {
        let scanner = CodexTranscriptScanner.resolve()
        let readLogs = settings.readLocalAgentLogs
        let reader = detailReader
        do {
            let snapshots = try await withThrowingTaskGroup(
                of: [CodexTranscriptSnapshot].self
            ) { group in
                group.addTask { try scanner.scan() }
                return try await group.next() ?? []
            }
            // Parse tails off the UI actor; apply snapshots back on the store.
            let details: [SessionDetailSnapshot] = readLogs
                ? await withTaskGroup(of: SessionDetailSnapshot?.self) { group in
                    for snapshot in snapshots {
                        let path = snapshot.transcriptPath
                        let sid = SessionID(snapshot.sessionId)
                        group.addTask {
                            reader.read(sessionId: sid, transcriptPath: path)
                        }
                    }
                    var out: [SessionDetailSnapshot] = []
                    for await detail in group {
                        if let detail { out.append(detail) }
                    }
                    return out
                }
                : []
            for snapshot in snapshots {
                _ = await store.apply(snapshot.envelope())
            }
            for detail in details {
                _ = await store.applyDetailSnapshot(detail)
            }
        } catch {
            // Optional catch-up; fail-open.
        }
    }

    private func reconcileLocalOpenCodeSessions() async {
        let scanner = OpenCodeSessionScanner.resolve()
        do {
            let snapshots = try await withThrowingTaskGroup(
                of: [OpenCodeSessionSnapshot].self
            ) { group in
                group.addTask { try scanner.scan() }
                return try await group.next() ?? []
            }
            for snapshot in snapshots {
                _ = await store.apply(snapshot.envelope())
            }
        } catch {
            // Reconciliation is optional and fail-open. Socket hooks still start.
        }
    }

    private func reconcileLocalGrokSessions() async {
        let scanner = GrokSessionScanner.resolve()
        do {
            let snapshots = try await withThrowingTaskGroup(
                of: [GrokSessionSnapshot].self
            ) { group in
                group.addTask { try scanner.scan() }
                return try await group.next() ?? []
            }
            for snapshot in snapshots {
                _ = await store.apply(snapshot.envelope())
            }
        } catch {
            // Optional catch-up; fail-open.
        }
    }

    // MARK: - Session actions

    /// Submit an approval decision. Returns `true` only after a successful local record.
    ///
    /// - Parameters:
    ///   - note: Optional feedback on deny (or annotate allow).
    ///   - scope: `.sessionTool` sticky-allows this tool name for the session (local only).
    @discardableResult
    func approve(
        _ request: ApprovalRequest,
        approved: Bool,
        note: String? = nil,
        scope: ApprovalScope = .once
    ) async -> Bool {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = ApprovalDecision(
            requestId: request.id,
            sessionId: request.sessionId,
            approved: approved,
            note: (trimmedNote?.isEmpty == false) ? trimmedNote : nil,
            scope: scope
        )
        do {
            try await responseTransport?.submit(.approval(decision))
            _ = await store.applyLocalResponse(.approval(decision))
            // Unblock PermissionRequest hook forwarder / OpenCode plugin waiting on the socket.
            await permissionBroker?.complete(
                approvalRequestId: request.id,
                approved: approved,
                message: decision.note
            )
            // Route product-specific decision transport via AgentRegistry / adapters.
            let profile = await permissionProfile(for: request)
            if profile.decisionTransport == .http
                || (profile.source == .opencode)
                || OpenCodeAgentAdapter().shouldDeliverHTTPPermission(for: request)
            {
                await deliverOpenCodePermission(
                    request: request,
                    approved: approved,
                    scope: scope
                )
            }
            if approved {
                statusMessage = scope == .sessionTool
                    ? "Approved for agent (session always-allow)"
                    : "Approved for agent"
            } else {
                statusMessage = decision.note == nil
                    ? "Denied for agent"
                    : "Denied for agent with note"
            }
            if approvalSheetSessionID == request.sessionId {
                approvalSheetSessionID = nil
            }
            return true
        } catch {
            statusMessage = "Response failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Resolve which agent profile owns a permission decision.
    private func permissionProfile(for request: ApprovalRequest) async -> AgentProfile {
        if let session = await store.session(id: request.sessionId) {
            return AgentRegistry.profile(for: session)
        }
        if let raw = request.raw["source"]?.stringValue {
            return AgentRegistry.profile(parsing: raw)
        }
        if OpenCodeSessionIdentity.isOpenCodeSessionId(request.sessionId.rawValue) {
            return AgentRegistry.opencode
        }
        return AgentRegistry.unknown
    }

    /// Best-effort OpenCode server permission reply (fail-open).
    private func deliverOpenCodePermission(
        request: ApprovalRequest,
        approved: Bool,
        scope: ApprovalScope
    ) async {
        guard let pair = OpenCodePermissionClient.correlation(from: request) else { return }
        var bases = OpenCodePermissionClient.defaultBaseURLs()
        if let raw = request.raw["opencode_server_url"]?.stringValue
            ?? request.raw["opencode_base_url"]?.stringValue
            ?? request.raw["server_url"]?.stringValue
            ?? request.raw["opencode_server_url"]?.stringValue,
           let url = URL(string: raw)
        {
            bases.insert(url, at: 0)
        }
        // Also check payload-style keys mirrored into approval raw.
        if let raw = request.raw["payload"]?.objectValue?["opencode_server_url"]?.stringValue,
           let url = URL(string: raw)
        {
            bases.insert(url, at: 0)
        }
        let client = OpenCodePermissionClient(baseURLs: bases)
        let response = OpenCodePermissionResponse.from(approved: approved, scope: scope)
        let ok = await client.reply(
            sessionId: pair.sessionId,
            permissionId: pair.permissionId,
            response: response
        )
        if ok {
            statusMessage = approved
                ? "Approved in OpenCode"
                : "Denied in OpenCode"
        }
    }

    /// Local folder roots for the Folders sheet (existence-checked).
    var folderEntries: [FolderEntry] {
        FolderEntry.resolve(appSupportPath: persistencePaths?.root.path)
    }

    func revealFolder(_ entry: FolderEntry) {
        revealInFinder(entry.path)
        noteStatus("Revealed \(entry.title)")
    }

    /// Submit a freeform / choice answer. Returns `true` only after a successful local record.
    @discardableResult
    func answer(_ prompt: QuestionPrompt, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Answer cannot be empty"
            return false
        }
        let answer = QuestionAnswer(
            promptId: prompt.id,
            sessionId: prompt.sessionId,
            text: trimmed
        )
        do {
            try await responseTransport?.submit(.question(answer))
            _ = await store.applyLocalResponse(.question(answer))
            // Local file-drop only — does not claim the external agent consumed it.
            statusMessage = "Recorded answer"
            if questionSheetSessionID == prompt.sessionId {
                questionSheetSessionID = nil
            }
            return true
        } catch {
            statusMessage = "Answer failed: \(error.localizedDescription)"
            return false
        }
    }

    func jumpBack(to session: Session) async {
        let context = session.jumpBack ?? JumpBackContext(workingDirectory: session.workingDirectory)
        let result = await jumpBack.jump(using: context)
        statusMessage = result.detail
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        // Ignore edits until bootstrap finishes so a late load cannot overwrite them.
        // Persist first; only then publish UI state — never optimistic mutate + try? save
        // (future-schema refusal must leave toggles unchanged and surface status).
        //
        // Load → mutate on MainActor → save(value). Do not send the non-Sendable
        // UI closure into SettingsStore.update (Swift 6 isolation).
        guard isBootstrapped, let store = settingsStore else { return }
        let previousPill = settings.showFloatingPill
        do {
            var next = try await store.load()
            mutate(&next)
            settings = try await store.save(next)
            if previousPill != settings.showFloatingPill {
                syncOverlayVisibility()
            }
            // Resize overlay if reduce motion or other prefs change while expanded.
            overlay.refreshLayout(
                expanded: isOverlayExpanded,
                reduceMotion: prefersReducedMotion
            )
        } catch let error as SettingsStoreError {
            switch error {
            case .newerSchemaOnDisk(let onDisk, let supported):
                statusMessage =
                    "Could not save settings (schema \(onDisk) is newer than this app supports, \(supported))"
            case .encodingFailed:
                statusMessage = "Could not save settings (encoding failed)"
            case .ioFailed(let detail):
                statusMessage = "Could not save settings: \(detail)"
            }
        } catch {
            statusMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func selectSession(_ id: SessionID?) {
        selectedSessionID = id
    }

    func selectNextSession(delta: Int) {
        let sessions = visibleSessions
        guard !sessions.isEmpty else {
            selectedSessionID = nil
            return
        }
        guard let current = selectedSessionID,
              let idx = sessions.firstIndex(where: { $0.id == current })
        else {
            selectedSessionID = sessions.first?.id
            return
        }
        let next = (idx + delta + sessions.count) % sessions.count
        selectedSessionID = sessions[next].id
    }

    func presentApproval(for session: Session) {
        guard session.pendingApproval != nil else { return }
        approvalSheetSessionID = session.id
        selectedSessionID = session.id
    }

    func presentQuestion(for session: Session) {
        guard session.pendingQuestion != nil else { return }
        questionSheetSessionID = session.id
        selectedSessionID = session.id
    }

    func dismissSheets() {
        approvalSheetSessionID = nil
        questionSheetSessionID = nil
    }

    // MARK: - Empty-state / setup helpers (UI orchestration only)

    func copySetupCommand() {
        copyToPasteboard(setupInstallCommand)
        noteStatus("Copied setup command")
    }

    func copySocketPath() {
        copyToPasteboard(socketPathDisplay)
        noteStatus("Copied socket path")
    }

    func revealAppSupport() {
        guard canRevealAppSupport, let paths = persistencePaths else {
            noteStatus("App Support path unavailable")
            return
        }
        revealInFinder(paths.root.path)
    }

    func revealSetupHelper() {
        if let url = Bundle.main.url(
            forResource: "nocturnal-setup",
            withExtension: nil,
            subdirectory: "Helpers"
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            noteStatus("Revealed nocturnal-setup")
            return
        }
        let macOSURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/nocturnal-setup")
        if FileManager.default.fileExists(atPath: macOSURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([macOSURL])
            noteStatus("Revealed nocturnal-setup")
            return
        }
        // Development run: copy the command so the user can still act.
        copySetupCommand()
        noteStatus("Copied setup command (helper not packaged)")
    }

    // MARK: - Overlay

    func toggleOverlayExpanded() {
        setOverlayExpanded(!isOverlayExpanded)
    }

    func setOverlayExpanded(_ expanded: Bool) {
        // Geometry: OverlayController / NSPanel is the sole size authority
        // (`NSHostingView.sizingOptions = []`). Do not wrap the model flag in a
        // SwiftUI size transaction that races AppKit `setFrame` — that restarted
        // layout and contributed to the constraint-cycle crash.
        // Content transitions (opacity) are driven by OverlayRootView's
        // `.animation(_:value:)` on `isOverlayExpanded`.
        //
        // Expand: grow panel first so expanded content has a stable frame.
        // Collapse: swap content first so the pill is not stretched during shrink.
        if expanded {
            overlay.setExpanded(true, reduceMotion: prefersReducedMotion)
            isOverlayExpanded = true
            if selectedSessionID == nil {
                selectedSessionID = visibleSessions.first?.id
            }
        } else {
            isOverlayExpanded = false
            overlay.setExpanded(false, reduceMotion: prefersReducedMotion)
        }
    }

    func collapseOverlay() {
        setOverlayExpanded(false)
    }

    func syncOverlayVisibility() {
        if settings.showFloatingPill {
            overlay.show(
                model: self,
                expanded: isOverlayExpanded,
                reduceMotion: prefersReducedMotion
            )
        } else {
            overlay.hide()
        }
    }

    // MARK: - Keyboard helpers

    /// Approve the selected session's pending request (keyboard: A / Return on approve focus).
    func approveSelected(approved: Bool) async {
        guard let session = selectedSession, let request = session.pendingApproval else { return }
        await approve(request, approved: approved)
    }

    // MARK: - Socket

    private func startSocket(path: URL) async {
        await stopSocket()
        let broker = PermissionBroker()
        permissionBroker = broker
        let server = EventSocketServer(path: path, permissionBroker: broker)
        socketServer = server
        do {
            let stream = try await server.start()
            isSocketRunning = true
            statusMessage = "Listening on socket"
            socketTask = Task { [store] in
                for await envelope in stream {
                    _ = await store.apply(envelope)
                }
            }
        } catch {
            isSocketRunning = false
            statusMessage = "Socket error: \(error.localizedDescription)"
        }
    }

    private func stopSocket() async {
        socketTask?.cancel()
        socketTask = nil
        await socketServer?.stop()
        socketServer = nil
        permissionBroker = nil
        isSocketRunning = false
    }

    // MARK: - Observation helpers

    private func handleSnapshot(_ snap: SessionStoreSnapshot) {
        let previousAttention = lastAttentionCount
        let previousMode = pillIslandContent.mode
        snapshot = snap
        lastAttentionCount = snap.sessionsNeedingAttention.count

        // Drop selection if session vanished.
        if let selectedSessionID,
           !snap.sessions.contains(where: { $0.id == selectedSessionID })
        {
            self.selectedSessionID = nil
        }

        // Soft attention cue when new work needs the user.
        if settings.soundEnabled,
           lastAttentionCount > previousAttention,
           previousAttention >= 0,
           isBootstrapped
        {
            playAttentionSound()
        }

        // Morph island size when activity mode changes (Dynamic Island dynamics).
        let nextMode = pillIslandContent.mode
        if previousMode != nextMode || lastAttentionCount != previousAttention {
            refreshPillIslandLayout()
        }

        scheduleLocalAlwaysAllow(from: snap)
        scheduleDetailEnrichment(from: snap)
    }

    /// Bounded local JSONL enrichment when `readLocalAgentLogs` is on (default).
    private func scheduleDetailEnrichment(from snap: SessionStoreSnapshot) {
        guard settings.readLocalAgentLogs else { return }
        let now = Date()
        var targets: [(SessionID, String)] = []
        for session in snap.sessions {
            guard let path = session.transcriptPath, !path.isEmpty else { continue }
            if let last = lastDetailEnrichmentAt[session.id],
               now.timeIntervalSince(last) < 8
            {
                continue
            }
            // Refresh when missing snapshot or stats lack tokens while path exists.
            if session.detailSnapshot == nil || session.stats.tokensIn == nil {
                targets.append((session.id, path))
            }
            if targets.count >= 4 { break }
        }
        guard !targets.isEmpty else { return }

        for (id, _) in targets {
            lastDetailEnrichmentAt[id] = now
        }

        detailEnrichmentTask?.cancel()
        detailEnrichmentTask = Task { [weak self, detailReader] in
            guard let self else { return }
            for (id, path) in targets {
                if Task.isCancelled { return }
                let snapshot = detailReader.read(sessionId: id, transcriptPath: path)
                guard let snapshot else { continue }
                _ = await self.store.applyDetailSnapshot(snapshot)
            }
        }
    }

    /// Auto-approve pending tools the user sticky-allowed for this session.
    /// Completes the PermissionRequest hook so Codex proceeds without a second prompt.
    private func scheduleLocalAlwaysAllow(from snap: SessionStoreSnapshot) {
        var pending: [ApprovalRequest] = []
        for session in snap.sessions {
            guard let approval = session.pendingApproval else { continue }
            let key = Session.normalizedToolName(approval.toolName)
            guard !key.isEmpty,
                  session.sessionAlwaysAllowTools.contains(key),
                  !autoAllowedRequestIDs.contains(approval.id)
            else { continue }
            pending.append(approval)
        }
        guard !pending.isEmpty else { return }

        for approval in pending {
            autoAllowedRequestIDs.insert(approval.id)
        }

        autoAllowTask?.cancel()
        autoAllowTask = Task { [weak self] in
            guard let self else { return }
            for approval in pending {
                if Task.isCancelled { return }
                // Completes broker via approve() so a waiting forwarder unblocks.
                _ = await self.approve(approval, approved: true, scope: .once)
            }
        }
    }

    private func playAttentionSound() {
        // Quiet system sound — not a custom jingle.
        NSSound(named: .init("Tink"))?.play()
    }

    private func observeSystemReduceMotion() {
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.overlay.refreshLayout(
                    expanded: self.isOverlayExpanded,
                    reduceMotion: self.prefersReducedMotion
                )
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
