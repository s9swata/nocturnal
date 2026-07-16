import Foundation
import Testing
@testable import NocturnalCore

/// Geometry and host-layout contracts for the floating overlay.
///
/// AppKit pixel rendering cannot be unit-tested under CLT. These tests exercise
/// production ``OverlayGeometry`` / ``OverlayHostLayoutPolicy`` so clamp, placement,
/// and the empty-`sizingOptions` crash-prevention contract stay locked without
/// restating free-floating magic numbers in isolation.
struct OverlayGeometryTests {

    // MARK: - Compact / expanded targets (production policy)

    /// Compact island stays a drip (not a panel); width may clamp on tiny screens.
    @Test func compactTargetSizeStaysIslandFootprint() {
        let frames = [
            CGRect(x: 0, y: 0, width: 320, height: 480),
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 0, width: 3024, height: 1964),
        ]
        for visible in frames {
            let size = OverlayGeometry.targetSize(expanded: false, visibleFrame: visible)
            // Pill discipline: island chrome, never a card/panel footprint.
            #expect(size.width < OverlayGeometry.idealExpandedWidth * 0.6)
            #expect(size.height < 64)
            #expect(size.width >= OverlayGeometry.islandMinWidth - 1)
            #expect(size.height > 24)
            #expect(size.height < OverlayGeometry.minExpandedHeight)
        }
        // Normal laptop: full liveCompact width.
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(
            OverlayGeometry.targetSize(
                expanded: false,
                visibleFrame: laptop,
                islandMode: .liveCompact
            ) == OverlayGeometry.islandSize(for: .liveCompact)
        )
    }

    @Test func expandedTargetUsesClampPolicyOnSmallScreens() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 500)
        let size = OverlayGeometry.targetSize(expanded: true, visibleFrame: tiny)
        #expect(size == OverlayGeometry.clampedExpandedSize(visibleFrame: tiny))
        #expect(size.width < OverlayGeometry.idealExpandedWidth)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func targetSizePicksCompactOrClampedExpanded() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(OverlayGeometry.targetSize(expanded: false, visibleFrame: visible)
            == OverlayGeometry.compactSize)
        #expect(OverlayGeometry.targetSize(expanded: true, visibleFrame: visible)
            == OverlayGeometry.idealExpandedSize)
    }

    // MARK: - Screen clamp (real policy math)

    @Test func expandedClampsToSmallVisibleFrame() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 500)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: tiny)
        let maxW = tiny.width - OverlayGeometry.panelScreenPadding
        let maxH = tiny.height - OverlayGeometry.panelScreenPadding
        #expect(size.width == maxW)
        #expect(size.height == maxH)
        #expect(size.width < OverlayGeometry.idealExpandedWidth)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func expandedDoesNotExceedIdealOnLargeScreen() {
        let large = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: large)
        #expect(size == OverlayGeometry.idealExpandedSize)
    }

    /// Confirmed regression display: 1440-point-wide laptop must keep full ideal
    /// expanded size — empty-state content must not compress the panel.
    @Test func expandedStaysIdealOn1440PointDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: visible)
        #expect(size == OverlayGeometry.idealExpandedSize)
        #expect(size.width == OverlayGeometry.idealExpandedWidth)
        #expect(size.height == OverlayGeometry.idealExpandedHeight)
    }

    @Test func expandedHeightClampsWhenVisibleIsShort() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: short)
        #expect(size.width == OverlayGeometry.idealExpandedWidth)
        #expect(size.height == 500 - OverlayGeometry.panelScreenPadding)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func clampRespectsMinimumFloorsOnTinyDisplays() {
        let microscopic = CGRect(x: 0, y: 0, width: 50, height: 50)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: microscopic)
        #expect(size.width >= OverlayGeometry.minExpandedWidth)
        #expect(size.height >= OverlayGeometry.minExpandedHeight)
    }

    // MARK: - Placement (notch-hug production policy)

    @Test func notchHugPlacesCompactFlushToScreenTop() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875) // 25pt menu bar
        let size = OverlayGeometry.compactSize
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            gap: 0,
            hugTop: true
        )
        #expect(frame.size == size)
        #expect(abs(frame.midX - screen.midX) < 0.5)
        // Flush to absolute top — extends through the menu-bar / notch band.
        #expect(abs(frame.maxY - screen.maxY) < 0.5)
        #expect(abs(frame.minY - (screen.maxY - size.height)) < 0.5)
    }

    @Test func notchHugIgnoresSafeAreaTop() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let size = OverlayGeometry.compactSize
        let safeTop: CGFloat = 37
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: safeTop,
            gap: 0,
            hugTop: true
        )
        // Safe area must not push the extension below the notch.
        #expect(abs(frame.maxY - screen.maxY) < 0.5)
    }

    @Test func expandedAlsoHugsScreenTop() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = OverlayGeometry.targetSize(expanded: true, visibleFrame: visible)
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            hugTop: true
        )
        #expect(frame.size == OverlayGeometry.idealExpandedSize)
        #expect(abs(frame.maxY - screen.maxY) < 0.5)
        #expect(frame.width > OverlayGeometry.minExpandedWidth)
        #expect(frame.height > OverlayGeometry.minExpandedHeight)
    }

    @Test func legacyBelowChromePlacementStillWorks() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = OverlayGeometry.compactSize
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            gap: 6,
            hugTop: false
        )
        let menuBarHeight = screen.maxY - visible.maxY
        let expectedMaxY = screen.maxY - menuBarHeight - 6
        #expect(abs(frame.maxY - expectedMaxY) < 0.5)
    }

    @Test func notchHugClampsHorizontallyOnNarrowScreen() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 700)
        let size = CGSize(width: 380, height: 38)
        let frame = OverlayGeometry.notchHugFrame(
            size: size,
            screenFrame: screen,
            gap: 0,
            edgeInset: OverlayGeometry.screenEdgeInset
        )
        #expect(frame.size == size)
        #expect(frame.minX >= screen.minX + OverlayGeometry.screenEdgeInset - 0.5)
        #expect(frame.maxX <= screen.maxX - OverlayGeometry.screenEdgeInset + 0.5)
        #expect(abs(frame.maxY - screen.maxY) < 0.5)
    }

    // MARK: - Host layout policy (crash-prevention contract)

    @Test func hostLayoutPolicyDisablesAutomaticWindowSizing() {
        #expect(
            OverlayHostLayoutPolicy.isAutomaticWindowSizingDisabled(
                sizingOptionsRawValue: OverlayHostLayoutPolicy.disabledHostingSizingOptionsRawValue
            )
        )
        #expect(
            !OverlayHostLayoutPolicy.isAutomaticWindowSizingDisabled(sizingOptionsRawValue: 1)
        )
        #expect(
            !OverlayHostLayoutPolicy.isAutomaticWindowSizingDisabled(sizingOptionsRawValue: 0b1111)
        )
    }

    @Test func hostLayoutPolicyMatchesProductionChromeFlags() {
        #expect(
            OverlayHostLayoutPolicy.matchesProductionContract(
                sizingOptionsRawValue: OverlayHostLayoutPolicy.disabledHostingSizingOptionsRawValue,
                autoresizesWithPanel: OverlayHostLayoutPolicy.autoresizesWidthAndHeight,
                panelIsOpaque: OverlayHostLayoutPolicy.panelIsOpaque,
                panelHasShadow: OverlayHostLayoutPolicy.panelHasShadow,
                panelBackgroundIsClear: OverlayHostLayoutPolicy.panelBackgroundIsClear,
                hostingLayerIsClear: OverlayHostLayoutPolicy.hostingLayerIsClear
            )
        )
        #expect(
            !OverlayHostLayoutPolicy.matchesProductionContract(
                sizingOptionsRawValue: 0,
                autoresizesWithPanel: true,
                panelIsOpaque: false,
                panelHasShadow: true,
                panelBackgroundIsClear: true,
                hostingLayerIsClear: true
            )
        )
        #expect(
            !OverlayHostLayoutPolicy.matchesProductionContract(
                sizingOptionsRawValue: 1,
                autoresizesWithPanel: true,
                panelIsOpaque: false,
                panelHasShadow: false,
                panelBackgroundIsClear: true,
                hostingLayerIsClear: true
            )
        )
        #expect(
            !OverlayHostLayoutPolicy.matchesProductionContract(
                sizingOptionsRawValue: 0,
                autoresizesWithPanel: false,
                panelIsOpaque: false,
                panelHasShadow: false,
                panelBackgroundIsClear: true,
                hostingLayerIsClear: true
            )
        )
    }
}
