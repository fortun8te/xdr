import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let isXDRActive: Bool
    let showLevel: Bool
    let currentLevel: Double

    // Worst-case value ("10.0") used purely to reserve layout width so the
    // menu bar status item never resizes as the level changes.
    private static let widthPlaceholder = "10.0"

    private var iconName: String {
        isXDRActive ? "sun.max.fill" : "sun.max"
    }

    // Icon-only content used both for rendering (when showLevel == false) and
    // as the hidden placeholder ensuring the whole HStack has a stable width.
    private var iconView: some View {
        Image(systemName: iconName)
            .font(.system(size: 12))
            .contentTransition(.symbolEffect(.replace))
    }

    // Level text ("7.3") overlaid on top of an invisible "10.0" placeholder so the
    // numeric region's width is always the width of the worst-case string.
    private var levelView: some View {
        ZStack(alignment: .trailing) {
            Text(Self.widthPlaceholder)
                .font(.caption2)
                .monospacedDigit()
                .hidden()
            Text(String(format: "%.1f", currentLevel))
                .font(.caption2)
                .monospacedDigit()
        }
    }

    // The "real" content as it should appear given the current showLevel flag.
    private var visibleContent: some View {
        HStack(spacing: 3) {
            iconView
            if showLevel {
                levelView
            }
        }
    }

    // The worst-case content (icon + level) used as an invisible placeholder
    // so the outer frame is always the maximum possible width. This locks
    // the rendered label width across every level value. Toggling
    // showLevel in settings is still allowed to change the width once.
    private var widthAnchor: some View {
        HStack(spacing: 3) {
            iconView
            levelView
        }
        .hidden()
    }

    var body: some View {
        if showLevel {
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
        MenuBarLabel(isXDRActive: false, showLevel: false, currentLevel: 0.0)
        MenuBarLabel(isXDRActive: true, showLevel: false, currentLevel: 7.2)
    }
    .padding()
}

#Preview("Menu Bar - With Level") {
    VStack(spacing: 12) {
        MenuBarLabel(isXDRActive: false, showLevel: true, currentLevel: 0.0)
        MenuBarLabel(isXDRActive: true, showLevel: true, currentLevel: 10.0)
    }
    .padding()
}
