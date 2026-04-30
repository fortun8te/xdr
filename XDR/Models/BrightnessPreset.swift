import Foundation

struct BrightnessPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var brightness: Double
    var icon: String

    func nits(maxNits: Int = 1600) -> Int {
        if brightness <= 1.0 {
            return Int(brightness * 500)
        }
        return 500 + Int((brightness - 1.0) * Double(maxNits - 500))
    }

    var description: String {
        "\(name) (\(nits()) nits)"
    }

    static let defaults: [BrightnessPreset] = [
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Normal", brightness: 1.0, icon: "sun.max"),
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Extra", brightness: 1.3, icon: "sun.max.fill"),
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Outdoor", brightness: 2.0, icon: "sun.horizon.fill"),
    ]
}
