import Foundation

enum XDRConstants {
    // Unified brightness scale
    static let minBrightness: Double = 0.0
    static let sdrMaxBrightness: Double = 1.0
    static let xdrMaxBrightness: Double = 2.0

    // Nit values
    static let sdrMaxNits: Int = 500

    // User-facing brightness level (shown in the UI instead of raw nits).
    // The unified 0.0–2.0 brightness maps linearly to 0–10:
    //   level 5  = SDR max (normal brightness ceiling)
    //   level 10 = full XDR boost
    static let maxLevel: Double = 10.0

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

    /// Converts a unified brightness value to the user-facing 0–10 boost level.
    /// The app only controls the XDR *boost* range (brightness 1.0–2.0); macOS owns
    /// plain SDR (0.0–1.0). So we map the boost range to the full 0–10 scale:
    ///   level 0  = boost off (at or below SDR max)
    ///   level 10 = full XDR boost
    static func level(forBrightness brightness: Double) -> Double {
        let boost = max(0.0, min(brightness, xdrMaxBrightness) - sdrMaxBrightness) // 0…1
        return boost / (xdrMaxBrightness - sdrMaxBrightness) * maxLevel            // 0…10
    }

    /// Formats a brightness as a one-decimal 0–10 level string (e.g. "7.3"),
    /// giving smooth sublevels for the numeric-text drag animation.
    static func levelString(forBrightness brightness: Double) -> String {
        String(format: "%.1f", level(forBrightness: brightness))
    }
}
