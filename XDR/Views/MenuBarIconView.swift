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
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .contentTransition(.symbolEffect(.replace))

            if showNits {
                HStack(spacing: 0) {
                    Text("\(currentNits)")
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)

                    Text(" nits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 16, alignment: .leading)
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

