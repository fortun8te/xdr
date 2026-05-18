import SwiftUI

struct BrightnessSliderView: View {
    @Binding var brightness: Double
    @Binding var isDragging: Bool
    let maxBrightness: Double
    let isXDR: Bool
    let currentNits: Int
    var isActivating: Bool = false

    @State private var pulse = false

    // Layout constants
    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 20
    private let iconSize: CGFloat = 14
    private let tickWidth: CGFloat = 1
    private let tickHeight: CGFloat = 8

    // The normalized position of the SDR/XDR boundary on the track (0...1)
    private var sdrBoundaryFraction: CGFloat {
        guard maxBrightness > 0 else { return 1.0 }
        return 1.0 / maxBrightness
    }

    // Current thumb fraction along the track (0...1)
    private var thumbFraction: CGFloat {
        guard maxBrightness > 0 else { return 0 }
        return min(max(brightness / maxBrightness, 0), 1)
    }

    // Whether we're currently in XDR territory
    private var inXDRRange: Bool {
        brightness > 1.0 && isXDR
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            sliderBody

            Image(systemName: "sun.max.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    // MARK: - Slider Body

    private var sliderBody: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbX = thumbFraction * trackWidth

            ZStack(alignment: .leading) {
                // Background track (full width)
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: trackHeight)

                // Fill track (left of thumb)
                trackFill(thumbX: thumbX, trackWidth: trackWidth)

                // SDR/XDR boundary tick mark
                if isXDR && maxBrightness > 1.0 {
                    let tickX = sdrBoundaryFraction * trackWidth
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: tickWidth, height: tickHeight)
                        .position(x: tickX, y: geometry.size.height / 2)
                }

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .position(x: clampThumbX(thumbX, in: trackWidth),
                              y: geometry.size.height / 2)
                    .animation(isDragging ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: brightness)

                // Nits label (or activating indicator) above thumb
                if isActivating && inXDRRange {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.xdrAmber)
                            .frame(width: 5, height: 5)
                            .opacity(pulse ? 1.0 : 0.3)
                        Text("Activating…")
                            .font(.caption)
                            .foregroundStyle(Color.xdrAmber)
                    }
                    .position(x: clampThumbX(thumbX, in: trackWidth),
                              y: geometry.size.height / 2 - thumbSize / 2 - 20)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .onDisappear { pulse = false }
                } else {
                    Text("\(currentNits) nits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .position(x: clampThumbX(thumbX, in: trackWidth),
                                  y: geometry.size.height / 2 - thumbSize / 2 - 20)
                        .animation(isDragging ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: brightness)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Brightness")
            .accessibilityValue("\(currentNits) nits")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    brightness = min(brightness + 0.05, maxBrightness)
                case .decrement:
                    brightness = max(brightness - 0.05, 0)
                @unknown default:
                    break
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let fraction = min(max(value.location.x / trackWidth, 0), 1)
                        var newBrightness = fraction * maxBrightness
                        // Snap to SDR/XDR boundary when within ±0.03
                        if abs(newBrightness - 1.0) < 0.03 && maxBrightness > 1.0 {
                            newBrightness = 1.0
                        }
                        brightness = newBrightness
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: thumbSize + 36) // thumb + nits label space
        .modifier(HapticDetentModifier(trigger: inXDRRange))
    }

    // MARK: - Track Fill

    @ViewBuilder
    private func trackFill(thumbX: CGFloat, trackWidth: CGFloat) -> some View {
        if inXDRRange {
            // XDR gradient fill
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.xdrAmber, Color.xdrOrange, Color.xdrGradientEnd],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(thumbX, 0), height: trackHeight)
                .animation(.easeInOut(duration: 0.25), value: inXDRRange)
        } else {
            // SDR fill — app blue gradient
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.appBlue, Color.appBlueLight],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(thumbX, 0), height: trackHeight)
                .animation(.easeInOut(duration: 0.25), value: inXDRRange)
        }
    }

    // MARK: - Helpers

    /// Clamp thumb so it doesn't overflow the track edges
    private func clampThumbX(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        let half = thumbSize / 2
        return min(max(x, half), width - half)
    }
}

// MARK: - Haptic Detent Modifier

/// Applies `.sensoryFeedback(.impact)` on macOS 14+; no-op on earlier versions.
private struct HapticDetentModifier: ViewModifier {
    let trigger: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .sensoryFeedback(.impact, trigger: trigger)
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview("XDR Display") {
    @Previewable @State var brightness = 1.2
    VStack(spacing: 24) {
        BrightnessSliderView(
            brightness: $brightness,
            isDragging: .constant(false),
            maxBrightness: 2.0,
            isXDR: true,
            currentNits: Int(brightness * 800)
        )
        .padding(.horizontal, 16)

        Text("Brightness: \(brightness, specifier: "%.2f")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .frame(width: 320)
    .padding()
}

#Preview("SDR Display") {
    @Previewable @State var brightness = 0.7
    BrightnessSliderView(
        brightness: $brightness,
        isDragging: .constant(false),
        maxBrightness: 1.0,
        isXDR: false,
        currentNits: Int(brightness * 500)
    )
    .padding(.horizontal, 16)
    .frame(width: 320)
    .padding()
}
