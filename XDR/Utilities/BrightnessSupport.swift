import CoreGraphics
import Foundation

// MARK: - BrightnessSupport

/// Detects whether a display exposes hardware brightness control.
///
/// Built-in panels and many external displays (Apple's, or ones macOS can reach
/// over DDC) respond to the private DisplayServices brightness API. Displays that
/// don't — the cheap HDMI panel with no brightness slider in System Settings —
/// return failure. Those are the ones SoftwareDimmer dims in software.
enum BrightnessSupport {

    private static let displayServicesPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices"

    private typealias GetBrightnessFunc =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen(displayServicesPath, RTLD_NOW)

    private static let getBrightness: GetBrightnessFunc? = {
        guard let handle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFunc.self)
    }()

    /// True when the display responds to the hardware brightness API. Built-in
    /// displays always count as supported. A non-built-in display that returns a
    /// readable 0...1 value is hardware-controlled; anything else is a software-dim
    /// candidate.
    static func hasHardwareBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(displayID) != 0 { return true }
        // If the DisplayServices probe is unavailable, assume the display IS
        // hardware-controlled. That preserves existing behavior rather than routing
        // every external display into software dimming on a probe failure.
        guard let getBrightness else { return true }
        var value: Float = -1
        let result = getBrightness(displayID, &value)
        // kIOReturnSuccess == 0, and a real brightness reads back inside 0...1.
        return result == 0 && value >= 0 && value <= 1
    }
}
