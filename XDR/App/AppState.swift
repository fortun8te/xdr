import CoreGraphics
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    // MARK: - Display state

    var displays: [DisplayInfo] = []

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: [
            "smoothTransitions": true,
            "boostMode": BoostMode.gamma.rawValue,
        ])
    }

    // MARK: - Settings (persisted via UserDefaults)

    var smoothTransitions: Bool {
        get { UserDefaults.standard.bool(forKey: "smoothTransitions") }
        set { UserDefaults.standard.set(newValue, forKey: "smoothTransitions") }
    }

    /// Whether the menu bar shows the numeric brightness level (0–10) next to the icon.
    /// UserDefaults key is kept as "showNitsInMenuBar" for settings continuity.
    var showLevelInMenuBar: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "showNitsInMenuBar") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "showNitsInMenuBar")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showNitsInMenuBar") }
    }

    /// Boost mechanism for brightness > 1.0. See `BoostMode` for details.
    /// When changed, the AppLifecycleManager re-asserts active brightness so the new
    /// mode takes effect immediately (gamma table reset + overlay torn down or vice versa).
    var boostMode: BoostMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "boostMode") ?? BoostMode.gamma.rawValue
            return BoostMode(rawValue: raw) ?? .gamma
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "boostMode")
        }
    }

    // MARK: - Computed

    var activeDisplay: DisplayInfo? {
        displays.first(where: { $0.brightness > 1.0 }) ?? displays.first
    }

    var isAnyXDRActive: Bool {
        displays.contains { $0.brightness > 1.0 }
    }

    // MARK: - Formatting

    func levelForBrightness(_ brightness: Double) -> Double {
        XDRConstants.level(forBrightness: brightness)
    }
}
