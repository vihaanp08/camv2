import Foundation

/// Everything the render pipeline needs, snapshotted so the capture queue never
/// reads main-actor state.
struct RenderConfig: Sendable, Equatable {
    /// While armed the overlay is painted; once revealed the real card shows.
    var armed: Bool = true
    var torchPolicy: TorchPolicy = .auto
    /// Replace only the face side of a card, leaving backs alone.
    var facesOnly: Bool = true
    /// Mirror the preview, matching the stock camera's selfie behaviour.
    var mirrored: Bool = false
    /// Run the preview slightly behind live while waiting for a card, so the
    /// fake is already painted the instant it enters frame.
    var entryLead: Bool = true
    /// Keep fingers in front of the overlay.
    var occlusion: Bool = true
    /// Match the overlay's grain to the frame's.
    var matchGrain: Bool = true
    /// Draw tracking diagnostics.
    var debugOverlay: Bool = false
    var snapSensitivity: Double = 0.5
    var snapEnabled: Bool = true
    var hardwareButtonEnabled: Bool = true
    var hapticOnTrigger: Bool = true
    /// Re-arm automatically once the card leaves the frame.
    var autoRearm: Bool = true
}
