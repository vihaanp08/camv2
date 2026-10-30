import Foundation

/// Turns a noisy per-frame tracking confidence into an overlay opacity that
/// never strobes.
///
/// This is the single most important piece for "no glitches in the dark". At
/// high ISO the tracker's confidence does not fail cleanly — it rattles, dipping
/// below threshold for one or two frames at a time. Reacting to each dip makes
/// the fake card blink, which is both ugly and, for a trick, a dead giveaway.
///
/// The gate therefore does three things:
///
/// - **Hysteresis.** Rising past `confidenceOn` arms it; it only disarms below
///   `confidenceOff`. A confidence hovering between the two holds its state.
/// - **Coasting.** A dropout shorter than `coastTime` is treated as measurement
///   noise: the last good quad is reused at full opacity. Real losses last
///   longer than noise does.
/// - **Asymmetric fades.** Fade-in is quick enough to feel instant; fade-out is
///   slower, because a gentle fade reads as nothing at all whereas a hard cut
///   draws the eye. If tracking is genuinely lost the overlay leaves quietly
///   instead of twitching.
public struct ConfidenceGate: Sendable {

    public enum Phase: Sendable, Equatable { case idle, live, coasting, releasing }

    private var phase: Phase = .idle
    private var opacity: Double = 0
    private var coastedFor: Double = 0
    private var quadAge: Double = 0

    public init() {}

    public var currentPhase: Phase { phase }
    public var currentOpacity: Double { opacity }
    /// True while the caller should keep drawing the last known quad.
    public var holdsLastQuad: Bool { phase == .coasting || phase == .releasing }
    /// Seconds since the last accepted measurement.
    public var ageOfQuad: Double { quadAge }

    public mutating func reset() {
        phase = .idle; opacity = 0; coastedFor = 0; quadAge = 0
    }

    /// - Parameters:
    ///   - confidence: tracker confidence for this frame, 0...1.
    ///   - measured: whether the tracker produced a quad at all this frame.
    ///   - dt: seconds since the previous frame.
    /// - Returns: opacity to draw the overlay at, 0...1.
    @discardableResult
    public mutating func update(confidence: Double, measured: Bool, dt: Double) -> Double {
        let step = max(0, min(dt, 0.25))
        let good = measured && confidence >= Tuning.confidenceOn
        let acceptable = measured && confidence >= Tuning.confidenceOff

        if good || acceptable {
            quadAge = 0
        } else {
            quadAge += step
        }

        switch phase {
        case .idle:
            if good {
                phase = .live
                coastedFor = 0
            }

        case .live:
            if acceptable {
                coastedFor = 0
            } else {
                phase = .coasting
                coastedFor = 0
            }

        case .coasting:
            if acceptable {
                phase = .live
                coastedFor = 0
            } else {
                coastedFor += step
                // Hold briefly, then give up and fade. Also bail out if the
                // held quad has simply gone stale.
                if coastedFor >= Tuning.coastTime || quadAge >= Tuning.maxCoast {
                    phase = .releasing
                }
            }

        case .releasing:
            // Only a solidly good measurement recaptures, so we do not bounce
            // back on the same noise that lost us tracking.
            if good {
                phase = .live
                coastedFor = 0
            }
        }

        // Drive opacity toward the phase's target with the appropriate tau.
        let target: Double = (phase == .live || phase == .coasting) ? 1 : 0
        let tau = target > opacity ? Tuning.fadeInTau : Tuning.fadeOutTau
        if step > 0, tau > 1e-6 {
            opacity += (target - opacity) * (1 - exp(-step / tau))
        } else {
            opacity = target
        }
        opacity = min(1, max(0, opacity))
        if phase == .releasing, opacity < 0.002 {
            opacity = 0
            phase = .idle
            quadAge = 0
        }
        return opacity
    }
}
