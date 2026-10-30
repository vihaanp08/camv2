import Foundation

/// Detects a finger snap in a stream of mono audio.
///
/// A snap is a very short broadband click. Two properties separate it from the
/// noise a phone hears outdoors — where this app is most likely to be used in
/// the dark, and where a fixed threshold fails:
///
/// - **It is transient.** Wind, traffic, HVAC and speech are sustained. Testing
///   the *rise* in energy, not just its level, rejects all of them.
/// - **It is high-frequency.** Differencing the signal once is a cheap one-pole
///   high-pass that suppresses the low-frequency rumble dominating outdoor
///   noise before any energy is measured.
///
/// The trigger level floats on a slowly adapting background estimate, so a quiet
/// room and a windy street both end up needing a snap that is genuinely louder
/// than *their own* ambience. The background deliberately stops adapting while
/// a candidate onset is in progress, otherwise a snap raises the very floor it
/// is being compared against.
public struct SnapOnsetDetector: Sendable {

    /// Per-hop diagnostics, exposed for tests and the sensitivity UI.
    public struct Frame: Sendable {
        public var energy: Float
        public var background: Float
        public var ratio: Float
        public var fired: Bool
    }

    private var background: Float = 0
    private var previousEnergy: Float = 0
    private var refractory: Double = 0
    private var carry: [Float] = []
    private var lastSample: Float = 0
    private var primed: Double = 0

    /// Absolute floor on the background estimate, so near-silence does not make
    /// the ratio explode on a dust-mote of a sound.
    private static let noiseFloor: Float = 2.0e-4
    /// Hops the background is frozen for after a candidate rise.
    private static let freezeHops = 6
    private var freeze = 0

    public init() {}

    public mutating func reset() {
        background = 0; previousEnergy = 0; refractory = 0
        carry.removeAll(); lastSample = 0; freeze = 0; primed = 0
    }

    /// Feeds a buffer of samples and reports whether a snap started in it.
    ///
    /// - Parameters:
    ///   - samples: mono PCM, nominally -1...1.
    ///   - sampleRate: samples per second.
    ///   - sensitivity: 0 (least sensitive) ... 1 (most). 0.5 is the default.
    /// - Returns: true if at least one snap onset fired within this buffer.
    @discardableResult
    public mutating func process(samples: [Float],
                                 sampleRate: Double,
                                 sensitivity: Double) -> Bool {
        guard sampleRate > 0, !samples.isEmpty else { return false }
        let hop = max(16, Int(Tuning.snapHopSeconds * sampleRate))
        let hopSeconds = Double(hop) / sampleRate

        // A louder snap is needed when sensitivity is low. The range is chosen
        // so 0.5 lands near 6x background, which separates a snap from a clap
        // of speech in practice.
        let s = max(0, min(1, Float(sensitivity)))
        let triggerRatio: Float = 14.0 - 10.0 * s     // 14x ... 4x
        let attackRatio: Float = 3.4 - 1.6 * s        // 3.4x ... 1.8x rise

        carry.append(contentsOf: samples)
        var fired = false

        while carry.count >= hop {
            let chunk = carry[0..<hop]
            carry.removeFirst(hop)

            // Differenced RMS: a one-tap high-pass, then energy.
            var acc: Float = 0
            var prev = lastSample
            for v in chunk {
                let d = v - prev
                acc += d * d
                prev = v
            }
            lastSample = prev
            let energy = (acc / Float(hop)).squareRoot()

            refractory = max(0, refractory - hopSeconds)
            primed += hopSeconds

            let floorEnergy = max(background, Self.noiseFloor)
            let ratio = energy / floorEnergy
            let rising = energy > previousEnergy * attackRatio
            // Give the background a moment to settle before trusting ratios,
            // otherwise starting the engine mid-sound fires instantly.
            let ready = primed >= 0.20

            if ready, refractory <= 0, ratio >= triggerRatio, rising {
                fired = true
                refractory = Tuning.snapRefractory
                freeze = Self.freezeHops
            }

            // Freeze background adaptation across the onset itself.
            if freeze > 0 {
                freeze -= 1
            } else {
                let alpha = Float(1 - exp(-hopSeconds / Tuning.snapBackgroundTau))
                if background == 0 {
                    background = energy
                } else {
                    // Rise slowly, fall a little faster: ambience that quietens
                    // should let sensitivity recover promptly, while a passing
                    // truck should not desensitise us for seconds afterwards.
                    let a = energy > background ? alpha : alpha * 2.5
                    background += (energy - background) * min(1, a)
                }
            }
            previousEnergy = energy
        }

        // Never let the carry grow without bound if the caller misbehaves.
        if carry.count > hop * 8 { carry.removeFirst(carry.count - hop * 8) }
        return fired
    }

    public var backgroundLevel: Float { background }
}
