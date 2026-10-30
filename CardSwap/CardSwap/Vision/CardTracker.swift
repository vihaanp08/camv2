import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics
import Foundation

/// Finds and follows a playing card in the frame.
///
/// Detection is the stage that fails first when the light goes, so most of the
/// work here is preprocessing rather than detection itself. Three steps carry it:
///
/// 1. **Downscale.** Averaging an NxN block divides noise sigma by N, so a dark
///    frame tracked small is genuinely cleaner than the same frame tracked
///    large — and cheaper. The plan picks a smaller target as it gets darker.
///
/// 2. **Temporal averaging.** Blending the last few frames trades a little
///    motion smear for another large cut in noise. Only engaged when the plan
///    says the per-frame noise is actually hurting.
///
/// 3. **Additive local contrast.** The card is a low-contrast patch sitting in
///    an uneven pool of light. Subtracting a blurred copy flattens the
///    illumination gradient and leaves the edges the detector needs.
///
///    The textbook move here is *multiplicative* normalisation — divide by the
///    blur — but that is wrong for this problem: where the blur approaches zero,
///    which is most of a dark frame, the quotient explodes and manufactures
///    edges out of sensor noise. Subtraction degrades gracefully instead.
///
/// Confidence is then scored honestly and handed to `ConfidenceGate`, which owns
/// the decision about whether to draw anything. A tracker that reports failure
/// cleanly is worth far more here than one that guesses.
final class CardTracker {

    struct Result {
        var quad: Quad?
        /// 0...1. Combines detector confidence, shape plausibility and temporal
        /// agreement. Consumed by `ConfidenceGate`, never used directly.
        var confidence: Double = 0
        /// True when the visible side looks like a card *face* rather than a back.
        var faceUp: Bool = true
        /// Card-region luminance in scan order, linear light, for the lighting
        /// estimator's robust statistics.
        var regionSamples: [Float] = []
        /// Mean linear luminance of the replacement-art-sized region.
        var regionMean: Float = 0
    }

    private let context: CIContext
    private var smoother = QuadSmoother()
    private var previousQuad: Quad?
    private var previousVelocity: CGPoint = .zero
    private var previousTime: Double = 0
    private var history: [CIImage] = []
    private var discontinuity = true

    /// A playing card is 2.5 x 3.5 inches, so 1.4 long-to-short.
    private static let cardAspect: CGFloat = 1.4

    /// Scratch bitmap for region sampling. Small and reused; a fresh allocation
    /// per frame would churn memory at 60 Hz.
    /// Rectified sampling grid. Internal because `FramePipeline` passes these
    /// dimensions on to the occlusion mask, and two copies of the same constant
    /// would silently mis-index the samples if either changed.
    static let sampleW = 36
    static let sampleH = 50
    private var sampleBuffer = [UInt8](repeating: 0, count: sampleW * sampleH * 4)

    init(context: CIContext) {
        self.context = context
    }

    func reset() {
        smoother.reset()
        previousQuad = nil
        previousVelocity = .zero
        previousTime = 0
        history.removeAll()
        discontinuity = true
    }

    func noteDiscontinuity() {
        // A dropped frame breaks temporal adjacency, so the averaged history is
        // no longer a valid estimate of "now".
        discontinuity = true
        history.removeAll()
    }

    /// - Parameters:
    ///   - image: the live frame, Core Image orientation (origin bottom-left).
    ///   - time: presentation time in seconds.
    ///   - dt: seconds since the previous frame.
    func process(image: CIImage, time: Double, dt: Double, plan: LowLightPlan) -> Result {
        var result = Result()
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return result }

        let prepared = prepare(image: image, plan: plan)
        let candidates = detect(in: prepared, frameExtent: extent, plan: plan)

        // Predict where the card should be, from the last quad and its velocity.
        // Used only to score candidates, never to invent one.
        let predicted = predictQuad(dt: dt)

        var best: (quad: Quad, score: Double)?
        for candidate in candidates {
            let score = cardLikeness(candidate.quad,
                                     detectorConfidence: candidate.confidence,
                                     predicted: predicted,
                                     frameExtent: extent)
            if score > (best?.score ?? -1) {
                best = (candidate.quad, score)
            }
        }

        guard var quad = best?.quad, let score = best?.score, score > 0 else {
            // No measurement. Report the failure plainly; the gate decides
            // whether to coast on the previous quad or fade out.
            result.confidence = 0
            result.quad = nil
            previousTime = time
            return result
        }

        // Keep corner labelling continuous, or the overlay spins when the
        // detector happens to return corners in a different order.
        quad = quad.canonicalized()
        if let prev = previousQuad {
            quad = quad.aligned(to: prev)
        }

        let smoothed = smoother.smooth(quad, dt: dt, scale: plan.smoothingScale)

        // Reject anything that would warp into a visual catastrophe. A bow-tie
        // or a sliver produces a spectacular glitch, and in the dark the
        // detector emits them occasionally.
        guard smoothed.isConvex, smoothed.minAngleDegrees > 25, smoothed.area > 200 else {
            result.confidence = 0
            previousTime = time
            return result
        }

        if let prev = previousQuad, dt > 0 {
            let c = smoothed.center, p = prev.center
            previousVelocity = CGPoint(x: (c.x - p.x) / CGFloat(dt),
                                       y: (c.y - p.y) / CGFloat(dt))
        }
        previousQuad = smoothed
        previousTime = time

        let sampled = sampleRegion(image: image, quad: smoothed)
        result.quad = smoothed
        result.confidence = score
        result.regionSamples = sampled.samples
        result.regionMean = sampled.mean
        result.faceUp = sampled.looksLikeFace
        return result
    }

    /// Where the card would be if it kept moving as it was. Scoring aid only.
    private func predictQuad(dt: Double) -> Quad? {
        guard let prev = previousQuad else { return nil }
        guard abs(previousVelocity.x) > 0.01 || abs(previousVelocity.y) > 0.01 else { return prev }
        let dx = previousVelocity.x * CGFloat(dt)
        let dy = previousVelocity.y * CGFloat(dt)
        return Quad(corners: prev.corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
    }

    /// Where to draw while coasting through a dropout, extrapolated forward so a
    /// card still in motion does not leave its overlay behind.
    func coastQuad(dt: Double) -> Quad? {
        predictQuad(dt: dt)
    }

    // MARK: - Preprocessing

    private func prepare(image: CIImage, plan: LowLightPlan) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let scale = min(1.0, CGFloat(plan.trackLongSide) / longSide)

        var working = image
        if scale < 0.999 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = working
            f.scale = Float(scale)
            f.aspectRatio = 1
            working = f.outputImage ?? working
        }

        // Desaturate. Chroma carries almost no usable edge information at high
        // ISO — colour noise is the first thing to go — and it triples the work.
        let mono = CIFilter.colorControls()
        mono.inputImage = working
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1
        working = mono.outputImage ?? working

        // Temporal average across recent frames.
        if plan.denoiseFrames > 1 && !discontinuity {
            history.append(working)
            if history.count > plan.denoiseFrames {
                history.removeFirst(history.count - plan.denoiseFrames)
            }
            if history.count > 1 {
                working = Self.average(history) ?? working
            }
        } else {
            history = [working]
        }
        discontinuity = false

        // Lift the shadows before measuring local contrast, so detail that is
        // crushed into the bottom few code values becomes visible to the
        // detector. Gamma below 1 expands the darks.
        if plan.band >= .dark {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = working
            gamma.power = plan.band == .veryDark ? 0.55 : 0.70
            working = gamma.outputImage ?? working
        }

        // Additive local contrast: subtract a blurred copy, re-centre, boost.
        let radius: Float = max(4, Float(plan.trackLongSide) / 40)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = working.clampedToExtent()
        blur.radius = radius
        guard let blurred = blur.outputImage?.cropped(to: working.extent) else { return working }

        let subtract = CIFilter.subtractBlendMode()
        subtract.inputImage = working
        subtract.backgroundImage = blurred
        guard let highpass = subtract.outputImage else { return working }

        // Re-centre around mid-grey and amplify. The boost rises in dark bands
        // because what survives there is a fainter signal, not a weaker one.
        let boost: Float = plan.band >= .dark ? 3.2 : 2.2
        let lift = CIFilter.colorMatrix()
        lift.inputImage = highpass
        lift.rVector = CIVector(x: CGFloat(boost), y: 0, z: 0, w: 0)
        lift.gVector = CIVector(x: 0, y: CGFloat(boost), z: 0, w: 0)
        lift.bVector = CIVector(x: 0, y: 0, z: CGFloat(boost), w: 0)
        lift.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        lift.biasVector = CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)
        return lift.outputImage ?? highpass
    }

    /// Equal-weight mean of several images.
    private static func average(_ images: [CIImage]) -> CIImage? {
        guard let first = images.first else { return nil }
        var acc = first
        // Blend each subsequent frame in with decreasing weight so the running
        // result is a true equal-weight mean.
        for (i, img) in images.enumerated().dropFirst() {
            let f = CIFilter.mix()
            f.inputImage = img
            f.backgroundImage = acc
            f.amount = Float(1.0 / Double(i + 1))
            guard let out = f.outputImage else { continue }
            acc = out
        }
        return acc
    }

    // MARK: - Detection

    private struct Candidate {
        var quad: Quad
        var confidence: Double
    }

    private func detect(in image: CIImage, frameExtent: CGRect, plan: LowLightPlan) -> [Candidate] {
        let request = VNDetectRectanglesRequest()
        // A playing card seen straight on is 0.714 wide-to-tall; perspective and
        // rotation widen that a lot, so the window is generous and the real
        // filtering happens in `cardLikeness`.
        request.minimumAspectRatio = 0.40
        request.maximumAspectRatio = 1.00
        request.quadratureTolerance = 38
        request.minimumSize = 0.10
        // The detector's own confidence is unreliable on noisy input, so we take
        // more candidates than we need and score them ourselves.
        request.minimumConfidence = plan.band >= .dark ? 0.0 : 0.15
        request.maximumObservations = 10

        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        // Vision reports normalised coordinates with the origin bottom-left,
        // matching Core Image, so corners scale straight onto the full frame.
        let w = frameExtent.width, h = frameExtent.height
        let ox = frameExtent.origin.x, oy = frameExtent.origin.y

        return observations.map { obs in
            func pt(_ p: CGPoint) -> CGPoint {
                CGPoint(x: ox + p.x * w, y: oy + p.y * h)
            }
            let quad = Quad(topLeft: pt(obs.topLeft),
                            topRight: pt(obs.topRight),
                            bottomRight: pt(obs.bottomRight),
                            bottomLeft: pt(obs.bottomLeft))
            return Candidate(quad: quad, confidence: Double(obs.confidence))
        }
    }

    // MARK: - Scoring

    /// How much this candidate looks like the card we are tracking, 0...1.
    ///
    /// Returns exactly 0 for anything disqualifying, so the caller can treat a
    /// zero as "no measurement" rather than "a poor one".
    private func cardLikeness(_ quad: Quad,
                              detectorConfidence: Double,
                              predicted: Quad?,
                              frameExtent: CGRect) -> Double {
        guard quad.isConvex else { return 0 }
        guard quad.minAngleDegrees > 25 else { return 0 }

        let area = quad.area
        let frameArea = frameExtent.width * frameExtent.height
        guard frameArea > 0 else { return 0 }
        let areaFraction = Double(area / frameArea)
        // Too small to warp convincingly; too large and it is probably a wall.
        guard areaFraction > 0.012, areaFraction < 0.80 else { return 0 }

        // Aspect plausibility against a real card's 1.4 ratio. Perspective only
        // ever makes a rectangle look *less* elongated from this viewpoint, so
        // the tolerance is asymmetric.
        let aspect = quad.aspect
        guard aspect > 1.02 else { return 0 }
        let aspectError = abs(aspect - Self.cardAspect) / Self.cardAspect
        let aspectScore = Double(max(0, 1 - aspectError * 1.6))
        guard aspectScore > 0.05 else { return 0 }

        // Squareness of the corners: a real rectangle under mild perspective
        // keeps its angles near 90.
        let angleScore = Double(min(1, max(0, (quad.minAngleDegrees - 25) / 55)))

        // Temporal agreement. A candidate near where the card was predicted to
        // be is far more likely to be the card than a same-shaped distractor
        // elsewhere in the frame — the main defence against the overlay jumping
        // to a book edge or a floor tile in a cluttered dark room.
        var continuity = 0.5
        if let predicted {
            let travel = Double(quad.distance(to: predicted))
            let span = Double(max(frameExtent.width, frameExtent.height))
            continuity = max(0, 1 - travel / (span * 0.22))
        }

        // The detector's own confidence still carries information, just not
        // enough to lead with.
        let detector = max(0.1, min(1, detectorConfidence))

        let score = aspectScore * 0.34
                  + angleScore * 0.16
                  + continuity * 0.30
                  + detector * 0.20
        return max(0, min(1, score))
    }

    // MARK: - Region sampling

    private struct RegionSample {
        var samples: [Float]
        var mean: Float
        var looksLikeFace: Bool
    }

    /// Rectifies the card region into a small upright bitmap and reads it back.
    ///
    /// One small readback per frame (36x50) is cheap, and having the card's own
    /// pixels on the CPU is what makes a robust lighting estimate and a
    /// face-versus-back decision possible at all.
    private func sampleRegion(image: CIImage, quad: Quad) -> RegionSample {
        let w = Self.sampleW, h = Self.sampleH
        // Shrink slightly so the card's own border and the background just
        // outside it do not contaminate the lighting estimate.
        let inner = quad.scaled(by: 0.82)

        let f = CIFilter.perspectiveCorrection()
        f.inputImage = image
        f.topLeft = inner.topLeft
        f.topRight = inner.topRight
        f.bottomRight = inner.bottomRight
        f.bottomLeft = inner.bottomLeft
        f.crop = true
        guard let corrected = f.outputImage, corrected.extent.width > 2 else {
            return RegionSample(samples: [], mean: 0, looksLikeFace: true)
        }

        let sx = CGFloat(w) / corrected.extent.width
        let sy = CGFloat(h) / corrected.extent.height
        let scaled = corrected
            .transformed(by: CGAffineTransform(translationX: -corrected.extent.origin.x,
                                               y: -corrected.extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var samples = [Float]()
        samples.reserveCapacity(w * h)
        var bright = 0
        var sum: Float = 0

        sampleBuffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled,
                           toBitmap: base,
                           rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        for i in 0..<(w * h) {
            let r = Float(sampleBuffer[i * 4 + 0]) / 255
            let g = Float(sampleBuffer[i * 4 + 1]) / 255
            let b = Float(sampleBuffer[i * 4 + 2]) / 255
            // Linearise before averaging; averaging gamma-encoded values
            // systematically overstates how bright a dark region is.
            let lum = SceneMeter.srgbToLinear(r) * 0.2126
                    + SceneMeter.srgbToLinear(g) * 0.7152
                    + SceneMeter.srgbToLinear(b) * 0.0722
            samples.append(lum)
            sum += lum
            // Brightness relative to the region's own level, so this test still
            // works when the whole card is dim.
            if lum > 0 { bright += 1 }
        }

        let mean = samples.isEmpty ? 0 : sum / Float(samples.count)

        // Face versus back. A card face is mostly white stock with sparse ink,
        // so a large majority of its pixels sit well above the region mean. A
        // patterned back fills the area and leaves far fewer.
        var aboveMean = 0
        let threshold = mean * 1.08
        for s in samples where s > threshold { aboveMean += 1 }
        let brightFraction = samples.isEmpty ? 0 : Double(aboveMean) / Double(samples.count)
        let looksLikeFace = brightFraction > 0.42

        return RegionSample(samples: samples, mean: mean, looksLikeFace: looksLikeFace)
    }
}
