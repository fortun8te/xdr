import AppKit

extension NSScreen {

    /// The Core Graphics display ID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// Whether this is the built-in display (MacBook screen).
    var isBuiltIn: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }
}
