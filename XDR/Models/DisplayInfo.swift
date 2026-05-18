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

    var currentNits: Int {
        XDRConstants.nits(forBrightness: brightness, maxNits: maxNits)
    }

}
