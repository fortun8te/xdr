import Foundation
import AppKit
import KeyboardShortcuts
import UserNotifications

@MainActor
@Observable
final class AppLifecycleManager {
    /// Shared instance for App Intents and other out-of-hierarchy access.
    static var shared: AppLifecycleManager?

    let displayManager = DisplayManager.shared
    let xdrController = XDRController()
    let sleepWakeManager: SleepWakeManager
    let batteryMonitor = BatteryMonitor()

    /// Back-reference to AppState so brightness changes update the menu bar icon.
    var appState: AppState?

    /// Smooth transition duration in seconds.
    private let transitionDuration = XDRConstants.brightnessTransitionDuration
    private let transitionSteps = 20
    private var animationTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    // MARK: - Battery Auto-Disable State

    /// Tracks whether XDR was already auto-disabled by the battery monitor
    /// this discharge cycle, so we don't keep re-notifying on every poll.
    private var didAutoDisableForBattery = false

    // MARK: - Thermal Tracking

    /// When XDR was first activated on each display (nil = not active).
    private var xdrActivationTime: [CGDirectDisplayID: Date] = [:]

    /// Tracks whether we already sent the thermal reminder for each display
    /// this activation session (reset when XDR is deactivated).
    private var thermalReminderSent: [CGDirectDisplayID: Bool] = [:]

    /// Duration after which we send an informational thermal reminder.
    private static let thermalReminderInterval: TimeInterval = 30 * 60 // 30 minutes

    init() {
        // Wire sleep/wake restoration to XDR controller
        sleepWakeManager = SleepWakeManager(
            onRestore: { [weak xdrController] displayID, brightness in
                xdrController?.setBrightness(brightness, for: displayID)
            },
            onRefresh: { [weak xdrController] in
                xdrController?.refreshOverlays()
            }
        )

        // Register as shared instance for App Intents access
        Self.shared = self

        requestNotificationPermission()
        setupKeyboardShortcuts()
        startDisplayMonitoring()
        startBatteryMonitoring()
        startThermalMonitoring()
    }

    // MARK: - Setup

    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleXDR) { [weak self] in
            Task { @MainActor in
                self?.toggleXDRForActiveDisplay()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .increaseBrightness) { [weak self] in
            Task { @MainActor in
                self?.adjustBrightness(by: 0.05)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .decreaseBrightness) { [weak self] in
            Task { @MainActor in
                self?.adjustBrightness(by: -0.05)
            }
        }
    }

    private func startDisplayMonitoring() {
        // Initial display enumeration happens in DisplayManager.init
        // Sync display brightness readings
        syncBrightnessFromSystem()

        // Re-sync appState.displays when monitors are connected/disconnected
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let appState = self.appState else { return }
                self.displayManager.refreshDisplays()
                let freshDisplays = self.displayManager.displays
                appState.displays = freshDisplays.map { fresh in
                    var display = fresh
                    if let existing = appState.displays.first(where: { $0.id == fresh.id }) {
                        display.brightness = existing.brightness
                    }
                    return display
                }
            }
        }
    }

    // MARK: - Public API

    func syncBrightnessFromSystem() {
        for display in displayManager.displays {
            let current = xdrController.getBrightness(for: display.id)
            sleepWakeManager.saveBrightness(current, for: display.id)
            sleepWakeManager.saveXDRActive(current > 1.0, for: display.id)

            // Keep AppState in sync so the menu bar icon updates
            if let idx = appState?.displays.firstIndex(where: { $0.id == display.id }) {
                appState?.displays[idx].brightness = current
            }
        }
    }

    func toggleXDRForActiveDisplay() {
        guard let display = activeDisplay() else { return }
        let current = xdrController.getBrightness(for: display.id)

        if current > XDRConstants.sdrMaxBrightness {
            // Currently in XDR range -- transition down to SDR max
            animateBrightness(from: current, to: XDRConstants.sdrMaxBrightness, for: display.id)
        } else {
            // Currently in SDR range -- transition up to XDR sweet spot (1.4 = ~940 nits)
            guard display.isXDR else { return }
            animateBrightness(from: current, to: 1.4, for: display.id)
        }
    }

    func adjustBrightness(by delta: Double) {
        guard let display = activeDisplay() else { return }
        let current = xdrController.getBrightness(for: display.id)
        let maxAllowed = display.isXDR ? XDRConstants.xdrMaxBrightness : XDRConstants.sdrMaxBrightness
        let target = max(XDRConstants.minBrightness, min(current + delta, maxAllowed))

        setBrightness(target, for: display.id)
    }

    func applyPreset(_ preset: BrightnessPreset) {
        guard let display = activeDisplay() else { return }
        let maxAllowed = display.isXDR ? XDRConstants.xdrMaxBrightness : XDRConstants.sdrMaxBrightness
        let target = max(XDRConstants.minBrightness, min(preset.brightness, maxAllowed))
        let current = xdrController.getBrightness(for: display.id)

        animateBrightness(from: current, to: target, for: display.id)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let wasXDR = (xdrController.getBrightness(for: displayID) > XDRConstants.sdrMaxBrightness)
        let isXDR = (value > XDRConstants.sdrMaxBrightness)

        xdrController.setBrightness(value, for: displayID)
        sleepWakeManager.saveBrightness(value, for: displayID)
        sleepWakeManager.saveXDRActive(isXDR, for: displayID)

        // Track XDR activation time for thermal monitoring
        if isXDR && !wasXDR {
            xdrActivationTime[displayID] = Date()
            thermalReminderSent[displayID] = false
        } else if !isXDR && wasXDR {
            xdrActivationTime.removeValue(forKey: displayID)
            thermalReminderSent.removeValue(forKey: displayID)
        }

        // Keep AppState in sync so the menu bar icon updates
        if let idx = appState?.displays.firstIndex(where: { $0.id == displayID }) {
            appState?.displays[idx].brightness = value
        }
    }

    /// Called from XDRApp on applicationWillTerminate to ensure gamma tables
    /// are reset to identity before the process exits.
    func shutdown() {
        batteryTask?.cancel()
        thermalTask?.cancel()
        xdrController.shutdown()
    }

    // MARK: - Smooth Transition

    private func animateBrightness(from start: Double, to end: Double, for displayID: CGDirectDisplayID) {
        animationTasks[displayID]?.cancel()

        let steps = transitionSteps
        let stepDuration = transitionDuration / Double(steps)
        let delta = (end - start) / Double(steps)

        animationTasks[displayID] = Task { @MainActor [weak self] in
            for i in 1...steps {
                let sleepNanoseconds = UInt64(stepDuration * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
                guard !Task.isCancelled else { return }
                let value = (i == steps) ? end : start + delta * Double(i)
                self?.setBrightness(value, for: displayID)
            }
        }
    }

    // MARK: - Battery Auto-Disable

    private var batteryTask: Task<Void, Never>?

    private func startBatteryMonitoring() {
        batteryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.checkBatteryState()
            }
        }
    }

    private func checkBatteryState() {
        let enabled = UserDefaults.standard.bool(forKey: "autoDisableOnBattery")
        guard enabled else { return }

        // Reset the auto-disable flag when plugged back in, but do NOT
        // re-enable XDR -- let the user do that manually.
        if !batteryMonitor.isOnBattery {
            didAutoDisableForBattery = false
            return
        }

        // Already handled this discharge cycle
        guard !didAutoDisableForBattery else { return }

        let threshold = UserDefaults.standard.integer(forKey: "batteryThreshold")
        let effectiveThreshold = threshold > 0 ? threshold : 20

        guard batteryMonitor.shouldDisableXDR(threshold: effectiveThreshold) else { return }

        var didDisableAny = false
        for display in displayManager.displays {
            let current = xdrController.getBrightness(for: display.id)
            if current > XDRConstants.sdrMaxBrightness {
                animateBrightness(from: current, to: XDRConstants.sdrMaxBrightness, for: display.id)
                didDisableAny = true
            }
        }

        if didDisableAny {
            didAutoDisableForBattery = true
            sendNotification(
                title: "XDR Brightness Disabled",
                body: "Battery at \(batteryMonitor.batteryLevel)% -- XDR was disabled to save power. Plug in to re-enable."
            )
        }
    }

    // MARK: - Thermal Monitoring

    private var thermalTask: Task<Void, Never>?

    private func startThermalMonitoring() {
        thermalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60)) // Check every minute
                self?.checkThermalState()
            }
        }
    }

    private func checkThermalState() {
        let now = Date()
        for (displayID, activationTime) in xdrActivationTime {
            // Skip if we already sent a reminder for this activation session
            guard thermalReminderSent[displayID] != true else { continue }

            let elapsed = now.timeIntervalSince(activationTime)
            if elapsed >= Self.thermalReminderInterval {
                let minutes = Int(elapsed / 60)
                let displayName = displayManager.displays.first(where: { $0.id == displayID })?.name ?? "Display"
                sendNotification(
                    title: "XDR Active for \(minutes) Minutes",
                    body: "\(displayName) has been running at XDR brightness. Extended use increases power draw and heat."
                )
                thermalReminderSent[displayID] = true
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private nonisolated func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private func activeDisplay() -> DisplayInfo? {
        // Prefer the display under the mouse cursor, fall back to main display
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            let cursorDisplayID = screen.displayID
            return displayManager.displays.first { $0.id == cursorDisplayID }
        }
        // Fall back to the first (main) display
        return displayManager.displays.first
    }
}
