// XDR — Main App Window (redesigned May 2026, compact-boost edition)
// ============================================================
// 240pt-wide window. macOS already owns SDR adjustment (F1/F2, Control Center,
// the native HUD) for the 0.0–1.0 range. This window owns the "boost" — the
// extra headroom above the macOS max, 1.0–2.0 on XDR-capable panels.
//
// Layout, top to bottom (single-display window ~240 × ~260):
//   * Permissions banner (only when !permissions.allGranted)
//   * Compact display card:
//       - Header: icon + display name + big serif current-nits (right)
//       - Subtitle line (Liquid Retina XDR / Built-in / etc.)
//       - XDRBoostMeter — slim capsule that only spans the boost range
//       - Preset chip row (Normal / Extra / Outdoor), very compact
//   * Empty state when no displays are connected
//   * Divider + footer (settings gear + Quit XDR)
//
// Settings sheet (`SettingsSheet`) and the permissions sheet are unchanged.
// ============================================================

import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

// MARK: - Root view

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleManager.self) private var lifecycle

    @State private var showSettings = false
    @State private var showPermissionsSheet = false
    @State private var permissions = PermissionsService.shared

    var body: some View {
        ZStack {
            AppShellBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !permissions.allGranted {
                    PermissionsBanner(onTap: { showPermissionsSheet = true })
                        .padding(.horizontal, Sp.sm)
                        .padding(.top, Sp.sm)
                }

                if appState.displays.isEmpty {
                    emptyState
                        .padding(.vertical, Sp.md)
                } else {
                    VStack(spacing: Sp.sm) {
                        ForEach(appState.displays) { display in
                            DisplayCard(display: display,
                                        onSet: { lifecycle.setBrightness($0, for: display.id) },
                                        surface: .window)
                        }
                    }
                    .padding(.horizontal, Sp.sm)
                    .padding(.top, Sp.sm)
                    .padding(.bottom, Sp.sm)
                }

                Divider()
                footer
            }
        }
        .frame(width: 240)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showPermissionsSheet) {
            PermissionsView(onDone: { showPermissionsSheet = false })
                .frame(minWidth: 460, minHeight: 440)
        }
        .task {
            permissions.refresh()
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: Sp.sm) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("No displays detected")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Sp.sm)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Sp.sm)
                    .padding(.vertical, Sp.xs)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Sp.sm))
            }
            .buttonStyle(.plain)
            .help("Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit XDR")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Sp.sm)
                    .padding(.vertical, Sp.xs)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Sp.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Sp.sm)
        .padding(.vertical, Sp.sm)
    }
}

// MARK: - Permissions banner

private struct PermissionsBanner: View {
    var onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Sp.sm) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)

                Text("Set up XDR")
                    .font(.bodyMedium.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Sp.sm)
            .padding(.vertical, Sp.xs)
            .background(
                RoundedRectangle(cornerRadius: CardShape.corner)
                    .fill(Color.orange.opacity(isHovering ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardShape.corner)
                    .strokeBorder(Color.orange.opacity(0.25), lineWidth: CardShape.borderUnselected)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: CardShape.corner))
        .onHover { isHovering = $0 }
        .help("Open the XDR permission setup")
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleManager.self) private var lifecycle
    @Environment(\.dismiss) private var dismiss

    @AppStorage("userName") private var userName: String = ""
    @AppStorage("autoDisableOnBattery") private var autoDisableOnBattery: Bool = false
    @AppStorage("batteryThreshold") private var batteryThreshold: Int = 20

    @State private var permissions = PermissionsService.shared
    @State private var showFullPermissionsSheet = false
    @State private var refreshTimer: Timer?

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.serifTitle)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.top, Sp.xl)
            .padding(.bottom, Sp.lg)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    section("Name") {
                        TextField("Your name", text: $userName)
                            .textFieldStyle(.roundedBorder)
                            .font(.bodyBase)
                    }

                    Divider()

                    section("Menu bar") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("Show level in menu bar", isOn: $state.showLevelInMenuBar)
                            LaunchAtLogin.Toggle("Launch at Login")
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.bodyBase)
                        }
                    }

                    Divider()

                    section("Behavior") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Boost mode")
                                        .font(.bodyBase)
                                        .foregroundStyle(.primary)
                                    Text(state.boostMode == .gamma
                                         ? "Color-safe, lower peak (~750 nits)"
                                         : "Brighter (~1100 nits), slight SDR shift")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Picker("", selection: $state.boostMode) {
                                    ForEach(BoostMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                                .labelsHidden()
                                .onChange(of: state.boostMode) { _, _ in
                                    lifecycle.handleBoostModeChange()
                                }
                            }

                            toggle("Smooth transitions", isOn: $state.smoothTransitions)
                            toggle("Auto-disable on low battery", isOn: $autoDisableOnBattery)

                            if autoDisableOnBattery {
                                HStack {
                                    Text("Disable below")
                                        .font(.bodyBase)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Picker("", selection: $batteryThreshold) {
                                        Text("20%").tag(20)
                                        Text("30%").tag(30)
                                        Text("50%").tag(50)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 200)
                                    .labelsHidden()
                                }
                                .padding(.leading, Sp.xl)
                            }
                        }
                    }

                    Divider()

                    section("Hotkeys") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            hotkeyRow("Toggle XDR", name: .toggleXDR)
                            hotkeyRow("Brightness +", name: .increaseBrightness)
                            hotkeyRow("Brightness −", name: .decreaseBrightness)
                        }
                    }

                    Divider()

                    section("Permissions") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            permissionRow(
                                "Notifications",
                                granted: permissions.notifications == .granted
                            ) {
                                openPane("Notifications")
                            }
                            permissionRow(
                                "Input Monitoring",
                                granted: permissions.inputMonitoring == .granted
                            ) {
                                openPane("Privacy_ListenEvent")
                            }

                            if !permissions.allGranted {
                                Button {
                                    showFullPermissionsSheet = true
                                } label: {
                                    Text("Open setup")
                                        .font(.bodyMedium)
                                        .padding(.horizontal, Sp.md)
                                        .padding(.vertical, Sp.xs)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, Sp.xs)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("XDR v\(XDRConstants.appVersion)")
                    .font(.bodySmall)
                    .foregroundStyle(.quaternary)
                Spacer()
                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(.bodyMedium)
                        .padding(.horizontal, Sp.md)
                        .padding(.vertical, Sp.xs)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
        }
        .frame(width: 460, height: 520)
        .background(AppShellBackground().ignoresSafeArea())
        .sheet(isPresented: $showFullPermissionsSheet) {
            PermissionsView(onDone: { showFullPermissionsSheet = false })
                .frame(minWidth: 500, minHeight: 480)
        }
        .onAppear {
            permissions.refresh()
            let t = Timer(timeInterval: 1.5, repeats: true) { _ in
                DispatchQueue.main.async { permissions.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Section helpers

    @ViewBuilder
    private func section<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            Text(label.uppercased())
                .font(.label)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.lg)
    }

    @ViewBuilder
    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.primary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    @ViewBuilder
    private func hotkeyRow(_ label: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.primary)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    @ViewBuilder
    private func permissionRow(_ label: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: Sp.sm) {
            Circle()
                .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: granted ? "checkmark" : "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(granted ? .green : .orange)
                )
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.primary)
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.borderless)
                    .font(.bodyMedium)
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.bodySmall)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func openPane(_ key: String) {
        let urlString: String
        if key == "Notifications" {
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?\(key)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
