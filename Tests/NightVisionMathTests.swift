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
    /// genuinely deeper red shift, not just a warm tint.
    func testFullIntensity_isDeepRedShift() {
        XCTAssertLessThan(NightVisionCurve.blueFactor(forIntensity: 1.0), 0.10)
        XCTAssertLessThan(NightVisionCurve.greenFactor(forIntensity: 1.0), 0.25)
    }
}
