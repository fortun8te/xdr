import AppKit
import CoreGraphics
import Observation
import QuartzCore
import os.log

// MARK: - NightVisionCurve (pure, testable)

/// Maps a user-facing Night Vision intensity (0...1) onto a true red-shift
/// transform applied at the display's hardware gamma LUT.
///
/// WHY GAMMA, NOT AN OVERLAY: the science of dark adaptation (rod cells are
/// blind to long-red wavelengths, so suppressing blue/green preserves night
/// vision, and even a bright red wash hurts) calls for actually removing the
/// short-wavelength output, not painting a translucent red film on top. A
/// per-channel gamma LUT does exactly that: it scales each channel's maximum
/// output in hardware, so white becomes deep red, blue collapses toward black,
/// and the result is a genuine red filter rather than a pink veil. This is how
/// real astronomy red-screen tools work, and it reaches every pixel including
/// full-screen video and the cursor.
///
/// `CGSetDisplayTransferByFormula(id, rMin,rMax,rGamma, gMin,gMax,gGamma, bMin,bMax,bGamma)`
/// gives output = min + (max-min) * input^(1/gamma). With gamma 1 that is a
/// straight scale of each channel's ceiling, which is all we need: lower the
/// green and (harder) the blue ceiling as intensity climbs, and gently lower the
/// red ceiling at the very top for a dimmer deep end.
enum NightVisionCurve {

    /// Green channel ceiling at full intensity. A small floor (not zero) keeps a
    /// trace of green so anti-aliased text edges and warm UI stay legible rather
    /// than collapsing to a single flat red.
    static let minGreen: Double = 0.10
    /// Blue channel ceiling at full intensity. Lower than green: blue light is
    /// the worst for dark adaptation, so it is suppressed hardest. Pushed to the
    /// readability floor so saturated greens/blues (e.g. a bright logo) dim as far
    /// as the per-channel gamma path allows before edges start to disappear.
    static let minBlue: Double = 0.03
    /// Red channel ceiling at full intensity. Kept high so the surviving image is
    /// bright red, with a gentle dim at the very top for comfort.
    static let minRed: Double = 0.80

    /// smoothstep: keeps the low end gentle (a better Night Shift) and brings the
    /// strong red on smoothly rather than abruptly.
    private static func eased(_ t: Double) -> Double {
        let c = clamp(t)
        return c * c * (3 - 2 * c)
    }

    /// Red ceiling fed to the gamma LUT. 1.0 (no attenuation) until the top third,
    /// then eases down to `minRed` so the deep end dims a touch.
    static func redMax(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        guard t > 0.7 else { return 1.0 }
        let k = (t - 0.7) / 0.3
        return 1.0 + (minRed - 1.0) * eased(k)
    }

    /// Green ceiling: eases from 1.0 (no shift) down to `minGreen` (deep red).
    static func greenMax(forIntensity intensity: Double) -> Double {
        1.0 + (minGreen - 1.0) * eased(intensity)
    }

    /// Blue ceiling: eases from 1.0 down to `minBlue`. Always below the green
    /// curve, so blue is the most suppressed channel at every intensity.
    static func blueMax(forIntensity intensity: Double) -> Double {
        1.0 + (minBlue - 1.0) * eased(intensity)
    }

    // MARK: - Overlay fallback (for displays whose gamma is owned by boost/dimmer)

    /// A display already driven by the XDR boost or the SoftwareDimmer owns its
    /// gamma table; we must not fight it. There we paint a red wash overlay
    /// instead (source-over, no gamma). These two values drive that overlay.
    ///
    /// Wash opacity: the red film strength. Tuned so the overlay's look roughly
    /// matches the gamma path at the same intensity.
    static func washAlpha(forIntensity intensity: Double) -> Double {
        0.55 * eased(intensity)
    }

    /// Black dim opacity beneath the wash, for the deep end only.
    static func dimAlpha(forIntensity intensity: Double) -> Double {
        let t = clamp(intensity)
        guard t > 0.6 else { return 0 }
        return (t - 0.6) / 0.4 * 0.33
    }

    static let washColor = (red: 1.0, green: 0.07, blue: 0.0)

    // MARK: - Engage ramp (pure, testable)

    /// Eased 0...1 ramp used to step the gamma in and out over ~1s so engaging
    /// never snaps. Shared by fade-in and fade-out.
    static func rampProgress(_ t: Double) -> Double {
        eased(t)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - Red wash overlay (fallback for boosted / dimmed displays only)

@MainActor
private final class NightVisionOverlayWindow {
    let window: NSWindow
    private let host: NSView
    private let dimLayer = CALayer()
    private let washLayer = CALayer()

    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                          backing: .buffered, defer: false, screen: screen)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none

        host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        dimLayer.frame = host.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        host.layer?.addSublayer(dimLayer)

        washLayer.frame = host.bounds
        washLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        let w = NightVisionCurve.washColor
        washLayer.backgroundColor = CGColor(red: w.red, green: w.green, blue: w.blue, alpha: 1)
        washLayer.opacity = 0
        host.layer?.addSublayer(washLayer)

        window.contentView = host
        window.orderFrontRegardless()
    }

    func apply(intensity: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        washLayer.opacity = Float(NightVisionCurve.washAlpha(forIntensity: intensity))
        dimLayer.opacity = Float(NightVisionCurve.dimAlpha(forIntensity: intensity))
        CATransaction.commit()
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

    func destroy() { window.orderOut(nil) }
}

// MARK: - NightVision

/// Astronomy-style deep red mode for dark adaptation. Applies a per-display
/// gamma LUT that suppresses green and (hardest) blue, so the screen becomes a
/// true red rather than a translucent red film. Stronger than Night Shift's
/// warmest while staying readable.
///
/// COEXISTENCE WITH THE FORBIDDEN BOOST ZONE: a display whose gamma is already
/// owned by the XDR boost engine or the SoftwareDimmer is left alone; there we
/// fall back to a red wash overlay window (no gamma) so the two never fight over
/// the same LUT. In the normal dark-room case nothing is boosted or dimmed, so
/// every display gets the proper hardware gamma red.
///
/// Enumerates displays with `CGGetOnlineDisplayList` (every panel, including
/// externals that `NSScreen.displayID` can report as 0) and re-asserts on
/// display-layout and wake changes, since macOS wipes gamma on both.
@MainActor
@Observable
final class NightVision {

    /// Injected by AppLifecycleManager: true when this display's gamma is owned
    /// by the boost engine or the software dimmer, so Night Vision must use the
    /// overlay fallback there instead of writing gamma.
    @ObservationIgnored
    var isGammaBusy: (CGDirectDisplayID) -> Bool = { _ in false }

    /// Dim scale (0...1, 1 = none) for a display, injected by AppLifecycleManager
    /// from the SoftwareDimmer. Folded into the gamma write so Night Vision red
    /// and software dimming COMPOSE on one LUT instead of fighting over it.
    @ObservationIgnored
    var dimScale: (CGDirectDisplayID) -> Double = { _ in 1.0 }

    /// Displays we currently drive via gamma (so we only ever reset our own).
    @ObservationIgnored
    private var gammaDisplays: Set<CGDirectDisplayID> = []
    /// Red wash overlays for displays whose gamma is busy.
    @ObservationIgnored
    private var overlays: [CGDirectDisplayID: NightVisionOverlayWindow] = [:]

    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeReassertTask: Task<Void, Never>?
    @ObservationIgnored private var rampTask: Task<Void, Never>?
    /// Coalesces the burst of screen-parameter notifications that HDR/SDR video
    /// transitions fire (the compositor toggles EDR on cursor moves and play/pause),
    /// so we re-apply gamma ONCE per burst instead of fighting it frame-by-frame.
    @ObservationIgnored private var reassertDebounceTask: Task<Void, Never>?
    /// Low-frequency drift watchdog: macOS silently overrides our gamma when a video
    /// engages EDR (the gamma table and the EDR EOTF are mutually exclusive). The
    /// notification does not always fire for these, so we poll and re-assert ONLY when
    /// the table has actually drifted back toward identity. No drift => no write => no flicker.
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    @ObservationIgnored private let logger = Logger(subsystem: "com.xdr.app", category: "NightVision")

    private static let enabledKey = "nightVision_enabled"
    private static let intensityKey = "nightVision_intensity"

    nonisolated static let firstEnableIntensity: Double = 0.35
    nonisolated static let safeRestoreCeiling: Double = 0.70

    /// Steps and duration for the engage / disengage gamma ramp.
    private static let rampSteps = 36
    private static let fadeInDuration: Double = 1.2
    private static let fadeOutDuration: Double = 0.4

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

    nonisolated static func safeRestore(enabled: Bool, intensity: Double) -> (enabled: Bool, intensity: Double) {
        (enabled && intensity <= safeRestoreCeiling, intensity)
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
        if enabled {
            ramp(to: intensity, over: Self.fadeInDuration)
            startWatchdog()
        } else {
            stopWatchdog()
            ramp(to: 0, over: Self.fadeOutDuration) { [weak self] in self?.teardownAll() }
        }
    }

    func setIntensity(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        intensity = clamped
        hasEverEnabled = true
        UserDefaults.standard.set(clamped, forKey: Self.intensityKey)
        guard isEnabled else { return }
        // Live slider: cancel any ramp and apply directly so dragging is responsive.
        rampTask?.cancel()
        applyEverywhere(intensity: clamped)
    }

    /// Re-fold the latest dim scales into gamma. Called when a dim level changes
    /// while Night Vision owns the LUT. Coalesced to one gamma pass per frame so
    /// a fast dim-slider drag does not rewrite every display's LUT on each tick
    /// (that was the dimming lag).
    func reapplyGamma() {
        guard isEnabled, !reapplyScheduled else { return }
        reapplyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.reapplyScheduled = false
            guard self.isEnabled else { return }
            self.applyEverywhere(intensity: self.intensity)
        }
    }
    @ObservationIgnored private var reapplyScheduled = false

    func restoreOnLaunch() {
        let resolved = Self.safeRestore(enabled: isEnabled, intensity: intensity)
        intensity = resolved.intensity
        if resolved.enabled != isEnabled {
            isEnabled = resolved.enabled
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
        if isEnabled {
            ramp(to: intensity, over: Self.fadeInDuration)
            startWatchdog()
        }
    }

    func shutdown() {
        rampTask?.cancel()
        wakeReassertTask?.cancel()
        reassertDebounceTask?.cancel()
        stopWatchdog()
        if let token = screenObserver { NotificationCenter.default.removeObserver(token) }
        for token in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wakeObservers.removeAll()
        teardownAll()
    }

    // MARK: - Application

    /// Push a fixed intensity to every online display, choosing gamma or the
    /// overlay fallback per display.
    private func applyEverywhere(intensity i: Double) {
        let online = Self.onlineDisplayIDs()
        for id in online {
            if isGammaBusy(id) {
                applyOverlay(intensity: i, for: id)
                resetGammaIfOwned(id)
            } else {
                applyGamma(intensity: i, for: id)
                dropOverlay(id)
            }
        }
        // Drop overlays / gamma for displays that went away.
        for id in overlays.keys where !online.contains(id) { dropOverlay(id) }
        for id in gammaDisplays where !online.contains(id) { gammaDisplays.remove(id) }
    }

    private func applyGamma(intensity i: Double, for id: CGDirectDisplayID) {
        // Compose with software dimming: multiply each channel ceiling by the
        // display's dim scale, so a dimmed monitor stays dim AND red.
        let dim = max(0, min(1, dimScale(id)))
        let r = Float(NightVisionCurve.redMax(forIntensity: i) * dim)
        let g = Float(NightVisionCurve.greenMax(forIntensity: i) * dim)
        let b = Float(NightVisionCurve.blueMax(forIntensity: i) * dim)
        // output = min + (max-min) * input^(1/gamma); gamma 1 => straight ceiling scale.
        let err = CGSetDisplayTransferByFormula(id,
                                                0, r, 1,
                                                0, g, 1,
                                                0, b, 1)
        if err == .success {
            gammaDisplays.insert(id)
        } else {
            logger.error("NV gamma set failed for \(id, privacy: .public): \(err.rawValue)")
        }
    }

    private func applyOverlay(intensity i: Double, for id: CGDirectDisplayID) {
        guard let screen = Self.screen(for: id) else { dropOverlay(id); return }
        let overlay = overlays[id] ?? {
            let o = NightVisionOverlayWindow(screen: screen)
            overlays[id] = o
            return o
        }()
        overlay.reposition(to: screen)
        overlay.apply(intensity: i)
    }

    private func dropOverlay(_ id: CGDirectDisplayID) {
        if let o = overlays.removeValue(forKey: id) { o.destroy() }
    }

    private func resetGammaIfOwned(_ id: CGDirectDisplayID) {
        guard gammaDisplays.contains(id) else { return }
        _ = CGSetDisplayTransferByFormula(id, 0, 1, 1, 0, 1, 1, 0, 1, 1)
        gammaDisplays.remove(id)
    }

    private func teardownAll() {
        for id in gammaDisplays { _ = CGSetDisplayTransferByFormula(id, 0, 1, 1, 0, 1, 1, 0, 1, 1) }
        gammaDisplays.removeAll()
        for (_, o) in overlays { o.destroy() }
        overlays.removeAll()
    }

    /// Step the intensity from its current applied value to `target` over
    /// `duration`, easing, so gamma engages/disengages smoothly instead of
    /// snapping. The final step lands exactly on `target`.
    private func ramp(to target: Double, over duration: Double, then completion: (@MainActor () -> Void)? = nil) {
        rampTask?.cancel()
        let start = currentAppliedIntensity
        let steps = Self.rampSteps
        rampTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...steps {
                if Task.isCancelled { return }
                let p = NightVisionCurve.rampProgress(Double(step) / Double(steps))
                self.currentAppliedIntensity = start + (target - start) * p
                self.applyEverywhere(intensity: self.currentAppliedIntensity)
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
            }
            if Task.isCancelled { return }
            self.currentAppliedIntensity = target
            self.applyEverywhere(intensity: target)
            completion?()
        }
    }

    @ObservationIgnored private var currentAppliedIntensity: Double = 0

    // MARK: - Observers

    private func registerObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisplaysChanged() }
        }
        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleWakeReassert() }
            }
            wakeObservers.append(token)
        }
    }

    private func handleDisplaysChanged() {
        guard isEnabled else { teardownAll(); return }
        // Debounce: a video starting/stopping (or the compositor toggling EDR as the
        // cursor moves over HDR content) fires this notification in rapid bursts. Applying
        // gamma on every one is exactly the "gamma goes weird while watching a video"
        // flicker. Coalesce to a single re-apply ~250 ms after the burst settles.
        reassertDebounceTask?.cancel()
        reassertDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.applyEverywhere(intensity: self.intensity)
        }
    }

    // MARK: - Drift watchdog

    /// Starts (or restarts) the watchdog while Night Vision is enabled. Cheap: it reads
    /// back each owned display's gamma table every ~2 s and only rewrites the ones macOS
    /// has clobbered (e.g. a video that engaged EDR reset the table toward identity).
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.reassertDriftedDisplays()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Re-applies gamma only to displays whose green ceiling has drifted back up toward
    /// identity (1.0) while we expect it suppressed — the signature of an EDR override.
    private func reassertDriftedDisplays() {
        let expectedGreen = NightVisionCurve.greenMax(forIntensity: currentAppliedIntensity)
        // Only meaningful to check when we actually expect suppression below identity.
        guard expectedGreen < 0.95 else { return }
        for id in gammaDisplays where !isGammaBusy(id) {
            guard let actualGreen = Self.readGreenCeiling(id) else { continue }
            // Tolerance: if the live green ceiling sits well above what we wrote, macOS
            // reset it. 0.85 is comfortably above any value our curve produces below 0.95.
            if actualGreen > 0.85 {
                applyGamma(intensity: currentAppliedIntensity, for: id)
            }
        }
    }

    /// Reads back the top entry of a display's green gamma channel (its output ceiling).
    /// Returns nil if the table can't be read. Used purely to detect OS overrides.
    private static func readGreenCeiling(_ id: CGDirectDisplayID) -> Double? {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        let err = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &sampleCount)
        guard err == .success, sampleCount > 0 else { return nil }
        return Double(green[Int(sampleCount) - 1])
    }

    private func scheduleWakeReassert() {
        guard isEnabled else { return }
        wakeReassertTask?.cancel()
        wakeReassertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.applyEverywhere(intensity: self.intensity)
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled, self.isEnabled else { return }
            self.applyEverywhere(intensity: self.intensity)
        }
    }

    // MARK: - Display helpers

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
