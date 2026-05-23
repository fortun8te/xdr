import Foundation

/// How brightness boost above 1.0 is achieved.
///
/// - `gamma`: applies CGSetDisplayTransferByTable scaling at the panel-firmware level.
///   Color-safe by construction (R/G/B scale uniformly, no compositor interaction).
///   Lower ceiling (~750 nits on Liquid Retina XDR) because the gamma factor saturates
///   at roughly half the panel's EDR headroom.
///
/// - `metalOverlay`: a full-screen Metal multiply overlay in `extendedLinearDisplayP3`
///   (matches the panel's native gamut, matching xdr-boost's proven config and Apple
///   WWDC 2022 session 10114's recommendation). Pushes brightness higher (~1100+ nits)
///   at the cost of putting the macOS compositor into EDR-wide mode for the whole
///   screen — which remaps SDR reference white slightly. The color shift this causes
///   on a P3 panel for a uniform-gray multiply factor is mathematically zero, but the
///   white-point remap from EDR mode is structural and cannot be eliminated.
enum BoostMode: String, CaseIterable, Codable, Sendable {
    case gamma        = "gamma"
    case metalOverlay = "metalOverlay"

    var displayName: String {
        switch self {
        case .gamma: return "Gamma"
        case .metalOverlay: return "Metal"
        }
    }
}
