import SwiftUI
import ServiceManagement
import AppKit

@main
struct XDRApp: App {
    @State private var appState = AppState()
    @State private var lifecycle = AppLifecycleManager()

    @NSApplicationDelegateAdaptor(XDRAppDelegate.self) private var appDelegate

    init() {
        UserDefaults.standard.register(defaults: [
            "userName": XDRConstants.bundledUserName
        ])
        if #available(macOS 13.0, *) {
            let firstRunKey = "didRegisterLoginItem"
            if !UserDefaults.standard.bool(forKey: firstRunKey) {
                try? SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: firstRunKey)
            }
        }
    }

    /// Wires AppState ↔ AppLifecycleManager and the AppDelegate once.
    /// Called from the MenuBarExtra label's .onAppear, which fires exactly
    /// once per stable view identity. The guard makes additional calls no-ops.
    @MainActor
    private func wireLifecycle() {
        guard lifecycle.appState == nil else { return }
        lifecycle.appState = appState
        appState.displays = lifecycle.displayManager.displays
        lifecycle.syncBrightnessFromSystem()
        appDelegate.lifecycle = lifecycle
        appDelegate.appState = appState
        // Now that delegate has both refs, it can create + show the main window.
        appDelegate.ensureMainWindowVisible()
    }

    var body: some Scene {
        // Menu bar only — no SwiftUI Window/WindowGroup. The main window is
        // an AppKit NSWindow created and managed by XDRAppDelegate. SwiftUI's
        // Window/WindowGroup don't reliably materialize alongside MenuBarExtra,
        // so we bypass them entirely.
        MenuBarExtra {
            PopoverContentView()
                .environment(appState)
                .environment(lifecycle)
                .frame(width: 320)
        } label: {
            MenuBarLabel(
                isXDRActive: appState.isAnyXDRActive,
                showNits: appState.showNitsInMenuBar,
                currentNits: appState.activeDisplay?.currentNits ?? 500
            )
            .accessibilityLabel("XDR Brightness Control")
            .onAppear { wireLifecycle() }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate
//
// Owns the main NSWindow. We do it in AppKit (rather than SwiftUI's
// Window/WindowGroup) because SwiftUI's window scenes don't reliably
// instantiate their NSWindow when a MenuBarExtra is also in the scene
// graph — the window registers but never appears.

final class XDRAppDelegate: NSObject, NSApplicationDelegate {
    var lifecycle: AppLifecycleManager?
    var appState: AppState?

    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Window creation needs appState + lifecycle, which are wired by the
        // MenuBarExtra label's .onAppear → wireLifecycle(). That fires after
        // didFinishLaunching, so ensureMainWindowVisible() is called there
        // once everything is ready. No deferred call needed here.
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        lifecycle?.shutdown()
    }

    /// Dock icon click while app is running — bring the main window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureMainWindowVisible()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Creates the main window the first time, then orders it to front.
    @MainActor
    func ensureMainWindowVisible() {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        guard let window = mainWindow else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func makeMainWindow() -> NSWindow? {
        guard let appState, let lifecycle else { return nil }

        let content = MainWindowView()
            .environment(appState)
            .environment(lifecycle)

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "XDR Brightness"
        window.titlebarAppearsTransparent = false
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false  // so close-X just hides; reopen works
        window.setContentSize(NSSize(width: 280, height: 320))
        window.center()
        window.collectionBehavior = [.fullScreenAuxiliary]
        return window
    }
}
