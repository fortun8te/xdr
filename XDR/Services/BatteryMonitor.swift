import Foundation
import IOKit.ps

@MainActor
@Observable
final class BatteryMonitor {

    // MARK: - Published State

    var batteryLevel: Int = 100
    var isCharging: Bool = true
    var isOnBattery: Bool = false

    // MARK: - Private

    /// Storage for the IOKit power-source notification run-loop source. Excluded
    /// from `@Observable` tracking so `deinit` (which is nonisolated) can read
    /// it to remove the source from the main run loop. Writes only happen on the
    /// main actor via `startMonitoring`, so there is no actual data race.
    @ObservationIgnored
    private var runLoopSource: CFRunLoopSource?

    /// Guards against the run loop source callback firing during deallocation.
    /// Excluded from observation so both the C callback (off-actor) and `deinit`
    /// can access it without tripping the observation machinery.
    @ObservationIgnored
    private var isShuttingDown = false

    // MARK: - Init / Deinit

    init() {
        updateBatteryState()
        startMonitoring()
    }

    // Order matters: set isShuttingDown first so the callback no-ops,
    // then remove the run loop source to prevent further invocations.
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
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any]
        else { return }

        // Filter to the internal battery so a UPS does not shadow the real battery level.
        let internalSource = sources.first { src in
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any] else { return false }
            return (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        } ?? sources.first  // fall back to first source on desktops without a battery

        guard let source = internalSource,
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
        // Safe to use passUnretained: the run loop source is removed in deinit
        // before deallocation completes, so the callback cannot fire on a freed object.
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
