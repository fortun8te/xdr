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

    private var firstName: String {
        // First check if userName was set by @AppStorage
        if !userName.isEmpty { return userName }
        // Fall back to bundledUserName if set at build time
        if !XDRConstants.bundledUserName.isEmpty { return XDRConstants.bundledUserName }
        // Finally, system username
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
        VStack(spacing: 12) {
            // MARK: - Header

            HStack {
                Text(greeting)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            if showSettings {
                // MARK: - Inline Settings
                settingsPanel
            } else {
                // MARK: - Display Cards + Sliders
                displaysPanel
            }

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
                .onHover { isHovered in settingsHovered = isHovered }

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
                .onHover { isHovered in quitHovered = isHovered }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Displays Panel

    private var displaysPanel: some View {
        VStack(spacing: 12) {
            ForEach(appState.displays) { display in
                VStack(spacing: 8) {
                    DisplayCardView(display: display)
                    BrightnessSliderView(
                        brightness: Binding(
                            get: { appState.displays.first(where: { $0.id == display.id })?.brightness ?? 1.0 },
                            set: { newValue in
                                if let idx = appState.displays.firstIndex(where: { $0.id == display.id }) {
                                    appState.displays[idx].brightness = newValue
                                    lifecycle.setBrightness(newValue, for: display.id)
                                }
                            }
                        ),
                        maxBrightness: display.isXDR ? 2.0 : 1.0,
                        isXDR: display.isXDR,
                        currentNits: appState.nitsForBrightness(display.brightness, maxNits: display.maxNits)
                    )
                }
                .padding(.top, display.id == appState.displays.first?.id ? 4 : 0)
            }

            Divider().opacity(0.3)

            // Presets
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(BrightnessPreset.defaults) { preset in
                    PresetButton(preset: preset) {
                        lifecycle.applyPreset(preset)
                    }
                }
            }
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }

            // Toggles — all left-aligned, consistent style
            VStack(alignment: .leading, spacing: 10) {
                @Bindable var state = appState
                @AppStorage("autoDisableOnBattery") var autoDisable = false
                @AppStorage("batteryThreshold") var threshold = 20

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
                    Picker("Disable below", selection: $threshold) {
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

            // Shortcuts
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

            // Version
            Text("XDR v\(XDRConstants.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preset Button

private struct PresetButton: View {
    let preset: BrightnessPreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: preset.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(preset.name)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    PopoverContentView()
        .environment(AppState())
        .environment(AppLifecycleManager())
}
