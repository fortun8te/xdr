import AppIntents
import Foundation
import CoreGraphics

// MARK: - Toggle XDR Brightness

struct ToggleXDRIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle XDR Brightness"
    static var description = IntentDescription("Toggles extended brightness on the primary display")

    @Parameter(title: "Enable XDR")
    var enable: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let lifecycle = AppLifecycleManager.shared else {
            throw IntentError.appNotRunning
        }

        let controller = lifecycle.xdrController
        let displayID = CGMainDisplayID()

        let current = controller.getBrightness(for: displayID)
        let isCurrentlyXDR = current > 1.0

        let shouldEnable: Bool
        if let explicit = enable {
            shouldEnable = explicit
        } else {
            shouldEnable = !isCurrentlyXDR
        }

        if shouldEnable {
            guard controller.isXDRCapable(displayID: displayID) else {
                throw IntentError.displayNotFound("This display does not support XDR brightness")
            }
            lifecycle.setBrightness(1.4, for: displayID)
        } else {
            lifecycle.setBrightness(1.0, for: displayID)
        }

        return .result(value: shouldEnable)
    }
}

// MARK: - Set Display Brightness

struct SetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display Brightness"
    static var description = IntentDescription("Sets the display brightness to a specific nit value")

    @Parameter(title: "Brightness (nits)")
    var nits: Int

    @Parameter(title: "Display Name")
    var displayName: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lifecycle = AppLifecycleManager.shared else {
            throw IntentError.appNotRunning
        }

        let controller = lifecycle.xdrController
        let manager = lifecycle.displayManager

        let matchedDisplay: DisplayInfo?
        if let name = displayName {
            matchedDisplay = manager.displays.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
        } else {
            matchedDisplay = manager.displays.first(where: { $0.id == CGMainDisplayID() })
        }
        let displayID = matchedDisplay?.id ?? CGMainDisplayID()
        let displayIsXDR = matchedDisplay?.isXDR ?? false
        let maxNits = matchedDisplay?.maxNits ?? (displayIsXDR ? 1600 : 500)
        let clampedNits = max(0, min(nits, maxNits))
        let brightness = controller.brightnessFromNits(Double(clampedNits), maxNits: maxNits)

        lifecycle.setBrightness(brightness, for: displayID)
        return .result()
    }
}

// MARK: - Get Display Brightness

struct GetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Display Brightness"
    static var description = IntentDescription("Returns the current display brightness in nits")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        guard let lifecycle = AppLifecycleManager.shared else {
            throw IntentError.appNotRunning
        }

        let controller = lifecycle.xdrController
        let displayID = CGMainDisplayID()
        let maxNits = lifecycle.displayManager.display(for: displayID)?.maxNits ?? 1600
        let nits = controller.currentNits(for: displayID, maxNits: maxNits)
        return .result(value: nits)
    }
}

// MARK: - Preset Name Provider

struct PresetNameProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        return BrightnessPreset.defaults.map(\.name)
    }

    func defaultResult() async -> String? {
        return "Normal"
    }
}

// MARK: - Apply Brightness Preset

struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Brightness Preset"
    static var description = IntentDescription("Applies a named brightness preset")

    @Parameter(title: "Preset Name", optionsProvider: PresetNameProvider())
    var presetName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lifecycle = AppLifecycleManager.shared else {
            throw IntentError.appNotRunning
        }

        guard let preset = BrightnessPreset.defaults.first(where: {
            $0.name.localizedCaseInsensitiveCompare(presetName) == .orderedSame
        }) else {
            throw IntentError.presetNotFound(presetName)
        }

        lifecycle.applyPreset(preset)
        return .result()
    }
}

// MARK: - Get Display Info

struct GetDisplayInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Display Info"
    static var description = IntentDescription("Returns information about the current display")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let lifecycle = AppLifecycleManager.shared else {
            throw IntentError.appNotRunning
        }
        let displayID = CGMainDisplayID()
        let maxNits = lifecycle.displayManager.display(for: displayID)?.maxNits ?? 1600
        let nits = lifecycle.xdrController.currentNits(for: displayID, maxNits: maxNits)
        let isXDR = lifecycle.xdrController.getBrightness(for: displayID) > 1.0
        let status = isXDR ? "XDR Active" : "SDR"
        return .result(value: "\(status) - \(nits) nits")
    }
}

// MARK: - Intent Errors

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotRunning
    case presetNotFound(String)
    case displayNotFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotRunning:
            return "XDR is not running. Please launch the app first."
        case .presetNotFound(let name):
            return "Brightness preset '\(name)' was not found. Check available presets in the app."
        case .displayNotFound(let name):
            return "No display matching '\(name)' was found."
        }
    }
}

// MARK: - App Shortcuts Provider

struct XDRShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: ToggleXDRIntent(),
                phrases: ["Toggle XDR in \(.applicationName)"],
                shortTitle: "Toggle XDR",
                systemImageName: "sun.max.fill"
            ),
            AppShortcut(
                intent: SetBrightnessIntent(),
                phrases: ["Set brightness with \(.applicationName)"],
                shortTitle: "Set Brightness",
                systemImageName: "slider.horizontal.3"
            ),
            AppShortcut(
                intent: GetDisplayInfoIntent(),
                phrases: ["Get display info from \(.applicationName)"],
                shortTitle: "Display Info",
                systemImageName: "display"
            ),
        ]
    }
}
