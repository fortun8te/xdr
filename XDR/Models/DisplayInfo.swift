import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable, Hashable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var isXDR: Bool
    var maxNits: Int
    var brightness: Double = 1.0
    var maxEDR: Double = 1.0
    /// False when macOS exposes no hardware brightness for this display, so it is
    /// dimmed in software (gamma + overlay) instead. See SoftwareDimmer.
    var supportsHardwareBrightness: Bool = true

    var currentLevel: Double {
        XDRConstants.level(forBrightness: brightness)
    }

}
