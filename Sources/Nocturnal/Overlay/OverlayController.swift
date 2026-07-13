import AppKit
import NocturnalCore
import QuartzCore
import SwiftUI

/// Hosts a non-activating floating pill near the menu bar / notch.
///
/// Notch-aware top-center placement, multi-display awareness, and expand/collapse
/// sizing live here. SwiftUI owns visual content via ``OverlayRootView``.
///
/// ## Compact chrome (no rectangular backing)
/// The compact panel intentionally:
/// - Uses a clear, non-opaque `NSPanel`
/// - Disables AppKit **window** shadow (`hasShadow = false`) — the system shadow
///   is rectangular around the content rect and reads as square margins
/// - Clears `NSHostingView` / content layer backgrounds
/// - Relies on SwiftUI capsule fill + capsule-shaped shadow only
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
            configureClearHosting(hosting)
            hostingView = hosting

            let size = targetSize(expanded: expanded, on: preferredScreen())
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
            // Critical: native window shadow is a rectangular halo around contentRect.
            // Compact pill uses SwiftUI capsule shadow only.
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.acceptsMouseMovedEvents = true
            panel.contentView = hosting
            panel.isMovableByWindowBackground = false

            // Ensure the content view chain never paints an opaque rectangle.
            if let content = panel.contentView {
                content.wantsLayer = true
                content.layer?.backgroundColor = NSColor.clear.cgColor
                content.layer?.isOpaque = false
            }

            self.panel = panel
            installScreenObservers()
        } else {
            hostingView?.rootView = OverlayRootView(model: model)
            if let hostingView {
                configureClearHosting(hostingView)
            }
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
        let size = targetSize(expanded: expanded, on: screen)
        let frame = frameForSize(size, on: screen)

        // Keep AppKit window shadow off in both modes; SwiftUI draws soft shadows
        // that match capsule / rounded-rect chrome.
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false

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
        if let hostingView {
            configureClearHosting(hostingView)
        }
    }

    func refreshLayout(expanded: Bool, reduceMotion: Bool) {
        guard panel != nil else { return }
        setExpanded(expanded, reduceMotion: reduceMotion, animated: false)
        positionPanel(expanded: expanded)
    }

    // MARK: - Geometry (Core policy — see ``OverlayGeometry``)

    /// Ideal compact size — never grows with screen.
    static var compactSize: NSSize {
        let size = OverlayGeometry.compactSize
        return NSSize(width: size.width, height: size.height)
    }

    /// Ideal expanded size before screen clamp.
    static var idealExpandedSize: NSSize {
        let size = OverlayGeometry.idealExpandedSize
        return NSSize(width: size.width, height: size.height)
    }

    /// Clamp expanded dimensions to a visible frame (multi-display / small screens).
    static func clampedExpandedSize(visibleFrame: NSRect) -> NSSize {
        // NSRect is CGRect on Apple platforms; Core owns the clamp policy.
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: visibleFrame)
        return NSSize(width: size.width, height: size.height)
    }

    /// Configuration snapshot for regression tests (no live window required).
    struct CompactChromeConfiguration: Equatable, Sendable {
        var panelIsOpaque: Bool
        var panelHasShadow: Bool
        var panelBackgroundIsClear: Bool
        var hostingDrawsBackground: Bool
    }

    /// Expected compact-panel chrome — documents the square-margin fix contract.
    static var expectedCompactChrome: CompactChromeConfiguration {
        CompactChromeConfiguration(
            panelIsOpaque: false,
            panelHasShadow: false,
            panelBackgroundIsClear: true,
            hostingDrawsBackground: false
        )
    }

    /// Live configuration of the current panel, if shown.
    var compactChromeConfiguration: CompactChromeConfiguration? {
        guard let panel, let hostingView else { return nil }
        let bgClear: Bool = {
            guard let color = panel.backgroundColor else { return false }
            return color.alphaComponent < 0.01
        }()
        return CompactChromeConfiguration(
            panelIsOpaque: panel.isOpaque,
            panelHasShadow: panel.hasShadow,
            panelBackgroundIsClear: bgClear,
            hostingDrawsBackground: hostingView.layer?.backgroundColor != nil
                && hostingView.layer?.backgroundColor != NSColor.clear.cgColor
                && (hostingView.layer?.isOpaque == true)
        )
    }

    // MARK: - Private geometry

    private func targetSize(expanded: Bool, on screen: NSScreen?) -> NSSize {
        if expanded {
            guard let screen else { return Self.idealExpandedSize }
            return Self.clampedExpandedSize(visibleFrame: screen.visibleFrame)
        }
        return Self.compactSize
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
        let size = targetSize(expanded: expanded, on: screen)
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
        let inset = NocturnalLayout.screenEdgeInset
        let minY = visible.minY + inset
        let clampedY = max(minY, min(y, visible.maxY - size.height - 4))
        let clampedX = min(max(x, visible.minX + inset), visible.maxX - size.width - inset)

        return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }

    private func configureClearHosting(_ hosting: NSHostingView<OverlayRootView>) {
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        // Avoid any default material / opaque fill from the hosting view.
        if #available(macOS 14.0, *) {
            // NSHostingView on modern macOS respects clear layer when non-opaque.
        }
        hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
