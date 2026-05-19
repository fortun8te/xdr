import SwiftUI

/// Solid app-shell background — near-black in dark mode, near-white in light.
/// Used as the root background for all XDR windows. Matches Voice's app shell.
///
/// A solid base color with a barely-there top sheen reads as a custom-built
/// app while still feeling at home on macOS. Only the content area is solid;
/// the title bar still picks up native chrome via the window's styleMask.
public struct AppShellBackground: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        ZStack {
            // Base solid color — near-black in dark mode, near-white in light.
            (scheme == .dark
                ? Color(red: 0.072, green: 0.072, blue: 0.080)
                : Color(red: 0.985, green: 0.985, blue: 0.990))

            // Subtle vertical sheen (top a few percent lighter than bottom).
            // Only meaningfully visible in dark mode; light mode stays flat.
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(scheme == .dark ? 0.015 : 0.000), location: 0.0),
                    .init(color: Color.white.opacity(0.0), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
