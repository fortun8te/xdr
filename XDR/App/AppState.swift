import CoreGraphics
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    // MARK: - Display state

    var displays: [DisplayInfo] = []

    // MARK: - Settings (persisted via UserDefaults)

    var smoothTransitions: Bool {
        get { UserDefaults.standard.object(forKey: "smoothTransitions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "smoothTransitions") }
    }

    var showNitsInMenuBar: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "showNitsInMenuBar") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "showNitsInMenuBar")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showNitsInMenuBar") }
    }

    // MARK: - Computed

    var activeDisplay: DisplayInfo? {
        displays.first(where: { $0.brightness > 1.0 }) ?? displays.first
    }

    var isAnyXDRActive: Bool {
        displays.contains { $0.brightness > 1.0 }
    }

    // MARK: - Formatting

    func nitsForBrightness(_ brightness: Double, maxNits: Int) -> Int {
        XDRConstants.nits(forBrightness: brightness, maxNits: maxNits)
    }
}
