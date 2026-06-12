import XCTest
@testable import XDR

final class NightVisionMathTests: XCTestCase {

    // MARK: - Wash alpha

    func testWashAlpha_endpoints() {
        XCTAssertEqual(NightVisionCurve.washAlpha(forIntensity: 0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.washAlpha(forIntensity: 1.0), NightVisionCurve.maxWash, accuracy: 0.0001)
    }

    func testWashAlpha_monotonicallyIncreases() {
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = NightVisionCurve.washAlpha(forIntensity: t)
            XCTAssertGreaterThanOrEqual(v, last, "wash must never decrease as intensity rises")
            last = v
        }
    }

    func testWashAlpha_gentleAtLowEnd() {
        // The warm zone should be subtle: at 30% intensity the wash stays under
        // half of its maximum (smoothstep keeps the low end gentle).
        XCTAssertLessThan(NightVisionCurve.washAlpha(forIntensity: 0.30),
                          NightVisionCurve.maxWash * 0.5)
    }

    // MARK: - Dim alpha

    func testDimAlpha_belowThreshold_isZero() {
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: NightVisionCurve.dimThreshold), 0.0, accuracy: 0.0001)
    }

    func testDimAlpha_atFull_isMax() {
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 1.0), NightVisionCurve.maxDim, accuracy: 0.0001)
    }

    func testDimAlpha_capIsModest() {
        // Dark adaptation must dim, never black out.
        XCTAssertLessThanOrEqual(NightVisionCurve.maxDim, 0.35)
    }

    // MARK: - Readability floors (white response at FULL intensity)

    func testFullIntensity_whiteStaysReadable() {
        // These floors are the contract that prevents the "flat red wall":
        // a white pixel at maximum intensity keeps enough of every channel
        // that text and UI edges stay distinguishable.
        XCTAssertGreaterThanOrEqual(NightVisionCurve.whiteGreen(forIntensity: 1.0), 0.30)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.whiteBlue(forIntensity: 1.0), 0.28)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.whiteRed(forIntensity: 1.0), 0.80)
    }

    func testFullIntensity_isStronglyRed() {
        // It still has to feel like night vision: red clearly dominates.
        let r = NightVisionCurve.whiteRed(forIntensity: 1.0)
        let g = NightVisionCurve.whiteGreen(forIntensity: 1.0)
        let b = NightVisionCurve.whiteBlue(forIntensity: 1.0)
        XCTAssertGreaterThan(r, g + 0.3)
        XCTAssertGreaterThan(r, b + 0.3)
    }

    func testBlueNeverAboveGreen() {
        // The wash carries a whisper of green and zero blue, so blue is always
        // the most suppressed channel.
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertLessThanOrEqual(NightVisionCurve.whiteBlue(forIntensity: t),
                                     NightVisionCurve.whiteGreen(forIntensity: t))
        }
    }

    func testZeroIntensity_isIdentity() {
        XCTAssertEqual(NightVisionCurve.whiteRed(forIntensity: 0.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.whiteGreen(forIntensity: 0.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.whiteBlue(forIntensity: 0.0), 1.0, accuracy: 0.0001)
    }

    func testWarmZone_barelyDarkens() {
        // At 35% (the first-enable default) there is no dimming at all and the
        // wash is mild: the screen stays bright and readable.
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 0.35), 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(NightVisionCurve.whiteGreen(forIntensity: 0.35), 0.75)
    }

    // MARK: - Clamping

    func testInputsAreClamped() {
        XCTAssertEqual(NightVisionCurve.washAlpha(forIntensity: -1), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.washAlpha(forIntensity: 2), NightVisionCurve.maxWash, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 2), NightVisionCurve.maxDim, accuracy: 0.0001)
    }

    // MARK: - Engage ramp

    func testRampProgress_endpointsAndMonotonic() {
        XCTAssertEqual(NightVisionCurve.rampProgress(0), 0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.rampProgress(1), 1, accuracy: 0.0001)
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = NightVisionCurve.rampProgress(t)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func testRampProgress_isEased() {
        // Softer than linear near both ends.
        XCTAssertLessThan(NightVisionCurve.rampProgress(0.1), 0.1)
        XCTAssertGreaterThan(NightVisionCurve.rampProgress(0.9), 0.9)
    }

    // MARK: - Safe restore rule

    func testSafeRestore_disabledStaysDisabled() {
        let r = NightVision.safeRestore(enabled: false, intensity: 0.5)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.5, accuracy: 0.0001)
    }

    func testSafeRestore_enabledWithinCeiling_staysEnabled() {
        let r = NightVision.safeRestore(enabled: true, intensity: 0.5)
        XCTAssertTrue(r.enabled)
    }

    func testSafeRestore_ceilingIsInclusive() {
        let r = NightVision.safeRestore(enabled: true, intensity: NightVision.safeRestoreCeiling)
        XCTAssertTrue(r.enabled)
    }

    func testSafeRestore_extremeRestoresOffButKeepsIntensity() {
        let r = NightVision.safeRestore(enabled: true, intensity: 0.9)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.9, accuracy: 0.0001)
    }

    func testSafeRestore_fullIntensityRestoresOff() {
        XCTAssertFalse(NightVision.safeRestore(enabled: true, intensity: 1.0).enabled)
    }

    func testFirstEnableDefault_isWarmZone() {
        XCTAssertEqual(NightVision.firstEnableIntensity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: NightVision.firstEnableIntensity), 0, accuracy: 0.0001)
    }
}
