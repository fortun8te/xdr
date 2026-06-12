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

    /// Green channel multiplier at full intensity. Held at a readability floor so
    /// white surfaces become a deep salmon-red rather than collapsing into an
    /// illegible wall of pure red (anti-aliased text edges need some green to stay
    /// distinguishable from their background).
    static let minGreen: Double = 0.30
    /// Blue channel multiplier at full intensity. Lower than green: blue light is
    /// the worst offender for night/dark adaptation, so it is suppressed hardest,
    /// but kept above zero so cool UI hues do not vanish entirely.
    static let minBlue: Double = 0.12
    /// Green multiplier at the very bottom of the range (mild warm look, a touch
    /// gentler than Night Shift's warmest).
    static let maxGreen: Double = 0.94
    /// Blue multiplier at the very bottom of the range.
    static let maxBlue: Double = 0.86

    /// Deepest black-overlay opacity at full intensity. Kept modest so the deep end
    /// is dim-but-readable dark adaptation, never a near-black screen.
    static let maxDarken: Double = 0.22
    /// Intensity below which no darkening is applied. The lower two thirds of the
    /// range are pure tint so the screen stays at full luminance and fully readable.
    static let darkenThreshold: Double = 0.6

    /// Shapes the channel falloff. A gentle ease keeps the low end (0 to 0.3) close
    /// to the warm endpoint so small settings feel like a better Night Shift, then
    /// lets the upper range pull green/blue down toward their floors. Eased rather
    /// than linear so the transition into strong red is smooth, not abrupt.
    private static func eased(_ t: Double) -> Double {
        // smoothstep: 0->0, 1->1, flat slope at both ends.
        let c = clamp(t)
        return c * c * (3 - 2 * c)
    }

    /// Red multiply factor. Red is always preserved fully so the surviving image is
    /// bright red rather than dim red.
    static func redFactor(forIntensity intensity: Double) -> Double {
        _ = clamp(intensity) // intensity does not attenuate red; kept explicit for clarity
        return 1.0
    }

    /// Green multiply factor: eases from `maxGreen` (mild) down to `minGreen` (deep).
    static func greenFactor(forIntensity intensity: Double) -> Double {
        let t = eased(intensity)
        return maxGreen + (minGreen - maxGreen) * t
    }

    /// Blue multiply factor: eases from `maxBlue` (mild) down to `minBlue` (deep).
    /// Both endpoints sit below the green curve's, so blue is suppressed harder than
    /// green at every intensity (blue is the worst offender for dark adaptation).
    static func blueFactor(forIntensity intensity: Double) -> Double {
        let t = eased(intensity)
        return maxBlue + (minBlue - maxBlue) * t
    }

    /// Opacity of the black darkening layer beneath the tint. Zero until
    /// `darkenThreshold`, then ramps to `maxDarken` at full intensity.
    static func darkenAlpha(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        guard t > darkenThreshold else { return 0 }
        return (t - darkenThreshold) / (1 - darkenThreshold) * maxDarken
    }

    // MARK: - Engage ramp (pure, testable)

    /// Eased 0…1 ramp used to fade the overlay in and out without snapping. Linear in
    /// time would still read as a hard edge at the start and end; this smoothstep gives
    /// a soft start and soft stop. Shared by the fade-in and fade-out so both feel calm.
    static func rampProgress(_ t: Double) -> Double {
        eased(t)
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
    private let host: NSView
    private let darkenLayer = CALayer()
    private let tintLayer = CALayer()

    /// Fade-in duration when Night Vision engages. Slow enough that the red never
    /// snaps onto the screen and ambushes the eye.
    static let fadeInDuration: CFTimeInterval = 1.2
    /// Fade-out duration when Night Vision disengages. Quicker than the fade-in so
    /// turning it off feels responsive while still being a fade, not a cut.
    static let fadeOutDuration: CFTimeInterval = 0.4
    /// How long a slider move takes to settle. Short, so dragging feels live, but
    /// non-zero so each step glides rather than jumps.
    static let slideDuration: CFTimeInterval = 0.18

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

        host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Start fully transparent; apply(intensity:animated:) fades the whole overlay
        // in over fadeInDuration so engaging never snaps to full red.
        host.layer?.opacity = 0

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
    ///
    /// `animated == true` is used for the initial engage: the tint/darken values are
    /// set with no animation (so the destination color is correct from frame zero),
    /// then the whole host layer is faded from transparent to opaque over
    /// `fadeInDuration`. `animated == false` (slider moves) cross-fades the tint and
    /// darken values over `slideDuration` so dragging glides instead of stepping.
    func apply(intensity: Double, animated: Bool) {
        let tint = NightVisionCurve.tintColor(forIntensity: intensity)
        let darken = Float(NightVisionCurve.darkenAlpha(forIntensity: intensity))

        if animated {
            // Engage: set the look instantly, then fade the overlay in as a whole.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tintLayer.backgroundColor = tint
            darkenLayer.opacity = darken
            CATransaction.commit()
            fadeHost(to: 1, duration: Self.fadeInDuration)
        } else {
            // Live slider move: glide the tint and darken toward their new values.
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.slideDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            tintLayer.backgroundColor = tint
            darkenLayer.opacity = darken
            CATransaction.commit()
        }
    }

    /// Fade the whole overlay out over `fadeOutDuration`, then run `completion` (used to
    /// order the window out only once it has fully faded, so disengage is never a cut).
    func fadeOutAndDestroy(_ completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        fadeHost(to: 0, duration: Self.fadeOutDuration)
        CATransaction.commit()
    }

    private func fadeHost(to target: Float, duration: CFTimeInterval) {
        guard let layer = host.layer else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
        anim.toValue = target
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = target
        layer.add(anim, forKey: "nvFade")
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

    /// Default intensity for the very first time Night Vision is ever enabled. A
    /// gentle 35% lands in the "pleasant warm" zone so the first experience is a
    /// soft warm shift, never a wall of red.
    nonisolated static let firstEnableIntensity: Double = 0.35

    /// On launch, a persisted enabled state is only auto-restored if the stored
    /// intensity is at or below this. A forgotten extreme setting (deep dark
    /// adaptation) should not ambush the user at login, so above this the toggle is
    /// restored OFF while the stored intensity is preserved.
    nonisolated static let safeRestoreCeiling: Double = 0.70

    init() {
        registerObservers()
    }

    // MARK: - Public state

    /// Whether Night Vision is currently active. Persisted.
    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: NightVision.enabledKey)

    /// Whether the user has ever explicitly enabled Night Vision. Used so the first
    /// enable can default to a gentle intensity rather than a saved/extreme one.
    private var hasEverEnabled: Bool = UserDefaults.standard.object(forKey: NightVision.intensityKey) != nil

    /// Filter strength, 0…1. Persisted. Defaults to the gentle first-enable value.
    private(set) var intensity: Double = {
        guard UserDefaults.standard.object(forKey: NightVision.intensityKey) != nil else {
            return NightVision.firstEnableIntensity
        }
        let v = UserDefaults.standard.double(forKey: NightVision.intensityKey)
        return (v.isFinite && (0.0...1.0).contains(v)) ? v : NightVision.firstEnableIntensity
    }()

    // MARK: - Pure restore rule (testable)

    /// Decides whether a persisted (enabled, intensity) pair should be restored as
    /// enabled on launch. Enabled stays true only when it was true AND the stored
    /// intensity is within the safe ceiling; a forgotten extreme setting restores OFF.
    /// The intensity itself is always kept so the user's chosen level is not lost.
    nonisolated static func safeRestore(enabled: Bool, intensity: Double) -> (enabled: Bool, intensity: Double) {
        let keepEnabled = enabled && intensity <= safeRestoreCeiling
        return (keepEnabled, intensity)
    }

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
        // First-ever enable starts at the gentle default rather than any stale value,
        // so a user's first taste of Night Vision is a soft warm shift.
        if enabled && !hasEverEnabled {
            hasEverEnabled = true
            intensity = Self.firstEnableIntensity
            UserDefaults.standard.set(intensity, forKey: Self.intensityKey)
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { applyToAllDisplays(animated: true) } else { teardownAll(fade: true) }
    }

    func setIntensity(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        intensity = clamped
        hasEverEnabled = true
        UserDefaults.standard.set(clamped, forKey: Self.intensityKey)
        guard isEnabled else { return }
        // Slider moves glide to the new value (animated: false uses the short slide
        // cross-fade, not the slow engage fade).
        for (_, overlay) in overlays { overlay.apply(intensity: clamped, animated: false) }
    }

    /// Apply the persisted state. Call once after launch (defers overlay creation out
    /// of init, mirroring SoftwareDimmer). A forgotten extreme setting restores OFF.
    func restoreOnLaunch() {
        let resolved = Self.safeRestore(enabled: isEnabled, intensity: intensity)
        intensity = resolved.intensity
        if resolved.enabled != isEnabled {
            isEnabled = resolved.enabled
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
        if isEnabled { applyToAllDisplays(animated: true) }
    }

    /// Tear down everything cleanly on app termination. Persisted state is kept.
    func shutdown() {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        teardownAll(fade: false)
    }

    // MARK: - Application

    private func applyToAllDisplays(animated: Bool) {
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard displayID != 0 else { continue }
            let overlay: NightVisionOverlayWindow
            let isNew: Bool
            if let existing = overlays[displayID] {
                overlay = existing
                overlay.reposition(to: screen)
                isNew = false
            } else {
                overlay = NightVisionOverlayWindow(screen: screen)
                overlays[displayID] = overlay
                isNew = true
            }
            // Only freshly-created overlays do the slow engage fade. An overlay that
            // already exists (e.g. a display-layout change while enabled) just updates
            // its values so it does not re-fade from black.
            overlay.apply(intensity: intensity, animated: animated && isNew)
        }
    }

    private func teardownAll(fade: Bool) {
        let current = overlays
        overlays.removeAll()
        if fade {
            for (_, overlay) in current {
                overlay.fadeOutAndDestroy { overlay.destroy() }
            }
        } else {
            for (_, overlay) in current { overlay.destroy() }
        }
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
            teardownAll(fade: false)
            return
        }

        let online = Set(NSScreen.screens.map(\.displayID)).subtracting([0])

        // Drop overlays for displays that went away (screen no longer resolvable).
        for (displayID, overlay) in overlays where !online.contains(displayID) {
            overlay.destroy()
            overlays.removeValue(forKey: displayID)
        }

        // Reposition survivors and create overlays for newly-connected displays. New
        // overlays fade in; survivors just update without re-fading.
        applyToAllDisplays(animated: true)
    }
}
