import Cocoa

// MARK: - Main Actor Helper

/// Executes a closure on the main actor, using `MainActor.assumeIsolated` when already
/// on the main thread and `DispatchQueue.main.sync` otherwise. This avoids the trap that
/// `MainActor.assumeIsolated` triggers when called off the main thread, while still
/// returning a value synchronously (required by `performDefaultImplementation`).
private func onMainActorSync<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            body()
        }
    } else {
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

// MARK: - Toggle XDR

@objc(ToggleXDRCommand)
final class ToggleXDRCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMainActorSync {
            guard let manager = AppLifecycleManager.shared else {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = "XDR is not ready — the app may still be launching"
                return nil as Any?
            }

            let displayID = CGMainDisplayID()

            guard manager.xdrController.isXDRCapable(displayID: displayID) else {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = "This display does not support XDR/EDR brightness"
                return nil as Any?
            }

            let current = manager.xdrController.getBrightness(for: displayID)

            if current > 1.0 {
                manager.setBrightness(1.0, for: displayID)
            } else {
                manager.setBrightness(1.4, for: displayID)
            }

            let isXDR = manager.xdrController.getBrightness(for: displayID) > 1.0
            return isXDR as Any?
        }
    }
}

// MARK: - Set Brightness

@objc(SetBrightnessCommand)
final class SetBrightnessCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMainActorSync {
            guard let manager = AppLifecycleManager.shared else {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = "XDR is not ready — the app may still be launching"
                return nil as Any?
            }

            guard let nits = self.directParameter as? Int else {
                self.scriptErrorNumber = errOSATypeError
                self.scriptErrorString = "Expected brightness as an integer in nits (0–1600)"
                return nil as Any?
            }

            let displayID = CGMainDisplayID()
            let perDisplayMaxNits = AppLifecycleManager.shared?.displayManager.display(for: displayID)?.maxNits ?? 1600
            let maxNits = perDisplayMaxNits

            if nits > maxNits {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = maxNits == 500
                    ? "This display does not support XDR — maximum brightness is 500 nits"
                    : "Maximum brightness is \(maxNits) nits"
                return nil as Any?
            }

            let clampedNits = max(0, min(nits, maxNits))
            let unified = manager.xdrController.brightnessFromNits(Double(clampedNits), maxNits: maxNits)
            manager.setBrightness(unified, for: displayID)

            return nil as Any?
        }
    }
}

// MARK: - Get Brightness

@objc(GetBrightnessCommand)
final class GetBrightnessCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMainActorSync {
            guard let manager = AppLifecycleManager.shared else {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = "XDR is not ready — the app may still be launching"
                return nil as Any?
            }

            let displayID = CGMainDisplayID()
            let maxNits = AppLifecycleManager.shared?.displayManager.display(for: displayID)?.maxNits ?? 1600
            return manager.xdrController.currentNits(for: displayID, maxNits: maxNits) as Any?
        }
    }
}
