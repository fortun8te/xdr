import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let isXDRActive: Bool
    let showNits: Bool
    let currentNits: Int

    private var iconName: String {
        isXDRActive ? "sun.max.fill" : "sun.max"
    }

    var body: some View {
        if showNits {
            HStack(spacing: 2) {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))

                HStack(spacing: 0) {
                    Text("\(currentNits)")
                        .font(.caption2)
                        .monospacedDigit()

                    Text(" nits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

// MARK: - XDR Badge

struct XDRBadge: View {
    var compact: Bool = false

    var body: some View {
        Text("XDR")
            .font(compact ? .caption2 : .caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.xdrAmber)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.xdrAmber.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
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

#Preview("Components") {
    VStack(spacing: 12) {
        XDRBadge()
        XDRBadge(compact: true)
    }
    .padding()
}
