import AppKit
import Foundation
import Observation
import SwiftUI
import NocturnalCore

/// UI-facing observable façade over ``SessionStore`` and settings.
///
/// Core owns mutation; this type only mirrors snapshots for SwiftUI and
/// orchestrates overlay / sound / demo lifecycle.
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

    let store = SessionStore()
    private var settingsStore: SettingsStore?
    private var sessionPersistence: SessionPersistence?
    private var persistencePaths: PersistencePaths?
    private var socketServer: EventSocketServer?
    private var observeTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private let jumpBack = JumpBackCoordinator()
    private var responseTransport: (any ResponseTransporting)?
    private let overlay = OverlayController()
    private var lastAttentionCount = 0
    private var systemReduceMotion = false

    /// Combined reduce-motion: user setting OR system accessibility preference.
    var prefersReducedMotion: Bool {
        settings.reduceMotion || systemReduceMotion
    }

    /// Sessions for list surfaces: attention-first, capped by settings.
    var visibleSessions: [Session] {
        SessionPresentation.sortedForDisplay(
            snapshot.sessions,
            limit: settings.maxVisibleSessions
        )
    }

    var attentionCount: Int {
        snapshot.sessionsNeedingAttention.count
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

            if !settings.demoMode {
                _ = await store.hydrate(from: persistence)
            }

            if settings.demoMode {
                // Demo fixtures stay in-memory only — never write synthetic sessions to disk.
                await store.setPolicy(SessionStorePolicy(autoPersist: false))
                await DemoSessions.load(into: store)
                statusMessage = "Demo mode"
            } else {
                await store.setPolicy(SessionStorePolicy(autoPersist: true))
                statusMessage = "Listening…"
                await startSocket(path: paths.socketURL)
            }
        } catch {
            // Fall back to in-memory demo so UI still works.
            await store.setPolicy(SessionStorePolicy(autoPersist: false))
            await DemoSessions.load(into: store)
            settings.demoMode = true
            statusMessage = "Demo fallback: \(error.localizedDescription)"
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
        syncOverlayVisibility()
    }

    // MARK: - Session actions

    func toggleDemoMode() async {
        settings.demoMode.toggle()
        try? await settingsStore?.save(settings)
        selectedSessionID = nil
        dismissSheets()

        if settings.demoMode {
            await stopSocket()
            await store.setPolicy(SessionStorePolicy(autoPersist: false))
            await DemoSessions.load(into: store)
            statusMessage = "Demo mode"
        } else if let paths = persistencePaths {
            await store.setPolicy(SessionStorePolicy(autoPersist: true))
            await store.reset()
            if let persistence = sessionPersistence {
                _ = await store.hydrate(from: persistence)
            }
            socketPathDisplay = paths.socketURL.path
            statusMessage = "Listening…"
            await startSocket(path: paths.socketURL)
        }
        syncOverlayVisibility()
    }

    func reloadDemoFixtures() async {
        await DemoSessions.load(into: store)
        statusMessage = "Demo fixtures reloaded"
    }

    func approve(_ request: ApprovalRequest, approved: Bool) async {
        let decision = ApprovalDecision(
            requestId: request.id,
            sessionId: request.sessionId,
            approved: approved
        )
        do {
            try await responseTransport?.submit(.approval(decision))
            _ = await store.applyLocalResponse(.approval(decision))
            // Local file-drop only — does not claim the external agent consumed it.
            statusMessage = approved ? "Recorded approval" : "Recorded denial"
            if approvalSheetSessionID == request.sessionId {
                approvalSheetSessionID = nil
            }
        } catch {
            statusMessage = "Response failed: \(error.localizedDescription)"
        }
    }

    func answer(_ prompt: QuestionPrompt, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Answer cannot be empty"
            return
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
        } catch {
            statusMessage = "Answer failed: \(error.localizedDescription)"
        }
    }

    func jumpBack(to session: Session) async {
        let context = session.jumpBack ?? JumpBackContext(workingDirectory: session.workingDirectory)
        let result = await jumpBack.jump(using: context)
        statusMessage = result.detail
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        let previousPill = settings.showFloatingPill
        mutate(&settings)
        try? await settingsStore?.save(settings)
        if previousPill != settings.showFloatingPill {
            syncOverlayVisibility()
        }
        // Resize overlay if reduce motion or other prefs change while expanded.
        overlay.refreshLayout(
            expanded: isOverlayExpanded,
            reduceMotion: prefersReducedMotion
        )
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

    // MARK: - Overlay

    func toggleOverlayExpanded() {
        setOverlayExpanded(!isOverlayExpanded)
    }

    func setOverlayExpanded(_ expanded: Bool) {
        let animation = NocturnalMotion.expand(reduceMotion: prefersReducedMotion)
        if let animation {
            withAnimation(animation) {
                isOverlayExpanded = expanded
            }
        } else {
            isOverlayExpanded = expanded
        }
        overlay.setExpanded(expanded, reduceMotion: prefersReducedMotion)
        if expanded, selectedSessionID == nil {
            selectedSessionID = visibleSessions.first?.id
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
        let server = EventSocketServer(path: path)
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
        isSocketRunning = false
    }

    // MARK: - Observation helpers

    private func handleSnapshot(_ snap: SessionStoreSnapshot) {
        let previousAttention = lastAttentionCount
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
}
