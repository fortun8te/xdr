import SwiftUI

// MARK: - Night Vision section

/// Menu bar panel row for Night Vision: a toggle plus an intensity slider.
/// Matches the DisplayCard surface treatment and Typography tokens. Copy avoids
/// em dashes by hard rule.
struct NightVisionSection: View {
    let isEnabled: Bool
    let intensity: Double
    let onToggle: (Bool) -> Void
    let onSetIntensity: (Double) -> Void

    @Environment(\.colorScheme) private var scheme

    private var percentString: String {
        "\(Int((intensity * 100).rounded()))"
    }

    /// Names the zone the current intensity sits in, mirroring the curve's three
    /// readability bands. Updates live as the slider moves. Sentence case, no em dash.
    private var zoneName: String {
        switch intensity {
        case ..<0.30: return "Warm"
        case ..<0.70: return "Red shift"
        default:      return "Dark adaptation"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            HStack(alignment: .top, spacing: Sp.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(isEnabled ? Color.nightVisionRed : .secondary)
                        Text("Night Vision")
                            .font(.bodyMedium)
                            .lineLimit(1)
                    }
                    Text("Deep red mode for dark adaptation")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if isEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Sp.sm) {
                        NightVisionSlider(intensity: intensity, onSet: onSetIntensity)
                        Text("\(percentString)%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                            .contentTransition(.numericText())
                    }
                    Text(zoneName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.nightVisionRed.opacity(0.85))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: zoneName)
                }
            }
        }
        .padding(Sp.sm)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(0.05)
                    : Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: CardShape.borderUnselected)
        )
    }
}

// MARK: - Night Vision slider

/// A 0–100% intensity slider for Night Vision. Mirrors DimSlider's track/thumb/spring
/// but uses a red fill to signal the deep-red mode it controls.
struct NightVisionSlider: View {
    let intensity: Double
    let onSet: (Double) -> Void

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 14
    private let rowHeight: CGFloat = 24

    @State private var dragging = false
    @State private var displayed: Double = 0.35

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerY = rowHeight / 2
            let frac = CGFloat(min(max(displayed, 0), 1))
            let thumbX = max(thumbDiameter / 2,
                             min(width - thumbDiameter / 2, frac * width))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: trackHeight)
                    .position(x: width / 2, y: centerY)

                Capsule()
                    .fill(Color.nightVisionRed.opacity(0.85))
                    .frame(width: max(0, thumbX), height: trackHeight)
                    .position(x: max(0, thumbX) / 2, y: centerY)

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
        .help("Drag to set Night Vision strength")
        .onAppear { displayed = intensity }
        .onChange(of: intensity) { _, new in
            if !dragging { displayed = new }
        }
    }
}
