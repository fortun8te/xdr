import Foundation

enum XDRConstants {
    static let sdrMaxNits: Int = 500
    static let xdrMaxNits: Int = 1600

    // Unified brightness scale
    static let minBrightness: Double = 0.0
    static let sdrMaxBrightness: Double = 1.0
    static let xdrMaxBrightness: Double = 2.0

    // EDR overlay settings
    static let edrTriggerValue: Double = 16.0
    static let edrOverlayFPS: Int = 5

    // Sleep/wake restoration delays
    static let wakeRestoreDelay1: TimeInterval = 1.5
    static let wakeRestoreDelay2: TimeInterval = 3.0

    // Animation
    static let brightnessTransitionDuration: TimeInterval = 0.3

    // Brightness steps (keyboard shortcuts)
    static let brightnessStep: Double = 0.05
    static let brightnessStepLarge: Double = 0.1

    // EDR engagement
    static let edrEngageTimeout: TimeInterval = 2.1
    static let edrReadyThreshold: Double = 1.05

    // Battery
    static let defaultBatteryThreshold: Int = 20

    // App info
    static let appName = "XDR"

    /// Pre-filled user name for personalised builds (e.g. friend DMGs).
    /// Empty string = falls back to NSFullUserName() at runtime.
    static let bundledUserName = ""

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    /// Format a nit value for display (e.g. "500 nits").
    static func nitsDescription(_ nits: Int) -> String {
        "\(nits) nits"
    }
}
