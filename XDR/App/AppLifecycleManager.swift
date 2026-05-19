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

    // MARK: - Animation State

    /// One task per display drives the 60fps brightness ramp.
    private var animationTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    // MARK: - Keyboard Shortcut Tasks

    /// One cancellable task per shortcut name prevents rapid-press task stacking.
    private var shortcutTasks: [String: Task<Void, Never>] = [:]

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
        // Wire sleep/wake restoration to XDR controller.
        // Capture xdrController directly (strong) — no retain cycle because
        // SleepWakeManager is owned by AppLifecycleManager which also owns
        // xdrController.  Using [weak self] here would fail to compile because
        // self is not yet fully initialised when SleepWakeManager is created.
        let controller = xdrController
        sleepWakeManager = SleepWakeManager(
            onRestore: { displayID, brightness in
                controller.setBrightness(brightness, for: displayID)
            },
            onRefresh: {
                controller.refreshOverlays()
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
            self?.shortcutTasks["toggleXDR"]?.cancel()
            self?.shortcutTasks["toggleXDR"] = Task { @MainActor in
                self?.toggleXDRForActiveDisplay()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .increaseBrightness) { [weak self] in
            self?.shortcutTasks["increaseBrightness"]?.cancel()
            self?.shortcutTasks["increaseBrightness"] = Task { @MainActor in
                self?.adjustBrightness(by: 0.05)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .decreaseBrightness) { [weak self] in
            self?.shortcutTasks["decreaseBrightness"]?.cancel()
            self?.shortcutTasks["decreaseBrightness"] = Task { @MainActor in
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

                let previousIDs = Set(self.displayManager.displays.map(\.id))
                self.displayManager.refreshDisplays()
                let currentIDs = Set(self.displayManager.displays.map(\.id))

                // Restore XDR for displays that just reconnected
                let reconnected = currentIDs.subtracting(previousIDs)
                for displayID in reconnected {
                    if let saved = self.sleepWakeManager.savedBrightness[displayID],
                       saved > XDRConstants.sdrMaxBrightness {
                        self.setBrightness(saved, for: displayID)
                    }
                }

                let freshDisplays = self.displayManager.displays
                appState.displays = freshDisplays.map { fresh in
                    var display = fresh
                    if reconnected.contains(fresh.id) {
                        // Reconnected display: brightness was just restored via
                        // setBrightness above; read the authoritative value from
                        // xdrController rather than stale AppState data.
                        display.brightness = self.xdrController.getBrightness(for: fresh.id)
                    } else if let existing = appState.displays.first(where: { $0.id == fresh.id }) {
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
            let key = "xdr_brightness_\(display.id)"
            let savedXDR = UserDefaults.standard.double(forKey: key)

            // If a persisted XDR value exists (> 1.0), restore it instead of
            // reading the SDR-only value from DisplayServices.
            let current: Double
            if savedXDR > XDRConstants.sdrMaxBrightness {
                current = savedXDR
                setBrightness(savedXDR, for: display.id)
            } else {
                current = xdrController.getBrightness(for: display.id)
                UserDefaults.standard.removeObject(forKey: key)
            }

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
        // Apply preset to ALL connected displays, clamping per-display by capability.
        for display in displayManager.displays {
            let maxAllowed = display.isXDR ? XDRConstants.xdrMaxBrightness : XDRConstants.sdrMaxBrightness
            let target = max(XDRConstants.minBrightness, min(preset.brightness, maxAllowed))
            let current = xdrController.getBrightness(for: display.id)
            animateBrightness(from: current, to: target, for: display.id)
        }
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let wasXDR = (xdrController.getBrightness(for: displayID) > XDRConstants.sdrMaxBrightness)
        let isXDR = (value > XDRConstants.sdrMaxBrightness)

        xdrController.setBrightness(value, for: displayID)
        sleepWakeManager.saveBrightness(value, for: displayID)
        sleepWakeManager.saveXDRActive(isXDR, for: displayID)

        // Persist XDR brightness so it survives app restarts.
        let key = "xdr_brightness_\(displayID)"
        if isXDR {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }

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
        cancelAllRamps()
        batteryTask?.cancel()
        thermalTask?.cancel()
        for (_, task) in shortcutTasks { task.cancel() }
        shortcutTasks.removeAll()
        sleepWakeManager.shutdown()
        xdrController.shutdown()
    }

    private func cancelAllRamps() {
        for (_, task) in animationTasks { task.cancel() }
        animationTasks.removeAll()
    }

    // MARK: - Smooth Transition

    private func animateBrightness(from start: Double, to end: Double, for displayID: CGDirectDisplayID) {
        // Fix 4: Respect smoothTransitions flag.
        guard appState?.smoothTransitions != false else {
            setBrightness(end, for: displayID)
            return
        }

        // Fix 5: Skip the ramp for imperceptibly small changes.
        guard abs(end - start) >= 0.01 else {
            setBrightness(end, for: displayID)
            return
        }

        // Fix 3: If a ramp is already in flight for this display, sample the
        // CURRENT brightness before canceling so we never regress.
        let actualStart: Double
        if animationTasks[displayID] != nil {
            actualStart = xdrController.getBrightness(for: displayID)
            animationTasks[displayID]?.cancel()
        } else {
            actualStart = start
        }

        // Fix 1 (fallback): CADisplayLink is API_UNAVAILABLE on macOS.
        // Drive the ramp with a Task that sleeps ~1/60 s per tick so we
        // achieve ~60fps eased updates without any extra dependencies.
        let frameDuration: UInt64 = 16_666_667 // nanoseconds (~60fps)
        let totalDuration = transitionDuration
        let rampStart = actualStart
        let rampEnd = end

        animationTasks[displayID] = Task { @MainActor [weak self] in
            let startTime = Date()
            while true {
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(startTime)
                let t = min(elapsed / totalDuration, 1.0)
                // Fix 2: ease-in-out cubic.
                let easedT = self?.easeInOutCubic(t) ?? t
                let value = rampStart + (rampEnd - rampStart) * easedT
                self?.setBrightness(value, for: displayID)
                if t >= 1.0 { return }
                try? await Task.sleep(nanoseconds: frameDuration)
            }
        }
    }

    // Fix 2: Cubic ease-in-out: 0->0, 0.5->0.5, 1->1.
    private func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: - Battery Auto-Disable

    private var batteryTask: Task<Void, Never>?

    private func startBatteryMonitoring() {
        batteryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
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
                if Task.isCancelled { return }
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

    private func sendNotification(title: String, body: String) {
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
