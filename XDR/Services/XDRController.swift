import AppKit
import CoreGraphics
import Metal
import MetalKit
import os.log

// MARK: - DisplayServices Private API (SDR brightness only)

private let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices"

private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

private let displayServicesHandle: UnsafeMutableRawPointer? = dlopen(displayServicesPath, RTLD_NOW)

private let _DisplayServicesSetBrightness: SetBrightnessFunc? = {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: SetBrightnessFunc.self)
}()

private let _DisplayServicesGetBrightness: GetBrightnessFunc? = {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFunc.self)
}()

// MARK: - EDR Trigger

/// A tiny 1x1 pixel Metal window that forces the system to allocate EDR headroom.
///
/// The window renders a single pixel with RGB values far above SDR white (16.0)
/// in extended linear sRGB. This tells the compositor "this display needs HDR headroom,"
/// which makes the panel ramp its backlight up. The pixel is invisible — 1x1 at the
/// top edge of the screen.
///
/// Actual brightness boost comes from gamma table scaling AFTER EDR engages.
/// This two-step approach (trigger + gamma) avoids any full-screen overlay that could
/// flash white during window transitions.
private final class EDRTrigger: NSObject, MTKViewDelegate {
    let window: NSWindow
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue

    init?(for screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        self.commandQueue = queue

        let metalView = MTKView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: device)
        metalView.colorPixelFormat = .rgba16Float
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalView.clearColor = MTLClearColor(red: 16.0, green: 16.0, blue: 16.0, alpha: 1.0)
        // Bug 2 fix: 60 fps keeps EDR headroom pinned during app-focus transitions.
        // At 5 fps the compositor can drop headroom between frames; 60 fps is negligible
        // GPU cost for a 1×1 pixel view and matches the overlay's cadence.
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        // Bug 1 fix: CGShieldingWindowLevel() is above .screenSaver and above the
        // Space-transition overlay that macOS uses during Mission Control / full-screen
        // app switches. At this level the window is never occluded by the Space-change
        // animation layer, eliminating the blink that occurred at .screenSaver level.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // canJoinAllSpaces — appears on every Space without re-attaching.
        // fullScreenAuxiliary — stays visible above other apps' full-screen content.
        // ignoresCycle — never enters Cmd+~ window cycling.
        // (Dropped .stationary — it's about Mission Control scroll alignment,
        // not Space membership, and it can cause the window to lag a Space switch.)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        window.hasShadow = false
        window.contentView = metalView
        window.alphaValue = 1.0

        self.window = window
        self.metalView = metalView

        super.init()

        metalView.delegate = self

        // Anchor on the target screen's top-left corner.
        let origin = CGPoint(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - 1
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func repositionOnScreen(_ screen: NSScreen) {
        let origin = CGPoint(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - 1
        )
        window.setFrameOrigin(origin)
    }

    func destroy() {
        metalView.isPaused = true
        metalView.delegate = nil
        window.orderOut(nil)
    }
}

// MARK: - EDR Boost Overlay (M5 fallback only)

/// Full-screen Metal overlay that multiplies desktop content by a boost factor.
///
/// On M5 Pro/Max/Neo hardware, `CGSetDisplayTransferByTable` returns success but
/// has no visual effect (Apple bug FB22273730). This overlay works around the bug
/// by covering the entire screen with a Metal view whose CAMetalLayer compositing
/// filter is set to "multiply". Rendering a clear color with RGB = boost factor
/// (e.g. 1.5, 1.5, 1.5) multiplies every pixel on screen by that factor, pushing
/// content into the EDR range.
///
/// The EDRTrigger is still needed alongside this overlay to force the compositor
/// to allocate HDR headroom.
///
/// This class is NOT instantiated on M1–M4 hardware. It exists purely as a fallback
/// for chips where the gamma table API has no effect.
private final class EDRBoostOverlay: NSObject, MTKViewDelegate {
    let window: NSWindow
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue

    init?(for screen: NSScreen, factor: Float) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        self.commandQueue = queue

        let frame = screen.frame

        let metalView = MTKView(frame: CGRect(origin: .zero, size: frame.size), device: device)
        metalView.colorPixelFormat = .rgba16Float
        // CRITICAL: extendedLinearSRGB, NOT extendedLinearDisplayP3.
        // The previous attempt used extendedLinearDisplayP3 which caused visible
        // oversaturation: sRGB-tagged desktop content (Safari, system UI, most apps)
        // got reinterpreted with P3 primaries by the compositor, making reds look
        // fluorescent, skies cyan, skin tones orange.
        // extendedLinearSRGB keeps sRGB primaries (matching the bulk of desktop content)
        // while still allowing values > 1.0 to push into the HDR range.
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalView.clearColor = MTLClearColor(
            red: Double(factor), green: Double(factor), blue: Double(factor), alpha: 1.0
        )
        // 60fps so slider drags translate to smooth brightness changes rather
        // than chunky 10fps steps that read as flicker.
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        // Bug 1 fix: same level as the trigger window — CGShieldingWindowLevel()
        // survives Space-change animations and full-screen app transitions without
        // requiring orderFrontRegardless() to be called after the switch.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Same Space-friendly behavior as the trigger window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        window.hasShadow = false
        window.contentView = metalView

        // The multiply compositing filter is the key: it multiplies every pixel
        // underneath by the overlay's color values. RGB > 1.0 boosts into EDR.
        window.contentView?.layer?.compositingFilter = "multiply"

        self.window = window
        self.metalView = metalView

        super.init()

        metalView.delegate = self

        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func updateFactor(_ factor: Float) {
        metalView.clearColor = MTLClearColor(
            red: Double(factor), green: Double(factor), blue: Double(factor), alpha: 1.0
        )
    }

    func repositionOnScreen(_ screen: NSScreen) {
        let frame = screen.frame
        window.setFrame(frame, display: true)
        metalView.frame = CGRect(origin: .zero, size: frame.size)
    }

    func destroy() {
        metalView.isPaused = true
        metalView.delegate = nil
        window.orderOut(nil)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - XDRController

/// Manages display brightness on a unified scale from 0 nits to 1600 nits.
///
/// - `0.0`–`1.0` maps to SDR range (0–500 nits) via the native brightness API.
/// - `1.0`–`2.0` maps to XDR range (500–1600 nits) via:
///   1. A 1×1 pixel EDR trigger that forces panel HDR headroom allocation.
///   2. `CGSetDisplayTransferByTable` gamma scaling (M1–M4 path, no overlay required).
///      On M5+ where the gamma table API returns success but has no visual effect
///      (Apple bug FB22273730), falls back to the full-screen Metal multiply overlay.
@MainActor
@Observable
final class XDRController {

    // MARK: - Constants

    static let sdrMaxNits: Double = 500
    static let xdrMaxNits: Double = 1600
    static let maxBrightness: Double = 2.0

    // MARK: - State

    private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    private var triggers: [CGDirectDisplayID: EDRTrigger] = [:]
    private var xdrActive: [CGDirectDisplayID: Bool] = [:]
    private var pendingGammaTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var boostOverlays: [CGDirectDisplayID: EDRBoostOverlay] = [:]
    // Bug 2 fix: per-display headroom monitor — polls maximumExtendedDynamicRangeColorComponentValue
    // and re-asserts the trigger when headroom unexpectedly drops below 1.05
    // (e.g. during app-focus transitions on the same Space).
    private var headroomMonitorTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.xdr.app", category: "XDRController")
    // Observer tokens — retained so we can remove them in shutdown().
    private var observerTokens: [NSObjectProtocol] = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []

    /// Cache of gamma-table effectiveness per display.
    /// `true`  = gamma tables work on this display (M1–M4 path, no overlay needed).
    /// `false` = gamma tables return success but have no effect (M5+ fallback, overlay required).
    /// `nil`   = not yet tested (first activation will populate this).
    private var gammaTableWorks: [CGDirectDisplayID: Bool] = [:]

    // MARK: - Lifecycle

    init() {
        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
        observerTokens.append(screenToken)

        // Bug 1 fix: Re-assert window ordering on BOTH the active-space-did-change
        // notification AND on app occlusion-state changes (covers same-Space app switches).
        // The windows are now at CGShieldingWindowLevel() which survives most transitions,
        // but orderFrontRegardless() on these notifications is a cheap belt-and-suspenders.
        let spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSpaceChange()
            }
        }
        workspaceObserverTokens.append(spaceToken)

        // NOTE: didChangeOcclusionStateNotification was previously wired here to call
        // handleSpaceChange(), but that notification fires for EVERY app focus change
        // (not just Space switches), producing constant orderFrontRegardless() calls
        // that were causing unnecessary compositor interactions. The headroom monitor
        // (polling at 250 ms with a 2-strike debounce) handles transient headroom dips,
        // and activeSpaceDidChangeNotification already covers true Space switches.
        // Removed to eliminate a source of spurious gamma/window operations.
    }

    @MainActor
    private func handleSpaceChange() {
        for (_, trigger) in triggers {
            trigger.window.orderFrontRegardless()
        }
        // Only re-order overlays when they exist (M5 fallback path).
        for (_, overlay) in boostOverlays {
            overlay.window.orderFrontRegardless()
        }
    }

    // MARK: - Public API

    /// Sets the unified brightness for a display.
    /// `0.0` (off) → `1.0` (SDR max, 500 nits) → `2.0` (XDR max, 1600 nits).
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let clamped = max(0.0, min(value, Self.maxBrightness))
        brightness[displayID] = clamped

        // Hysteresis: once XDR is active, only tear it down when brightness <= 1.0.
        // While currently inactive, only activate when brightness > 1.0. The slider's
        // left deadband already snaps to 1.0 to prevent oscillation, but we keep the
        // check here as a second line of defense against blink.
        let currentlyActive = xdrActive[displayID] == true

        if currentlyActive {
            if clamped <= 1.0 {
                setSDRBrightness(Float(clamped), for: displayID)
                deactivateXDR(for: displayID)
            } else {
                setSDRBrightness(1.0, for: displayID)
                applyGammaWhenReady(for: displayID, brightness: Float(clamped))
            }
        } else {
            if clamped > 1.0 {
                setSDRBrightness(1.0, for: displayID)
                activateXDR(for: displayID)
                applyGammaWhenReady(for: displayID, brightness: Float(clamped))
            } else {
                setSDRBrightness(Float(clamped), for: displayID)
            }
        }
    }

    func getBrightness(for displayID: CGDirectDisplayID) -> Double {
        if let stored = brightness[displayID] {
            return stored
        }
        var native: Float = 0
        if let getter = _DisplayServicesGetBrightness {
            _ = getter(displayID, &native)
        }
        let value = Double(native)
        brightness[displayID] = value
        return value
    }

    func isActivating(for displayID: CGDirectDisplayID) -> Bool {
        pendingGammaTasks[displayID] != nil
    }

    func isXDRCapable(displayID: CGDirectDisplayID) -> Bool {
        guard let screen = screen(for: displayID) else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    func currentNits(for displayID: CGDirectDisplayID) -> Int {
        nits(for: getBrightness(for: displayID))
    }

    func nits(for brightness: Double) -> Int {
        XDRConstants.nits(forBrightness: brightness, maxNits: Int(Self.xdrMaxNits))
    }

    func brightnessFromNits(_ nits: Double) -> Double {
        if nits <= Self.sdrMaxNits {
            return nits / Self.sdrMaxNits
        }
        return 1.0 + (nits - Self.sdrMaxNits) / (Self.xdrMaxNits - Self.sdrMaxNits)
    }

    func refreshOverlays() {
        // Bug 4 fix: only do a full Metal teardown when XDR is actually active.
        // For displays that have never activated XDR there is nothing to recreate,
        // so we skip them entirely to avoid a no-op churn that previously ran even
        // during slider drags and incidental state changes.
        let activeDisplays = xdrActive.filter { $0.value == true }.map { $0.key }
        guard !activeDisplays.isEmpty else { return }

        for displayID in activeDisplays {
            pendingGammaTasks[displayID]?.cancel()
            pendingGammaTasks.removeValue(forKey: displayID)

            headroomMonitorTasks[displayID]?.cancel()
            headroomMonitorTasks.removeValue(forKey: displayID)

            // Reset gamma table before tearing down.
            resetGammaTable(for: displayID)

            if let overlay = boostOverlays.removeValue(forKey: displayID) {
                overlay.destroy()
            }
            if let trigger = triggers.removeValue(forKey: displayID) {
                trigger.destroy()
            }

            xdrActive[displayID] = false
        }
    }

    func shutdown() {
        // Remove NotificationCenter observers to stop blocks firing after release.
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        for token in workspaceObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        // Cancel all pending gamma polling tasks.
        for (_, task) in pendingGammaTasks {
            task.cancel()
        }
        pendingGammaTasks.removeAll()

        // Bug 2/5 fix: cancel headroom monitor tasks to prevent dangling Tasks
        // holding a weak reference to self after deallocation.
        for (_, task) in headroomMonitorTasks {
            task.cancel()
        }
        headroomMonitorTasks.removeAll()

        // Destroy all boost overlays (M5 fallback path only).
        for (_, overlay) in boostOverlays {
            overlay.destroy()
        }
        boostOverlays.removeAll()

        // Reset gamma tables and destroy triggers.
        for (displayID, _) in triggers {
            xdrActive[displayID] = false
            resetGammaTable(for: displayID)
        }
        for (_, trigger) in triggers {
            trigger.destroy()
        }

        triggers.removeAll()
        brightness.removeAll()
        gammaTableWorks.removeAll()
    }

    // MARK: - SDR Brightness (Private API)

    private var lastSDRBrightness: [CGDirectDisplayID: Float] = [:]

    private func setSDRBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        guard let setter = _DisplayServicesSetBrightness else { return }
        let clamped = max(0.0, min(value, 1.0))
        // Skip if we just wrote this exact value — DisplayServices writes can
        // momentarily blip the display (especially at native max) and rapid
        // drag updates with the same value cause flicker.
        if let last = lastSDRBrightness[displayID], abs(last - clamped) < 0.001 {
            return
        }
        lastSDRBrightness[displayID] = clamped
        _ = setter(displayID, clamped)
    }

    // MARK: - XDR Activation

    private func activateXDR(for displayID: CGDirectDisplayID) {
        guard xdrActive[displayID] != true else { return }

        // Create 1x1 EDR trigger — always required to allocate panel HDR headroom.
        // This is needed on BOTH gamma-table path (M1–M4) and overlay path (M5+).
        // Without the trigger the compositor does not grant headroom and gamma
        // values > 1.0 get silently clamped to 1.0.
        if triggers[displayID] == nil {
            if let screen = screen(for: displayID) {
                triggers[displayID] = EDRTrigger(for: screen)
            }
        }

        // Pre-create the boost overlay at factor 1.0 (identity multiply = invisible).
        // The full-screen Metal layer being present causes a compositor mode shift that
        // we want to commit to BEFORE any visible boost — otherwise the first time we
        // ramp the overlay above 1.0 the user sees a one-frame discontinuity as the
        // compositor switches into HDR composition mode. Creating it at identity at
        // activation time hides that transition behind the slider crossing 1.0.
        if boostOverlays[displayID] == nil, let screen = screen(for: displayID) {
            boostOverlays[displayID] = EDRBoostOverlay(for: screen, factor: 1.0)
        }

        xdrActive[displayID] = true

        // Bug 2 fix: start a lightweight headroom monitor (polls every ~100 ms).
        // When the compositor drops EDR headroom (e.g. during app-focus transitions),
        // we immediately re-assert the trigger so boost never disappears.
        startHeadroomMonitor(for: displayID)
    }

    private func deactivateXDR(for displayID: CGDirectDisplayID) {
        guard xdrActive[displayID] == true else { return }

        // Cancel any in-flight gamma polling task for this display.
        pendingGammaTasks[displayID]?.cancel()
        pendingGammaTasks.removeValue(forKey: displayID)

        // Bug 2 fix: cancel headroom monitor.
        headroomMonitorTasks[displayID]?.cancel()
        headroomMonitorTasks.removeValue(forKey: displayID)

        // Reset gamma table to identity (removes any brightness boost).
        resetGammaTable(for: displayID)

        // Keep the overlay alive but set to identity multiply (factor 1.0, invisible).
        // Destroying here would force the compositor to switch back out of HDR composition
        // mode, which can cause a one-frame discontinuity. Keeping it alive at identity
        // means crossing the 1.0 boundary in either direction is smooth. The overlay only
        // gets destroyed in shutdown() or when the display disconnects.
        boostOverlays[displayID]?.updateFactor(1.0)

        // Keep the trigger alive. Tearing it down here means the next time the user
        // toggles XDR on, the compositor needs ~50-150ms to re-allocate headroom,
        // and during that window gamma writes are silently clamped — producing a
        // visible "ramp to SDR max, sit flat, snap to boost" blink at the boundary.
        // Leaving the trigger up keeps headroom pre-allocated so activation is
        // instantaneous. Cost is one always-running 1x1 invisible Metal layer.

        xdrActive[displayID] = false
    }

    /// Pre-allocates the EDR trigger for a display so HDR headroom is available
    /// the moment the user crosses into XDR range. Call this once per XDR-capable
    /// display at app launch (or display connect) so the first hotkey toggle /
    /// slider drag doesn't show a "flat at SDR max, then snap to boost" step.
    func warmUpEDRTrigger(for displayID: CGDirectDisplayID) {
        guard isXDRCapable(displayID: displayID) else { return }
        guard triggers[displayID] == nil else { return }
        guard let screen = screen(for: displayID) else { return }
        triggers[displayID] = EDRTrigger(for: screen)
    }

    // MARK: - Headroom Monitor

    /// Polls EDR headroom at 250 ms intervals while XDR is active.
    ///
    /// Polling at 100 ms was too aggressive: Space transitions last ~250–500 ms, so
    /// a 100 ms poll could sample mid-transition (headroom dipped), clear the gamma
    /// cache, then on the very next tick (100 ms later) see headroom recovered and
    /// force-reapply the gamma table — the write itself at that moment produced a
    /// micro-flicker on M1–M4. 250 ms gives the transition time to settle before
    /// we react.
    ///
    /// Threshold lowered from 1.05 to 1.02 to avoid false positives on M1 Max
    /// Liquid Retina XDR (potentialEDR ≈ 1.6): during a Space transition the
    /// compositor can briefly report headroom of 1.03–1.04 which is not a real
    /// collapse — it's just the animation layer temporarily capping allocation.
    ///
    /// On the gamma-table path (M1–M4) we ONLY reorder the 1×1 trigger window;
    /// we do NOT clear the gamma cache or force-reapply on headroom dip, because
    /// the gamma table is not invalidated by a Space transition — it persists in
    /// the display pipeline. Clearing the cache + force-rewriting was the primary
    /// cause of the on/off/on flicker the user observed.
    ///
    /// On the overlay path (M5) we do reorder the overlay so it stays front-most.
    private func startHeadroomMonitor(for displayID: CGDirectDisplayID) {
        headroomMonitorTasks[displayID]?.cancel()
        var lowHeadroomStrikes = 0          // require 2 consecutive readings before acting
        var wasLowHeadroom = false
        let task = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                if self.xdrActive[displayID] == true,
                   let screen = self.screen(for: displayID) {
                    let currentHeadroom = screen.maximumExtendedDynamicRangeColorComponentValue
                    // Use 1.02 threshold: anything above is considered "headroom present".
                    // Require 2 consecutive sub-threshold readings to avoid reacting to
                    // a single sample taken mid-Space-transition animation.
                    if currentHeadroom < 1.02 {
                        lowHeadroomStrikes += 1
                        if lowHeadroomStrikes >= 2 && !wasLowHeadroom {
                            wasLowHeadroom = true
                            self.logger.debug("EDR headroom collapsed for \(displayID) — re-asserting trigger")
                            // Only reorder windows; do NOT clear gamma cache.
                            // The gamma table survives Space transitions intact on M1–M4.
                            // Clearing the cache here caused a forced re-write on recovery
                            // which was visible as a flicker.
                        }
                        self.triggers[displayID]?.window.orderFrontRegardless()
                        // Only re-order overlay if it exists (M5 fallback).
                        self.boostOverlays[displayID]?.window.orderFrontRegardless()
                    } else {
                        lowHeadroomStrikes = 0
                        if wasLowHeadroom {
                            // Headroom recovered after a confirmed collapse.
                            // On M5 overlay path, reorder to ensure overlay is front-most.
                            // On M1–M4 gamma path, the table is still in effect — no re-write needed.
                            wasLowHeadroom = false
                            if self.boostOverlays[displayID] != nil {
                                // M5 overlay path: force-reapply overlay factor.
                                if let stored = self.brightness[displayID], stored > 1.0 {
                                    self.applyGammaScale(for: displayID, brightness: Float(stored))
                                }
                            }
                            // M1–M4 gamma path: intentionally no action.
                            // The gamma table is already applied and was never lost.
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        headroomMonitorTasks[displayID] = task
    }

    // MARK: - Gamma Table (Primary boost path, M1–M4)

    /// Applies a gamma ramp that scales all output values by `factor`.
    /// Values > 1.0 push content into EDR headroom (valid only after the EDR trigger
    /// has caused the compositor to allocate headroom).
    ///
    /// Returns `true` if `CGSetDisplayTransferByTable` reported success.
    /// Note: M5 may return success but have no visual effect — empirical verification
    /// is done by `applyGammaWhenReady` after a 500 ms delay.
    /// Per-display cache of the last gamma factor we wrote, so we can skip
    /// `CGSetDisplayTransferByTable` calls that wouldn't change the curve
    /// perceptibly. The animator drives this function at 60Hz; each call is a
    /// system-call into the graphics framework which can micro-blip the panel.
    private var lastGammaFactor: [CGDirectDisplayID: Float] = [:]

    @discardableResult
    private func applyGammaTable(factor: Float, for displayID: CGDirectDisplayID) -> Bool {
        // Skip writes that wouldn't perceptibly change the panel output.
        // 0.005 ≈ 0.5% of the boost range — below the visible threshold.
        if let last = lastGammaFactor[displayID], abs(last - factor) < 0.005 {
            return true
        }

        let length: UInt32 = 256
        var red   = [CGGammaValue](repeating: 0, count: Int(length))
        var green = [CGGammaValue](repeating: 0, count: Int(length))
        var blue  = [CGGammaValue](repeating: 0, count: Int(length))

        for i in 0..<Int(length) {
            let normalized = Float(i) / Float(length - 1)
            // Allow values > 1.0 to push into EDR headroom.
            let scaled = min(normalized * factor, factor)
            red[i]   = CGGammaValue(scaled)
            green[i] = CGGammaValue(scaled)
            blue[i]  = CGGammaValue(scaled)
        }

        let result = CGSetDisplayTransferByTable(displayID, length, &red, &green, &blue)
        if result == .success {
            lastGammaFactor[displayID] = factor
        }
        return result == .success
    }

    /// Restores the gamma ramp to a linear identity (no scaling) for the given display.
    /// Uses a per-display identity table rather than `CGDisplayRestoreColorSyncSettings()`
    /// so other displays are not affected.
    private func resetGammaTable(for displayID: CGDirectDisplayID) {
        let length: UInt32 = 256
        var ramp = [CGGammaValue](repeating: 0, count: Int(length))
        for i in 0..<Int(length) {
            ramp[i] = CGGammaValue(Float(i) / Float(length - 1))
        }
        _ = CGSetDisplayTransferByTable(displayID, length, &ramp, &ramp, &ramp)
        lastGammaFactor.removeValue(forKey: displayID)
    }

    // MARK: - Combined Gamma + Overlay Boost
    //
    // Total brightness boost on M1–M4 = gamma_factor × overlay_factor.
    // The overlay does most of the lift (1.0 → 1.6), gamma is a slight supplement (1.0 → 1.2).
    // Both apply the SAME uniform multiplier to R, G, B — so hue and saturation are preserved.
    // Only the luminance changes.
    //
    // Combined peak at brightness=2.0:  ~1.2 × 1.6 = 1.92x SDR (≈ 960 nits)
    //
    // The overlay runs in extendedLinearSRGB (NOT extendedLinearDisplayP3) to avoid the
    // sRGB → P3 reinterpretation that visibly oversaturated colors in the previous attempt.

    /// Gamma scaling factor — small supplement to the multiply overlay.
    /// At brightness=1.0 → 1.0 (identity).  At brightness=2.0 → 1.2 (gentle).
    /// Kept conservative on purpose: large gamma factors at the same time as a multiply
    /// overlay risk crushing midtones (linear-light compounding).
    static func edrGammaFactor(xdrBrightness: Float, maxPotentialEdr: CGFloat) -> Float {
        let t = max(0.0, min(1.0, xdrBrightness - 1.0))
        return 1.0 + t * 0.2
    }

    /// Overlay multiply factor — the primary brightness boost mechanism.
    /// At brightness=1.0 → 1.0 (identity multiply, invisible).
    /// At brightness=2.0 → 1.6 (panel pushed into upper EDR range).
    /// Ramp is linear so the slider feels uniform end-to-end.
    static func edrOverlayFactor(xdrBrightness: Float) -> Float {
        let t = max(0.0, min(1.0, xdrBrightness - 1.0))
        return 1.0 + t * 0.6
    }

    private func applyGammaScale(for displayID: CGDirectDisplayID, brightness: Float) {
        guard let s = screen(for: displayID) else { return }
        // Use the CURRENT available EDR headroom (not the theoretical potential).
        let maxEdr = s.maximumExtendedDynamicRangeColorComponentValue

        // If EDR headroom isn't available, skip — applying a >1.0 boost without it clips white.
        // Threshold matches the headroom monitor (1.02): both must agree on what "headroom present" means.
        guard maxEdr > 1.02 else { return }

        let maxPotentialEdr = s.maximumPotentialExtendedDynamicRangeColorComponentValue
        let gammaFactor = Self.edrGammaFactor(xdrBrightness: brightness, maxPotentialEdr: maxPotentialEdr)
        let overlayFactor = Self.edrOverlayFactor(xdrBrightness: brightness)

        // M5 fallback: gamma tables don't work. Overlay alone carries the combined boost.
        if gammaTableWorks[displayID] == false {
            updateOrCreateOverlay(for: displayID, factor: gammaFactor * overlayFactor)
            return
        }

        // M1–M4 (confirmed): apply gamma + overlay together.
        // The overlay is pre-created in activateXDR at factor 1.0 (identity, invisible),
        // so updateFactor here just smoothly varies its brightness contribution.
        if gammaTableWorks[displayID] == true {
            applyGammaTable(factor: gammaFactor, for: displayID)
            boostOverlays[displayID]?.updateFactor(overlayFactor)
            return
        }

        // First activation: verify gamma works before committing to the combined path.
        let apiSuccess = applyGammaTable(factor: gammaFactor, for: displayID)
        if !apiSuccess {
            logger.warning("CGSetDisplayTransferByTable failed for display \(displayID) — using overlay-only fallback")
            gammaTableWorks[displayID] = false
            updateOrCreateOverlay(for: displayID, factor: gammaFactor * overlayFactor)
            return
        }
        // Apply overlay too, then verify gamma below.
        boostOverlays[displayID]?.updateFactor(overlayFactor)

        // Gamma API returned success. Verify visually after 500 ms that the panel firmware
        // actually responded (M5 silently no-ops but reports success).
        let baselineHeadroom = maxEdr
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  self.xdrActive[displayID] == true,
                  let screen = self.screen(for: displayID) else { return }

            let currentHeadroom = screen.maximumExtendedDynamicRangeColorComponentValue
            let gammaEffective = currentHeadroom >= (baselineHeadroom - 0.05)

            if gammaEffective {
                self.logger.info("Gamma table verified — using gamma + overlay path for display \(displayID)")
                self.gammaTableWorks[displayID] = true
                if let stored = self.brightness[displayID], stored > 1.0 {
                    self.applyGammaScale(for: displayID, brightness: Float(stored))
                }
            } else {
                self.logger.warning("Gamma table ineffective for display \(displayID) — collapsing into overlay-only")
                self.gammaTableWorks[displayID] = false
                self.resetGammaTable(for: displayID)
                if let stored = self.brightness[displayID], stored > 1.0 {
                    let g = Self.edrGammaFactor(
                        xdrBrightness: Float(stored),
                        maxPotentialEdr: screen.maximumPotentialExtendedDynamicRangeColorComponentValue
                    )
                    let o = Self.edrOverlayFactor(xdrBrightness: Float(stored))
                    self.updateOrCreateOverlay(for: displayID, factor: g * o)
                }
            }
        }
    }

    /// Creates or updates the EDR boost overlay window for a display.
    /// Reuses an existing overlay if present (avoids destroy/recreate blinks).
    private func updateOrCreateOverlay(for displayID: CGDirectDisplayID, factor: Float) {
        if let overlay = boostOverlays[displayID] {
            overlay.updateFactor(factor)
            return
        }
        guard let screen = screen(for: displayID) else { return }
        boostOverlays[displayID] = EDRBoostOverlay(for: screen, factor: factor)
    }

    /// Applies brightness scaling, polling for EDR headroom only if not yet available.
    /// When EDR is already engaged (e.g., adjusting brightness while in XDR range),
    /// gamma/overlay updates happen synchronously — no polling delay.
    private func applyGammaWhenReady(for displayID: CGDirectDisplayID, brightness: Float) {
        // Fast path: EDR headroom is already available → apply immediately.
        if let s = screen(for: displayID),
           s.maximumExtendedDynamicRangeColorComponentValue > 1.05 {
            applyGammaScale(for: displayID, brightness: brightness)
            return
        }

        // Slow path: EDR not yet engaged (first activation). Poll until ready.
        // IMPORTANT: if a polling task is already running, do NOT cancel it. The
        // polling task reads `self.brightness[displayID]` when headroom comes
        // online, so it'll naturally pick up the latest value. Cancelling on
        // every animation frame (the animator hits this 60×/sec) kept resetting
        // the 50ms sleep window, so the headroom check never actually ran — the
        // gamma boost only engaged AFTER the animation finished, producing a
        // visible jump from "SDR max" to "boosted" instead of a smooth crossing.
        if pendingGammaTasks[displayID] != nil {
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(2.1)
            while Date() < deadline {
                if Task.isCancelled { return }

                if let s = self.screen(for: displayID),
                   s.maximumExtendedDynamicRangeColorComponentValue > 1.05 {
                    guard let stored = self.brightness[displayID], stored > 1.0 else {
                        self.pendingGammaTasks.removeValue(forKey: displayID)
                        return
                    }
                    self.applyGammaScale(for: displayID, brightness: Float(stored))
                    self.pendingGammaTasks.removeValue(forKey: displayID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            self.pendingGammaTasks.removeValue(forKey: displayID)
        }
        pendingGammaTasks[displayID] = task
    }

    // MARK: - Screen Change

    private func handleScreenChange() {
        // Collect IDs first — mutating a dictionary during for-in is undefined behavior.
        let displayIDs = Array(triggers.keys)
        for displayID in displayIDs {
            guard let trigger = triggers[displayID] else { continue }
            guard let screen = screen(for: displayID) else {
                // Display disconnected.
                pendingGammaTasks[displayID]?.cancel()
                pendingGammaTasks.removeValue(forKey: displayID)
                resetGammaTable(for: displayID)
                trigger.destroy()
                triggers.removeValue(forKey: displayID)
                if let overlay = boostOverlays.removeValue(forKey: displayID) {
                    overlay.destroy()
                }
                xdrActive[displayID] = false
                lastSDRBrightness.removeValue(forKey: displayID)
                gammaTableWorks.removeValue(forKey: displayID)
                continue
            }
            trigger.repositionOnScreen(screen)
            boostOverlays[displayID]?.repositionOnScreen(screen)
        }
    }

    // MARK: - Helpers

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    // NOTE: No deinit — cleanup is handled by shutdown(), which must be called
    // before the object is released. A previous deinit used MainActor.assumeIsolated,
    // which crashes if the object is deallocated off the main thread (deinit is nonisolated).
}
