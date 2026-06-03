import SwiftUI

// MARK: - DimSlider

/// A plain 0–100% brightness slider for software-dimmed displays. Mirrors the look
/// of `XDRBoostMeter` (same track, thumb, and spring) but spans the full 0…1 range
/// instead of the boost range, and uses a neutral fill rather than the amber boost
/// gradient. `level` is 0…1 where 1.0 = the panel's native brightness.
struct DimSlider: View {
    let level: Double
    /// Called with the new 0…1 level as the user drags.
    let onSet: (Double) -> Void

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 14
    private let rowHeight: CGFloat = 24

    @State private var dragging = false
    @State private var displayed: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerY = rowHeight / 2
            let frac = CGFloat(min(max(displayed, 0), 1))
            let thumbX = max(thumbDiameter / 2,
                             min(width - thumbDiameter / 2, frac * width))

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: trackHeight)
                    .position(x: width / 2, y: centerY)

                // Filled portion — neutral, since this is plain brightness not boost
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(0, thumbX), height: trackHeight)
                    .position(x: max(0, thumbX) / 2, y: centerY)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
                    .position(x: thumbX, y: centerY)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.92), value: thumbX)
            }
            .frame(width: width, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let f = width > 0 ? Double(min(max(value.location.x, 0), width) / width) : 0
                        displayed = f
                        onSet(f)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: rowHeight)
        .help("Drag to dim this display (software brightness)")
        .onAppear { displayed = level }
        .onChange(of: level) { _, new in
            // External model update with no active gesture — follow it.
            if !dragging { displayed = new }
        }
    }
}
