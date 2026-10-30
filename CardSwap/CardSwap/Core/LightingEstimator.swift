import Foundation

/// Robust estimate of how bright the real card is, and how noisy the frame is.
///
/// The overlay has to be relit to match the card it covers, and in the dark both
/// halves of that job get hard. A plain mean over the card region is pulled
/// around by specular glints and by the fat noise tails of a high-ISO sensor, so
/// the overlay's brightness wobbles frame to frame — visible as a shimmer that
/// gives the trick away. Three defences:
///
/// - **Trimmed mean.** Both tails are discarded before averaging; the trim
///   widens in dark bands where the tails are fatter.
/// - **Clamped gain.** The relight factor is bounded, so a bad frame cannot
///   blow the overlay out or black it.
/// - **Temporal smoothing with a longer tau when dark.** The estimate is
///   allowed to move slowly; real lighting changes are slow, shimmer is not.
///
/// It also measures the frame's noise level, which the compositor needs: a
/// perfectly clean card face composited into a grainy dark frame looks pasted
/// on. Matching the grain is what makes it sit in the image.
public struct LightingEstimator: Sendable {

    public struct Lighting: Sendable, Equatable {
        /// Robust luminance of the card region, linear 0...1.
        public var level: Float
        /// Multiplier to apply to the albedo so it matches the card.
        public var gain: Float
        /// Estimated per-pixel noise sigma of the frame, linear units.
        public var noiseSigma: Float
    }

    private var levelSmoother = ExpSmoother()
    private var noiseSmoother = ExpSmoother()

    public init() {}

    public mutating func reset() {
        levelSmoother.reset(); noiseSmoother.reset()
    }

    /// - Parameters:
    ///   - samples: luminance samples from the card region, in **scan order**
    ///     (adjacency matters for the noise estimate), linear 0...1.
    ///   - reference: mean luminance of the replacement art, linear 0...1.
    ///   - dt: seconds since the previous estimate.
    ///   - trim: fraction to discard from each tail, 0...0.45.
    ///   - tau: smoothing time constant in seconds.
    public mutating func update(samples: [Float],
                                reference: Float,
                                dt: Double,
                                trim: Float,
                                tau: Double) -> Lighting? {
        guard samples.count >= 8 else { return nil }

        let raw = Self.trimmedMean(samples, trim: trim)
        let noise = Self.noiseSigma(samples)

        let level = Float(levelSmoother.update(Double(raw), dt: dt, tau: tau))
        let sigma = Float(noiseSmoother.update(Double(noise), dt: dt, tau: max(tau, 0.25)))

        let ref = max(reference, 0.02)
        let gain = min(Tuning.lightingGainMax, max(Tuning.lightingGainMin, level / ref))

        return Lighting(level: max(0, level), gain: gain, noiseSigma: max(0, sigma))
    }

    /// Mean after discarding `trim` of the samples from each tail.
    static func trimmedMean(_ values: [Float], trim: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let t = max(0, min(0.45, trim))
        let sorted = values.sorted()
        let drop = Int((Float(sorted.count) * t).rounded(.down))
        let lo = drop
        let hi = sorted.count - drop
        guard hi > lo else {
            return sorted[sorted.count / 2]
        }
        var sum: Float = 0
        for i in lo..<hi { sum += sorted[i] }
        return sum / Float(hi - lo)
    }

    /// Robust noise sigma from the median absolute successive difference.
    ///
    /// Real image structure is locally smooth, so neighbouring-pixel differences
    /// are dominated by noise. Using the *median* of those differences rather
    /// than their mean keeps genuine edges — which are rare but huge — from
    /// inflating the estimate. The 1.4826 factor converts MAD to a Gaussian
    /// sigma; the sqrt(2) accounts for differencing two noisy samples.
    static func noiseSigma(_ values: [Float]) -> Float {
        guard values.count >= 4 else { return 0 }
        var diffs = [Float]()
        diffs.reserveCapacity(values.count - 1)
        for i in 1..<values.count { diffs.append(abs(values[i] - values[i - 1])) }
        diffs.sort()
        let median = diffs[diffs.count / 2]
        return median * 1.4826 / 1.41421356
    }
}
