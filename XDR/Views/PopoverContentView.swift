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
                    DisplayCard(display: display,
                                onSet: { lifecycle.setBrightness($0, for: display.id) },
                                surface: .popover)
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
                    Toggle("Show level in menu bar", isOn: $state.showLevelInMenuBar)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text("Boost mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $state.boostMode) {
                        ForEach(BoostMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: state.boostMode) { _, _ in
                        lifecycle.handleBoostModeChange()
                    }
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

#Preview {
    PopoverContentView()
        .environment(AppState())
        .environment(AppLifecycleManager())
}
