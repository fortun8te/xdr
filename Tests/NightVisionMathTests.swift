import XCTest
@testable import XDR

final class NightVisionMathTests: XCTestCase {

    // MARK: - Channel ceilings (gamma LUT model)

    func testCeilings_endpoints() {
        // Zero intensity is identity: every channel at full ceiling.
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.greenMax(forIntensity: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.blueMax(forIntensity: 0), 1.0, accuracy: 0.0001)
        // Full intensity hits the floors.
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 1), NightVisionCurve.minRed, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.greenMax(forIntensity: 1), NightVisionCurve.minGreen, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.blueMax(forIntensity: 1), NightVisionCurve.minBlue, accuracy: 0.0001)
    }

    func testGreenAndBlue_monotonicallyDecrease() {
        var lastG = 2.0, lastB = 2.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let g = NightVisionCurve.greenMax(forIntensity: t)
            let b = NightVisionCurve.blueMax(forIntensity: t)
            XCTAssertLessThanOrEqual(g, lastG + 0.0001, "green must not increase as intensity rises")
            XCTAssertLessThanOrEqual(b, lastB + 0.0001, "blue must not increase as intensity rises")
            lastG = g; lastB = b
        }
    }

    func testBlueSuppressedHarderThanGreen() {
        // Blue is the worst offender for dark adaptation, so it is always the
        // most suppressed channel.
        for t in stride(from: 0.1, through: 1.0, by: 0.1) {
            XCTAssertLessThan(NightVisionCurve.blueMax(forIntensity: t),
                              NightVisionCurve.greenMax(forIntensity: t) + 0.0001,
                              "blue ceiling should be <= green at intensity \(t)")
        }
    }

    func testRed_staysDominant() {
        // Red is the surviving channel: once the shift is meaningfully engaged its
        // ceiling sits well above green/blue. (The low end is intentionally gentle —
        // a "warm Night Shift" — so dominance is asserted from mid-intensity up.)
        for t in stride(from: 0.6, through: 1.0, by: 0.1) {
            XCTAssertGreaterThan(NightVisionCurve.redMax(forIntensity: t),
                                 NightVisionCurve.greenMax(forIntensity: t) + 0.2)
            XCTAssertGreaterThan(NightVisionCurve.redMax(forIntensity: t),
                                 NightVisionCurve.blueMax(forIntensity: t) + 0.2)
        }
    }

    func testRed_onlyDimsAtTop() {
        // The lower two thirds keep full red brightness; only the deep end dims.
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 0.3), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 0.7), 1.0, accuracy: 0.0001)
        XCTAssertLessThan(NightVisionCurve.redMax(forIntensity: 1.0), 1.0)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.redMax(forIntensity: 1.0), 0.75) // never too dark
    }

    func testReadabilityFloors_atFullIntensity() {
        // The contract that prevents an illegible result: at maximum, green and
        // blue keep a trace so edges stay distinguishable, red stays bright.
        XCTAssertGreaterThanOrEqual(NightVisionCurve.greenMax(forIntensity: 1.0), 0.09)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.blueMax(forIntensity: 1.0), 0.025)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.redMax(forIntensity: 1.0), 0.78)
    }

    func testWarmZone_isGentle() {
        // At 35% (the first-enable default) the shift is mild: green and blue
        // ceilings stay high so the screen reads like a warm Night Shift.
        XCTAssertGreaterThan(NightVisionCurve.greenMax(forIntensity: 0.35), 0.70)
        XCTAssertGreaterThan(NightVisionCurve.blueMax(forIntensity: 0.35), 0.55)
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 0.35), 1.0, accuracy: 0.0001)
    }

    func testInputsAreClamped() {
        XCTAssertEqual(NightVisionCurve.greenMax(forIntensity: -1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.greenMax(forIntensity: 2), NightVisionCurve.minGreen, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.blueMax(forIntensity: 2), NightVisionCurve.minBlue, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: 2), NightVisionCurve.minRed, accuracy: 0.0001)
    }

    // MARK: - Overlay fallback values

    func testWashAlpha_endpointsAndMonotonic() {
        XCTAssertEqual(NightVisionCurve.washAlpha(forIntensity: 0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(NightVisionCurve.washAlpha(forIntensity: 1), 0.4)
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = NightVisionCurve.washAlpha(forIntensity: t)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func testDimAlpha_belowThreshold_isZero() {
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 0.0), 0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.dimAlpha(forIntensity: 0.6), 0, accuracy: 0.0001)
    }

    func testDimAlpha_atFull_isModest() {
        let d = NightVisionCurve.dimAlpha(forIntensity: 1.0)
        XCTAssertGreaterThan(d, 0)
        XCTAssertLessThanOrEqual(d, 0.35) // dims, never blacks out
    }

    // MARK: - Engage ramp

    func testRampProgress_endpointsAndEased() {
        XCTAssertEqual(NightVisionCurve.rampProgress(0), 0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.rampProgress(1), 1, accuracy: 0.0001)
        XCTAssertLessThan(NightVisionCurve.rampProgress(0.1), 0.1)
        XCTAssertGreaterThan(NightVisionCurve.rampProgress(0.9), 0.9)
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = NightVisionCurve.rampProgress(t)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    // MARK: - Safe restore rule

    func testSafeRestore_disabledStaysDisabled() {
        let r = NightVision.safeRestore(enabled: false, intensity: 0.5)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.5, accuracy: 0.0001)
    }

    func testSafeRestore_withinCeiling_staysEnabled() {
        XCTAssertTrue(NightVision.safeRestore(enabled: true, intensity: 0.5).enabled)
        XCTAssertTrue(NightVision.safeRestore(enabled: true, intensity: NightVision.safeRestoreCeiling).enabled)
    }

    func testSafeRestore_extremeRestoresOffButKeepsIntensity() {
        let r = NightVision.safeRestore(enabled: true, intensity: 0.9)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.9, accuracy: 0.0001)
        XCTAssertFalse(NightVision.safeRestore(enabled: true, intensity: 1.0).enabled)
    }

    func testFirstEnableDefault_isWarmZone() {
        XCTAssertEqual(NightVision.firstEnableIntensity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.redMax(forIntensity: NightVision.firstEnableIntensity), 1.0, accuracy: 0.0001)
    }
}
