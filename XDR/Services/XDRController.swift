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

// MARK: - EDR Boost Overlay (M5 fallback)

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
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
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
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
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
///   2. A full-screen Metal multiply overlay that boosts every pixel by the
///      requested factor, composited at the GPU level so RGB ratios (and color
///      accuracy) are preserved.
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
    // and re-asserts the trigger + overlay when headroom unexpectedly drops below 1.05
    // (e.g. during app-focus transitions on the same Space).
    private var headroomMonitorTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.xdr.app", category: "XDRController")
    // Observer tokens — retained so we can remove them in shutdown().
    private var observerTokens: [NSObjectProtocol] = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []

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

        // Bug 1 + Bug 2 fix: When ANY app's occlusion state changes (foreground/background
        // switch) the compositor may momentarily collapse EDR headroom. Re-ordering the
        // windows here keeps them front-most and triggers headroom re-assertion.
        let occlusionToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSpaceChange()
            }
        }
        observerTokens.append(occlusionToken)
    }

    @MainActor
    private func handleSpaceChange() {
        for (_, trigger) in triggers {
            trigger.window.orderFrontRegardless()
        }
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

        // Destroy all boost overlays.
        for (_, overlay) in boostOverlays {
            overlay.destroy()
        }
        boostOverlays.removeAll()

        for (displayID, _) in triggers {
            xdrActive[displayID] = false
        }
        for (_, trigger) in triggers {
            trigger.destroy()
        }

        triggers.removeAll()
        brightness.removeAll()
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

        // Create 1x1 EDR trigger if needed — required to allocate panel HDR headroom.
        if triggers[displayID] == nil {
            if let screen = screen(for: displayID) {
                triggers[displayID] = EDRTrigger(for: screen)
            }
        }

        // Create the full-screen multiply overlay for brightness boost.
        if boostOverlays[displayID] == nil {
            if let screen = screen(for: displayID) {
                boostOverlays[displayID] = EDRBoostOverlay(for: screen, factor: 1.0)
            }
        }

        xdrActive[displayID] = true

        // Bug 2 fix: start a lightweight headroom monitor (polls every ~100 ms).
        // When the compositor drops EDR headroom (e.g. during app-focus transitions),
        // we immediately re-assert the trigger and overlay so boost never disappears.
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

        // Destroy boost overlay.
        if let overlay = boostOverlays.removeValue(forKey: displayID) {
            overlay.destroy()
        }

        // Destroy trigger.
        if let trigger = triggers.removeValue(forKey: displayID) {
            trigger.destroy()
        }

        xdrActive[displayID] = false
    }

    // MARK: - Headroom Monitor

    /// Polls EDR headroom at 100 ms intervals while XDR is active.
    /// If headroom unexpectedly drops below 1.05 (compositor collapsed it during an
    /// app-focus or Space transition), re-orders both windows to the front so the
    /// trigger re-asserts headroom before the user notices a brightness dip.
    private func startHeadroomMonitor(for displayID: CGDirectDisplayID) {
        headroomMonitorTasks[displayID]?.cancel()
        let task = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                if self.xdrActive[displayID] == true,
                   let screen = self.screen(for: displayID),
                   screen.maximumExtendedDynamicRangeColorComponentValue < 1.05 {
                    self.logger.debug("EDR headroom dipped for \(displayID) — re-asserting trigger")
                    self.triggers[displayID]?.window.orderFrontRegardless()
                    self.boostOverlays[displayID]?.window.orderFrontRegardless()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        headroomMonitorTasks[displayID] = task
    }

    // MARK: - Gamma Scaling

    /// Computes the gamma factor for a given XDR brightness level.
    /// At 1.0 → factor 1.0 (no scaling). Capped at 1.65x to prevent washed-out highlights.
    ///
    /// The divisor equals `maxPotentialEdr` (the display's theoretical ceiling) so the
    /// factor scales proportionally on future displays with higher potential EDR (e.g. 4.0).
    /// The 1.65 cap prevents midtones from being pushed blown-out regardless of potential.
    static func edrGammaFactor(xdrBrightness: Float, maxPotentialEdr: CGFloat) -> Float {
        let divisor = max(Float(maxPotentialEdr), 1.0)
        let raw = 1.0 + (xdrBrightness - 1.0) / divisor
        return min(raw, 1.65)
    }

    private func applyGammaScale(for displayID: CGDirectDisplayID, brightness: Float) {
        guard let s = screen(for: displayID) else { return }
        // Use the CURRENT available EDR headroom (not the theoretical potential).
        let maxEdr = s.maximumExtendedDynamicRangeColorComponentValue

        // If EDR headroom isn't available, skip — applying a >1.0 boost without it clips white.
        guard maxEdr > 1.05 else { return }

        // Pass the display's theoretical potential as the divisor so future high-EDR
        // displays get a proportionally scaled factor rather than a fixed /3.0.
        let maxPotentialEdr = s.maximumPotentialExtendedDynamicRangeColorComponentValue
        let factor = Self.edrGammaFactor(xdrBrightness: brightness, maxPotentialEdr: maxPotentialEdr)

        // Update the full-screen multiply overlay factor.
        boostOverlays[displayID]?.updateFactor(factor)
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
        pendingGammaTasks[displayID]?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(2.1)
            while Date() < deadline {
                if Task.isCancelled { return }

                if let s = self.screen(for: displayID),
                   s.maximumExtendedDynamicRangeColorComponentValue > 1.05 {
                    guard let stored = self.brightness[displayID], stored > 1.0 else { return }
                    self.applyGammaScale(for: displayID, brightness: Float(stored))
                    self.pendingGammaTasks.removeValue(forKey: displayID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                // Re-check after sleep: the cancelled task may have woken from sleep
                // before the cancellation flag was observed.
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
                trigger.destroy()
                triggers.removeValue(forKey: displayID)
                if let overlay = boostOverlays.removeValue(forKey: displayID) {
                    overlay.destroy()
                }
                xdrActive[displayID] = false
                lastSDRBrightness.removeValue(forKey: displayID)
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
