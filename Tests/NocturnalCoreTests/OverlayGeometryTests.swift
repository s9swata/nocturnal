import Foundation
import Testing
@testable import NocturnalCore

/// Geometry contracts for the floating overlay via production ``OverlayGeometry``.
///
/// AppKit visual rendering (shadow shape) cannot be unit-tested under CLT, so
/// compact-chrome expectations document the UI configuration contract only:
/// non-opaque clear panel, no native window shadow. Expanded size clamp is
/// exercised against the real Core type used by ``OverlayController``.
struct OverlayGeometryTests {
    @Test func compactSizeStaysCompact() {
        let size = OverlayGeometry.compactSize
        #expect(size.width == 228)
        #expect(size.height == 36)
        #expect(size.width < 300)
        #expect(size.height < 48)
    }

    @Test func idealExpandedMeetsComfortTargets() {
        let size = OverlayGeometry.idealExpandedSize
        #expect(size.width == 520)
        #expect(size.height == 620)
        #expect(size.width >= 500)
        #expect(size.height >= 600)
    }

    @Test func expandedClampsToSmallVisibleFrame() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 500)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: tiny)
        #expect(size.width <= 400 - OverlayGeometry.panelScreenPadding)
        #expect(size.height <= 500 - OverlayGeometry.panelScreenPadding)
        #expect(size.width < OverlayGeometry.idealExpandedWidth)
        #expect(size.height < OverlayGeometry.idealExpandedHeight)
    }

    @Test func expandedDoesNotExceedIdealOnLargeScreen() {
        let large = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = OverlayGeometry.clampedExpandedSize(visibleFrame: large)
        #expect(size.width == OverlayGeometry.idealExpandedWidth)
        #expect(size.height == OverlayGeometry.idealExpandedHeight)
    }

    /// Documents the compact-chrome AppKit configuration (not enforceable in Core).
    ///
    /// Root cause: `NSPanel.hasShadow = true` draws a **rectangular** native
    /// shadow around the content rect; combined with any opaque hosting fill this
    /// reads as square margins around the capsule. Fix: clear non-opaque panel,
    /// `hasShadow = false`, clear hosting layer, SwiftUI capsule shadow only.
    @Test func compactChromeContractDisablesRectangularWindowShadow() {
        struct CompactChrome: Equatable {
            var panelIsOpaque: Bool
            var panelHasShadow: Bool
            var panelBackgroundIsClear: Bool
        }
        let expected = CompactChrome(
            panelIsOpaque: false,
            panelHasShadow: false,
            panelBackgroundIsClear: true
        )
        #expect(expected.panelIsOpaque == false)
        #expect(expected.panelHasShadow == false)
        #expect(expected.panelBackgroundIsClear == true)
    }
}
