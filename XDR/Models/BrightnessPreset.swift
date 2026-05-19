import Foundation

struct BrightnessPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var brightness: Double
    var icon: String

    func nits(maxNits: Int = 1600) -> Int {
        XDRConstants.nits(forBrightness: brightness, maxNits: maxNits)
    }

    var description: String {
        "\(name) (\(nits()) nits)"
    }

    // IDs are compile-time constants persisted to UserDefaults — failure here
    // would be a compile-time misspelling, not a runtime condition.
    static let defaults: [BrightnessPreset] = [
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Normal", brightness: 1.0, icon: "sun.max"),
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Extra", brightness: 1.3, icon: "sun.max.fill"),
        BrightnessPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Outdoor", brightness: 2.0, icon: "sun.horizon.fill"),
    ]
}
