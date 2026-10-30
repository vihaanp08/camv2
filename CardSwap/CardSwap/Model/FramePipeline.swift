import CoreImage
import CoreVideo
import CoreGraphics
import Foundation

/// Per-frame orchestration: track, estimate lighting, decide, composite.
///
/// The interesting part is the short delay buffer. While waiting for a card the
/// preview runs a fraction of a second behind live, which buys something that
/// cannot be had any other way: **future information about past frames**.
///
/// Detection has latency. On the frame where the card first enters, the detector
/// has only one noisy look at it and reports low confidence — and in the dark,
/// barely any confidence at all. Drawing nothing until it is sure means the
/// first few frames show the *real* card before the fake appears, which is the
/// one moment a spectator is looking hardest.
///
/// Running behind lets the pipeline revisit that entry frame once the following
/// frames have confirmed a card really is there, and accept its weak detection
/// retroactively. The fake is already painted the instant the card becomes
/// visible. Once the overlay is established the buffer is dropped and the
/// preview returns to live, so performing never feels laggy.
final class FramePipeline {

    private struct Entry {
        var buffer: CVPixelBuffer
        var time: Double
        var dt: Double
        var quad: Quad?
        var confidence: Double
        var faceUp: Bool
        var regionSamples: [Float]
        var regionMean: Float
    }

    private let context: CIContext
    private let tracker: CardTracker
    private let compositor: Compositor
    private let occluder = OcclusionMask()
    private var lighting = LightingEstimator()
    private var gate = ConfidenceGate()

    private var ring: [Entry] = []
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    private var albedo: CIImage?
    private var albedoReference: Float = 0.5

    /// True while the fake is being shown; false once revealed.
    private var armed = true
    /// Set when the overlay has been solidly up, after which we stop running
    /// behind live.
    private var established = false
    private var establishedFor: Double = 0
    private var framesSinceCardSeen: Double = 0
    private var lastPlan = LowLightPlan()

    /// Bounded so the delay buffer cannot grow without limit. Six frames of
    /// 720p BGRA is about 22 MB, which is the ceiling we are willing to hold.
    private static let maxRing = 6

    init(context: CIContext) {
        self.context = context
        self.tracker = CardTracker(context: context)
        self.compositor = Compositor(context: context)
    }

    // MARK: - External control

    func reset() {
        ring.removeAll()
        tracker.reset()
        occluder.reset()
        lighting.reset()
        gate.reset()
        armed = true
        established = false
        establishedFor = 0
        framesSinceCardSeen = 0
    }

    /// Show the fake again.
    func rearm() {
        armed = true
        established = false
        establishedFor = 0
        gate.reset()
        tracker.reset()
        occluder.reset()
    }

    /// Reveal the real card.
    func reveal() {
        armed = false
        established = false
        establishedFor = 0
        ring.removeAll()
    }

    var isArmed: Bool { armed }

    func setAlbedo(_ image: CIImage?) {
        albedo = image
        if let image {
            albedoReference = CardFaceRenderer.referenceLuminance(of: image, context: context)
        }
        lighting.reset()
    }

    func noteDroppedFrame() {
        tracker.noteDiscontinuity()
    }

    // MARK: - Main entry point

    func process(pixelBuffer: CVPixelBuffer,
                 image: CIImage,
                 time: Double,
                 dt: Double,
                 plan: LowLightPlan,
                 config: RenderConfig) -> CIImage {
        lastPlan = plan

        // Always track on the *live* frame: the whole point of the delay is to
        // know more about the past than the past did.
        let result = tracker.process(image: image, time: time, dt: dt, plan: plan)

        // Auto re-arm once the card has been out of frame for a moment.
        if result.quad == nil {
            framesSinceCardSeen += dt
            if !armed, config.autoRearm, framesSinceCardSeen > 0.8 {
                rearm()
            }
        } else {
            framesSinceCardSeen = 0
        }

        // Revealed, or nothing to draw: straight through, no delay, no buffer.
        guard armed, config.armed, albedo != nil else {
            ring.removeAll()
            _ = gate.update(confidence: 0, measured: false, dt: dt)
            return orient(image, config: config)
        }

        // Decide whether to run behind live.
        let wantLead = config.entryLead && !established
        guard wantLead else {
            ring.removeAll()
            return render(image: image,
                          entry: Entry(buffer: pixelBuffer, time: time, dt: dt,
                                       quad: result.quad, confidence: result.confidence,
                                       faceUp: result.faceUp,
                                       regionSamples: result.regionSamples,
                                       regionMean: result.regionMean),
                          lookahead: [],
                          config: config,
                          plan: plan)
        }

        // Copy into our own pool. The capture pool is shallow and holding its
        // buffers would starve it, costing exactly the frames we cannot spare.
        guard let copy = copyToPool(pixelBuffer) else {
            // Out of pool: degrade to live rather than stall.
            ring.removeAll()
            return render(image: image,
                          entry: Entry(buffer: pixelBuffer, time: time, dt: dt,
                                       quad: result.quad, confidence: result.confidence,
                                       faceUp: result.faceUp,
                                       regionSamples: result.regionSamples,
                                       regionMean: result.regionMean),
                          lookahead: [],
                          config: config,
                          plan: plan)
        }

        ring.append(Entry(buffer: copy, time: time, dt: dt,
                          quad: result.quad, confidence: result.confidence,
                          faceUp: result.faceUp,
                          regionSamples: result.regionSamples,
                          regionMean: result.regionMean))
        if ring.count > Self.maxRing { ring.removeFirst(ring.count - Self.maxRing) }

        // Emit the oldest frame that is at least `entryLeadSeconds` old. Holding
        // longer than that is latency the performer would feel.
        let lead = min(Tuning.entryLeadSeconds, Tuning.entryLeadMax)
        guard let oldest = ring.first, time - oldest.time >= lead || ring.count >= Self.maxRing else {
            // Still filling the buffer. Show live meanwhile; the overlay is not
            // up yet by definition, so nothing is lost.
            return orient(image, config: config)
        }

        let entry = ring.removeFirst()
        let lookahead = ring   // everything newer than the frame being shown
        let display = CIImage(cvPixelBuffer: entry.buffer)
        return render(image: display, entry: entry, lookahead: lookahead,
                      config: config, plan: plan)
    }

    // MARK: - Render one frame

    private func render(image: CIImage,
                        entry: Entry,
                        lookahead: [Entry],
                        config: RenderConfig,
                        plan: LowLightPlan) -> CIImage {

        var confidence = entry.confidence
        var quad = entry.quad

        // Retroactive confidence. If later frames agree that a card is here,
        // this frame's weak detection is believable after all. Only ever raises
        // confidence, and only for a frame that produced geometry of its own.
        if let own = quad, !lookahead.isEmpty {
            var best = 0.0
            for future in lookahead {
                guard let fq = future.quad, future.confidence > Tuning.confidenceOn else { continue }
                // It must be the *same* card: a confident detection elsewhere in
                // frame says nothing about this one.
                let travel = Double(own.distance(to: fq))
                let span = Double(max(own.edgeLengths.w, own.edgeLengths.h))
                guard span > 1, travel < span * 1.1 else { continue }
                best = max(best, future.confidence)
            }
            if best > 0 {
                // Discounted, because the evidence is about a neighbouring
                // moment rather than this one.
                confidence = max(confidence, best * 0.92)
            }
        }

        // Honour "replace faces only": a card back should be left alone.
        if config.facesOnly, !entry.faceUp {
            confidence = 0
            quad = nil
        }

        let measured = quad != nil && confidence > 0
        let opacity = gate.update(confidence: confidence, measured: measured, dt: entry.dt)

        // While coasting, hold the last good quad, extrapolated forward so a
        // card still in motion does not leave its overlay trailing behind.
        var drawQuad = quad
        if drawQuad == nil, gate.holdsLastQuad {
            drawQuad = tracker.coastQuad(dt: gate.ageOfQuad)
        }

        guard opacity > 0.002, let target = drawQuad, let art = albedo else {
            return orient(image, config: config)
        }

        // Relight from this frame's own card-region samples.
        let samples = entry.regionSamples
        let light = lighting.update(samples: samples,
                                    reference: albedoReference,
                                    dt: entry.dt,
                                    trim: plan.lightingTrim,
                                    tau: plan.lightingTau)
            ?? LightingEstimator.Lighting(level: entry.regionMean,
                                          gain: 1,
                                          noiseSigma: plan.grainSigma)

        let mask = config.occlusion
            ? occluder.build(image: image,
                             quad: target,
                             regionSamples: samples,
                             sampleWidth: CardTracker.sampleW,
                             sampleHeight: CardTracker.sampleH,
                             cardLevel: light.level,
                             plan: plan)
            : nil

        var out = compositor.overlay(frame: image,
                                     quad: target,
                                     albedo: art,
                                     lighting: light,
                                     occlusion: mask,
                                     opacity: opacity,
                                     config: config,
                                     plan: plan)

        // Once the overlay has been solidly up for a moment, stop running
        // behind live so the preview feels immediate again.
        if opacity > 0.95 {
            establishedFor += entry.dt
            if establishedFor > 0.30 { established = true }
        } else {
            establishedFor = 0
        }

        if config.debugOverlay {
            out = DebugOverlay.draw(on: out, quad: target,
                                    confidence: confidence, opacity: opacity,
                                    plan: plan, context: context)
        }
        return orient(out, config: config)
    }

    private func orient(_ image: CIImage, config: RenderConfig) -> CIImage {
        guard config.mirrored else { return image }
        let e = image.extent
        return image
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: e.width + e.origin.x * 2, y: 0))
    }

    // MARK: - Pixel buffer pool

    private func copyToPool(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source)
        let h = CVPixelBufferGetHeight(source)
        let size = CGSize(width: w, height: h)

        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: Self.maxRing + 2
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                 poolAttrs as CFDictionary,
                                                 attrs as CFDictionary,
                                                 &created)
            guard status == kCVReturnSuccess, let created else { return nil }
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }

        var dest: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dest) == kCVReturnSuccess,
              let dest else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(dest) else { return nil }
            let srcRow = CVPixelBufferGetBytesPerRow(source)
            let dstRow = CVPixelBufferGetBytesPerRow(dest)
            let bytes = min(srcRow, dstRow)
            for row in 0..<h {
                memcpy(dst.advanced(by: row * dstRow),
                       src.advanced(by: row * srcRow),
                       bytes)
            }
        } else {
            for plane in 0..<planes {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else { continue }
                let srcRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstRow = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytes = min(srcRow, dstRow)
                for row in 0..<rows {
                    memcpy(dst.advanced(by: row * dstRow),
                           src.advanced(by: row * srcRow),
                           bytes)
                }
            }
        }
        return dest
    }
}
