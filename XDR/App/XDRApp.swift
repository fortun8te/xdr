import SwiftUI

@main
struct XDRApp: App {
    @State private var appState = AppState()
    @State private var lifecycle = AppLifecycleManager()

    /// Handles applicationWillTerminate to reset gamma tables on quit.
    @NSApplicationDelegateAdaptor(XDRAppDelegate.self) private var appDelegate

    init() {
        // Register default user preferences. Set XDRConstants.bundledUserName
        // to bake a name into a personalised build (e.g., Nathan's DMG).
        UserDefaults.standard.register(defaults: [
            "userName": XDRConstants.bundledUserName
        ])
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environment(appState)
                .environment(lifecycle)
                .frame(width: 320)
        } label: {
            Image(systemName: appState.isAnyXDRActive ? "sun.max.fill" : "sun.max")
                .task {
                    // Wire AppState into the lifecycle manager so brightness
                    // changes update the icon.  This runs once when SwiftUI
                    // first renders the menu-bar label — at that point @State
                    // storage is fully owned by SwiftUI, so mutations stick.
                    guard lifecycle.appState == nil else { return }
                    lifecycle.appState = appState
                    appState.displays = lifecycle.displayManager.displays
                    lifecycle.syncBrightnessFromSystem()

                    // Give the delegate a reference so it can call shutdown()
                    appDelegate.lifecycle = lifecycle
                }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate for Safe Shutdown

/// Ensures gamma tables are reset to identity when the app terminates normally.
///
/// If the app crashes (SIGKILL, SIGABRT, etc.), macOS automatically restores
/// the display gamma tables to the ColorSync defaults -- so even an unclean
/// exit will not leave the display stuck at XDR brightness.
final class XDRAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by XDRApp once the lifecycle manager is wired up.
    var lifecycle: AppLifecycleManager?

    func applicationWillTerminate(_ notification: Notification) {
        // Run shutdown synchronously on the main thread. applicationWillTerminate
        // is always called on the main thread, and we need gamma reset to complete
        // before the process exits.
        MainActor.assumeIsolated {
            lifecycle?.shutdown()
        }
    }
}
