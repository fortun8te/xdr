import AppKit
import CoreGraphics
import IOKit
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
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalView.clearColor = MTLClearColor(red: 16.0, green: 16.0, blue: 16.0, alpha: 1.0)
        metalView.preferredFramesPerSecond = 5
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
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
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        metalView.preferredFramesPerSecond = 10
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
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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

// MARK: - Gamma Table

private struct GammaTable {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
    let sampleCount: UInt32

    static func read(for displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0

        let err = CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount)
        guard err == CGError.success else { return nil }

        return GammaTable(red: red, green: green, blue: blue, sampleCount: sampleCount)
    }

    /// Scale the table by a factor. Values CAN exceed 1.0 — this maps into the EDR range
    /// once the system has allocated HDR headroom via the trigger overlay.
    func scaled(by factor: Float) -> GammaTable {
        GammaTable(
            red: red.map { $0 * CGGammaValue(factor) },
            green: green.map { $0 * CGGammaValue(factor) },
            blue: blue.map { $0 * CGGammaValue(factor) },
            sampleCount: sampleCount
        )
    }

    func apply(to displayID: CGDirectDisplayID) {
        var r = red
        var g = green
        var b = blue
        CGSetDisplayTransferByTable(displayID, sampleCount, &r, &g, &b)
    }
}

// MARK: - Per-Display Gamma Restore

/// Restores the gamma table for a single display to its ColorSync baseline,
/// preserving the display's color profile (sRGB/P3 gamma curve).
///
/// Previous implementation wrote a LINEAR ramp which destroyed the ~2.2 gamma
/// curve baked into the ColorSync profile, causing washed-out/wrong colors.
private func restoreGamma(for displayID: CGDirectDisplayID, baseline: GammaTable?) {
    if let baseline {
        baseline.apply(to: displayID)
    } else {
        // No saved baseline — let ColorSync restore all displays as a fallback.
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - XDRController

/// Manages display brightness on a unified scale from 0 nits to 1600 nits.
///
/// - `0.0`–`1.0` maps to SDR range (0–500 nits) via the native brightness API.
/// - `1.0`–`2.0` maps to XDR range (500–1600 nits) via:
///   1. A 1×1 pixel EDR trigger that forces panel HDR headroom allocation.
///   2. Gamma table scaling that boosts all desktop content into the EDR range.
///
/// No full-screen overlay. No compositing filter. No white flash risk.
@MainActor
@Observable
final class XDRController {

    // MARK: - Constants

    static let sdrMaxNits: Double = 500
    static let xdrMaxNits: Double = 1600
    static let maxBrightness: Double = 2.0

    // MARK: - M5 Detection

    /// Returns `true` on M5-family Macs (Mac16,x and later) where
    /// `CGSetDisplayTransferByTable` is broken (Apple bug FB22273730).
    /// The gamma API returns success but has no visual effect on these machines.
    private static func isGammaTableBroken() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        guard let data = IORegistryEntryCreateCFProperty(
            service,
            "model" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Data else { return false }

        let model = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters) ?? ""

        // Mac16,x = M5 family. Future Mac17+ would also need this path.
        guard model.hasPrefix("Mac") else { return false }
        let digits = model.dropFirst(3).prefix(while: { $0.isNumber })
        guard let generation = Int(digits) else { return false }
        return generation >= 16
    }

    // MARK: - State

    private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    private var triggers: [CGDirectDisplayID: EDRTrigger] = [:]
    private var baselineGamma: [CGDirectDisplayID: GammaTable] = [:]
    private var xdrActive: [CGDirectDisplayID: Bool] = [:]
    private var pendingGammaTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private let useMetalOverlay: Bool
    private var boostOverlays: [CGDirectDisplayID: EDRBoostOverlay] = [:]
    private let logger = Logger(subsystem: "com.xdr.app", category: "XDRController")

    // MARK: - Lifecycle

    init() {
        self.useMetalOverlay = Self.isGammaTableBroken()

        // Capture baseline gamma for all displays at launch.
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if let table = GammaTable.read(for: displayID) {
                baselineGamma[displayID] = table
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
    }

    // MARK: - Public API

    /// Sets the unified brightness for a display.
    /// `0.0` (off) → `1.0` (SDR max, 500 nits) → `2.0` (XDR max, 1600 nits).
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let clamped = max(0.0, min(value, Self.maxBrightness))
        brightness[displayID] = clamped

        if clamped <= 1.0 {
            setSDRBrightness(Float(clamped), for: displayID)
            deactivateXDR(for: displayID)
        } else {
            setSDRBrightness(1.0, for: displayID)
            activateXDR(for: displayID)
            applyGammaWhenReady(for: displayID, brightness: Float(clamped))
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
        // Tear down all existing triggers, overlays, and pending tasks so that
        // activateXDR will recreate them with fresh Metal state.
        for displayID in xdrActive.keys {
            pendingGammaTasks[displayID]?.cancel()
            pendingGammaTasks.removeValue(forKey: displayID)

            if let overlay = boostOverlays.removeValue(forKey: displayID) {
                overlay.destroy()
            }
            if !useMetalOverlay {
                restoreGamma(for: displayID, baseline: baselineGamma[displayID])
            }
            if let trigger = triggers.removeValue(forKey: displayID) {
                trigger.destroy()
            }

            xdrActive[displayID] = false
        }
    }

    func shutdown() {
        // Cancel all pending gamma polling tasks.
        for (_, task) in pendingGammaTasks {
            task.cancel()
        }
        pendingGammaTasks.removeAll()

        // Destroy all boost overlays (M5 path).
        for (_, overlay) in boostOverlays {
            overlay.destroy()
        }
        boostOverlays.removeAll()

        for (displayID, _) in triggers {
            if !useMetalOverlay {
                restoreGamma(for: displayID, baseline: baselineGamma[displayID])
            }
            xdrActive[displayID] = false
        }
        for (_, trigger) in triggers {
            trigger.destroy()
        }

        // Safety net: reset gamma for any display that was in XDR range
        // but whose trigger was already removed (e.g. disconnected mid-session).
        if !useMetalOverlay {
            for (displayID, level) in brightness where level > 1.0 {
                if triggers[displayID] == nil {
                    restoreGamma(for: displayID, baseline: baselineGamma[displayID])
                }
            }
        }

        triggers.removeAll()
        baselineGamma.removeAll()
        brightness.removeAll()
    }

    // MARK: - SDR Brightness (Private API)

    private func setSDRBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        guard let setter = _DisplayServicesSetBrightness else { return }
        let clamped = max(0.0, min(value, 1.0))
        _ = setter(displayID, clamped)
    }

    // MARK: - XDR Activation

    private func activateXDR(for displayID: CGDirectDisplayID) {
        guard xdrActive[displayID] != true else { return }

        // Always capture the current (unmodified) gamma table before scaling.
        // This ensures we restore the correct ColorSync profile on deactivation,
        // even if Night Shift / True Tone changed since the last activation.
        if !useMetalOverlay {
            baselineGamma[displayID] = GammaTable.read(for: displayID)
        }

        // Create 1x1 EDR trigger if needed — still required on M5 to allocate headroom.
        if triggers[displayID] == nil {
            if let screen = screen(for: displayID) {
                triggers[displayID] = EDRTrigger(for: screen)
            }
        }

        // On M5, create the full-screen multiply overlay for brightness boost.
        if useMetalOverlay, boostOverlays[displayID] == nil {
            if let screen = screen(for: displayID) {
                boostOverlays[displayID] = EDRBoostOverlay(for: screen, factor: 1.0)
            }
        }

        xdrActive[displayID] = true
    }

    private func deactivateXDR(for displayID: CGDirectDisplayID) {
        guard xdrActive[displayID] == true else { return }

        // Cancel any in-flight gamma polling task for this display.
        pendingGammaTasks[displayID]?.cancel()
        pendingGammaTasks.removeValue(forKey: displayID)

        // Destroy boost overlay (M5 path).
        if let overlay = boostOverlays.removeValue(forKey: displayID) {
            overlay.destroy()
        }

        // Restore gamma to defaults for THIS display only (pre-M5 path).
        if !useMetalOverlay {
            restoreGamma(for: displayID, baseline: baselineGamma[displayID])
        }

        // Destroy trigger.
        if let trigger = triggers.removeValue(forKey: displayID) {
            trigger.destroy()
        }

        xdrActive[displayID] = false
    }

    // MARK: - Gamma Scaling

    /// Computes the gamma factor for a given XDR brightness level.
    /// At 1.0 → factor 1.0 (no scaling). Capped at 1.65x to prevent washed-out highlights.
    ///
    /// Previous divisor of 2.0 gave factor 2.0 at max brightness, which doubled every pixel
    /// and pushed midtones into EDR — everything looked blown out. Divisor 3.0 + a 1.65 cap
    /// keeps highlights under the EDR ceiling and preserves color accuracy. Competitors
    /// (Vivid, BetterDisplay) use similar ~1.5–1.7x limits.
    static func edrGammaFactor(xdrBrightness: Float, maxEdr: CGFloat) -> Float {
        let raw = 1.0 + (xdrBrightness - 1.0) * Float(maxEdr) / 3.0
        return min(raw, 1.65)
    }

    private func applyGammaScale(for displayID: CGDirectDisplayID, brightness: Float) {
        // Use the CURRENT available EDR headroom (not the theoretical potential).
        let maxEdr = screen(for: displayID)?
            .maximumExtendedDynamicRangeColorComponentValue ?? 1.0

        // If EDR headroom isn't available, skip — applying gamma >1.0 without it clips white.
        guard maxEdr > 1.05 else { return }

        let factor = Self.edrGammaFactor(xdrBrightness: brightness, maxEdr: maxEdr)

        if useMetalOverlay {
            // M5 path: update the full-screen multiply overlay factor.
            boostOverlays[displayID]?.updateFactor(factor)
        } else {
            // Pre-M5 path: scale the gamma table.
            guard let baseline = baselineGamma[displayID] else { return }
            let scaled = baseline.scaled(by: factor)
            scaled.apply(to: displayID)
        }
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
            }
            self.pendingGammaTasks.removeValue(forKey: displayID)
        }
        pendingGammaTasks[displayID] = task
    }

    // MARK: - Screen Change

    private func handleScreenChange() {
        for (displayID, trigger) in triggers {
            guard let screen = screen(for: displayID) else {
                // Display disconnected.
                pendingGammaTasks[displayID]?.cancel()
                pendingGammaTasks.removeValue(forKey: displayID)
                trigger.destroy()
                triggers.removeValue(forKey: displayID)
                if let overlay = boostOverlays.removeValue(forKey: displayID) {
                    overlay.destroy()
                }
                if !useMetalOverlay {
                    restoreGamma(for: displayID, baseline: baselineGamma[displayID])
                }
                xdrActive[displayID] = false
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
