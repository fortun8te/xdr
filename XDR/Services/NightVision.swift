import AppKit
import CoreGraphics
import Observation
import QuartzCore
import os.log

// MARK: - NightVisionCurve (pure, testable)

/// Maps a user-facing Night Vision intensity (0...1) onto the two values the
/// overlay needs:
///   * the opacity of a deep-red WASH layer (source-over), and
///   * the opacity of a black DIM layer beneath it.
///
/// WHY SOURCE-OVER AND NOT MULTIPLY: a CALayer `compositingFilter` only blends
/// within its own window's layer tree. The window server composites separate
/// windows with plain source-over, so a "multiplyBlendMode" overlay window can
/// never multiply the screen behind it; it just paints its color on top (this
/// was the original implementation, and it produced a flat red wall plus
/// compositor artifacts). With source-over the math is honest and predictable:
///
///   after dim d:   c1 = content * (1 - d)
///   after wash a:  c2 = c1 * (1 - a) + washColor * a
///
/// so for white content the channel response is:
///   red   = (1-d)(1-a) + a * washRed   (red is lifted by the wash)
///   green = (1-d)(1-a) + a * washGreen (tiny, keeps text edges alive)
///   blue  = (1-d)(1-a)                 (suppressed hardest, wash has no blue)
///
/// Readability floors at full intensity are locked by tests on these derived
/// white-response values. Nothing here touches a display gamma table, so it
/// never fights the XDR boost engine or the SoftwareDimmer.
enum NightVisionCurve {

    /// The wash color: deep red with a whisper of green (keeps anti-aliased
    /// text edges distinguishable) and zero blue (the worst offender for dark
    /// adaptation gets nothing).
    static let washRed: Double = 1.0
    static let washGreen: Double = 0.07
    static let washBlue: Double = 0.0

    /// Wash opacity at full intensity. 0.55 leaves (1-d)(1-a) = 0.30 of the
    /// original green/blue detail at max, a readable deep salmon-red.
    static let maxWash: Double = 0.55
    /// Dim opacity at full intensity. Modest: the deep end is dim-but-readable
    /// dark adaptation, never a near-black screen.
    static let maxDim: Double = 0.33
    /// Intensity below which no dimming is applied; the warm and red-shift
    /// zones stay at full luminance.
    static let dimThreshold: Double = 0.45

    /// smoothstep: keeps the low end gentle (a better Night Shift) and brings
    /// the strong red on smoothly rather than abruptly.
    private static func eased(_ t: Double) -> Double {
        let c = clamp(t)
        return c * c * (3 - 2 * c)
    }

    /// Opacity of the red wash layer for a given intensity.
    static func washAlpha(forIntensity intensity: Double) -> Double {
        maxWash * eased(intensity)
    }

    /// Opacity of the black dim layer. Zero until `dimThreshold`, then ramps
    /// linearly to `maxDim` at full intensity.
    static func dimAlpha(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        guard t > dimThreshold else { return 0 }
        return (t - dimThreshold) / (1 - dimThreshold) * maxDim
    }

    // MARK: derived white response (what a white pixel becomes), for tests

    static func whiteRed(forIntensity intensity: Double) -> Double {
        let a = washAlpha(forIntensity: intensity)
        let d = dimAlpha(forIntensity: intensity)
        return (1 - d) * (1 - a) + a * washRed
    }

    static func whiteGreen(forIntensity intensity: Double) -> Double {
        let a = washAlpha(forIntensity: intensity)
        let d = dimAlpha(forIntensity: intensity)
        return (1 - d) * (1 - a) + a * washGreen
    }

    static func whiteBlue(forIntensity intensity: Double) -> Double {
        let a = washAlpha(forIntensity: intensity)
        let d = dimAlpha(forIntensity: intensity)
        return (1 - d) * (1 - a) + a * washBlue
    }

    // MARK: engage ramp (pure, testable)

    /// Eased 0...1 ramp used by the fade-in/out so engaging never snaps.
    static func rampProgress(_ t: Double) -> Double {
        eased(t)
    }

    /// The constant wash layer color (opacity is the animated quantity).
    static func washColor() -> CGColor {
        CGColor(red: washRed, green: washGreen, blue: washBlue, alpha: 1.0)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - Night Vision overlay window

/// A borderless, click-through, full-screen window pinned above everything on
/// one screen. Two plain source-over layers: black dim below, deep-red wash on
/// top. No blend-mode tricks: those cannot reach other windows' pixels.
@MainActor
private final class NightVisionOverlayWindow {
    let window: NSWindow
    private let host: NSView
    private let dimLayer = CALayer()
    private let washLayer = CALayer()

    /// Fade-in when Night Vision engages: slow enough that the red never snaps.
    static let fadeInDuration: CFTimeInterval = 1.2
    /// Fade-out when it disengages: quick but still a fade, not a cut.
    static let fadeOutDuration: CFTimeInterval = 0.4
    /// Settle time for live slider moves.
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
        // No implicit AppKit window animations: ordering in/out must never
        // flicker or scale (this was part of the engage glitch).
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        // One above the XDR boost / dimmer shielding windows so the red filter
        // composites on top of everything, including full-screen apps.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Never baked into screenshots or screen shares.
        window.sharingType = .none

        host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Start fully transparent; the engage fade brings the whole host in.
        host.layer?.opacity = 0

        dimLayer.frame = host.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        host.layer?.addSublayer(dimLayer)

        washLayer.frame = host.bounds
        washLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        washLayer.backgroundColor = NightVisionCurve.washColor()
        washLayer.opacity = 0
        host.layer?.addSublayer(washLayer)

        window.contentView = host
        // Order front only after the layer tree is fully configured and
        // transparent, so the window's first composited frame is invisible.
        window.orderFrontRegardless()
    }

    /// Push the current intensity into both layers.
    func apply(intensity: Double, animated: Bool) {
        let wash = Float(NightVisionCurve.washAlpha(forIntensity: intensity))
        let dim = Float(NightVisionCurve.dimAlpha(forIntensity: intensity))

        if animated {
            // Engage: set the destination look instantly while the host is
            // transparent, then fade the whole overlay in as one unit.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            washLayer.opacity = wash
            dimLayer.opacity = dim
            CATransaction.commit()
            fadeHost(to: 1, duration: Self.fadeInDuration)
        } else {
            // Live slider move: glide both opacities to their new values.
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.slideDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            washLayer.opacity = wash
            dimLayer.opacity = dim
            CATransaction.commit()
        }
    }

    /// Fade the whole overlay out, then run `completion` (orders the window out
    /// only once fully faded, so disengage is never a cut).
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
            dimLayer.frame = bounds
            washLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func destroy() {
        window.orderOut(nil)
    }
}

// MARK: - NightVision

/// Astronomy-style deep red mode for dark adaptation. Stronger than Night
/// Shift's warmest setting while keeping the screen readable.
///
/// Overlay-only: one filter window per display (black dim + red wash, plain
/// source-over). It NEVER writes a display gamma table, so it coexists with the
/// XDR boost engine and the SoftwareDimmer and survives macOS gamma wipes.
@MainActor
@Observable
final class NightVision {

    /// One filter overlay per online display while Night Vision is enabled.
    @ObservationIgnored
    private var overlays: [CGDirectDisplayID: NightVisionOverlayWindow] = [:]

    @ObservationIgnored
    private var screenObserver: NSObjectProtocol?

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.xdr.app", category: "NightVision")

    private static let enabledKey = "nightVision_enabled"
    private static let intensityKey = "nightVision_intensity"

    /// Default intensity for the very first enable: a gentle warm shift.
    nonisolated static let firstEnableIntensity: Double = 0.35

    /// A persisted enabled state is only auto-restored at launch when the
    /// stored intensity is at or below this; a forgotten extreme setting never
    /// ambushes the user at login.
    nonisolated static let safeRestoreCeiling: Double = 0.70

    init() {
        registerObservers()
    }

    // MARK: - Public state

    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: NightVision.enabledKey)

    @ObservationIgnored
    private var hasEverEnabled: Bool = UserDefaults.standard.object(forKey: NightVision.intensityKey) != nil

    private(set) var intensity: Double = {
        guard UserDefaults.standard.object(forKey: NightVision.intensityKey) != nil else {
            return NightVision.firstEnableIntensity
        }
        let v = UserDefaults.standard.double(forKey: NightVision.intensityKey)
        return (v.isFinite && (0.0...1.0).contains(v)) ? v : NightVision.firstEnableIntensity
    }()

    // MARK: - Pure restore rule (testable)

    /// Enabled survives a relaunch only when intensity is within the safe
    /// ceiling; the stored intensity itself is always kept.
    nonisolated static func safeRestore(enabled: Bool, intensity: Double) -> (enabled: Bool, intensity: Double) {
        let keepEnabled = enabled && intensity <= safeRestoreCeiling
        return (keepEnabled, intensity)
    }

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
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
        for (_, overlay) in overlays { overlay.apply(intensity: clamped, animated: false) }
    }

    /// Apply the persisted state once after launch. A forgotten extreme setting
    /// restores OFF (intensity preserved).
    func restoreOnLaunch() {
        let resolved = Self.safeRestore(enabled: isEnabled, intensity: intensity)
        intensity = resolved.intensity
        if resolved.enabled != isEnabled {
            isEnabled = resolved.enabled
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
        if isEnabled { applyToAllDisplays(animated: true) }
    }

    /// Tear down cleanly on app termination. Persisted state is kept.
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
            // Only fresh overlays do the slow engage fade; survivors of a
            // display-layout change just update without re-fading.
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
            teardownAll(fade: false)
            return
        }

        let online = Set(NSScreen.screens.map(\.displayID)).subtracting([0])

        for (displayID, overlay) in overlays where !online.contains(displayID) {
            overlay.destroy()
            overlays.removeValue(forKey: displayID)
        }

        applyToAllDisplays(animated: true)
    }
}
