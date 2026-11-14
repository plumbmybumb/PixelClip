import CoreGraphics
import XCTest
@testable import PixelClipKit

/// Per-screen orientation control and the landscape canvas's integer zoom.
@MainActor
final class LandscapeTests: XCTestCase {

    // MARK: OrientationLock

    func testPortraitWithNothingClaimed() {
        let lock = OrientationLock()
        XCTAssertEqual(lock.mask, .portrait)
        XCTAssertFalse(lock.allowsLandscape)
    }

    func testEachEditorAllowsLandscapeWhileOnScreen() {
        for screen in OrientationScreen.allCases {
            let lock = OrientationLock()
            let token = lock.claim(screen)
            XCTAssertEqual(lock.mask, [.portrait, .landscapeLeft, .landscapeRight], "\(screen)")
            XCTAssertFalse(lock.mask.contains(.portraitUpsideDown), "\(screen)")
            XCTAssertTrue(lock.allowsLandscape)
            lock.release(token)
            XCTAssertEqual(lock.mask, .portrait, "\(screen): leaving returns to portrait")
        }
    }

    func testMostRecentClaimWins() {
        let lock = OrientationLock()
        let draw = lock.claim(.draw)
        let portraitOnly = lock.claim(.portrait)     // e.g. something portrait-only on top
        XCTAssertEqual(lock.mask, .portrait)
        lock.release(portraitOnly)
        XCTAssertEqual(lock.mask, .portraitAndLandscape)
        lock.release(draw)
        XCTAssertEqual(lock.mask, .portrait)
    }

    func testLateDisappearDoesNotDropTheNewScreensClaim() {
        // Text → Cards: SwiftUI can call Cards' onAppear before Text's onDisappear.
        let lock = OrientationLock()
        let text = lock.claim(.text)
        let cards = lock.claim(.cards)
        lock.release(text)
        XCTAssertEqual(lock.mask, .portraitAndLandscape)
        lock.release(cards)
        lock.release(cards)                           // twice is harmless
        XCTAssertEqual(lock.mask, .portrait)
    }

    func testOnChangeFiresOnlyWhenTheMaskChanges() {
        let lock = OrientationLock()
        var seen: [InterfaceOrientations] = []
        lock.onChange = { seen.append($0) }
        let a = lock.claim(.draw)
        let b = lock.claim(.text)                     // same mask: no update
        lock.release(a)
        lock.release(b)
        XCTAssertEqual(seen, [.portraitAndLandscape, .portrait])
    }

    // MARK: Integer zoom fit

    private let scale3: CGFloat = 3

    /// iPhone 18 Pro (402 × 874 pt, 3×), as measured in the simulator: in landscape 62 pt on both
    /// sides, 20 pt for the home indicator, and the navigation bar's 78 pt (in `LandscapeChrome`).
    private let pro = (screen: CGSize(width: 874, height: 402), safe: CanvasZoom.Insets(leading: 62, bottom: 20, trailing: 62))
    /// iPhone 18 class (393 × 852 pt, 3×; insets as on the 16).
    private let base = (screen: CGSize(width: 852, height: 393), safe: CanvasZoom.Insets(leading: 59, bottom: 21, trailing: 59))
    /// SE class (375 × 667 pt, 2×, no insets; a 56-pt navigation bar assumed, not measured).
    private let se = (screen: CGSize(width: 667, height: 375), safe: CanvasZoom.Insets())

    func testPortraitFitIsWidthLimited() {
        // The portrait canvas spans the screen width (the container is taller than it needs).
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 402, height: 360), scale: 3), 2)
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 393, height: 340), scale: 3), 2)
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 375, height: 200), scale: 2), 1)
    }

    func testLandscapeFitOnCommonPhones() {
        XCTAssertEqual(CanvasZoom.LandscapeChrome.standard.railWidth, 156)
        XCTAssertEqual(CanvasZoom.LandscapeChrome.twoColumns.railWidth, 108)
        // The 18 Pro's editor area inside the safe area, as logged by the app: 750 × 304.
        XCTAssertEqual(CanvasZoom.landscapeCanvasArea(screen: pro.screen, safeArea: pro.safe, chrome: .init(railWidth: 0, strip: 0)),
                       CGSize(width: 750, height: 304))
        XCTAssertEqual(CanvasZoom.landscapeFitStep(screen: pro.screen, safeArea: pro.safe, scale: scale3), 3)
        XCTAssertEqual(CanvasZoom.landscapeFitStep(screen: base.screen, safeArea: base.safe, scale: scale3), 3)
        let seTwo = CanvasZoom.LandscapeChrome(railWidth: CanvasZoom.LandscapeChrome.railWidth(columns: 2), navigationBar: 56)
        let seThree = CanvasZoom.LandscapeChrome(railWidth: CanvasZoom.LandscapeChrome.railWidth(columns: 3), navigationBar: 56)
        XCTAssertEqual(CanvasZoom.landscapeFitStep(screen: se.screen, safeArea: se.safe, scale: 2, chrome: seTwo), 2)
        XCTAssertEqual(CanvasZoom.landscapeFitStep(screen: se.screen, safeArea: se.safe, scale: 2, chrome: seThree), 1)
    }

    func testRailNarrowsOnlyWhenThatBuysAStep() {
        func available(_ p: (screen: CGSize, safe: CanvasZoom.Insets), nav: CGFloat) -> CGSize {
            CGSize(width: p.screen.width - p.safe.leading - p.safe.trailing, height: p.screen.height - p.safe.top - p.safe.bottom - nav)
        }
        XCTAssertEqual(CanvasZoom.railColumns(available: available(pro, nav: 78), scale: 3), 3)
        XCTAssertEqual(CanvasZoom.railColumns(available: available(base, nav: 78), scale: 3), 3)
        XCTAssertEqual(CanvasZoom.railColumns(available: available(se, nav: 56), scale: 2), 2)
    }

    func testLandscapeCanvasIsMoreThanTwiceThePortraitArea() {
        let portrait = CanvasZoom.canvasSize(step: 2, scale: 3)
        let landscape = CanvasZoom.canvasSize(step: CanvasZoom.landscapeFitStep(screen: pro.screen, safeArea: pro.safe, scale: 3), scale: 3)
        XCTAssertEqual(landscape.width, 536, accuracy: 0.001)       // one point per canvas pixel
        XCTAssertEqual(landscape.height, 240, accuracy: 0.001)
        XCTAssertEqual(landscape.width / portrait.width, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(landscape.width * landscape.height, 2 * portrait.width * portrait.height)
    }

    func testTheNextStepNeedsTheRailOutOfTheWay() {
        // Step 4 is 714.7 × 320 pt: wider than the 18 Pro's safe width (750 pt) minus any rail.
        let area = CanvasZoom.landscapeCanvasArea(screen: pro.screen, safeArea: pro.safe)
        XCTAssertEqual(area, CGSize(width: 594, height: 256))
        let twoColumns = CanvasZoom.landscapeCanvasArea(screen: pro.screen, safeArea: pro.safe, chrome: .twoColumns)
        XCTAssertLessThan(twoColumns.width, CanvasZoom.canvasSize(step: 4, scale: 3).width + 2 * CanvasZoom.margin.width)
        // Collapsing the frame strip gives height, not width: still step 3.
        let collapsed = CanvasZoom.LandscapeChrome(railWidth: CanvasZoom.LandscapeChrome.railWidth(columns: 3),
                                                   strip: CanvasZoom.LandscapeChrome.stripCollapsed)
        XCTAssertEqual(CanvasZoom.landscapeFitStep(screen: pro.screen, safeArea: pro.safe, scale: 3, chrome: collapsed), 3)
    }

    func testExactFitAndFloor() {
        // Exactly 536 + 16 by 240 + 4 pt at 2× is step 2; a point less floors to 1 (never 0).
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 552, height: 244), scale: 2), 2)
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 552, height: 243), scale: 2), 1)
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 100, height: 50), scale: 1), 1)
        XCTAssertEqual(CanvasZoom.fitStep(in: CGSize(width: 536.0 * 2 / 3 + 16, height: 400), scale: 3), 2)
    }

    func testZoomCarriesAcrossRotation() {
        XCTAssertEqual(CanvasZoom.carriedStep(2, from: 2, to: 3), 3)      // Fit stays Fit
        XCTAssertEqual(CanvasZoom.carriedStep(4, from: 2, to: 3), 6)      // ×2 stays ×2
        XCTAssertEqual(CanvasZoom.carriedStep(6, from: 3, to: 2), 4)
        XCTAssertEqual(CanvasZoom.carriedStep(16, from: 2, to: 3), 24)    // the top of the range
        XCTAssertEqual(CanvasZoom.carriedStep(5, from: 0, to: 3), 3)
        XCTAssertEqual(CanvasZoom.label(step: 3, fit: 3), "Fit")
        XCTAssertEqual(CanvasZoom.label(step: 6, fit: 3), "×2")
        XCTAssertEqual(CanvasZoom.label(step: 3, fit: 2), "×1.5")
    }
}
