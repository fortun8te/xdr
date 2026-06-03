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

    /// Debounce flag: prevents duplicate restoration when didWake, screensDidWake,
    /// AND screenDidUnlock (which fires twice per unlock) all arrive on the same wake.
    /// All wake/unlock paths check and set this flag before scheduling work.
    private var isWakeRestoreScheduled = false

    /// Cancellable handle for the in-flight two-pass restore sequence.
    /// Kept so shutdown() can cancel it cleanly.
    private var restoreSequenceTask: Task<Void, Never>?

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

    /// Cancels any in-flight restore sequence. Call from AppLifecycleManager.shutdown().
    func shutdown() {
        restoreSequenceTask?.cancel()
        restoreSequenceTask = nil
        isWakeRestoreScheduled = false
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

    /// screenDidUnlock fires up to TWICE per unlock event on some machines.
    /// Route through the same debounced scheduler so it collapses with any
    /// preceding didWake/screensDidWake into a single two-pass sequence.
    @objc private func screenDidUnlock(_ note: Notification) {
        scheduleWakeRestore(source: "Screen unlocked")
    }

    /// Single entry point for all wake/unlock sources.
    /// The debounce flag (isWakeRestoreScheduled) ensures exactly one two-pass
    /// sequence runs per physical wake/unlock event, regardless of how many
    /// redundant notifications arrive.
    private func scheduleWakeRestore(source: String) {
        guard !isWakeRestoreScheduled else {
            logger.info("\(source) — skipping (restoration already scheduled)")
            return
        }
        isWakeRestoreScheduled = true
        logger.info("\(source) — scheduling two-pass restoration")

        // Cancel any leftover sequence from a previous (e.g. rapid) wake cycle.
        restoreSequenceTask?.cancel()

        // Two passes via a single Task keeps both delays cancellable via shutdown().
        // Pass 1 @ 1.5s: catches fast-initialising displays (built-in, most HDMI).
        // Pass 2 @ 3.5s: catches slow-initialising displays (Thunderbolt, USB-C hubs).
        // refreshOverlays() is now idempotent and flicker-free, so we call it on
        // both passes to flush any stale M5 Metal state before re-asserting gamma.
        restoreSequenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.restoreAllDisplays(pass: 1)

            try? await Task.sleep(for: .seconds(2.0)) // 1.5 + 2.0 = 3.5s from wake
            guard !Task.isCancelled else { return }
            self.restoreAllDisplays(pass: 2)

            // Sequence complete — reset debounce so the next wake can schedule freely.
            self.isWakeRestoreScheduled = false
            self.restoreSequenceTask = nil
        }
    }

    // MARK: - Restoration

    private func restoreAllDisplays(pass: Int) {
        isRestoring = true

        // refreshOverlays() is now idempotent (no gamma reset, no blink), so it's
        // safe to call on every pass. This flushes any stale M5 Metal state so the
        // subsequent setBrightness calls land on a clean overlay.
        logger.info("Restore pass \(pass) — refreshing overlays before restoration")
        onRefresh()

        let clamshellClosed = isClamshellClosed()

        logger.info("Restore pass \(pass) — clamshell closed: \(clamshellClosed)")

        var restoredCount = 0
        var skippedCount = 0

        for (displayID, brightness) in savedBrightness {
            // Skip phantom entries saved at 0.0 — these represent displays that were
            // never actually in XDR mode (or were recorded before a display connected)
            // and generate spurious restore calls visible in logs as "display N at 0.0".
            guard brightness > 0.0 else {
                logger.debug("  Skip display \(displayID) — saved brightness is 0.0 (phantom entry)")
                skippedCount += 1
                continue
            }

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
