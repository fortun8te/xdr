import XCTest
@testable import XDR

final class SoftwareDimmerMathTests: XCTestCase {

    // MARK: - Gamma scale

    func testGammaScale_fullBrightness_isIdentity() {
        XCTAssertEqual(DimCurve.gammaScale(forLevel: 1.0), 1.0, accuracy: 0.0001)
    }

    func testGammaScale_atSplit_isFloor() {
        XCTAssertEqual(DimCurve.gammaScale(forLevel: DimCurve.split), DimCurve.gammaFloor, accuracy: 0.0001)
    }

    func testGammaScale_belowSplit_holdsAtFloor() {
        XCTAssertEqual(DimCurve.gammaScale(forLevel: 0.0), DimCurve.gammaFloor, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.gammaScale(forLevel: 0.25), DimCurve.gammaFloor, accuracy: 0.0001)
    }

    func testGammaScale_isMonotonicInTopHalf() {
        XCTAssertGreaterThan(DimCurve.gammaScale(forLevel: 0.9), DimCurve.gammaScale(forLevel: 0.7))
        XCTAssertGreaterThan(DimCurve.gammaScale(forLevel: 0.7), DimCurve.gammaScale(forLevel: 0.5))
    }

    // MARK: - Overlay alpha

    func testOverlayAlpha_topHalf_isZero() {
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: 1.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: 0.75), 0.0, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: DimCurve.split), 0.0, accuracy: 0.0001)
    }

    func testOverlayAlpha_darkest_isMax() {
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: 0.0), DimCurve.maxOverlayAlpha, accuracy: 0.0001)
    }

    func testOverlayAlpha_isMonotonicInBottomHalf() {
        XCTAssertGreaterThan(DimCurve.overlayAlpha(forLevel: 0.1), DimCurve.overlayAlpha(forLevel: 0.3))
    }

    // MARK: - Clamping

    func testClamping_outOfRange() {
        XCTAssertEqual(DimCurve.gammaScale(forLevel: 2.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.gammaScale(forLevel: -1.0), DimCurve.gammaFloor, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: -1.0), DimCurve.maxOverlayAlpha, accuracy: 0.0001)
        XCTAssertEqual(DimCurve.overlayAlpha(forLevel: 2.0), 0.0, accuracy: 0.0001)
    }

    // MARK: - Combined behaviour

    /// Effective transmittance (gamma scale × overlay pass-through) must increase
    /// monotonically with level across the whole range, so the single slider always
    /// gets brighter as you drag right with no dead zones or reversals.
    func testEffectiveTransmittance_isMonotonic() {
        func transmittance(_ l: Double) -> Double {
            DimCurve.gammaScale(forLevel: l) * (1 - DimCurve.overlayAlpha(forLevel: l))
        }
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map(transmittance)
        for i in 1..<samples.count {
            XCTAssertGreaterThan(samples[i], samples[i - 1],
                                 "transmittance should increase with level at step \(i)")
        }
    }

    /// At the darkest setting the panel is dim but never fully black, so the slider
    /// stays findable.
    func testDarkest_isDimButVisible() {
        let transmittance = DimCurve.gammaScale(forLevel: 0.0) * (1 - DimCurve.overlayAlpha(forLevel: 0.0))
        XCTAssertGreaterThan(transmittance, 0.05)
        XCTAssertLessThan(transmittance, 0.20)
    }
}
