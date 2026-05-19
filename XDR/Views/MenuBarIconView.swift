import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let isXDRActive: Bool
    let showNits: Bool
    let currentNits: Int

    // Worst-case 4-digit value used purely to reserve layout width so the
    // menu bar status item never resizes as currentNits changes.
    private static let widthPlaceholder = "1600"

    private var iconName: String {
        isXDRActive ? "sun.max.fill" : "sun.max"
    }

    // Icon-only content used both for rendering (when showNits == false) and
    // as the hidden placeholder ensuring the whole HStack has a stable width.
    private var iconView: some View {
        Image(systemName: iconName)
            .font(.system(size: 12))
            .contentTransition(.symbolEffect(.replace))
    }

    // Nits text overlaid on top of an invisible 4-digit placeholder so the
    // numeric region's width is always the width of the worst-case string.
    private var nitsView: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(Self.widthPlaceholder)
                    .font(.caption2)
                    .monospacedDigit()
                    .hidden()
                Text("\(currentNits)")
                    .font(.caption2)
                    .monospacedDigit()
            }

            Text(" nits")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // The "real" content as it should appear given the current showNits flag.
    private var visibleContent: some View {
        HStack(spacing: 2) {
            iconView
            if showNits {
                nitsView
            }
        }
    }

    // The worst-case content (icon + nits) used as an invisible placeholder
    // so the outer frame is always the maximum possible width. This locks
    // the rendered label width across every currentNits value. Toggling
    // showNits in settings is still allowed to change the width once.
    private var widthAnchor: some View {
        HStack(spacing: 2) {
            iconView
            nitsView
        }
        .hidden()
    }

    var body: some View {
        if showNits {
            ZStack(alignment: .trailing) {
                widthAnchor
                visibleContent
            }
            .fixedSize()
        } else {
            visibleContent
                .fixedSize()
        }
    }
}

// MARK: - Previews

#Preview("Menu Bar - Icon Only") {
    VStack(spacing: 12) {
        MenuBarLabel(isXDRActive: false, showNits: false, currentNits: 500)
        MenuBarLabel(isXDRActive: true, showNits: false, currentNits: 720)
    }
    .padding()
}

#Preview("Menu Bar - With Nits") {
    VStack(spacing: 12) {
        MenuBarLabel(isXDRActive: false, showNits: true, currentNits: 500)
        MenuBarLabel(isXDRActive: true, showNits: true, currentNits: 1600)
    }
    .padding()
}
