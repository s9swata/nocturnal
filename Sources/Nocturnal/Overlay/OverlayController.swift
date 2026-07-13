import AppKit
import QuartzCore
import SwiftUI

/// Hosts a non-activating floating pill near the menu bar / notch.
///
/// Notch-aware top-center placement, multi-display awareness, and expand/collapse
/// sizing live here. SwiftUI owns visual content via ``OverlayRootView``.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayRootView>?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private weak var model: AppModel?

    init() {}

    func show(model: AppModel, expanded: Bool, reduceMotion: Bool) {
        self.model = model

        if panel == nil {
            let root = OverlayRootView(model: model)
            let hosting = NSHostingView(rootView: root)
            hostingView = hosting

            let size = targetSize(expanded: expanded)
            hosting.frame = NSRect(origin: .zero, size: size)

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.acceptsMouseMovedEvents = true
            panel.contentView = hosting
            panel.isMovableByWindowBackground = false

            self.panel = panel
            installScreenObservers()
        } else {
            hostingView?.rootView = OverlayRootView(model: model)
        }

        setExpanded(expanded, reduceMotion: reduceMotion, animated: false)
        positionPanel(expanded: expanded)
        panel?.orderFrontRegardless()
    }

    func hide() {
        removeScreenObservers()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        model = nil
    }

    func setExpanded(_ expanded: Bool, reduceMotion: Bool, animated: Bool = true) {
        guard let panel, let screen = preferredScreen() else { return }
        let size = targetSize(expanded: expanded)
        let frame = frameForSize(size, on: screen)

        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }

        hostingView?.frame = NSRect(origin: .zero, size: size)
    }

    func refreshLayout(expanded: Bool, reduceMotion: Bool) {
        guard panel != nil else { return }
        setExpanded(expanded, reduceMotion: reduceMotion, animated: false)
        positionPanel(expanded: expanded)
    }

    // MARK: - Geometry

    private func targetSize(expanded: Bool) -> NSSize {
        if expanded {
            return NSSize(width: NocturnalLayout.panelWidth, height: NocturnalLayout.panelHeight)
        }
        return NSSize(width: NocturnalLayout.pillWidth, height: NocturnalLayout.pillHeight)
    }

    private func preferredScreen() -> NSScreen? {
        // Prefer the screen containing the mouse; fall back to main / first.
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func positionPanel(expanded: Bool) {
        guard let panel, let screen = preferredScreen() else { return }
        let size = targetSize(expanded: expanded)
        let frame = frameForSize(size, on: screen)
        panel.setFrame(frame, display: true)
    }

    /// Top-center or notch-safe placement. Uses `safeAreaInsets` when available
    /// so the pill sits below the camera housing on notched MacBooks.
    private func frameForSize(_ size: NSSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let full = screen.frame

        // Distance from top of screen to top of visible frame ≈ menu bar.
        let menuBarHeight = max(0, full.maxY - visible.maxY)

        // Notch / camera housing: on macOS 12+ safeAreaInsets.top can exceed menu bar.
        var topInset = menuBarHeight
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            topInset = max(menuBarHeight, safeTop)
        }

        // Sit a few points below the menu bar / notch, centered horizontally.
        let gap: CGFloat = 6
        let x = visible.midX - size.width / 2
        let y = full.maxY - topInset - size.height - gap

        // Clamp so multi-height panels stay on-screen.
        let minY = visible.minY + 8
        let clampedY = max(minY, min(y, visible.maxY - size.height - 4))
        let clampedX = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }

    private func installScreenObservers() {
        removeScreenObservers()
        let center = NotificationCenter.default
        screenObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                self.positionPanel(expanded: model.isOverlayExpanded)
            }
        }
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.orderFrontRegardless()
            }
        }
    }

    private func removeScreenObservers() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let spaceObserver {
            NotificationCenter.default.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }
}
