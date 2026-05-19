import AppKit
import Foundation
import IOKit
import Observation
import os.log

// MARK: - SleepWakeManager

@MainActor
@Observable
final class SleepWakeManager {

    // MARK: - State

    /// Brightness levels saved before sleep, keyed by display ID
    private(set) var savedBrightness: [CGDirectDisplayID: Double] = [:]

    /// Whether XDR mode was active per display before sleep
    private(set) var savedXDRActive: [CGDirectDisplayID: Bool] = [:]

    /// True while a restoration pass is in progress
    private(set) var isRestoring = false

    // MARK: - Private

    /// Debounce flag: prevents duplicate restoration when both didWake and screensDidWake fire
    private var isWakeRestoreScheduled = false

    /// Post-wake watchdog: periodically refreshes overlays for 30 seconds after wake
    private var watchdogTask: Task<Void, Never>?

    private let onRestore: (CGDirectDisplayID, Double) -> Void
    private let onRefresh: () -> Void
    private let logger = Logger(subsystem: "com.xdr.app", category: "SleepWake")

    // MARK: - Lifecycle

    init(onRestore: @escaping (CGDirectDisplayID, Double) -> Void, onRefresh: @escaping () -> Void = {}) {
        self.onRestore = onRestore
        self.onRefresh = onRefresh
        registerNotifications()
        logger.info("SleepWakeManager initialized")
    }

    deinit {
        // Only use NotificationCenter.default.removeObserver(self) which is thread-safe.
        // NSWorkspace.shared.notificationCenter is main-thread-only and unsafe to call
        // from nonisolated deinit. NSWorkspace notification observers are automatically
        // cleaned up when the observer is deallocated.
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Shutdown

    /// Cancels the post-wake watchdog task. Call from AppLifecycleManager.shutdown().
    func shutdown() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Public API

    /// Call this whenever brightness changes so we have the latest state to restore after wake.
    func saveBrightness(_ level: Double, for displayID: CGDirectDisplayID) {
        savedBrightness[displayID] = level
    }

    /// Call this whenever XDR activation state changes.
    func saveXDRActive(_ active: Bool, for displayID: CGDirectDisplayID) {
        savedXDRActive[displayID] = active
    }

    // MARK: - Notification Registration

    private func registerNotifications() {
        let wsnc = NSWorkspace.shared.notificationCenter

        wsnc.addObserver(
            self,
            selector: #selector(willSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(didWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(screensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        wsnc.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    // MARK: - Sleep Handlers

    @objc private func willSleep(_ note: Notification) {
        logger.info("System will sleep — state already saved (\(self.savedBrightness.count) displays)")
    }

    @objc private func screensDidSleep(_ note: Notification) {
        logger.info("Screens did sleep — state preserved (\(self.savedBrightness.count) displays)")
    }

    // MARK: - Wake Handlers

    @objc private func didWake(_ note: Notification) {
        scheduleWakeRestore(source: "System did wake")
    }

    @objc private func screensDidWake(_ note: Notification) {
        scheduleWakeRestore(source: "Screens did wake")
    }

    @objc private func screenDidUnlock(_ note: Notification) {
        logger.info("Screen unlocked — scheduling delayed restore")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            self?.restoreAllDisplays(pass: 0)
        }
    }

    /// Shared wake-restore scheduling with debounce so only one double-pass runs
    /// even when both didWake and screensDidWake fire on the same wake event.
    private func scheduleWakeRestore(source: String) {
        guard !isWakeRestoreScheduled else {
            logger.info("\(source) — skipping (restoration already scheduled)")
            return
        }
        isWakeRestoreScheduled = true
        logger.info("\(source) — scheduling double-pass restoration")

        // Pass 1: 1.5s — catches most displays
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.restoreAllDisplays(pass: 1)
        }

        // Pass 2: 3.0s — catches slow-initializing displays (Thunderbolt, USB-C hubs).
        // Skip onRefresh() here (pass != 0) to avoid a second Metal teardown that causes
        // a visible brightness dip ~3s after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.restoreAllDisplays(pass: 2)
            self?.isWakeRestoreScheduled = false
        }

        // Watchdog: 3 checks × 5s = 15s of post-wake monitoring
        // Each tick tears down stale Metal state (onRefresh) then restores brightness (onRestore)
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            for tick in 0..<3 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.logger.info("Watchdog tick \(tick + 1)/3 — refreshing overlays")
                self.onRefresh()
                // Re-apply brightness so XDR state is rebuilt after refresh teardown
                for (displayID, brightness) in self.savedBrightness {
                    guard self.savedXDRActive[displayID] == true else { continue }
                    self.onRestore(displayID, brightness)
                }
            }
        }
    }

    // MARK: - Restoration

    private func restoreAllDisplays(pass: Int) {
        isRestoring = true

        // Tear down and recreate overlays to ensure fresh Metal state after sleep/wake.
        // Skip on pass 2 — a second teardown at 3s causes a visible brightness dip.
        if pass != 2 {
            logger.info("Restore pass \(pass) — refreshing overlays before restoration")
            onRefresh()
        } else {
            logger.info("Restore pass \(pass) — skipping overlay refresh to prevent brightness dip")
        }

        let clamshellClosed = isClamshellClosed()

        logger.info("Restore pass \(pass) — clamshell closed: \(clamshellClosed)")

        var restoredCount = 0
        var skippedCount = 0

        for (displayID, brightness) in savedBrightness {
            // Skip built-in display when lid is closed
            if clamshellClosed && isBuiltInDisplay(displayID) {
                logger.info("  Skip built-in display \(displayID) (clamshell closed)")
                skippedCount += 1
                continue
            }

            let wasXDRActive = savedXDRActive[displayID] == true
            logger.info("  Restoring display \(displayID) to brightness \(brightness) (XDR: \(wasXDRActive), pass \(pass))")
            onRestore(displayID, brightness)
            restoredCount += 1
        }

        isRestoring = false

        if restoredCount > 0 {
            logger.info("Restore pass \(pass) complete — restored \(restoredCount) display(s), skipped \(skippedCount)")
        } else {
            logger.warning("Restore pass \(pass) complete — no displays restored (skipped \(skippedCount), saved \(self.savedBrightness.count) total)")
        }
    }

    // MARK: - Clamshell Detection

    /// Reads `AppleClamshellState` from IOPMrootDomain via IOKit.
    private func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else {
            logger.warning("Could not find IOPMrootDomain service")
            return false
        }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            // Desktop Macs have no clamshell — not an error
            return false
        }

        let closed = property.takeRetainedValue() as? Bool ?? false
        return closed
    }

    /// Heuristic: built-in displays have a vendor ID matching Apple (0x610 = 1552).
    private func isBuiltInDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        return CGDisplayIsBuiltin(displayID) != 0
    }
}
