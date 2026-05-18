import Foundation

enum XDRConstants {
    // Unified brightness scale
    static let minBrightness: Double = 0.0
    static let sdrMaxBrightness: Double = 1.0
    static let xdrMaxBrightness: Double = 2.0

    // Nit values
    static let sdrMaxNits: Int = 500

    // Animation
    static let brightnessTransitionDuration: TimeInterval = 0.3

    /// Pre-filled user name for personalised builds (e.g. friend DMGs).
    /// Empty string = falls back to NSFullUserName() at runtime.
    static let bundledUserName = ""

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    /// Converts a unified brightness value (0.0–2.0) to nits.
    static func nits(forBrightness brightness: Double, maxNits: Int = 1600) -> Int {
        let clamped = max(0.0, min(brightness, 2.0))
        if clamped <= 1.0 {
            return Int(clamped * Double(sdrMaxNits))
        }
        return sdrMaxNits + Int((clamped - 1.0) * Double(maxNits - sdrMaxNits))
    }
}
