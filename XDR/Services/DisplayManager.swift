import Cocoa
import IOKit
import Observation

// MARK: - DisplayManager

@MainActor
@Observable
final class DisplayManager {

    static let shared = DisplayManager()

    private(set) var displays: [DisplayInfo] = []

    // MARK: - Lifecycle

    private init() {
        refreshDisplays()
        registerCallbacks()
    }

    // No deinit needed — DisplayManager is a singleton that lives for the app's lifetime.
    // Removing deinit avoids actor-isolation issues with CGDisplayRemoveReconfigurationCallback
    // and Unmanaged.passUnretained(self) from nonisolated context.

    // MARK: - Callback Registration

    private func registerCallbacks() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplays()
            }
        }
    }

    // MARK: - Display Enumeration

    func refreshDisplays() {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let error = CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)
        guard error == .success else { return }

        let activeIDs = Array(onlineDisplays.prefix(Int(displayCount)))
        let modelIdentifier = Self.readModelIdentifier()

        displays = activeIDs.map { displayID in
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let screen = NSScreen.screens.first { $0.displayID == displayID }

            let name = screen?.localizedName ?? "Unknown Display"
            let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            let isXDR = potentialEDR > 1.0
            let maxEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            let maxNits = Self.determineMaxNits(isXDR: isXDR, isBuiltIn: isBuiltIn, modelIdentifier: modelIdentifier)

            return DisplayInfo(
                id: displayID,
                name: name,
                isBuiltIn: isBuiltIn,
                isXDR: isXDR,
                maxNits: maxNits,
                maxEDR: maxEDR
            )
        }
    }

    // MARK: - Lookup

    func display(for id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    // MARK: - Max Nits Detection

    private static func determineMaxNits(isXDR: Bool, isBuiltIn: Bool, modelIdentifier: String?) -> Int {
        guard isXDR else { return 500 }

        if let model = modelIdentifier {
            // MacBook Pro 14"/16" with M1 Pro/Max or later
            if model.contains("MacBookPro") {
                if let suffix = model.components(separatedBy: "MacBookPro").last,
                   let majorVersion = Int(suffix.components(separatedBy: ",").first ?? ""),
                   majorVersion >= 18 {
                    return 1600
                }
            }
        }

        // External Pro Display XDR (non-built-in but XDR capable)
        if !isBuiltIn && isXDR {
            return 1600
        }

        // Built-in XDR display on a qualifying MacBook Pro
        if isBuiltIn && isXDR {
            return 1600
        }

        return 500
    }

    // MARK: - IOKit Model Identifier

    private static func readModelIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }

        guard let data = property.takeRetainedValue() as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}

// MARK: - CG Reconfiguration Callback (C function)

// Safe to use Unmanaged.passUnretained for the userInfo pointer because
// DisplayManager is a singleton that lives for the entire app lifetime,
// so it will never be deallocated while this callback is registered.
private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()

    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]
    guard flags.intersection(relevant).isEmpty == false else { return }

    Task { @MainActor in
        manager.refreshDisplays()
    }
}
