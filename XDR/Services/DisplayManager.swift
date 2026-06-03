import Cocoa
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
        // AppKit notification is sufficient for display config changes; the IOKit
        // CGDisplayRegisterReconfigurationCallback is redundant and produces duplicate
        // refreshes — removed.
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
        // Two-pass enumeration: first query for count, then allocate exactly.
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else { return }
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &onlineDisplays, &displayCount) == .success else { return }

        let activeIDs = Array(onlineDisplays.prefix(Int(displayCount)))

        displays = activeIDs.map { displayID in
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let screen = NSScreen.screens.first { $0.displayID == displayID }

            let name = screen?.localizedName ?? "Unknown Display"
            let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
            let isXDR = potentialEDR > 1.0
            let maxEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            let maxNits = Self.determineMaxNits(isXDR: isXDR)
            let supportsHardware = BrightnessSupport.hasHardwareBrightness(displayID)

            return DisplayInfo(
                id: displayID,
                name: name,
                isBuiltIn: isBuiltIn,
                isXDR: isXDR,
                maxNits: maxNits,
                maxEDR: maxEDR,
                supportsHardwareBrightness: supportsHardware
            )
        }
    }

    // MARK: - Lookup

    func display(for id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    // MARK: - Max Nits Detection

    private static func determineMaxNits(isXDR: Bool) -> Int {
        isXDR ? 1600 : 500
    }
}


