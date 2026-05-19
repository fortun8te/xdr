// XDR Permissions Onboarding View
// ============================================================
// Single-screen "set up XDR" flow adapted from Voice's
// PermissionsView. Same skeleton:
//
//   1. Hero icon + serif title + sans subtitle (+ stale-grant banner
//      + progress strip).
//   2. A drag affordance card: XDR icon -> animated arrow -> System
//      Settings tile that opens the first unresolved pane.
//   3. A vertical list of permission rows, one per
//      `PermissionsService.Kind`. Each row carries a status indicator
//      plus an action button when not granted.
//   4. A footer with "Re-check permissions" and an "All set" indicator.
//
// When `service.allGranted` flips to true the view calls `onDone()`,
// letting the parent decide what "done" means in context.
// ============================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PermissionsView: View {
    // MARK: Inputs

    /// Fired when every required permission is granted.
    var onDone: () -> Void

    // MARK: State

    @State private var service = PermissionsService.shared
    @State private var lastCompletionNotified = false

    // MARK: Layout constants

    private let cardCorner: CGFloat = 14
    private let cardBorderUnselected: CGFloat = 1.0
    private let cardBorderSelected: CGFloat = 1.5
    private let appIconSize: CGFloat = 80
    private let dragTileSize: CGFloat = 88

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.xl) {
                heroSection
                dragAffordanceSection
                permissionRows
                footer
            }
            .padding(.horizontal, Sp.xxl)
            .padding(.vertical, Sp.xxl)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            service.startMonitoring()
        }
        .onDisappear {
            service.stopMonitoring()
        }
        .onChange(of: service.allGranted) { _, newValue in
            if newValue, !lastCompletionNotified {
                lastCompletionNotified = true
                onDone()
            } else if !newValue {
                lastCompletionNotified = false
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            HStack(alignment: .center, spacing: Sp.lg) {
                appIcon
                    .frame(width: appIconSize, height: appIconSize)

                VStack(alignment: .leading, spacing: Sp.xs) {
                    Text(heroTitle)
                        .font(.serifTitle)
                        .foregroundStyle(.primary)
                    Text(heroSubtitle)
                        .font(.bodyLarge)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if service.anyPermissionNeedsReGrant {
                staleGrantBanner
            }

            progressStrip
        }
    }

    private var heroTitle: String {
        if service.allGranted { return "You're all set" }
        if service.anyPermissionNeedsReGrant { return "Re-grant after update" }
        return "Set up XDR"
    }

    private var heroSubtitle: String {
        if service.allGranted { return "XDR is ready to keep an eye on your display." }
        if service.anyPermissionNeedsReGrant {
            return "macOS reset XDR's permissions after an app update. Drag XDR back into each list below."
        }
        return "Grant a few permissions so XDR can alert you and capture your hotkey."
    }

    @ViewBuilder
    private var staleGrantBanner: some View {
        HStack(alignment: .top, spacing: Sp.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions reset after update")
                    .font(.bodyMedium)
                    .foregroundStyle(.primary)
                Text("If XDR is already in the System Settings list, remove it (click −) then drag the icon back in.")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Sp.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var progressStrip: some View {
        let required = PermissionsService.Kind.allCases.filter { $0.isRequired }
        let granted = required.filter { service.status(for: $0) == .granted }.count
        let total = required.count

        HStack(spacing: Sp.sm) {
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i < granted ? Color.accentColor : Color.primary.opacity(0.10))
                        .frame(width: 32, height: 4)
                        .animation(.easeOut(duration: 0.25), value: granted)
                }
            }
            Text("\(granted) of \(total) granted")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsImage = NSImage(named: NSImage.Name("AppIcon")) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: Drag affordance

    @ViewBuilder
    private var dragAffordanceSection: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            HStack(spacing: Sp.xs) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("FAST SETUP")
                    .font(.label)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text("Drag XDR into the System Settings list")
                .font(.serifSection)
                .foregroundStyle(.primary)
            Text("Open Privacy & Security → Input Monitoring, then drop the icon below into the list. Faster than tapping the + button.")
                .font(.bodyBase)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Sp.lg) {
                xdrDragSourceTile
                AnimatedArrow()
                    .frame(width: 32, height: 22)
                    .foregroundStyle(.secondary)
                systemSettingsDropTile
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Sp.xs)
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.accentColor.opacity(service.allGranted ? 0.03 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    service.allGranted ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.35),
                    lineWidth: cardBorderUnselected
                )
        )
        .animation(.easeOut(duration: 0.25), value: service.allGranted)
    }

    @ViewBuilder
    private var xdrDragSourceTile: some View {
        let appURL = Bundle.main.bundleURL
        let needsAttention = !service.allGranted

        VStack(spacing: Sp.sm) {
            appIcon
                .frame(width: dragTileSize - Sp.xl, height: dragTileSize - Sp.xl)
            HStack(spacing: 4) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(needsAttention ? Color.accentColor : .secondary)
                Text("Drag")
                    .font(.bodySmall)
                    .foregroundStyle(needsAttention ? Color.accentColor : .secondary)
            }
        }
        .frame(width: dragTileSize + Sp.xl, height: dragTileSize + Sp.sm)
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    needsAttention ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: needsAttention ? cardBorderSelected : cardBorderUnselected
                )
        )
        .draggable(appURL) {
            appIcon
                .frame(width: 48, height: 48)
        }
        .help("Drag XDR.app into the System Settings list")
    }

    // MARK: - Animated arrow

    private struct AnimatedArrow: View {
        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                let t = phase.truncatingRemainder(dividingBy: 1.4) / 1.4
                let s = sin(t * 2 * .pi)
                let offset = s * 3
                let opacity = 0.55 + 0.30 * (0.5 + 0.5 * s)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .offset(x: offset)
                    .opacity(opacity)
            }
        }
    }

    @ViewBuilder
    private var systemSettingsDropTile: some View {
        Button(action: openSettingsForFirstUnresolved) {
            VStack(spacing: Sp.sm) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("System Settings")
                    .font(.bodyMedium)
                    .foregroundStyle(.primary)
                Text("Tap to open the right pane")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: dragTileSize + Sp.sm)
            .padding(Sp.sm)
            .background(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: cardBorderUnselected)
            )
        }
        .buttonStyle(.plain)
    }

    private func openSettingsForFirstUnresolved() {
        for kind in PermissionsService.Kind.allCases where service.status(for: kind) != .granted {
            service.openSettings(for: kind)
            return
        }
    }

    // MARK: Permission rows

    @ViewBuilder
    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            Text("Permissions")
                .font(.label)
                .tracking(0.8)
                .foregroundStyle(.secondary)

            VStack(spacing: Sp.md) {
                ForEach(PermissionsService.Kind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        status: service.status(for: kind),
                        isActive: kind == firstUnresolvedKind,
                        onPrimaryAction: { performPrimaryAction(for: kind) },
                        onOpenSettings: { service.openSettings(for: kind) }
                    )
                }
            }
        }
    }

    private var firstUnresolvedKind: PermissionsService.Kind? {
        PermissionsService.Kind.allCases.first { service.status(for: $0) != .granted }
    }

    private func performPrimaryAction(for kind: PermissionsService.Kind) {
        switch kind {
        case .notifications:
            if service.notifications == .notDetermined {
                Task { await service.requestNotifications() }
            } else {
                service.openSettings(for: kind)
            }
        case .inputMonitoring:
            // No first-party prompt API. Always route to settings.
            service.openSettings(for: kind)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            if !service.allGranted {
                HStack(alignment: .top, spacing: Sp.xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text("If XDR is already in the System Settings list but a permission still shows red, remove the entry (click the −) and drag XDR back in.")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Sp.xs)
            }

            footerButtons
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        HStack {
            Button {
                service.refresh()
            } label: {
                HStack(spacing: Sp.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Re-check permissions")
                        .font(.bodyMedium)
                }
                .padding(.horizontal, Sp.md)
                .padding(.vertical, Sp.sm)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: cardBorderUnselected)
            )

            Spacer()

            if service.allGranted {
                HStack(spacing: Sp.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text("All set")
                        .font(.bodyMedium)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {
    let kind: PermissionsService.Kind
    let status: PermissionsService.Status
    let isActive: Bool
    let onPrimaryAction: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var scheme

    private let cardCorner: CGFloat = 14
    private let cardBorderUnselected: CGFloat = 1.0
    private let cardBorderSelected: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .center, spacing: Sp.md) {
            iconBadge

            VStack(alignment: .leading, spacing: Sp.xxs) {
                HStack(spacing: Sp.sm) {
                    Text(kind.displayName)
                        .font(.serifSection)
                        .foregroundStyle(.primary)
                    if !kind.isRequired {
                        Text("Optional")
                            .font(.badge)
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Sp.sm)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                    }
                }
                Text(kind.requirementCopy)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Sp.md)

            statusIndicator

            actionButton
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(scheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    isActive && status != .granted
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.06),
                    lineWidth: isActive && status != .granted ? cardBorderSelected : cardBorderUnselected
                )
        )
    }

    @ViewBuilder
    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 44, height: 44)
            Image(systemName: kind.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Granted")
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.red)
                .accessibilityLabel("Denied")
        case .notDetermined:
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityLabel("Not requested yet")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if status == .granted {
            EmptyView()
        } else {
            Button(action: onPrimaryAction) {
                Text(primaryButtonTitle)
                    .font(.bodyMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Sp.md)
                    .padding(.vertical, Sp.sm)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
    }

    private var primaryButtonTitle: String {
        switch (kind, status) {
        case (.notifications, .notDetermined): return "Allow"
        default: return "Open Settings"
        }
    }
}
