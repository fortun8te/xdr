import SwiftUI

struct DisplayCardView: View {
    let display: DisplayInfo
    @State private var glowActive = false

    private var isXDRActive: Bool {
        display.brightness > 1.0
    }

    private var subtitle: String {
        switch (display.isBuiltIn, display.isXDR) {
        case (true, true):   return "Liquid Retina XDR"
        case (true, false):  return "Built-in Display"
        case (false, true):  return "Pro Display XDR"
        case (false, false): return "External Display"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltIn ? "display" : "display.2")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if display.isXDR {
                Text("XDR")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.xdrAmber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.xdrAmber.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: isXDRActive ? Color.xdrAmber.opacity(glowActive ? 0.5 : 0.0) : .clear, radius: 4)
            } else {
                Text("SDR")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Divider().opacity(0.15) }
        .onAppear {
            guard display.isXDR && isXDRActive else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowActive = true
            }
        }
        .onChange(of: isXDRActive) { _, active in
            guard display.isXDR else { return }
            if active {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    glowActive = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    glowActive = false
                }
            }
        }
    }
}
