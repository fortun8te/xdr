import AppKit

extension NSScreen {

    /// The Core Graphics display ID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// Whether this display supports XDR (EDR headroom > 1.0).
    var isXDRCapable: Bool {
        maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    /// The current EDR headroom the system is allowing right now.
    var currentEDRHeadroom: Double {
        Double(maximumExtendedDynamicRangeColorComponentValue)
    }

    /// The maximum EDR headroom this display can ever provide.
    var maxEDRHeadroom: Double {
        Double(maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    /// The peak nits this display can produce.
    var nitsCapacity: Int {
        isXDRCapable ? 1600 : 500
    }

    /// A human-readable description of the EDR headroom.
    var edrHeadroomDescription: String {
        if maxEDRHeadroom > 1.0 {
            return String(format: "%.1fx EDR", maxEDRHeadroom)
        }
        return "SDR only"
    }

    /// The localized display name.
    var displayName: String {
        localizedName
    }

    /// Whether this is the built-in display (MacBook screen).
    var isBuiltIn: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    /// Find the NSScreen instance for a given display ID.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
