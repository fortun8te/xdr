import XCTest
@testable import XDR

final class NightVisionMathTests: XCTestCase {

    // MARK: - Red factor

    func testRedFactor_alwaysFull() {
        // Red is always preserved so the surviving image is bright red, not dim red.
        XCTAssertEqual(NightVisionCurve.redFactor(forIntensity: 0.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.redFactor(forIntensity: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.redFactor(forIntensity: 1.0), 1.0, accuracy: 0.0001)
    }

    // MARK: - Green factor

    func testGreenFactor_endpoints() {
        XCTAssertEqual(NightVisionCurve.greenFactor(forIntensity: 0.0), NightVisionCurve.maxGreen, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.greenFactor(forIntensity: 1.0), NightVisionCurve.minGreen, accuracy: 0.0001)
    }

    func testGreenFactor_decreasesWithIntensity() {
        XCTAssertGreaterThan(NightVisionCurve.greenFactor(forIntensity: 0.2),
                             NightVisionCurve.greenFactor(forIntensity: 0.5))
        XCTAssertGreaterThan(NightVisionCurve.greenFactor(forIntensity: 0.5),
                             NightVisionCurve.greenFactor(forIntensity: 0.9))
    }

    // MARK: - Blue factor

    func testBlueFactor_endpoints() {
        XCTAssertEqual(NightVisionCurve.blueFactor(forIntensity: 0.0), NightVisionCurve.maxBlue, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.blueFactor(forIntensity: 1.0), NightVisionCurve.minBlue, accuracy: 0.0001)
    }

    func testBlueFactor_decreasesWithIntensity() {
        XCTAssertGreaterThan(NightVisionCurve.blueFactor(forIntensity: 0.2),
                             NightVisionCurve.blueFactor(forIntensity: 0.6))
    }

    /// Blue is suppressed harder than green at any given intensity (blue is the worst
    /// offender for dark adaptation), and the gap widens as intensity climbs.
    func testBlueSuppressedHarderThanGreen() {
        for t in stride(from: 0.1, through: 1.0, by: 0.1) {
            XCTAssertLessThan(NightVisionCurve.blueFactor(forIntensity: t),
                              NightVisionCurve.greenFactor(forIntensity: t),
                              "blue should be <= green at intensity \(t)")
        }
    }

    // MARK: - Darken alpha

    func testDarkenAlpha_belowThreshold_isZero() {
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: 0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: NightVisionCurve.darkenThreshold), 0.0, accuracy: 0.0001)
    }

    func testDarkenAlpha_atFull_isMax() {
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: 1.0), NightVisionCurve.maxDarken, accuracy: 0.0001)
    }

    func testDarkenAlpha_increasesAboveThreshold() {
        XCTAssertGreaterThan(NightVisionCurve.darkenAlpha(forIntensity: 0.9),
                             NightVisionCurve.darkenAlpha(forIntensity: 0.6))
    }

    // MARK: - Clamping

    func testClamping_outOfRange() {
        XCTAssertEqual(NightVisionCurve.greenFactor(forIntensity: -1.0), NightVisionCurve.maxGreen, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.greenFactor(forIntensity: 2.0), NightVisionCurve.minGreen, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.blueFactor(forIntensity: 2.0), NightVisionCurve.minBlue, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: -1.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: 2.0), NightVisionCurve.maxDarken, accuracy: 0.0001)
    }

    // MARK: - Tint color

    func testTintColor_keepsRedKillsBlue() {
        let mild = NightVisionCurve.tintColor(forIntensity: 0.0)
        let deep = NightVisionCurve.tintColor(forIntensity: 1.0)
        // Red component pinned at full in both.
        XCTAssertEqual(mild.components?[0] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(deep.components?[0] ?? 0, 1.0, accuracy: 0.0001)
        // Deep mode kills green/blue far more than mild mode.
        XCTAssertLessThan(deep.components?[1] ?? 1, mild.components?[1] ?? 0)
        XCTAssertLessThan(deep.components?[2] ?? 1, mild.components?[2] ?? 0)
        XCTAssertEqual(deep.alpha, 1.0, accuracy: 0.0001)
    }

    // MARK: - Stronger than Night Shift

    /// At full intensity the blue channel is driven well below anything Night Shift's
    /// warmest setting produces (which keeps blue at roughly half), proving this is a
    /// genuinely deeper red shift, not just a warm tint, while still holding above the
    /// readability floor.
    func testFullIntensity_isDeepRedShift() {
        XCTAssertLessThan(NightVisionCurve.blueFactor(forIntensity: 1.0), 0.20)
        XCTAssertLessThan(NightVisionCurve.greenFactor(forIntensity: 1.0), 0.40)
    }

    // MARK: - Readability floors (locked)

    /// The whole point of the retune: at full intensity white must become a readable
    /// salmon-deep-red, never a wall of pure red. Lock the floors so a future change
    /// cannot quietly make the screen illegible again.
    func testReadabilityFloors_atFullIntensity() {
        XCTAssertGreaterThanOrEqual(NightVisionCurve.greenFactor(forIntensity: 1.0), 0.30)
        XCTAssertGreaterThanOrEqual(NightVisionCurve.blueFactor(forIntensity: 1.0), 0.12)
        XCTAssertLessThanOrEqual(NightVisionCurve.darkenAlpha(forIntensity: 1.0), 0.22)
    }

    /// Darkening must not kick in until the dark-adaptation zone (0.6), so the lower
    /// two thirds of the range stay at full screen luminance.
    func testDarken_startsAtSixtyPercent() {
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: 0.59), 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(NightVisionCurve.darkenAlpha(forIntensity: 0.61), 0.0)
    }

    /// The low end (warm zone) stays close to the warm endpoint so small settings read
    /// like a gentle Night Shift, not an aggressive red shift.
    func testWarmZone_staysGentle() {
        XCTAssertGreaterThan(NightVisionCurve.greenFactor(forIntensity: 0.2), 0.80)
        XCTAssertGreaterThan(NightVisionCurve.blueFactor(forIntensity: 0.2), 0.70)
    }

    // MARK: - Engage ramp

    func testRampProgress_endpoints() {
        XCTAssertEqual(NightVisionCurve.rampProgress(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.rampProgress(1.0), 1.0, accuracy: 0.0001)
    }

    func testRampProgress_isMonotonicAndSmooth() {
        // Strictly increasing across the ramp (never snaps backward), and eased so the
        // midpoint sits near 0.5 with soft slopes at both ends.
        var previous = NightVisionCurve.rampProgress(0.0)
        for step in stride(from: 0.1, through: 1.0, by: 0.1) {
            let current = NightVisionCurve.rampProgress(step)
            XCTAssertGreaterThan(current, previous, "ramp should increase at \(step)")
            previous = current
        }
        XCTAssertEqual(NightVisionCurve.rampProgress(0.5), 0.5, accuracy: 0.01)
    }

    func testRampProgress_clampsOutOfRange() {
        XCTAssertEqual(NightVisionCurve.rampProgress(-1.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(NightVisionCurve.rampProgress(2.0), 1.0, accuracy: 0.0001)
    }

    // MARK: - Safe restore rule

    /// A normal enabled state at or below the safe ceiling restores enabled, intensity intact.
    func testSafeRestore_keepsEnabledWhenWithinCeiling() {
        let r = NightVision.safeRestore(enabled: true, intensity: 0.5)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.intensity, 0.5, accuracy: 0.0001)
    }

    /// Exactly at the ceiling still restores enabled (boundary is inclusive).
    func testSafeRestore_atCeilingStaysEnabled() {
        let r = NightVision.safeRestore(enabled: true, intensity: NightVision.safeRestoreCeiling)
        XCTAssertTrue(r.enabled)
    }

    /// A forgotten extreme setting restores OFF but keeps the stored intensity, so it
    /// never ambushes the user at login yet does not lose their chosen level.
    func testSafeRestore_disablesAboveCeilingButKeepsIntensity() {
        let r = NightVision.safeRestore(enabled: true, intensity: 0.95)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.95, accuracy: 0.0001)
    }

    /// A disabled state stays disabled regardless of stored intensity.
    func testSafeRestore_staysDisabledWhenDisabled() {
        let r = NightVision.safeRestore(enabled: false, intensity: 0.2)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.intensity, 0.2, accuracy: 0.0001)
    }

    /// First-enable default lands in the warm zone (below the red-shift boundary).
    func testFirstEnableIntensity_isGentleWarm() {
        XCTAssertLessThan(NightVision.firstEnableIntensity, 0.5)
        XCTAssertEqual(NightVisionCurve.darkenAlpha(forIntensity: NightVision.firstEnableIntensity), 0.0, accuracy: 0.0001)
    }
}
