import SwiftUI

// MARK: - Display card

/// Shared display card used by both the main window and the popover.
/// The only visual difference between the two surfaces is the card background
/// fill opacity; `Surface` encodes those exact values so each context renders
/// what it always did.
struct DisplayCard: View {
    let display: DisplayInfo
    var onSet: (Double) -> Void
    var onEditingEnded: (() -> Void)? = nil
    let surface: Surface

    enum Surface {
        case window, popover

        var darkFillOpacity: Double {
            switch self {
            case .window:  return 0.04
            case .popover: return 0.05
            }
        }

        var lightFillOpacity: Double {
            switch self {
            case .window:  return 0.025
            case .popover: return 0.03
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme

    private var headerIcon: String {
        display.isBuiltIn ? "display" : "display.2"
    }

    private var subtitle: String {
        if display.supportsDDCBrightness { return "Monitor brightness" }
        switch (display.isBuiltIn, display.isXDR) {
        case (true,  true):  return "Liquid Retina XDR"
        case (true,  false): return "Built-in Display"
        case (false, true):  return "Pro Display XDR"
        case (false, false): return "External Display"
        }
    }

    private var levelString: String {
        XDRConstants.levelString(forBrightness: display.brightness)
    }

    private var isDimmed: Bool { display.supportsHardwareBrightness == false }

    private var percentString: String {
        "\(Int((display.brightness * 100).rounded()))"
    }

    @ViewBuilder private var boostReadout: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(levelString)
                    .font(.serif(20, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("/ 10")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            ModeBadge(isXDRActive: display.brightness > 1.0 && display.isXDR)
        }
    }

    @ViewBuilder private var dimReadout: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percentString)
                    .font(.serif(20, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if display.supportsDDCBrightness { Text("HARDWARE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) } else { DimBadge() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            HStack(alignment: .top, spacing: Sp.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: headerIcon)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(display.name)
                            .font(.bodyMedium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(subtitle)
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isDimmed || display.supportsDDCBrightness { dimReadout } else { boostReadout }
            }

            if display.supportsDDCBrightness {
                TernBrightnessSlider(value: display.brightness, onSet: onSet, onEditingEnded: onEditingEnded)
            } else if isDimmed {
                DimSlider(level: display.brightness, onSet: onSet)
            } else {
                XDRBoostMeter(
                    brightness: display.brightness,
                    isXDR: display.isXDR,
                    onSet: onSet
                )
            }
            if let message = display.controlMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Sp.sm)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(surface.darkFillOpacity)
                    : Color.black.opacity(surface.lightFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: CardShape.borderUnselected)
        )
    }
}

// MARK: - Mode badge

struct ModeBadge: View {
    let isXDRActive: Bool

    var body: some View {
        Text(isXDRActive ? "XDR" : "SDR")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(isXDRActive ? Color.xdrAmber : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                (isXDRActive ? Color.xdrAmber : Color.secondary).opacity(0.14),
                in: Capsule()
            )
    }
}

// MARK: - Dim badge

struct DimBadge: View {
    var body: some View {
        Text("DIM")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
    }
}

// Keep gesture feedback local and remove the 101 tick marks generated by a stepped Slider.
private struct TernBrightnessSlider: View {
    let value: Double
    let onSet: (Double) -> Void
    let onEditingEnded: (() -> Void)?
    @State private var gestureValue: Double?
    @State private var isEditing = false
    var body: some View {
        Slider(value: Binding(get: { isEditing ? (gestureValue ?? value) : value }, set: { next in
            gestureValue = next
            onSet(next)
        }), in: 0...1, onEditingChanged: { editing in
            isEditing = editing
            if !editing { onEditingEnded?(); gestureValue = nil }
        })
        .accessibilityLabel("Tern hardware brightness")
    }
}
