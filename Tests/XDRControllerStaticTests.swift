import XCTest
@testable import XDR

/// Tests for the two pure-static helpers on XDRController.
/// XDRController is @MainActor-isolated, so test methods are annotated accordingly.
@MainActor
final class XDRControllerStaticTests: XCTestCase {

    // MARK: - edrGammaFactor

    /// At the SDR/XDR boundary (xdrBrightness 1.0), factor must be identity (1.0).
    func testGammaFactor_at1_0_isIdentity() {
        let factor = XDRController.edrGammaFactor(xdrBrightness: 1.0, maxEdr: 2.0)
        XCTAssertEqual(factor, 1.0, accuracy: 0.001)
    }

    /// Factor must never exceed 1.5, even with large headroom.
    func testGammaFactor_neverExceeds1_5_largeHeadroom() {
        let factor = XDRController.edrGammaFactor(xdrBrightness: 2.0, maxEdr: 16.0)
        XCTAssertLessThanOrEqual(factor, 1.5)
        XCTAssertEqual(factor, 1.5, accuracy: 0.001)
    }

    /// Factor is monotonically non-decreasing from xdrBrightness 1.0 to 2.0.
    func testGammaFactor_isMonotonicFromSDRToXDRMax() {
        let maxEdr: CGFloat = 4.0
        let steps = 20
        var previous: Float = 0.0
        for i in 0...steps {
            let b = Float(1.0) + Float(i) / Float(steps)
            let f = XDRController.edrGammaFactor(xdrBrightness: b, maxEdr: maxEdr)
            XCTAssertGreaterThanOrEqual(f, previous - 0.0001,
                "Factor must not decrease: step \(i), brightness \(b), factor \(f), previous \(previous)")
            previous = f
        }
    }

    /// With small headroom (maxEdr 1.2), ceiling = min(1.5, 1.0 + 0.2*0.5) = 1.1.
    /// At xdrBrightness 2.0 (t=1.0), factor should be ~1.1.
    func testGammaFactor_smallHeadroom_ceilsAt1_1() {
        // ceiling = min(1.5, 1.0 + (1.2 - 1.0) * 0.5) = min(1.5, 1.1) = 1.1
        let factor = XDRController.edrGammaFactor(xdrBrightness: 2.0, maxEdr: 1.2)
        XCTAssertEqual(factor, 1.1, accuracy: 0.001)
    }

    /// Midpoint: xdrBrightness 1.5 with large headroom → factor midway from 1.0 to 1.5 = 1.25.
    func testGammaFactor_midpoint_largeHeadroom() {
        let factor = XDRController.edrGammaFactor(xdrBrightness: 1.5, maxEdr: 4.0)
        XCTAssertEqual(factor, 1.25, accuracy: 0.001)
    }

    // MARK: - edrOverlayBoostFactor

    /// At xdrBrightness 1.0 (SDR max), overlay factor must be 1.0 (identity).
    func testOverlayBoost_at1_0_isIdentity() {
        let factor = XDRController.edrOverlayBoostFactor(xdrBrightness: 1.0)
        XCTAssertEqual(factor, 1.0, accuracy: 0.001)
    }

    /// At xdrBrightness 2.0 (XDR max), overlay factor must be 2.0.
    func testOverlayBoost_at2_0_is2() {
        let factor = XDRController.edrOverlayBoostFactor(xdrBrightness: 2.0)
        XCTAssertEqual(factor, 2.0, accuracy: 0.001)
    }

    /// Midpoint: xdrBrightness 1.5 → factor 1.5.
    func testOverlayBoost_midpoint_is1_5() {
        let factor = XDRController.edrOverlayBoostFactor(xdrBrightness: 1.5)
        XCTAssertEqual(factor, 1.5, accuracy: 0.001)
    }

    /// Values below 1.0 are clamped: xdrBrightness 0.5 → factor 1.0 (t clamped to 0).
    func testOverlayBoost_below1_0_clampedToIdentity() {
        let factor = XDRController.edrOverlayBoostFactor(xdrBrightness: 0.5)
        XCTAssertEqual(factor, 1.0, accuracy: 0.001)
    }

    /// Values above 2.0 are clamped: xdrBrightness 3.0 → factor 2.0 (t clamped to 1).
    func testOverlayBoost_above2_0_clampedToMax() {
        let factor = XDRController.edrOverlayBoostFactor(xdrBrightness: 3.0)
        XCTAssertEqual(factor, 2.0, accuracy: 0.001)
    }
}
