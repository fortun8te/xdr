import SwiftUI

/// Single source of truth for spacing tokens across XDR.
enum Sp {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
}

/// Shared corner radius and border weights used across all cards.
enum CardShape {
    static let corner: CGFloat = 14
    static let borderUnselected: CGFloat = 1.0
    static let borderSelected: CGFloat = 1.5
}
