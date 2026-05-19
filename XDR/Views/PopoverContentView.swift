// XDR — Menu bar popover (rewritten May 2026)
// ============================================================
// Minimal popover surfaced from the menu bar. Mirrors the MainWindowView
// design language (Sp tokens, CardShape, slim XDR boost meter) but rendered
// on `.ultraThinMaterial` since it floats over the desktop.
//
// No presets row, no legacy DisplayCardView / BrightnessSliderView — those
// were retired with the redesign. Layout, top to bottom:
//   * Greeting header
//   * Per-display compact card (name, subtitle, big serif nits, SDR/XDR pill,
//     slim XDR boost meter on the bottom row)
//   * Empty state when no displays connected
//   * Settings panel (slid in/out via Group transition) — unchanged
//   * Bottom bar with Settings/Back + Quit
// ============================================================

import SwiftUI
import LaunchAtLogin
import KeyboardShortcuts

// MARK: - Cached formatters

private let nitsFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

struct PopoverContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleManager.self) private var lifecycle

    @State private var showSettings = false
    @State private var settingsHovered = false
    @State private var quitHovered = false

    @AppStorage("userName") private var userName = ""
    @AppStorage("autoDisableOnBattery") private var autoDisable = false
    @AppStorage("batteryThreshold") private var batteryThreshold = 20

    private var firstName: String {
        if !userName.isEmpty { return userName }
        if !XDRConstants.bundledUserName.isEmpty { return XDRConstants.bundledUserName }
        return NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning, \(firstName)!"
        case 12..<17: return "Good afternoon, \(firstName)!"
        case 17..<22: return "Good evening, \(firstName)!"
        default:      return "Hey \(firstName)!"
        }
    }

    var body: some View {
        VStack(spacing: Sp.md) {
            // MARK: - Header
            HStack {
                Text(greeting)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }

            Group {
                if showSettings {
                    settingsPanel
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                } else {
                    displaysPanel
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSettings)

            Divider().opacity(0.3)

            // MARK: - Bottom Bar
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettings.toggle()
                    }
                } label: {
                    Label(showSettings ? "Back" : "Settings",
                          systemImage: showSettings ? "chevron.left" : "gearshape")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(settingsHovered ? 1.0 : 0.7)
                .onHover { settingsHovered = $0 }

                Spacer()

                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(quitHovered ? 1.0 : 0.7)
                .onHover { quitHovered = $0 }
            }
        }
        .padding(Sp.lg)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Displays Panel

    private var displaysPanel: some View {
        VStack(spacing: Sp.sm) {
            if appState.displays.isEmpty {
                HStack(spacing: Sp.sm) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("No displays detected")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Sp.md)
            } else {
                ForEach(appState.displays) { display in
                    PopoverDisplayCard(display: display)
                }
            }
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 10) {
                @Bindable var state = appState

                HStack {
                    LaunchAtLogin.Toggle("Launch at Login")
                        .font(.subheadline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                HStack {
                    Toggle("Smooth transitions", isOn: $state.smoothTransitions)
                        .font(.subheadline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                HStack {
                    Toggle("Show nits in menu bar", isOn: $state.showNitsInMenuBar)
                        .font(.subheadline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                HStack {
                    Toggle("Auto-disable on low battery", isOn: $autoDisable)
                        .font(.subheadline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }

                if autoDisable {
                    Picker("Disable below", selection: $batteryThreshold) {
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                    .font(.subheadline)
                    .pickerStyle(.segmented)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.3)

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Toggle XDR", name: .toggleXDR)
                    .font(.subheadline)
                KeyboardShortcuts.Recorder("Brightness +", name: .increaseBrightness)
                    .font(.subheadline)
                KeyboardShortcuts.Recorder("Brightness -", name: .decreaseBrightness)
                    .font(.subheadline)
            }

            Text("XDR v\(XDRConstants.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Popover Display Card
//
// Compact display card scoped to the popover. Mirrors MainWindowView's
// DisplayCard but lives here so the popover can ship without depending on
// types declared `private` inside MainWindowView.

private struct PopoverDisplayCard: View {
    let display: DisplayInfo

    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleManager.self) private var lifecycle
    @Environment(\.colorScheme) private var scheme

    private var headerIcon: String {
        display.isBuiltIn ? "display" : "display.2"
    }

    private var subtitle: String {
        switch (display.isBuiltIn, display.isXDR) {
        case (true,  true):  return "Liquid Retina XDR"
        case (true,  false): return "Built-in Display"
        case (false, true):  return "Pro Display XDR"
        case (false, false): return "External Display"
        }
    }

    private var nitsString: String {
        let n = appState.nitsForBrightness(display.brightness, maxNits: display.maxNits)
        return nitsFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
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

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(nitsString)
                            .font(.serif(20, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        Text("nits")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    PopoverModeBadge(isXDRActive: display.brightness > 1.0 && display.isXDR)
                }
            }

            XDRBoostMeter(
                brightness: display.brightness,
                isXDR: display.isXDR,
                onSet: { newValue in
                    lifecycle.setBrightness(newValue, for: display.id)
                }
            )
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

// MARK: - Mode badge (popover-scoped)

private struct PopoverModeBadge: View {
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

#Preview {
    PopoverContentView()
        .environment(AppState())
        .environment(AppLifecycleManager())
}
