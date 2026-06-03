// XDRBoostMeter — shared, smoothed boost-range slider
// =====================================================
// Fixes applied vs. original inline implementations:
//
//  Fix A  — Coalesced drag updates via a 120 Hz TimelineView ramp.
//            .onChanged writes only to targetBrightness; the ramp eases
//            displayed brightness 25 % closer per tick (critically-damped)
//            and calls onSet at most every other tick to halve Metal API
//            pressure. Final snap calls onSet once more when within 0.001.
//
//  Fix B  — Thumb animated with .interactiveSpring(response:0.18,
//            dampingFraction:0.92) so event jitter is visually absorbed.
//
//  Fix C  — SDR/XDR boundary crossing (deadband snap to 1.0) uses a
//            slightly springier animation (response:0.22, dampingFraction:0.7)
//            to signal the mode transition visually.
//
//  Fix D  — Single canonical implementation consumed by both
//            MainWindowView.DisplayCard and PopoverContentView.PopoverDisplayCard.
//
//  Fix E  — Tap (zero-translation DragGesture) uses the same ramp rather
//            than an instant jump, so it feels intentional not a hard cut.

import SwiftUI

// MARK: - Public view

struct XDRBoostMeter: View {
    /// Current brightness from the model layer (1.0 = SDR max, 2.0 = full XDR).
    let brightness: Double
    let isXDR: Bool
    /// Called with the final coalesced value; NOT called on every drag tick.
    let onSet: (Double) -> Void

    // ── internal dims ────────────────────────────────────────────────────────
    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 14
    private let rowHeight: CGFloat = 24

    // ── ramp state ───────────────────────────────────────────────────────────
    /// Raw drag destination. nil means no active gesture.
    @State private var targetBrightness: Double? = nil
    /// Smoothed value driving the visual thumb & fill.
    @State private var displayedBrightness: Double = 1.0
    /// Counter so onSet fires at most every other TimelineView tick (~60 Hz effective).
    @State private var tickCount: Int = 0

    // ── helpers ───────────────────────────────────────────────────────────────
    private var fillFraction: Double {
        guard displayedBrightness > 1.0 else { return 0 }
        return min(max((displayedBrightness - 1.0) / 1.0, 0), 1)
    }

    private var isActive: Bool { displayedBrightness > 1.0 && isXDR }

    private func brightnessValue(forX x: CGFloat, width: CGFloat) -> Double {
        let clamped = min(max(x, 0), width)
        let frac = width > 0 ? Double(clamped / width) : 0
        return 1.0 + frac
    }

    // ── body ─────────────────────────────────────────────────────────────────
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerY = rowHeight / 2
            let thumbX = max(thumbDiameter / 2,
                             min(width - thumbDiameter / 2,
                                 CGFloat(fillFraction) * width))

            // TimelineView drives the 120 Hz ramp while a gesture is active.
            TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: targetBrightness == nil)) { context in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: trackHeight)
                        .position(x: width / 2, y: centerY)

                    // Filled portion — amber → orange gradient
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.xdrAmber, Color.xdrOrange, Color.xdrGradientEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, thumbX), height: trackHeight)
                        .position(x: max(0, thumbX) / 2, y: centerY)
                        .opacity(isActive ? 1.0 : 0.0)

                    // Thumb — Fix B: spring animation on every drag update
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                        )
                        .position(x: thumbX, y: centerY)
                        .opacity(isActive ? 1.0 : 0.55)
                        .animation(
                            .interactiveSpring(response: 0.18, dampingFraction: 0.92),
                            value: thumbX
                        )
                }
                .frame(width: width, height: rowHeight)
                // Drive the ramp on every TimelineView tick by observing the
                // context date — this fires at ~120 Hz while targetBrightness
                // is non-nil (paused: false), advancing the smoothed ramp each frame.
                .onChange(of: context.date) { advanceRamp() }
            }
            .frame(width: width, height: rowHeight)
            .contentShape(Rectangle())
            .opacity(isXDR ? 1.0 : 0.4)
            .allowsHitTesting(isXDR)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isXDR else { return }
                        var raw = brightnessValue(forX: value.location.x, width: width)
                        raw = max(1.0, min(2.0, raw))
                        // Deadband: snap to exactly 1.0 near the SDR/XDR boundary
                        if raw < 1.04 { raw = 1.0 }
                        targetBrightness = raw
                    }
                    .onEnded { value in
                        // Fix E: taps (zero translation) and drag-ends both ramp naturally;
                        // clearing targetBrightness lets the ramp finish to the last value.
                        // We keep targetBrightness non-nil until the ramp snaps.
                        // (The ramp's final snap will nil it out automatically.)
                        _ = value // suppress warning
                    }
            )
        }
        .frame(height: rowHeight)
        .help(isXDR
              ? (isActive ? "Drag to adjust XDR boost (1× → 2×) — actual peak brightness depends on Boost mode (Gamma vs Metal)" : "Tap to enable XDR boost")
              : "XDR boost not supported on this display")
        .onAppear {
            displayedBrightness = brightness
        }
        .onChange(of: brightness) { _, newBrightness in
            // External model update with no active gesture — jump immediately
            if targetBrightness == nil {
                displayedBrightness = newBrightness
            }
        }
    }

    // MARK: - Ramp engine (Fix A)
    //
    // Called by TimelineView each tick (~120 Hz while paused: false).
    // Eases displayedBrightness 25 % closer to targetBrightness per tick.
    // Calls onSet every other tick and once more on final snap.

    private func advanceRamp() {
        guard let target = targetBrightness else { return }

        let remaining = target - displayedBrightness
        let step = remaining * 0.25          // ~25 % per tick → critically damped

        let nextDisplayed: Double
        if abs(remaining) < 0.001 {
            // Close enough — snap and finish
            nextDisplayed = target
            let crossesBoundary = (displayedBrightness <= 1.0 && target > 1.0)
                                || (displayedBrightness > 1.0 && target <= 1.0)
            if crossesBoundary {
                // Fix C: springier animation when crossing SDR/XDR boundary
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.7)) {
                    displayedBrightness = nextDisplayed
                }
            } else {
                displayedBrightness = nextDisplayed
            }
            onSet(target)
            targetBrightness = nil
            return
        } else {
            nextDisplayed = displayedBrightness + step
        }

        displayedBrightness = nextDisplayed

        // Call onSet at most every other tick (Fix A — halve Metal API pressure)
        tickCount &+= 1
        if tickCount.isMultiple(of: 2) {
            onSet(nextDisplayed)
        }
    }

}
