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
        if brightness <= 1.0 {
            return Int(brightness * 500)
        }
        return 500 + Int((brightness - 1.0) * Double(maxNits - 500))
    }

    var brightnessPercent: Int {
        Int(brightness * 100)
    }

    var statusText: String {
        if brightness > 1.0 {
            return "XDR \(currentNits) nits"
        }
        return "\(currentNits) nits"
    }

    static let preview = DisplayInfo(
        id: CGMainDisplayID(),
        name: "Built-in Display",
        isBuiltIn: true,
        isXDR: true,
        maxNits: 1600
    )
}
