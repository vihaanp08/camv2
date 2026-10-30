import Vision
import CoreImage
import CoreGraphics
import Foundation

/// Builds the mask of things that should stay *in front* of the overlay —
/// in practice the fingers and thumb gripping the card.
///
/// The original build decided this by skin colour, testing chroma ratios for a
/// skin-like hue. That works in daylight and fails exactly where this rewrite
/// has to succeed. Under a streetlight, a phone torch, or any tungsten bulb,
/// auto-white-balance drags the whole frame's chroma a long way, and at high ISO
/// colour noise is the first channel to fall apart — chroma is the *least*
/// reliable signal available in the dark. When the test fails, the fake card
/// paints straight over the performer's fingers, which is about as obvious a
/// tell as the app could produce.
///
/// So geometry leads instead. Hand-pose joints give finger positions from shape
/// rather than colour, and shape survives darkness. Two independent cues are
/// combined, either of which can carry a frame alone:
///
/// - **Hand pose.** Joint positions projected into card space, with each finger
///   bone drawn as a thick capsule. Colour-blind by construction.
/// - **Luminance deviation.** A finger over a card is a region markedly darker
///   than the card stock and connected to the card's edge. Still a luminance
///   test, not a chroma one, so it degrades gracefully rather than inverting.
///
/// The mask is built in **card space** (the unit square the replacement art
/// occupies), which is the space the compositor needs it in, and is independent
/// of where the card happens to be in frame.
final class OcclusionMask {

    /// Mask resolution in card space. Enough to resolve a fingertip; small
    /// enough to build on the CPU every frame without noticing.
    static let width = 72
    static let height = 100

    private let handRequest = VNDetectHumanHandPoseRequest()
    private var cachedPoints: [[CGPoint]] = []
    private var framesSincePose = 99
    private var buffer = [UInt8](repeating: 0, count: OcclusionMask.width * OcclusionMask.height)
    private let colorSpace = CGColorSpaceCreateDeviceGray()

    /// Hand pose is the most expensive request in the pipeline and fingers move
    /// slowly relative to the frame rate, so it runs intermittently and the
    /// joints are reused in between. The cadence eases off further when dark,
    /// where there are fewer frames per second to spare.
    private var poseInterval: Int = 2

    init() {
        handRequest.maximumHandCount = 2
    }

    func reset() {
        cachedPoints = []
        framesSincePose = 99
    }

    /// - Parameters:
    ///   - image: the live frame, Core Image orientation.
    ///   - quad: the tracked card, in image coordinates.
    ///   - regionSamples: rectified card luminance from the tracker, scan order,
    ///     `CardTracker.sampleW` x `sampleH`.
    ///   - cardLevel: robust luminance of the card, linear.
    /// - Returns: a single-channel mask in card space where white means "this
    ///   belongs in front of the overlay", or nil when nothing occludes.
    func build(image: CIImage,
               quad: Quad,
               regionSamples: [Float],
               sampleWidth: Int,
               sampleHeight: Int,
               cardLevel: Float,
               plan: LowLightPlan) -> CIImage? {

        poseInterval = plan.band >= .dark ? 3 : 2

        // Card space <- image space.
        guard let forward = Homography.unitSquare(to: quad),
              let inverse = forward.inverted() else { return nil }

        framesSincePose += 1
        if framesSincePose >= poseInterval {
            framesSincePose = 0
            cachedPoints = detectHands(in: image)
        }

        for i in buffer.indices { buffer[i] = 0 }
        var painted = false

        // MARK: Cue 1 — hand pose geometry
        let extent = image.extent
        for hand in cachedPoints {
            // Project joints into card space, then draw each bone as a capsule.
            let cardPts: [CGPoint] = hand.map { p in
                let imgPt = CGPoint(x: extent.origin.x + p.x * extent.width,
                                    y: extent.origin.y + p.y * extent.height)
                return inverse.apply(imgPt)
            }
            // Joints arrive grouped four per finger, tip first.
            var i = 0
            while i + 3 < cardPts.count {
                let joints = Array(cardPts[i...(i + 3)])
                for j in 0..<3 {
                    // A finger is widest at the base and narrows to the tip.
                    let r = 0.075 - Double(2 - j) * 0.008
                    if drawCapsule(from: joints[j], to: joints[j + 1], radius: r) {
                        painted = true
                    }
                }
                i += 4
            }
        }

        // MARK: Cue 2 — luminance deviation
        // A finger lying across the card reads much darker than the stock. This
        // is a luminance test on purpose: it stays meaningful under any colour
        // of light, where a chroma test does not.
        if !regionSamples.isEmpty,
           regionSamples.count == sampleWidth * sampleHeight,
           cardLevel > 0.002 {
            // The threshold scales with the card's own level, so it works for a
            // card at 0.05 as well as one at 0.5.
            let cut = cardLevel * (plan.band >= .dark ? 0.46 : 0.55)
            for y in 0..<Self.height {
                let sy = min(sampleHeight - 1, y * sampleHeight / Self.height)
                for x in 0..<Self.width {
                    let sx = min(sampleWidth - 1, x * sampleWidth / Self.width)
                    // Rectified samples are stored top-row-first; card space has
                    // y increasing upward, so the row index is flipped.
                    let srcRow = sampleHeight - 1 - sy
                    let v = regionSamples[srcRow * sampleWidth + sx]
                    if v < cut {
                        let idx = y * Self.width + x
                        buffer[idx] = max(buffer[idx], 200)
                        painted = true
                    }
                }
            }
        }

        guard painted else { return nil }

        // Soften the mask so occluder edges blend instead of showing a hard
        // cut-out, which reads as obviously composited.
        let data = Data(buffer)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: Self.width,
                               height: Self.height,
                               bitsPerComponent: 8,
                               bitsPerPixel: 8,
                               bytesPerRow: Self.width,
                               space: colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: true,
                               intent: .defaultIntent)
        else { return nil }

        return CIImage(cgImage: cg)
    }

    // MARK: - Hand pose

    private func detectHands(in image: CIImage) -> [[CGPoint]] {
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([handRequest])
        } catch {
            return []
        }
        guard let observations = handRequest.results, !observations.isEmpty else { return [] }

        let fingers: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbTip, .thumbIP, .thumbMP, .thumbCMC],
            [.indexTip, .indexDIP, .indexPIP, .indexMCP],
            [.middleTip, .middleDIP, .middlePIP, .middleMCP],
            [.ringTip, .ringDIP, .ringPIP, .ringMCP],
            [.littleTip, .littleDIP, .littlePIP, .littleMCP],
        ]

        var hands: [[CGPoint]] = []
        for obs in observations {
            var pts: [CGPoint] = []
            for finger in fingers {
                var ok = true
                var group: [CGPoint] = []
                for joint in finger {
                    guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.25 else {
                        ok = false; break
                    }
                    group.append(CGPoint(x: p.location.x, y: p.location.y))
                }
                // Only whole fingers are used; a partially recognised finger
                // would paint a capsule to a meaningless joint position.
                if ok, group.count == 4 { pts.append(contentsOf: group) }
            }
            if !pts.isEmpty { hands.append(pts) }
        }
        return hands
    }

    // MARK: - Mask drawing

    /// Fills a capsule between two card-space points. Returns false if the
    /// segment lies entirely outside the card.
    @discardableResult
    private func drawCapsule(from a: CGPoint, to b: CGPoint, radius: Double) -> Bool {
        // Reject segments far outside the unit square; projecting a joint behind
        // the camera plane can produce wild coordinates.
        let pad = radius + 0.1
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return false }
        if max(a.x, b.x) < -pad || min(a.x, b.x) > 1 + pad { return false }
        if max(a.y, b.y) < -pad || min(a.y, b.y) > 1 + pad { return false }

        let ax = Double(a.x), ay = Double(a.y)
        let bx = Double(b.x), by = Double(b.y)
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        var touched = false

        for py in 0..<Self.height {
            let v = (Double(py) + 0.5) / Double(Self.height)
            for px in 0..<Self.width {
                let u = (Double(px) + 0.5) / Double(Self.width)
                // Distance from the pixel to the segment.
                var t = 0.0
                if lenSq > 1e-12 {
                    t = ((u - ax) * dx + (v - ay) * dy) / lenSq
                    t = min(1, max(0, t))
                }
                let cx = ax + dx * t, cy = ay + dy * t
                let d = ((u - cx) * (u - cx) + (v - cy) * (v - cy)).squareRoot()
                if d <= radius {
                    // Feather the last 25% of the radius for a soft edge.
                    let inner = radius * 0.75
                    let a255: Double = d <= inner ? 255 : 255 * (1 - (d - inner) / (radius - inner))
                    let idx = py * Self.width + px
                    buffer[idx] = max(buffer[idx], UInt8(max(0, min(255, a255))))
                    touched = true
                }
            }
        }
        return touched
    }
}
