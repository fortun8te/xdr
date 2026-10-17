import SwiftUI

extension Color {
    // Amber accent for XDR active states
    static let xdrAmber = Color(red: 0.96, green: 0.62, blue: 0.04)       // #F59E0B
    static let xdrOrange = Color(red: 0.98, green: 0.45, blue: 0.09)      // #F97316

    // Gradient for XDR range on slider
    static let xdrGradientEnd = Color(red: 0.99, green: 0.90, blue: 0.54)   // #FDE68A

    // Deep red accent for Night Vision. Sits high in the red channel and low in
    // green/blue so it survives the overlay's multiply-red filter: under the filter
    // it reads as a strong red rather than vanishing the way cool hues do.
    static let nightVisionRed = Color(red: 0.85, green: 0.13, blue: 0.13)   // #D92121
}

