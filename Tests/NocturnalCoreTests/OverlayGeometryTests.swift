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

    // MARK: - Compact / expanded targets

    @Test func compactSizeStaysCompact() {
        let size = OverlayGeometry.compactSize
        #expect(size.width == OverlayGeometry.compactWidth)
        #expect(size.height == OverlayGeometry.compactHeight)
        #expect(size == CGSize(width: 228, height: 36))
        // Must stay a narrow pill — never inflate toward empty-state fitting width.
        #expect(size.width < 300)
        #expect(size.height < 48)
    }

    @Test func idealExpandedMeetsComfortTargets() {
        let size = OverlayGeometry.idealExpandedSize
        #expect(size == CGSize(width: 520, height: 620))
        #expect(size.width == OverlayGeometry.idealExpandedWidth)
        #expect(size.height == OverlayGeometry.idealExpandedHeight)
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

    /// Confirmed regression display: 1440-point-wide laptop must keep full 520×620
    /// when expanded — empty-state content must not compress the panel.
    @Test func expandedStaysIdealOn1440PointDisplay() {
        // Typical 14" laptop visible frame (menu bar already excluded).
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: visible)
        #expect(size.width == 520)
        #expect(size.height == 620)
        #expect(size == OverlayGeometry.idealExpandedSize)
    }

    @Test func expandedHeightClampsWhenVisibleIsShort() {
        // Wide but short (e.g. lots of Dock + menu chrome).
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: short)
        #expect(size.width == OverlayGeometry.idealExpandedWidth)
        #expect(size.height == 500 - OverlayGeometry.panelScreenPadding)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func clampRespectsMinimumFloorsOnTinyDisplays() {
        let microscopic = CGRect(x: 0, y: 0, width: 50, height: 50)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: microscopic)
        // max(minFloor, visible - padding) can exceed visible on tiny frames;
        // floors still hold so the panel never collapses below usable size policy.
        #expect(size.width >= OverlayGeometry.minExpandedWidth)
        #expect(size.height >= OverlayGeometry.minExpandedHeight)
    }

    // MARK: - Placement

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
        #expect(frame.width == 228)
        #expect(frame.height == 36)
        // Horizontally centered in visible frame.
        #expect(abs(frame.midX - visible.midX) < 0.5)
        // Top of panel sits gap below menu bar.
        let menuBarHeight = screen.maxY - visible.maxY
        let expectedMaxY = screen.maxY - menuBarHeight - 6
        #expect(abs(frame.maxY - expectedMaxY) < 0.5)
        // Fully inside visible bounds (with edge inset slack for height).
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
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
        #expect(frame.width == 520)
        #expect(frame.height == 620)
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
        #expect(frame.width == size.width)
        #expect(frame.height == size.height)
    }

    // MARK: - Host layout policy (crash-prevention contract)

    /// Production must pass empty `NSHostingSizingOptions` so the panel is not
    /// resized by intrinsic empty-state content (~225×218) and cannot enter the
    /// `updateAnimatedWindowSize` → constraint-pass NSGenericException loop.
    @Test func hostLayoutPolicyDisablesAutomaticWindowSizing() {
        #expect(OverlayHostLayoutPolicy.disabledHostingSizingOptionsRawValue == 0)
        #expect(
            OverlayHostLayoutPolicy.isAutomaticWindowSizingDisabled(sizingOptionsRawValue: 0)
        )
        // Any non-empty option set is unsafe for this overlay.
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
                sizingOptionsRawValue: 0,
                autoresizesWithPanel: true,
                panelIsOpaque: false,
                panelHasShadow: false,
                panelBackgroundIsClear: true,
                hostingLayerIsClear: true
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
        #expect(frame.width == 520)
        #expect(frame.height == 620)
        // Must not collapse toward empty-state intrinsic (~225×218).
        #expect(frame.width > 400)
        #expect(frame.height > 500)
    }
}
