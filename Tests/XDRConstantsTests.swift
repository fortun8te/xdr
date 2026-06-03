import XCTest
@testable import XDR

final class XDRConstantsTests: XCTestCase {

    // MARK: - SDR range (0.0 – 1.0)

    func testBrightness0_returns0Nits() {
        XCTAssertEqual(XDRConstants.nits(forBrightness: 0.0, maxNits: 1600), 0)
    }

    func testBrightness1_returns500Nits_withMaxNits1600() {
        // SDR cap is always 500 regardless of maxNits
        XCTAssertEqual(XDRConstants.nits(forBrightness: 1.0, maxNits: 1600), 500)
    }

    func testBrightness1_returns500Nits_withMaxNits500() {
        XCTAssertEqual(XDRConstants.nits(forBrightness: 1.0, maxNits: 500), 500)
    }

    // MARK: - XDR range (> 1.0)

    func testBrightness2_returns1600Nits_withMaxNits1600() {
        XCTAssertEqual(XDRConstants.nits(forBrightness: 2.0, maxNits: 1600), 1600)
    }

    func testBrightness2_returns500Nits_withMaxNits500() {
        // When maxNits == sdrMaxNits the XDR range collapses to 0 extra nits
        XCTAssertEqual(XDRConstants.nits(forBrightness: 2.0, maxNits: 500), 500)
    }

    func testBrightness1_5_returns1050Nits_withMaxNits1600() {
        // 500 + 0.5 * (1600 - 500) = 500 + 550 = 1050
        XCTAssertEqual(XDRConstants.nits(forBrightness: 1.5, maxNits: 1600), 1050)
    }

    func testBrightness1_5_returns750Nits_withMaxNits1000() {
        // 500 + 0.5 * (1000 - 500) = 500 + 250 = 750
        XCTAssertEqual(XDRConstants.nits(forBrightness: 1.5, maxNits: 1000), 750)
    }

    // MARK: - Clamping

    func testNegativeBrightness_clamps_to0() {
        XCTAssertEqual(XDRConstants.nits(forBrightness: -1.0, maxNits: 1600), 0)
    }

    func testBrightness3_clampedTo2_returns1600Nits_withMaxNits1600() {
        // brightness 3 clamps to 2.0 — same result as brightness 2.0
        XCTAssertEqual(
            XDRConstants.nits(forBrightness: 3.0, maxNits: 1600),
            XDRConstants.nits(forBrightness: 2.0, maxNits: 1600)
        )
    }

    // MARK: - User-facing 0–10 level

    func testLevel_endpoints() {
        // Boost range (brightness 1.0–2.0) maps to 0–10; plain SDR is boost-off = 0.
        XCTAssertEqual(XDRConstants.level(forBrightness: 1.0), 0.0, accuracy: 0.0001)  // boost off
        XCTAssertEqual(XDRConstants.level(forBrightness: 2.0), 10.0, accuracy: 0.0001) // full boost
        XCTAssertEqual(XDRConstants.level(forBrightness: 0.0), 0.0, accuracy: 0.0001)  // below SDR max
    }

    func testLevel_isLinear() {
        XCTAssertEqual(XDRConstants.level(forBrightness: 1.5), 5.0, accuracy: 0.0001)
        XCTAssertEqual(XDRConstants.level(forBrightness: 1.4), 4.0, accuracy: 0.0001)
    }

    func testLevel_clamps() {
        XCTAssertEqual(XDRConstants.level(forBrightness: -1.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(XDRConstants.level(forBrightness: 0.5), 0.0, accuracy: 0.0001) // SDR → boost off
        XCTAssertEqual(XDRConstants.level(forBrightness: 3.0), 10.0, accuracy: 0.0001)
    }

    func testLevelString_oneDecimal() {
        XCTAssertEqual(XDRConstants.levelString(forBrightness: 1.4), "4.0")
        XCTAssertEqual(XDRConstants.levelString(forBrightness: 2.0), "10.0")
        XCTAssertEqual(XDRConstants.levelString(forBrightness: 1.0), "0.0")
    }
}
