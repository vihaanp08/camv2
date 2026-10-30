import Foundation
import CoreGraphics

// MARK: - Minimal test harness

final class T {
    static var passed = 0, failed = 0
    static var failures: [String] = []
    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { passed += 1 }
        else { failed += 1; failures.append("\(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    }
    static func near(_ a: Double, _ b: Double, _ tol: Double, _ name: String) {
        check(abs(a - b) <= tol, name, String(format: "got %.5f expected %.5f (tol %.5f)", a, b, tol))
    }
}

/// Seeded LCG so noisy tests are reproducible.
struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    mutating func uniform() -> Float { Float(next() >> 11) / Float(1 << 53) }
    /// Box-Muller normal.
    mutating func normal() -> Float {
        let u1 = max(1e-7, uniform()), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - LowLightController

func testBandHysteresis() {
    // Luma oscillating right on the dark threshold must not flap the band.
    var c = LowLightController()
    var bands = Set<LightBand>()
    var changes = 0
    var last: LightBand? = nil
    for i in 0..<400 {
        // Straddle darkEnter (0.060) by +/- 0.004 every frame.
        let luma: Float = i % 2 == 0 ? 0.056 : 0.064
        let p = c.update(luma: luma, dt: 1.0 / 30.0, policy: .auto, torchAvailable: true)
        bands.insert(p.band)
        if let l = last, l != p.band { changes += 1 }
        last = p.band
    }
    T.check(changes <= 1, "band hysteresis: no flapping on threshold", "changes=\(changes) bands=\(bands.count)")
}

func testBandMonotonicity() {
    // Progressively darker scenes must ask for progressively more help.
    var results: [(LightBand, Float, Int, Int, Float)] = []
    for luma in [Float(0.50), 0.12, 0.04, 0.008] {
        var c = LowLightController()
        var plan = LowLightPlan()
        // Settle past the dwell timer.
        for _ in 0..<120 { plan = c.update(luma: luma, dt: 1.0 / 30.0, policy: .off, torchAvailable: true) }
        results.append((plan.band, plan.torchLevel, plan.trackLongSide, plan.denoiseFrames, plan.grainSigma))
    }
    T.check(results.map(\.0) == [.bright, .dim, .dark, .veryDark], "bands map to luma",
            "\(results.map { $0.0.name })")
    var ok = true
    for i in 1..<results.count {
        if !(results[i].2 <= results[i-1].2) { ok = false }   // smaller tracking image
        if !(results[i].3 >= results[i-1].3) { ok = false }   // more temporal denoise
        if !(results[i].4 >= results[i-1].4) { ok = false }   // more grain to match
    }
    T.check(ok, "darker -> smaller track image, more denoise, more grain")
}

func testTorchFeedbackDoesNotOscillate() {
    // Closed loop: the torch raises measured luma, which a naive controller
    // reads as "bright enough" and switches it off, darkening the scene again.
    var c = LowLightController()
    var ambient: Float = 0.02            // genuinely dark room
    var onOffTransitions = 0
    var wasOn = false
    for _ in 0..<900 {                   // 30 s at 30 fps
        let plan = c.update(luma: ambient, dt: 1.0 / 30.0, policy: .auto, torchAvailable: true)
        // Measured luma = ambient + torch contribution.
        ambient = 0.02 + plan.torchLevel * 0.30
        let isOn = plan.torchLevel > 0.05
        if isOn != wasOn { onOffTransitions += 1 }
        wasOn = isOn
    }
    T.check(onOffTransitions <= 1, "torch does not oscillate in closed loop",
            "transitions=\(onOffTransitions)")
    T.check(wasOn, "torch stays lit in a dark room")
}

func testTorchPolicyOff() {
    var c = LowLightController()
    var maxLevel: Float = 0
    for _ in 0..<300 {
        let p = c.update(luma: 0.001, dt: 1.0 / 30.0, policy: .off, torchAvailable: true)
        maxLevel = max(maxLevel, p.torchLevel)
    }
    T.check(maxLevel == 0, "torch policy .off never lights", "max=\(maxLevel)")
}

func testTorchUnavailable() {
    var c = LowLightController()
    var maxLevel: Float = 0
    for _ in 0..<300 {
        let p = c.update(luma: 0.001, dt: 1.0 / 30.0, policy: .on, torchAvailable: false)
        maxLevel = max(maxLevel, p.torchLevel)
    }
    T.check(maxLevel == 0, "no torch hardware -> never lights")
}

func testBandTimingIsFrameRateIndependent() {
    // The dwell timer is in seconds, so the same wall-clock settles the band at
    // any frame rate. This is the bug class that broke the original at night.
    func settleTime(fps: Double) -> Double {
        var c = LowLightController()
        let dt = 1.0 / fps
        var t = 0.0
        for _ in 0..<2000 {
            let p = c.update(luma: 0.01, dt: dt, policy: .off, torchAvailable: false)
            t += dt
            if p.band == .veryDark { return t }
        }
        return .infinity
    }
    let fast = settleTime(fps: 60), slow = settleTime(fps: 10)
    T.check(fast.isFinite && slow.isFinite, "band settles at both rates")
    T.check(abs(fast - slow) < 0.15, "band dwell is frame-rate independent",
            String(format: "60fps=%.3fs 10fps=%.3fs", fast, slow))
}

// MARK: - ExpSmoother

func testSmootherFrameRateIndependence() {
    func run(fps: Double) -> Double {
        var s = ExpSmoother()
        _ = s.update(0, dt: 1.0 / fps, tau: 0.2)
        let dt = 1.0 / fps
        var v = 0.0
        for _ in 0..<Int(fps) { v = s.update(1.0, dt: dt, tau: 0.2) }   // 1 second of step input
        return v
    }
    let a = run(fps: 10), b = run(fps: 120)
    T.check(abs(a - b) < 0.02, "exp smoother is frame-rate independent",
            String(format: "10fps=%.4f 120fps=%.4f", a, b))
    T.near(b, 1 - exp(-1.0 / 0.2), 0.02, "exp smoother matches analytic step response")
}

// MARK: - ConfidenceGate

func testGateCoastsThroughBriefDropout() {
    var g = ConfidenceGate()
    let dt = 1.0 / 30.0
    for _ in 0..<30 { g.update(confidence: 0.9, measured: true, dt: dt) }
    let before = g.currentOpacity
    T.check(before > 0.95, "gate reaches full opacity when tracking is solid", "op=\(before)")
    // Three frames of dropout — typical high-ISO rattle.
    var low = 1.0
    for _ in 0..<3 { low = min(low, g.update(confidence: 0.0, measured: false, dt: dt)) }
    T.check(low > 0.95, "brief dropout does not dim the overlay", "min op=\(low)")
    T.check(g.holdsLastQuad, "gate asks caller to hold the last quad while coasting")
}

func testGateReleasesOnRealLoss() {
    var g = ConfidenceGate()
    let dt = 1.0 / 30.0
    for _ in 0..<30 { g.update(confidence: 0.9, measured: true, dt: dt) }
    var op = 1.0
    for _ in 0..<60 { op = g.update(confidence: 0.0, measured: false, dt: dt) }   // 2 s
    T.check(op < 0.01, "sustained loss fades overlay out fully", "op=\(op)")
    T.check(g.currentPhase == .idle, "gate returns to idle")
}

func testGateDoesNotStrobeAtThreshold() {
    // Confidence rattling across the on/off thresholds is the exact signal a
    // high-ISO tracker produces. Opacity must not oscillate.
    var g = ConfidenceGate()
    let dt = 1.0 / 30.0
    for _ in 0..<30 { g.update(confidence: 0.9, measured: true, dt: dt) }
    var reversals = 0
    var prev = g.currentOpacity
    var dir = 0
    var rng = RNG(42)
    for i in 0..<300 {
        let conf = 0.45 + Double(rng.normal()) * 0.08   // straddles 0.35...0.55
        let op = g.update(confidence: conf, measured: true, dt: dt)
        let d = op > prev + 1e-6 ? 1 : (op < prev - 1e-6 ? -1 : 0)
        if d != 0 && dir != 0 && d != dir { reversals += 1 }
        if d != 0 { dir = d }
        prev = op
        _ = i
    }
    T.check(reversals <= 2, "opacity does not strobe when confidence rattles", "reversals=\(reversals)")
    T.check(prev > 0.9, "overlay stays up through acceptable-confidence noise", "op=\(prev)")
}

func testGateStaleQuadBailout() {
    var g = ConfidenceGate()
    let dt = 1.0 / 8.0   // slow, dark-room frame rate
    for _ in 0..<20 { g.update(confidence: 0.9, measured: true, dt: dt) }
    var op = 1.0
    for _ in 0..<20 { op = g.update(confidence: 0.0, measured: false, dt: dt) }
    T.check(op < 0.05, "stale quad bails out even at 8 fps", "op=\(op)")
}

// MARK: - Quad / Homography

func testHomographyRoundTrip() {
    let q = Quad(topLeft: CGPoint(x: 100, y: 400),
                 topRight: CGPoint(x: 320, y: 430),
                 bottomRight: CGPoint(x: 350, y: 120),
                 bottomLeft: CGPoint(x: 80, y: 100))
    guard let h = Homography.unitSquare(to: q) else {
        T.check(false, "homography solves for a valid quad"); return
    }
    T.check(true, "homography solves for a valid quad")
    let corners = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)]
    var worst = 0.0
    for (i, c) in corners.enumerated() {
        let p = h.apply(c)
        worst = max(worst, Double(hypot(p.x - q.corners[i].x, p.y - q.corners[i].y)))
    }
    T.check(worst < 1e-6, "unit square maps onto quad corners", String(format: "worst=%.2e", worst))
}

func testHomographyRejectsDegenerate() {
    // All four corners collapsed — what a failing tracker emits in the dark.
    let bad = Quad(corners: [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5),
                             CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)])
    T.check(Homography.unitSquare(to: bad) == nil, "degenerate quad yields no homography")
    // Three collinear points.
    let line = Quad(corners: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                              CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0)])
    T.check(Homography.unitSquare(to: line) == nil, "collinear quad yields no homography")
}

func testConvexityAndAngles() {
    let good = Quad(topLeft: CGPoint(x: 0, y: 10), topRight: CGPoint(x: 10, y: 10),
                    bottomRight: CGPoint(x: 10, y: 0), bottomLeft: CGPoint(x: 0, y: 0))
    T.check(good.isConvex, "square is convex")
    T.near(Double(good.minAngleDegrees), 90, 0.001, "square min angle is 90")
    T.near(Double(good.area), 100, 0.001, "square area")
    T.near(Double(good.aspect), 1.0, 0.001, "square aspect")
    // Bow-tie: swapped corners, which warps into a visual catastrophe.
    let bow = Quad(corners: [CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10),
                             CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
    T.check(!bow.isConvex, "bow-tie is rejected as non-convex")
}

func testQuadAlignment() {
    let q = Quad(topLeft: CGPoint(x: 0, y: 10), topRight: CGPoint(x: 10, y: 10),
                 bottomRight: CGPoint(x: 10, y: 0), bottomLeft: CGPoint(x: 0, y: 0))
    let spun = q.rotatedLabels(1)
    T.check(spun.corners[0] != q.corners[0], "rotating labels changes order")
    let fixed = spun.aligned(to: q)
    T.check(fixed.corners == q.corners, "aligned(to:) undoes a label rotation")
}

func testCanonicalization() {
    let q = Quad(corners: [CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 0),
                           CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10)])
    let c = q.canonicalized()
    T.check(c.topLeft == CGPoint(x: 0, y: 10), "canonical corner 0 is top-left", "\(c.topLeft)")
    T.check(c.isConvex, "canonicalized quad is a simple polygon")
}

func testHomographyInverse() {
    let q = Quad(topLeft: CGPoint(x: 100, y: 400),
                 topRight: CGPoint(x: 320, y: 430),
                 bottomRight: CGPoint(x: 350, y: 120),
                 bottomLeft: CGPoint(x: 80, y: 100))
    guard let h = Homography.unitSquare(to: q), let inv = h.inverted() else {
        T.check(false, "inverse exists for a valid quad"); return
    }
    T.check(true, "inverse exists for a valid quad")
    // Image point -> card space -> back again.
    var worst = 0.0
    for p in [CGPoint(x: 150, y: 200), CGPoint(x: 300, y: 380), q.center] {
        let round = h.apply(inv.apply(p))
        worst = max(worst, Double(hypot(round.x - p.x, round.y - p.y)))
    }
    T.check(worst < 1e-6, "homography inverse round-trips", String(format: "worst=%.2e", worst))

    // Corners must land on the unit square in card space.
    let tl = inv.apply(q.topLeft)
    T.check(abs(tl.x - 0) < 1e-6 && abs(tl.y - 1) < 1e-6,
            "top-left maps to card-space (0,1)", "\(tl)")
    let br = inv.apply(q.bottomRight)
    T.check(abs(br.x - 1) < 1e-6 && abs(br.y - 0) < 1e-6,
            "bottom-right maps to card-space (1,0)", "\(br)")
}

func testHomographyInverseRejectsSingular() {
    let singular = Homography(m: [1, 0, 0, 2, 0, 0, 3, 0, 0])
    T.check(singular.inverted() == nil, "singular matrix has no inverse")
}

// MARK: - SnapOnsetDetector

/// A snap: a few ms of broadband burst with a sharp attack and fast decay.
func snapBurst(sampleRate: Double, amplitude: Float, rng: inout RNG) -> [Float] {
    let n = Int(0.012 * sampleRate)
    var out = [Float]()
    out.reserveCapacity(n)
    for i in 0..<n {
        let env = exp(-Double(i) / (0.0022 * sampleRate))
        out.append(rng.normal() * amplitude * Float(env))
    }
    return out
}

func silence(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

/// Low-frequency rumble, standing in for wind and traffic.
func rumble(sampleRate: Double, n: Int, amplitude: Float, rng: inout RNG) -> [Float] {
    var out = [Float](); out.reserveCapacity(n)
    var lp: Float = 0
    for _ in 0..<n {
        lp += (rng.normal() - lp) * 0.012     // heavy low-pass
        out.append(lp * amplitude * 8)
    }
    return out
}

func testSnapFiresInQuietRoom() {
    let sr = 48000.0
    var rng = RNG(7)
    var d = SnapOnsetDetector()
    // Prime on near-silence (a little dither, as a real mic has).
    for _ in 0..<40 {
        var buf = silence(512)
        for i in 0..<buf.count { buf[i] = rng.normal() * 0.0004 }
        d.process(samples: buf, sampleRate: sr, sensitivity: 0.5)
    }
    let fired = d.process(samples: snapBurst(sampleRate: sr, amplitude: 0.35, rng: &rng),
                          sampleRate: sr, sensitivity: 0.5)
    T.check(fired, "snap fires in a quiet room")
}

func testNoFalseFireOnOutdoorRumble() {
    let sr = 48000.0
    var rng = RNG(11)
    var d = SnapOnsetDetector()
    var falseFires = 0
    for _ in 0..<200 {   // ~2 s of windy-street noise
        let buf = rumble(sampleRate: sr, n: 512, amplitude: 0.25, rng: &rng)
        if d.process(samples: buf, sampleRate: sr, sensitivity: 0.5) { falseFires += 1 }
    }
    T.check(falseFires == 0, "wind/traffic rumble does not false-fire", "fires=\(falseFires)")
}

func testSnapStillFiresOverRumble() {
    let sr = 48000.0
    var rng = RNG(13)
    var d = SnapOnsetDetector()
    for _ in 0..<200 {
        let buf = rumble(sampleRate: sr, n: 512, amplitude: 0.25, rng: &rng)
        d.process(samples: buf, sampleRate: sr, sensitivity: 0.5)
    }
    // Snap mixed on top of the same ambience.
    var mixed = rumble(sampleRate: sr, n: 1024, amplitude: 0.25, rng: &rng)
    let burst = snapBurst(sampleRate: sr, amplitude: 0.5, rng: &rng)
    for i in 0..<min(burst.count, mixed.count) { mixed[i] += burst[i] }
    T.check(d.process(samples: mixed, sampleRate: sr, sensitivity: 0.5),
            "a snap still fires over outdoor ambience")
}

func testSustainedToneDoesNotFire() {
    let sr = 48000.0
    var d = SnapOnsetDetector()
    var fires = 0
    var phase = 0.0
    for _ in 0..<300 {
        var buf = [Float](); buf.reserveCapacity(512)
        for _ in 0..<512 {
            phase += 2 * .pi * 1000 / sr
            buf.append(Float(sin(phase)) * 0.4)
        }
        if d.process(samples: buf, sampleRate: sr, sensitivity: 0.5) { fires += 1 }
    }
    // A tone starting from silence is one genuine onset; it must not retrigger.
    T.check(fires <= 1, "a sustained tone does not repeatedly fire", "fires=\(fires)")
}

func testRefractoryBlocksDoubleTrigger() {
    let sr = 48000.0
    var rng = RNG(17)
    var d = SnapOnsetDetector()
    for _ in 0..<40 {
        var buf = silence(512)
        for i in 0..<buf.count { buf[i] = rng.normal() * 0.0004 }
        d.process(samples: buf, sampleRate: sr, sensitivity: 0.5)
    }
    var fires = 0
    // Two bursts 60 ms apart — one snap's echo, not two snaps.
    if d.process(samples: snapBurst(sampleRate: sr, amplitude: 0.4, rng: &rng), sampleRate: sr, sensitivity: 0.5) { fires += 1 }
    if d.process(samples: silence(Int(0.06 * sr)), sampleRate: sr, sensitivity: 0.5) { fires += 1 }
    if d.process(samples: snapBurst(sampleRate: sr, amplitude: 0.4, rng: &rng), sampleRate: sr, sensitivity: 0.5) { fires += 1 }
    T.check(fires == 1, "refractory period blocks a double trigger", "fires=\(fires)")
}

// MARK: - LightingEstimator

func testTrimmedMeanRejectsGlints() {
    // 90 samples of card white plus 10 blown-out specular glints.
    var v = [Float](repeating: 0.40, count: 90)
    v.append(contentsOf: [Float](repeating: 1.0, count: 10))
    let plain = v.reduce(0, +) / Float(v.count)
    let trimmed = LightingEstimator.trimmedMean(v, trim: 0.25)
    T.check(abs(trimmed - 0.40) < 0.001, "trimmed mean ignores specular glints",
            String(format: "trimmed=%.4f plain=%.4f", trimmed, plain))
    T.check(plain > 0.45, "plain mean is dragged up by glints (control)")
}

func testNoiseSigmaEstimate() {
    var rng = RNG(23)
    let trueSigma: Float = 0.05
    // Smooth ramp (real structure) plus known noise.
    var v = [Float]()
    for i in 0..<4000 { v.append(0.3 + Float(i) * 0.00001 + rng.normal() * trueSigma) }
    let est = LightingEstimator.noiseSigma(v)
    T.check(abs(est - trueSigma) < 0.012, "noise sigma recovered from noisy samples",
            String(format: "est=%.4f true=%.4f", est, trueSigma))
}

func testLightingIsStableInTheDark() {
    // The headline low-light test. A dark, noisy card region is sampled for two
    // seconds; the relight gain must stay steady, because a wobbling gain is a
    // shimmering overlay. It is compared against the naive per-frame mean that
    // a straightforward implementation would use.
    var rng = RNG(29)
    var est = LightingEstimator()
    let dt = 1.0 / 15.0            // slow dark-room stream
    let reference: Float = 0.5
    let trueLevel: Float = 0.055   // a card lit only by a streetlight
    var gains = [Float]()
    var naiveGains = [Float]()
    for _ in 0..<30 {
        var samples = [Float]()
        for i in 0..<200 {
            let base = trueLevel + 0.008 * Float(sin(Double(i) * 0.05))
            samples.append(max(0, base + rng.normal() * 0.060))   // noise above signal
        }
        if let l = est.update(samples: samples, reference: reference, dt: dt,
                              trim: Tuning.lightingTrimDark, tau: Tuning.lightingTauDark) {
            gains.append(l.gain)
        }
        let naive = samples.reduce(0, +) / Float(samples.count)
        naiveGains.append(naive / reference)
    }
    func spread(_ a: [Float]) -> Float { (a.max() ?? 0) - (a.min() ?? 0) }
    let settled = Array(gains.dropFirst(12))
    let naiveSettled = Array(naiveGains.dropFirst(12))
    let smoothSpread = spread(settled), naiveSpread = spread(naiveSettled)

    // Guard against the clamp making this test vacuous: the gain must actually
    // be tracking the scene, not resting on a bound.
    let expected = trueLevel / reference
    let mean = settled.reduce(0, +) / Float(settled.count)
    T.check(abs(mean - expected) < 0.025, "dark gain tracks the real card level (not clamped)",
            String(format: "mean=%.4f expected=%.4f", mean, expected))
    T.check(mean > Tuning.lightingGainMin * 1.5 && mean < Tuning.lightingGainMax * 0.5,
            "dark gain sits off the clamps", String(format: "mean=%.4f", mean))

    T.check(smoothSpread < 0.020, "dark-scene relight gain is stable",
            String(format: "spread=%.4f", smoothSpread))
    T.check(smoothSpread < naiveSpread * 0.7, "robust estimate beats the naive per-frame mean",
            String(format: "smoothed=%.4f naive=%.4f", smoothSpread, naiveSpread))
    T.check(gains.allSatisfy { $0 >= Tuning.lightingGainMin && $0 <= Tuning.lightingGainMax },
            "relight gain stays clamped")
    print(String(format: "   [info] dark gain spread: robust=%.4f  naive=%.4f  (mean gain %.3f)",
                 smoothSpread, naiveSpread, mean))
}

func testLightingMatchesWhenBright() {
    // A well-lit card whose brightness equals the art needs a gain near 1.
    var rng = RNG(31)
    var est = LightingEstimator()
    var last: Float = 0
    for _ in 0..<40 {
        var samples = [Float]()
        for _ in 0..<400 { samples.append(max(0, 0.46 + rng.normal() * 0.006)) }
        if let l = est.update(samples: samples, reference: 0.46, dt: 1.0 / 60.0,
                              trim: Tuning.lightingTrimBright, tau: Tuning.lightingTau) {
            last = l.gain
        }
    }
    T.check(abs(last - 1.0) < 0.05, "bright matched card yields unity gain",
            String(format: "gain=%.4f", last))
}

func testLightingNeedsEnoughSamples() {
    var est = LightingEstimator()
    T.check(est.update(samples: [0.1, 0.2], reference: 0.5, dt: 0.03, trim: 0.1, tau: 0.1) == nil,
            "too few samples yields no estimate")
}

// MARK: - Run

let tests: [(String, () -> Void)] = [
    ("band hysteresis", testBandHysteresis),
    ("band monotonicity", testBandMonotonicity),
    ("torch feedback loop", testTorchFeedbackDoesNotOscillate),
    ("torch policy off", testTorchPolicyOff),
    ("torch unavailable", testTorchUnavailable),
    ("band timing vs frame rate", testBandTimingIsFrameRateIndependent),
    ("smoother frame-rate independence", testSmootherFrameRateIndependence),
    ("gate coasts brief dropout", testGateCoastsThroughBriefDropout),
    ("gate releases real loss", testGateReleasesOnRealLoss),
    ("gate no strobe", testGateDoesNotStrobeAtThreshold),
    ("gate stale bailout", testGateStaleQuadBailout),
    ("homography round trip", testHomographyRoundTrip),
    ("homography degenerate", testHomographyRejectsDegenerate),
    ("convexity and angles", testConvexityAndAngles),
    ("quad alignment", testQuadAlignment),
    ("canonicalization", testCanonicalization),
    ("homography inverse", testHomographyInverse),
    ("singular inverse", testHomographyInverseRejectsSingular),
    ("snap quiet room", testSnapFiresInQuietRoom),
    ("no false fire on rumble", testNoFalseFireOnOutdoorRumble),
    ("snap over rumble", testSnapStillFiresOverRumble),
    ("sustained tone", testSustainedToneDoesNotFire),
    ("refractory", testRefractoryBlocksDoubleTrigger),
    ("trimmed mean", testTrimmedMeanRejectsGlints),
    ("noise sigma", testNoiseSigmaEstimate),
    ("dark lighting stability", testLightingIsStableInTheDark),
    ("bright unity gain", testLightingMatchesWhenBright),
    ("lighting sample guard", testLightingNeedsEnoughSamples),
]

print("Running \(tests.count) test groups\n")
for (name, fn) in tests {
    let before = T.failed
    fn()
    print("\(T.failed == before ? "pass" : "FAIL")  \(name)")
}
print("\n\(T.passed) assertions passed, \(T.failed) failed")
if !T.failures.isEmpty {
    print("\nFailures:")
    for f in T.failures { print("  - \(f)") }
    exit(1)
}
