import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    // MARK: - Display state

    var displays: [DisplayInfo] = []
    var selectedDisplayID: CGDirectDisplayID?

    // MARK: - Settings

    var launchAtLogin: Bool = false
    var smoothTransitions: Bool = true
    var showNitsInMenuBar: Bool = false

    // MARK: - Computed

    var activeDisplay: DisplayInfo? {
        if let id = selectedDisplayID {
            return displays.first { $0.id == id }
        }
        return displays.first
    }

    var isAnyXDRActive: Bool {
        displays.contains { $0.brightness > 1.0 }
    }

    var xdrCapableDisplays: [DisplayInfo] {
        displays.filter { $0.isXDR }
    }

    // MARK: - Formatting

    func nitsText(for display: DisplayInfo) -> String {
        "\(display.currentNits) nits"
    }

    func brightnessPercent(for display: DisplayInfo) -> String {
        if display.brightness <= 1.0 {
            return "\(Int(display.brightness * 100))%"
        } else {
            let nits = nitsForBrightness(display.brightness, maxNits: display.maxNits)
            return "\(nits) nits"
        }
    }

    func nitsForBrightness(_ brightness: Double, maxNits: Int) -> Int {
        let clamped = min(max(brightness, 0), 2.0)
        if clamped <= 1.0 {
            return Int(clamped * 500)
        } else {
            let xdrFraction = clamped - 1.0
            return 500 + Int(xdrFraction * Double(maxNits - 500))
        }
    }
}
