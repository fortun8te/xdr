import AppKit
import CoreGraphics
import os.log

// MARK: - DimCurve (pure, testable)

/// Maps a user-facing dim level (0…1, where 1.0 = the panel's native brightness
/// and 0.0 = darkest) onto the two mechanisms SoftwareDimmer combines:
///   * a gamma-table scale for the top of the range (full color, no veil), and
///   * a translucent black overlay for the deep end, where gamma alone would band.
///
/// `split` is where the gamma table bottoms out and the overlay takes over.
enum DimCurve {
    /// Below this level the gamma scale holds at its floor and the overlay ramps in.
    static let split: Double = 0.5
    /// Lowest gamma output scale before banding becomes objectionable.
    static let gammaFloor: Double = 0.45
    /// Deepest overlay opacity. Kept under 1.0 so a panel never goes fully black
    /// (you can always find the slider to bring it back).
    static let maxOverlayAlpha: Double = 0.78

    /// Output scale fed to the display's gamma table. 1.0 = identity (no dim).
    static func gammaScale(forLevel level: Double) -> Double {
        let b = min(max(level, 0), 1)
        guard b < 1 else { return 1 }
        if b >= split {
            return gammaFloor + (b - split) / (1 - split) * (1 - gammaFloor)
        }
        return gammaFloor
    }

    /// Opacity of the black overlay. 0 = no veil.
    static func overlayAlpha(forLevel level: Double) -> Double {
        let b = min(max(level, 0), 1)
        guard b < split else { return 0 }
        return (split - b) / split * maxOverlayAlpha
    }
}

// MARK: - Dim overlay window

/// A borderless black window pinned above everything on one screen. Its alpha is
/// the dimming veil for the deep end of the range. Click-through, present on every
/// Space, and excluded from screen capture so it never bakes into a screenshot.
@MainActor
private final class DimOverlayWindow {
    let window: NSWindow

    init(screen: NSScreen) {
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .black
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // We own the window's lifetime via the overlays dict; disable close-release
        // so ARC is the single owner (avoids an over-release crash).
        window.isReleasedWhenClosed = false
        // Above the menu bar and full-screen content so the whole panel dims,
        // matching how lowering hardware brightness affects everything on screen.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Never captured in screenshots or screen shares — dimming is a personal view.
        window.sharingType = .none
        window.orderFrontRegardless()
    }

    func set(alpha: Double) {
        window.alphaValue = CGFloat(min(max(alpha, 0), 1))
    }

    func reposition(to screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
    }

    func destroy() {
        window.orderOut(nil)
    }
}

// MARK: - SoftwareDimmer

/// Brightness control for displays that expose no hardware brightness — the cheap
/// external panel with no slider in System Settings. Dims at the GPU level with a
/// gamma table, and fades in a black overlay for the deep end.
///
/// Self-contained: it owns its own persistence, re-asserts after display-layout and
/// wake changes (macOS wipes gamma tables on those), and restores everything on quit.
/// It never touches the XDRController boost paths. A display is hardware-controlled
/// OR software-dimmed, never both, so the two never fight over the same gamma table.
@MainActor
final class SoftwareDimmer {

    /// Per-display dim level, 0…1 (1.0 = native brightness). Source of truth.
    private var levels: [CGDirectDisplayID: Double] = [:]

    /// One black overlay window per display that currently needs the deep-end veil.
    private var overlays: [CGDirectDisplayID: DimOverlayWindow] = [:]

    private var screenObserver: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var wakeReassertTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.xdr.app", category: "SoftwareDimmer")

    private static let defaultsPrefix = "dim_brightness_"

    init() {
        registerObservers()
        loadPersistedLevels()
    }

    // MARK: - Public API

    /// The stored dim level for a display (1.0 = full brightness when unknown).
    func brightness(for displayID: CGDirectDisplayID) -> Double {
        levels[displayID] ?? persistedLevel(for: displayID) ?? 1.0
    }

    /// Sets the dim level (0…1) for a display and applies it immediately.
    func setBrightness(_ level: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(max(level, 0), 1)
        levels[displayID] = clamped
        persist(clamped, for: displayID)
        apply(clamped, for: displayID)
    }

    /// Re-applies every active dim. Call after the display layout or wake state
    /// changes, since macOS resets gamma tables on those events.
    func reassertAll() {
        let online = Self.onlineDisplayIDs()
        for (displayID, level) in levels where level < 1.0 && online.contains(displayID) {
            apply(level, for: displayID)
        }
    }

    /// Resets gamma to identity and removes overlays for all dimmed displays.
    /// Persisted levels are kept so a relaunch restores them.
    func restoreAll() {
        for displayID in levels.keys {
            resetGamma(for: displayID)
        }
        for (_, overlay) in overlays { overlay.destroy() }
        overlays.removeAll()
    }

    /// Tear down everything cleanly on app termination.
    func shutdown() {
        wakeReassertTask?.cancel()
        wakeReassertTask = nil
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        for token in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        wakeObservers.removeAll()
        restoreAll()
    }

    // MARK: - Observers

    private func registerObservers() {
        // Resolution / color-profile / reconnect changes all wipe the gamma table.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisplaysChanged() }
        }

        // Wake also resets gamma; displays need a moment to settle first.
        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleWakeReassert() }
            }
            wakeObservers.append(token)
        }
    }

    private func handleDisplaysChanged() {
        let online = Self.onlineDisplayIDs()

        // Reposition overlays that are still onscreen; drop the ones that went away.
        for (displayID, overlay) in overlays {
            if online.contains(displayID), let screen = Self.screen(for: displayID) {
                overlay.reposition(to: screen)
            } else {
                overlay.destroy()
                overlays.removeValue(forKey: displayID)
            }
        }

        // Re-apply gamma + overlay for every dimmed display still present.
        for (displayID, level) in levels where level < 1.0 && online.contains(displayID) {
            apply(level, for: displayID)
        }
    }

    private func scheduleWakeReassert() {
        wakeReassertTask?.cancel()
        // Two passes catch both fast- and slow-initialising panels, mirroring the
        // cadence the XDR boost restore already uses on this hardware.
        wakeReassertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.reassertAll()
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.reassertAll()
        }
    }

    // MARK: - Application

    private func apply(_ level: Double, for displayID: CGDirectDisplayID) {
        if level >= 1.0 {
            resetGamma(for: displayID)
        } else {
            let scale = Float(DimCurve.gammaScale(forLevel: level))
            let err = CGSetDisplayTransferByFormula(
                displayID,
                0, scale, 1,
                0, scale, 1,
                0, scale, 1
            )
            if err != .success {
                logger.error("gamma set failed for \(displayID, privacy: .public): \(err.rawValue)")
            }
        }
        applyOverlay(alpha: DimCurve.overlayAlpha(forLevel: level), for: displayID)
    }

    private func applyOverlay(alpha: Double, for displayID: CGDirectDisplayID) {
        guard alpha > 0.001 else {
            if let overlay = overlays.removeValue(forKey: displayID) { overlay.destroy() }
            return
        }
        guard let screen = Self.screen(for: displayID) else {
            // Display isn't resolvable right now (e.g. mid-reconfiguration). Drop any
            // existing overlay rather than leave it pinned to a stale frame.
            if let overlay = overlays.removeValue(forKey: displayID) { overlay.destroy() }
            return
        }
        let overlay: DimOverlayWindow
        if let existing = overlays[displayID] {
            overlay = existing
            overlay.reposition(to: screen)
        } else {
            overlay = DimOverlayWindow(screen: screen)
            overlays[displayID] = overlay
        }
        overlay.set(alpha: alpha)
    }

    /// Identity transfer: output == input. Restores full brightness for this one
    /// display without disturbing any other display's gamma (so XDR boost on a
    /// different panel is untouched).
    private func resetGamma(for displayID: CGDirectDisplayID) {
        _ = CGSetDisplayTransferByFormula(displayID, 0, 1, 1, 0, 1, 1, 0, 1, 1)
    }

    // MARK: - Persistence

    /// Loads saved dim levels into memory WITHOUT touching the display yet. Applying
    /// (gamma + overlay window) is deferred to `reassertAll()`, called once the app has
    /// finished launching, so we never create an overlay window during init.
    private func loadPersistedLevels() {
        for displayID in Self.onlineDisplayIDs() {
            guard let level = persistedLevel(for: displayID), level < 1.0 else { continue }
            levels[displayID] = level
        }
    }

    private func key(for displayID: CGDirectDisplayID) -> String {
        "\(Self.defaultsPrefix)\(displayID)"
    }

    private func persist(_ level: Double, for displayID: CGDirectDisplayID) {
        if level >= 1.0 {
            UserDefaults.standard.removeObject(forKey: key(for: displayID))
        } else {
            UserDefaults.standard.set(level, forKey: key(for: displayID))
        }
    }

    private func persistedLevel(for displayID: CGDirectDisplayID) -> Double? {
        guard UserDefaults.standard.object(forKey: key(for: displayID)) != nil else { return nil }
        let level = UserDefaults.standard.double(forKey: key(for: displayID))
        // Reject corrupt / out-of-range values so a bad default can never load a
        // display as fully dark or feed an invalid gamma scale.
        guard level.isFinite, (0.0...1.0).contains(level) else { return nil }
        return level
    }

    // MARK: - Display helpers

    private static func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
