import SwiftUI
import ServiceManagement

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

    var body: some Scene {
        // Main dock window
        Window("XDR", id: "main") {
            MainWindowView()
                .environment(appState)
                .environment(lifecycle)
                .task {
                    guard lifecycle.appState == nil else { return }
                    lifecycle.appState = appState
                    appState.displays = lifecycle.displayManager.displays
                    lifecycle.syncBrightnessFromSystem()
                    appDelegate.lifecycle = lifecycle
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 360, height: 500)
        .windowResizability(.contentSize)

        // Menu bar extra for quick access
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
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate

final class XDRAppDelegate: NSObject, NSApplicationDelegate {
    var lifecycle: AppLifecycleManager?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            lifecycle?.shutdown()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows
                .first(where: { $0.identifier?.rawValue == "main" })?
                .makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
