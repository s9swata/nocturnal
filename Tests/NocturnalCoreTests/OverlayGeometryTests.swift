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

    /// Compact size is a fixed pill — independent of the visible frame (must not
    /// grow toward empty-state intrinsic ~225×218 or expand with screen size).
    @Test func compactTargetSizeIsIndependentOfVisibleFrame() {
        let frames = [
            CGRect(x: 0, y: 0, width: 320, height: 480),
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 0, width: 3024, height: 1964),
        ]
        let expected = OverlayGeometry.compactSize
        for visible in frames {
            let size = OverlayGeometry.targetSize(expanded: false, visibleFrame: visible)
            #expect(size == expected)
            // Pill discipline: fixed compact chrome, never a card/panel footprint.
            #expect(size.width < OverlayGeometry.idealExpandedWidth / 2)
            #expect(size.height < 48)
            #expect(size.width > 120)
            #expect(size.height > 24)
            // Must stay narrower than clamped expanded floors so compact never
            // masquerades as a small expanded panel.
            #expect(size.height < OverlayGeometry.minExpandedHeight)
        }
    }

    @Test func expandedTargetUsesClampPolicyOnSmallScreens() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 500)
        let size = OverlayGeometry.targetSize(expanded: true, visibleFrame: tiny)
        #expect(size == OverlayGeometry.clampedExpandedSize(visibleFrame: tiny))
        #expect(size.width < OverlayGeometry.idealExpandedWidth)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func targetSizePicksCompactOrClampedExpanded() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
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

    // MARK: - Placement (production top-center policy)

    @Test func topCenterPlacesCompactBelowMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875) // 25pt menu bar
        let size = OverlayGeometry.compactSize
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            gap: 6
        )
        #expect(frame.size == size)
        #expect(abs(frame.midX - visible.midX) < 0.5)
        let menuBarHeight = screen.maxY - visible.maxY
        let expectedMaxY = screen.maxY - menuBarHeight - 6
        #expect(abs(frame.maxY - expectedMaxY) < 0.5)
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
        // Production clamp: never above visible maxY - height - 4.
        #expect(frame.maxY <= visible.maxY - 4 + 0.5)
        #expect(frame.minY >= visible.minY + OverlayGeometry.screenEdgeInset - 0.5)
    }

    @Test func topCenterHonorsNotchSafeArea() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let size = OverlayGeometry.idealExpandedSize
        let safeTop: CGFloat = 37 // notch > menu bar remainder
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: safeTop,
            gap: 6
        )
        #expect(frame.size == size)
        let expectedMaxY = screen.maxY - safeTop - 6
        #expect(abs(frame.maxY - expectedMaxY) < 0.5)
    }

    /// When computed Y would place the panel above the visible area, production
    /// clamp `min(y, visibleFrame.maxY - size.height - 4)` pulls it down.
    @Test func topCenterClampsYWhenPanelWouldOverflowVisibleTop() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Tiny visible band near bottom — large panel cannot sit at menu-bar Y.
        let visible = CGRect(x: 0, y: 0, width: 800, height: 200)
        let size = CGSize(width: 228, height: 180)
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            gap: 6
        )
        #expect(frame.maxY <= visible.maxY - 4 + 0.5)
        #expect(frame.minY >= visible.minY + OverlayGeometry.screenEdgeInset - 0.5)
        #expect(frame.height == size.height)
    }

    @Test func topCenterClampsHorizontallyOnNarrowVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 670)
        let size = CGSize(width: 380, height: 500)
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0,
            gap: 6,
            edgeInset: OverlayGeometry.screenEdgeInset
        )
        #expect(frame.minX >= visible.minX + OverlayGeometry.screenEdgeInset - 0.5)
        #expect(frame.maxX <= visible.maxX - OverlayGeometry.screenEdgeInset + 0.5)
        #expect(frame.size == size)
    }

    // MARK: - Host layout policy (crash-prevention contract)

    /// Production must pass empty `NSHostingSizingOptions` so the panel is not
    /// resized by intrinsic empty-state content and cannot enter the
    /// `updateAnimatedWindowSize` → constraint-pass NSGenericException loop.
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
        // Shadow on fails the contract (rectangular system halo).
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
        // Non-empty sizing options fails the contract (constraint-cycle crash path).
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
        // Missing autoresizing fails the contract (content won't track panel content rect).
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

    @Test func expandedFrameOn1440MatchesAuthoritativeSize() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = OverlayGeometry.targetSize(expanded: true, visibleFrame: visible)
        let frame = OverlayGeometry.topCenterFrame(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0
        )
        #expect(frame.size == OverlayGeometry.idealExpandedSize)
        // Must not collapse toward empty-state intrinsic (~225×218).
        #expect(frame.width > OverlayGeometry.minExpandedWidth)
        #expect(frame.height > OverlayGeometry.minExpandedHeight)
    }
}
