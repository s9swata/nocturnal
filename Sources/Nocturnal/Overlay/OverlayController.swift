import AppKit
import NocturnalCore
import QuartzCore
import SwiftUI

/// Hosts a non-activating floating pill near the menu bar / notch.
///
/// Notch-aware top-center placement, multi-display awareness, and expand/collapse
/// sizing live here. SwiftUI owns visual content via ``OverlayRootView``.
///
/// ## Geometry ownership
/// **`NSPanel` is the single source of truth for overlay dimensions.** The hosting
/// view is frame-based and must never drive window size via intrinsic/min/max
/// content sizing (`sizingOptions = []`). Leaving automatic hosting sizing enabled
/// caused a recursive Auto Layout cycle on modern macOS:
/// `updateAnimatedWindowSize` → `setFrameSize` → `invalidateSafeAreaInsets` →
/// `setNeedsUpdateConstraints` → NSGenericException (too many constraint passes).
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
            let screen = preferredScreen()
            let size = targetSize(expanded: expanded, on: screen)

            let root = OverlayRootView(model: model)
            let hosting = NSHostingView(rootView: root)
            // Frame-based host: panel owns size; content fills via autoresizing.
            configureFrameBasedHosting(hosting)
            hostingView = hosting

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
            panel.isMovableByWindowBackground = false

            // Assign content view before positioning so autoresizing binds to the
            // content rect. Do not manually rewrite hosting.frame after setFrame —
            // that fought Auto Layout and contributed to constraint thrash.
            panel.contentView = hosting
            configureClearChrome(on: panel, hosting: hosting)

            self.panel = panel
            installScreenObservers()

            // Stable order: create → configure host → set contentView → setFrame once.
            if let placeScreen = screen ?? NSScreen.main ?? NSScreen.screens.first {
                let frame = frameForSize(size, on: placeScreen)
                panel.setFrame(frame, display: true)
            }
        } else {
            hostingView?.rootView = OverlayRootView(model: model)
            if let hostingView {
                configureFrameBasedHosting(hostingView)
                configureClearChrome(on: panel, hosting: hostingView)
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

        // Sole geometry animation path: AppKit panel frame only.
        // Hosting view does not participate in size (sizingOptions empty).
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // Allow the animator to change frame without re-enabling content sizing.
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }

        // Content view bounds track the panel content rect via autoresizing —
        // do not assign hostingView.frame here (redundant and layout-hostile).
        if let hostingView {
            configureClearChrome(on: panel, hosting: hostingView)
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

    // MARK: - Host layout / chrome contracts (production helpers)

    /// Frame-based hosting + clear non-opaque chrome — production configuration
    /// that must stay true to avoid the constraint-cycle crash and square margins.
    struct HostLayoutConfiguration: Equatable, Sendable {
        /// `NSHostingSizingOptions` must be empty so intrinsic content cannot resize the panel.
        var sizingOptionsEmpty: Bool
        /// Hosting view resizes with the panel content rect (width + height).
        var autoresizesWithPanel: Bool
        var panelIsOpaque: Bool
        var panelHasShadow: Bool
        var panelBackgroundIsClear: Bool
        var hostingLayerIsClear: Bool
    }

    /// Expected production host layout / chrome contract.
    static var expectedHostLayout: HostLayoutConfiguration {
        HostLayoutConfiguration(
            sizingOptionsEmpty: true,
            autoresizesWithPanel: true,
            panelIsOpaque: false,
            panelHasShadow: false,
            panelBackgroundIsClear: true,
            hostingLayerIsClear: true
        )
    }

    /// Legacy name used by chrome-only call sites; same contract as ``expectedHostLayout``.
    static var expectedCompactChrome: HostLayoutConfiguration { expectedHostLayout }

    /// Live configuration of the current panel, if shown.
    var hostLayoutConfiguration: HostLayoutConfiguration? {
        guard let panel, let hostingView else { return nil }
        let bgClear: Bool = {
            guard let color = panel.backgroundColor else { return false }
            return color.alphaComponent < 0.01
        }()
        let layerClear: Bool = {
            guard let cg = hostingView.layer?.backgroundColor else {
                // No fill is acceptable (clear by default when non-opaque).
                return hostingView.layer?.isOpaque != true
            }
            let color = NSColor(cgColor: cg)
            return (color?.alphaComponent ?? 0) < 0.01 && hostingView.layer?.isOpaque != true
        }()
        let mask = hostingView.autoresizingMask
        let autoresizes = mask.contains(.width) && mask.contains(.height)
        return HostLayoutConfiguration(
            sizingOptionsEmpty: hostingView.sizingOptions.isEmpty,
            autoresizesWithPanel: autoresizes,
            panelIsOpaque: panel.isOpaque,
            panelHasShadow: panel.hasShadow,
            panelBackgroundIsClear: bgClear,
            hostingLayerIsClear: layerClear
        )
    }

    /// Live configuration alias (compact chrome naming used in older docs/tests).
    var compactChromeConfiguration: HostLayoutConfiguration? { hostLayoutConfiguration }

    /// Current panel frame for debug / Accessibility probes (nil if not shown).
    var panelFrame: NSRect? { panel?.frame }

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

    /// Top-center or notch-safe placement via Core pure geometry.
    private func frameForSize(_ size: NSSize, on screen: NSScreen) -> NSRect {
        let rect = OverlayGeometry.topCenterFrame(
            size: CGSize(width: size.width, height: size.height),
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            gap: 6,
            edgeInset: OverlayGeometry.screenEdgeInset
        )
        return NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// Configure hosting as a frame-based content view that never drives panel size.
    /// Applies ``OverlayHostLayoutPolicy`` (empty sizing options + autoresizing).
    private func configureFrameBasedHosting(_ hosting: NSHostingView<OverlayRootView>) {
        // Disable min/intrinsic/max/preferred automatic window sizing (macOS 13+).
        // Empty option set is the supported way to make AppKit the sole size authority.
        // Matches OverlayHostLayoutPolicy.disabledHostingSizingOptionsRawValue == 0.
        hosting.sizingOptions = NSHostingSizingOptions(
            rawValue: OverlayHostLayoutPolicy.disabledHostingSizingOptionsRawValue
        )
        // Do not inherit window safe-area driven invalidation loops for this borderless panel.
        if #available(macOS 13.3, *) {
            hosting.safeAreaRegions = []
        }
        hosting.translatesAutoresizingMaskIntoConstraints = true
        if OverlayHostLayoutPolicy.autoresizesWidthAndHeight {
            hosting.autoresizingMask = [.width, .height]
        }
        configureClearHostingLayer(hosting)
    }

    private func configureClearHostingLayer(_ hosting: NSHostingView<OverlayRootView>) {
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    private func configureClearChrome(on panel: NSPanel?, hosting: NSHostingView<OverlayRootView>) {
        panel?.backgroundColor = .clear
        panel?.isOpaque = false
        panel?.hasShadow = false
        configureClearHostingLayer(hosting)
        if let content = panel?.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            content.layer?.isOpaque = false
        }
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
