import Foundation
import IOKit.ps

@MainActor
@Observable
final class BatteryMonitor {

    // MARK: - Published State

    var batteryLevel: Int = 100
    var isCharging: Bool = true
    var isOnBattery: Bool = false

    var powerSource: String {
        isOnBattery ? "Battery" : "AC Power"
    }

    var batteryLevelDescription: String {
        if !isOnBattery { return "Plugged In" }
        return "\(batteryLevel)%"
    }

    var isLowBattery: Bool {
        isOnBattery && batteryLevel < 20
    }

    /// Time remaining on battery, or `nil` when plugged in, calculating,
    /// or on a Mac with no battery (e.g. Mac mini / Mac Pro).
    var batteryTimeRemaining: String? {
        guard isOnBattery,
              let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                  .takeUnretainedValue() as? [String: Any],
              let minutes = desc[kIOPSTimeToEmptyKey] as? Int,
              minutes >= 0
        else { return nil }

        let hrs = minutes / 60
        let mins = minutes % 60
        if hrs > 0 {
            return "\(hrs) hr \(mins) min"
        } else {
            return "\(mins) min"
        }
    }

    // MARK: - Private

    /// Safe because this @MainActor class only reads/writes the source on the
    /// main thread. `nonisolated(unsafe)` silences the concurrency checker in
    /// `deinit`, which the compiler treats as nonisolated.
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    /// Guards against the run loop source callback firing during deallocation.
    /// Marked `nonisolated(unsafe)` so `deinit` (which is nonisolated) can write it.
    nonisolated(unsafe) private var isShuttingDown = false

    // MARK: - Init / Deinit

    init() {
        updateBatteryState()
        startMonitoring()
    }

    deinit {
        isShuttingDown = true
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Public

    /// Returns `true` when the Mac is running on battery power
    /// and the current level is below the given threshold (0-100).
    func shouldDisableXDR(threshold: Int) -> Bool {
        isOnBattery && batteryLevel < threshold
    }

    // MARK: - Battery Reading

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                  .takeUnretainedValue() as? [String: Any]
        else { return }

        batteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? true

        let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        isOnBattery = (state == kIOPSBatteryPowerValue)
    }

    // MARK: - Run Loop Monitoring

    private func startMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context)
                .takeUnretainedValue()
            guard !monitor.isShuttingDown else { return }
            Task { @MainActor in
                monitor.updateBatteryState()
            }
        }, context)?.takeRetainedValue() else { return }

        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
