import AppKit

extension NSScreen {

    /// The Core Graphics display ID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
