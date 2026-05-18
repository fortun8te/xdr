import SwiftUI

extension Color {
    // Amber accent for XDR active states
    static let xdrAmber = Color(red: 0.96, green: 0.62, blue: 0.04)       // #F59E0B
    static let xdrOrange = Color(red: 0.98, green: 0.45, blue: 0.09)      // #F97316

    // Gradient for XDR range on slider
    static let xdrGradientEnd = Color(red: 0.99, green: 0.90, blue: 0.54)   // #FDE68A

    // Blue accent (matches app icon gradient)
    static let appBlue = Color(red: 0x16/255, green: 0x31/255, blue: 0xFF/255)       // #1631FF
    static let appBlueLight = Color(red: 0x5A/255, green: 0x6E/255, blue: 0xFF/255)  // lighter end

    // Menu bar badge
    static let xdrBadge = Color.xdrAmber
}

