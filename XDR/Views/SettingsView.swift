import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("autoDisableOnBattery") private var autoDisableOnBattery = false
    @AppStorage("batteryThreshold") private var batteryThreshold = 20
    @AppStorage("userName") private var userName = ""
    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                TextField("Your name", text: $userName, prompt: Text("Used for greeting"))
                LaunchAtLogin.Toggle("Launch at Login")
                Toggle("Smooth brightness transitions", isOn: $appState.smoothTransitions)
                Toggle("Show nits in menu bar", isOn: $appState.showNitsInMenuBar)
            }

            Section("Battery") {
                Toggle("Auto-disable XDR on battery", isOn: $autoDisableOnBattery)
                if autoDisableOnBattery {
                    Picker("Disable below", selection: $batteryThreshold) {
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettingsTab: View {
    var body: some View {
        Form {
            Text("Customize keyboard shortcuts for quick brightness control.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Section {
                KeyboardShortcuts.Recorder("Toggle XDR", name: .toggleXDR)
                KeyboardShortcuts.Recorder("Increase Brightness", name: .increaseBrightness)
                KeyboardShortcuts.Recorder("Decrease Brightness", name: .decreaseBrightness)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("XDR")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(XDRConstants.appVersion) (\(XDRConstants.buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\u{00A9} 2026 XDR. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)


            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
