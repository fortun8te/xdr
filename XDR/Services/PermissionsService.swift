// XDR Permissions Service
// ============================================================
// Centralized status + request for the two macOS permissions XDR
// needs (or benefits from):
//
//   * Notifications    Required. Lets XDR alert the user when the
//                      battery is low or the display is heating up.
//   * Input Monitoring Optional. Improves global hotkey reliability
//                      across all apps. XDR works without it.
//
// Same architecture as Voice's PermissionsService:
//   - @MainActor @Observable singleton (`shared`)
//   - 0.7s polling Timer + didBecomeActive observer in startMonitoring()
//   - read-only refresh() that never prompts
//   - dedicated request* methods own the macOS prompt
//   - "ever granted" UserDefaults keys to detect stale TCC after rebuild
//
// Notification settings are async-only on macOS. We expose the status
// via a cached property that refresh() updates by scheduling a Task
// that calls UNUserNotificationCenter.current().notificationSettings.
// The Timer polling cadence (0.7s) is more than fast enough to feel
// instant to the user.
// ============================================================

import SwiftUI
import UserNotifications
import CoreGraphics
import AppKit

@MainActor
@Observable
final class PermissionsService {
    static let shared = PermissionsService()

    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
    }

    enum Kind: String, CaseIterable, Identifiable {
        case notifications
        case inputMonitoring

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .notifications: return "Notifications"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var systemPreferencesURL: URL {
            switch self {
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }

        var requirementCopy: String {
            switch self {
            case .notifications:
                return "Lets XDR alert you when battery is low or the display is heating up."
            case .inputMonitoring:
                return "Optional. Makes the global brightness hotkey more reliable across all apps."
            }
        }

        var symbolName: String {
            switch self {
            case .notifications: return "bell.badge.fill"
            case .inputMonitoring: return "keyboard"
            }
        }

        var isRequired: Bool {
            switch self {
            case .notifications: return true
            case .inputMonitoring: return false
            }
        }
    }

    // MARK: Observable state

    var notifications: Status = .notDetermined
    var inputMonitoring: Status = .notDetermined

    /// True once every required permission is granted. Input Monitoring
    /// is intentionally excluded; it is optional, and gating onboarding
    /// completion on it would block users who do not want to grant it.
    var allGranted: Bool {
        notifications == .granted
    }

    /// Subset accessor for views that render one row per Kind.
    func status(for kind: Kind) -> Status {
        switch kind {
        case .notifications: return notifications
        case .inputMonitoring: return inputMonitoring
        }
    }

    // MARK: Lifecycle

    private init() {}

    // MARK: Polling

    private var monitorTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Installs a 0.7-second repeating Timer that calls `refresh()`, plus
    /// a NSApplication.didBecomeActive observer that refreshes immediately
    /// when the user returns from System Settings.
    func startMonitoring() {
        stopMonitoring()
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer

        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Allow the tap probe to re-run after the user may have
                    // granted Input Monitoring in System Settings.
                    self?.hasProbedInputMonitoringDenied = false
                    self?.refresh()
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
    }

    // MARK: Refresh

    /// Re-reads the two permission statuses. Read-only; never shows
    /// the macOS system prompt. Safe to call on a timer.
    func refresh() {
        inputMonitoring = currentInputMonitoringStatus()
        // Notification settings is async-only — kick a task that reads
        // it and updates the cached property. The next poll tick will
        // see the fresh value.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notifications = await self.currentNotificationsStatus()
        }
    }

    private func currentNotificationsStatus() async -> Status {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UserDefaults.standard.set(true, forKey: "xdr.everGrantedNotifications")
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private var hasProbedInputMonitoringDenied = false

    private func currentInputMonitoringStatus() -> Status {
        // Once we have confirmed denial, early-return to avoid flooding the
        // system log with TCC denial noise. Re-probing happens on app-focus
        // change (NSApplication.didBecomeActiveNotification observer in
        // startMonitoring) so the UI refreshes when the user grants access.
        if hasProbedInputMonitoringDenied {
            let everGranted = UserDefaults.standard.bool(forKey: "xdr.everGrantedInputMonitoring")
            return everGranted ? .denied : .notDetermined
        }

        // Probe by attempting to create a session-level event tap. If
        // tapCreate returns nil, the kernel refused the tap which on
        // macOS 10.15+ means Input Monitoring is not granted for this
        // process. We immediately invalidate so we do not leak a tap.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        guard let tap else {
            // Denial confirmed — stop creating taps until next app-focus event.
            hasProbedInputMonitoringDenied = true
            let everGranted = UserDefaults.standard.bool(forKey: "xdr.everGrantedInputMonitoring")
            return everGranted ? .denied : .notDetermined
        }

        CFMachPortInvalidate(tap)
        // Successfully tapped — clear the denial flag so normal polling resumes.
        hasProbedInputMonitoringDenied = false
        UserDefaults.standard.set(true, forKey: "xdr.everGrantedInputMonitoring")
        return .granted
    }

    /// True if any required permission was once granted but currently isn't.
    /// Catches the "TCC binding invalidated after unsigned-app rebuild" case.
    var anyPermissionNeedsReGrant: Bool {
        let notifs = notifications != .granted
            && UserDefaults.standard.bool(forKey: "xdr.everGrantedNotifications")
        return notifs
    }

    // MARK: Requests

    /// Triggers the UserNotifications consent prompt. Resolves when
    /// the user dismisses it. Safe to call from `.task` on a view.
    func requestNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            // Authorization can throw if the bundle is not a proper app
            // bundle (e.g. a unit test). Treat as no-op; refresh will
            // re-read whatever the system thinks the status is.
        }
        await Task.yield()
        refresh()
    }

    // MARK: Deep linking

    /// Opens the System Settings pane for the given permission.
    func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.systemPreferencesURL)
    }
}
