import AppKit
import CoreGraphics
import QuartzCore
import os.log

// MARK: - NightVisionCurve (pure, testable)

/// Maps a user-facing Night Vision intensity (0…1) onto the two values the
/// overlay needs:
///   * a multiply tint color (red kept, green/blue suppressed), applied with a
///     `multiplyBlendMode` layer so the composited screen loses its blue/green
///     channels rather than just gaining a flat red wash, and
///   * a black darkening alpha layered underneath, so high intensity is both deep
///     red AND dimmer (true dark adaptation, well past Night Shift's warmest).
///
/// At low intensity it is a mild warm tint that leaves the screen near-natural and
/// fully readable. As intensity climbs, green and especially blue are driven toward
/// zero and a gentle dim fades in. Nothing here touches a display gamma table, so it
/// never fights the XDR boost engine or the SoftwareDimmer.
enum NightVisionCurve {

    /// Green channel multiplier at full intensity. Kept above zero so text stays
    /// legible (pure red-only renders anti-aliased edges as unreadable mush).
    static let minGreen: Double = 0.18
    /// Blue channel multiplier at full intensity. Lower than green: blue light is
    /// the worst offender for night/dark adaptation, so it is suppressed hardest.
    static let minBlue: Double = 0.05
    /// Green multiplier at the very bottom of the range (mild warm look).
    static let maxGreen: Double = 0.92
    /// Blue multiplier at the very bottom of the range.
    static let maxBlue: Double = 0.82

    /// Deepest black-overlay opacity at full intensity. Under 1.0 so the screen is
    /// never fully black and the slider stays findable.
    static let maxDarken: Double = 0.45
    /// Intensity below which no darkening is applied. The low end is pure tint so
    /// the screen stays readable at mild settings.
    static let darkenThreshold: Double = 0.5

    /// Red multiply factor. Red is always preserved fully so the surviving image is
    /// bright red rather than dim red.
    static func redFactor(forIntensity intensity: Double) -> Double {
        _ = clamp(intensity) // intensity does not attenuate red; kept explicit for clarity
        return 1.0
    }

    /// Green multiply factor: eases from `maxGreen` (mild) down to `minGreen` (deep).
    static func greenFactor(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        return maxGreen + (minGreen - maxGreen) * t
    }

    /// Blue multiply factor: eases linearly from `maxBlue` (mild) down to `minBlue`
    /// (deep). Both endpoints sit below the green curve's, so blue is suppressed
    /// harder than green at every intensity (blue is the worst offender for dark
    /// adaptation).
    static func blueFactor(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        return maxBlue + (minBlue - maxBlue) * t
    }

    /// Opacity of the black darkening layer beneath the tint. Zero until
    /// `darkenThreshold`, then ramps to `maxDarken` at full intensity.
    static func darkenAlpha(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        guard t > darkenThreshold else { return 0 }
        return (t - darkenThreshold) / (1 - darkenThreshold) * maxDarken
    }

    /// Convenience: the multiply tint color (red preserved, green/blue suppressed).
    /// Returned at full opacity. The layer's blend mode, not its alpha, does the work.
    static func tintColor(forIntensity intensity: Double) -> CGColor {
        CGColor(
            red: CGFloat(redFactor(forIntensity: intensity)),
            green: CGFloat(greenFactor(forIntensity: intensity)),
            blue: CGFloat(blueFactor(forIntensity: intensity)),
            alpha: 1.0
        )
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - Night Vision overlay window

/// A borderless full-screen window pinned above everything on one screen that applies
/// the red filter. Two stacked layers:
///   1. a black darkening layer (normal blend) for the dimmed deep end, and
///   2. a tint layer using `multiplyBlendMode`, so the screen content underneath is
///      multiplied by the tint color (kills green/blue, keeps red).
///
/// Click-through, present on every Space, sits above full-screen apps and the XDR
/// boost overlay, and excluded from screen capture (`sharingType = .none`). It owns
/// no gamma table, so it composites cleanly over both the XDR boost and SoftwareDimmer.
@MainActor
private final class NightVisionOverlayWindow {
    let window: NSWindow
    private let darkenLayer = CALayer()
    private let tintLayer = CALayer()

    init(screen: NSScreen) {
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // ARC is the single owner via the overlays dict; disable close-release so we
        // never over-release (mirrors the SoftwareDimmer overlay hardening).
        window.isReleasedWhenClosed = false
        // One level above the XDR boost / dimmer shielding window so the red filter
        // composites on top of everything, including full-screen apps.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Personal view: never baked into a screenshot or screen share.
        window.sharingType = .none

        let host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        darkenLayer.frame = host.bounds
        darkenLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        darkenLayer.backgroundColor = NSColor.black.cgColor
        darkenLayer.opacity = 0
        host.layer?.addSublayer(darkenLayer)

        tintLayer.frame = host.bounds
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // multiply: composited result = screen content × tint color. This is what
        // turns the display red-channel-only rather than applying a flat red wash.
        tintLayer.compositingFilter = "multiplyBlendMode"
        host.layer?.addSublayer(tintLayer)

        window.contentView = host
        window.orderFrontRegardless()
    }

    /// Push the current intensity into both layers.
    func apply(intensity: Double) {
        // Disable implicit animation so slider drags update instantly without lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NightVisionCurve.tintColor(forIntensity: intensity)
        darkenLayer.opacity = Float(NightVisionCurve.darkenAlpha(forIntensity: intensity))
        CATransaction.commit()
    }

    func reposition(to screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        if let bounds = window.contentView?.bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            darkenLayer.frame = bounds
            tintLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func destroy() {
        window.orderOut(nil)
    }
}

// MARK: - NightVision

/// Astronomy-style deep red mode for dark adaptation. Much stronger than Night
/// Shift's warmest setting, while keeping the screen readable.
///
/// Overlay-only: one filter window per display, composited with a `multiplyBlendMode`
/// tint layer plus a darkening layer. It NEVER writes a display gamma table, so it
/// coexists with the XDR boost engine and the SoftwareDimmer without fighting them
/// (and survives the gamma wipes macOS does on display reconfig, since it owns none).
///
/// Self-contained: owns its persistence (UserDefaults), re-asserts on display-layout
/// changes, tears down overlays for displays that go away, and restores on quit.
@MainActor
final class NightVision {

    /// One filter overlay per online display while Night Vision is enabled.
    private var overlays: [CGDirectDisplayID: NightVisionOverlayWindow] = [:]

    private var screenObserver: NSObjectProtocol?

    private let logger = Logger(subsystem: "com.xdr.app", category: "NightVision")

    private static let enabledKey = "nightVision_enabled"
    private static let intensityKey = "nightVision_intensity"

    init() {
        registerObservers()
    }

    // MARK: - Public state

    /// Whether Night Vision is currently active. Persisted.
    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: NightVision.enabledKey)

    /// Filter strength, 0…1. Persisted. Defaults to a strong-but-readable 0.7.
    private(set) var intensity: Double = {
        guard UserDefaults.standard.object(forKey: NightVision.intensityKey) != nil else { return 0.7 }
        let v = UserDefaults.standard.double(forKey: NightVision.intensityKey)
        return (v.isFinite && (0.0...1.0).contains(v)) ? v : 0.7
    }()

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { applyToAllDisplays() } else { teardownAll() }
    }

    func setIntensity(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        intensity = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intensityKey)
        guard isEnabled else { return }
        for (_, overlay) in overlays { overlay.apply(intensity: clamped) }
    }

    /// Apply the persisted state. Call once after launch (defers overlay creation out
    /// of init, mirroring SoftwareDimmer).
    func restoreOnLaunch() {
        if isEnabled { applyToAllDisplays() }
    }

    /// Tear down everything cleanly on app termination. Persisted state is kept.
    func shutdown() {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        teardownAll()
    }

    // MARK: - Application

    private func applyToAllDisplays() {
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard displayID != 0 else { continue }
            let overlay: NightVisionOverlayWindow
            if let existing = overlays[displayID] {
                overlay = existing
                overlay.reposition(to: screen)
            } else {
                overlay = NightVisionOverlayWindow(screen: screen)
                overlays[displayID] = overlay
            }
            overlay.apply(intensity: intensity)
        }
    }

    private func teardownAll() {
        for (_, overlay) in overlays { overlay.destroy() }
        overlays.removeAll()
    }

    // MARK: - Observers

    private func registerObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisplaysChanged() }
        }
    }

    private func handleDisplaysChanged() {
        guard isEnabled else {
            // Disabled: drop any leftover overlays (display change is a fine moment).
            teardownAll()
            return
        }

        let online = Set(NSScreen.screens.map(\.displayID)).subtracting([0])

        // Drop overlays for displays that went away (screen no longer resolvable).
        for (displayID, overlay) in overlays where !online.contains(displayID) {
            overlay.destroy()
            overlays.removeValue(forKey: displayID)
        }

        // Reposition survivors and create overlays for newly-connected displays.
        applyToAllDisplays()
    }
}
