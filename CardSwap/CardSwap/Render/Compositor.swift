import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Paints the replacement card face onto the tracked card.
///
/// Three details decide whether the result survives a dark room:
///
/// - **Relighting happens in linear light.** The `CIContext` is built with a
///   linear working space, so multiplying by the relight gain is a real
///   multiplication of light. Scaling gamma-encoded values instead — the easy
///   mistake — gets the midtones visibly wrong, and the error is worst in the
///   shadows, which is all a dark frame has.
///
/// - **Grain is matched and animated.** A clean card face composited into a
///   noisy high-ISO frame reads as pasted on no matter how good the geometry
///   is, because the eye picks up the missing noise instantly. The frame's own
///   noise sigma is measured and applied to the overlay, and the noise field is
///   re-offset every frame: static grain looks like a texture glued to the card,
///   which is its own tell.
///
/// - **The overlay's edge is feathered and corner-rounded.** Real cards have
///   rounded corners, and a hard-edged rectangle betrays sub-pixel tracking
///   error along every edge. A feathered boundary hides the error that
///   inevitably remains when corner estimates are noisy.
final class Compositor {

    private let context: CIContext
    /// Rounded-card alpha shape in card space, built once.
    private var shapeMask: CIImage?
    private var noiseField: CIImage?
    private var noisePhase: Int = 0

    private static let shapeW = 144
    private static let shapeH = 200

    init(context: CIContext) {
        self.context = context
        self.shapeMask = Self.makeShapeMask()
        self.noiseField = CIFilter.randomGenerator().outputImage
    }

    /// Composites the overlay for one frame.
    ///
    /// - Parameters:
    ///   - frame: the live frame.
    ///   - quad: tracked card corners, image coordinates.
    ///   - albedo: replacement art, any size; treated as filling card space.
    ///   - lighting: relight gain and measured frame noise.
    ///   - occlusion: card-space mask of what stays in front, or nil.
    ///   - opacity: from `ConfidenceGate`; 0 means draw nothing.
    func overlay(frame: CIImage,
                 quad: Quad,
                 albedo: CIImage,
                 lighting: LightingEstimator.Lighting,
                 occlusion: CIImage?,
                 opacity: Double,
                 config: RenderConfig,
                 plan: LowLightPlan) -> CIImage {

        guard opacity > 0.002 else { return frame }
        guard quad.isConvex, quad.minAngleDegrees > 20 else { return frame }

        // MARK: Relight the art to match the card, in linear light.
        let relit: CIImage
        do {
            let g = CGFloat(lighting.gain)
            let m = CIFilter.colorMatrix()
            m.inputImage = albedo
            m.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            relit = m.outputImage ?? albedo
        }

        // MARK: Build the card-space alpha: shape x (1 - occluders) x opacity.
        let albedoExtent = relit.extent
        guard albedoExtent.width > 1, albedoExtent.height > 1 else { return frame }

        var alpha: CIImage
        if let shape = shapeMask {
            alpha = Self.fit(shape, to: albedoExtent)
        } else {
            alpha = CIImage(color: .white).cropped(to: albedoExtent)
        }

        if config.occlusion, let occ = occlusion {
            // The mask marks occluders white; the overlay must be transparent
            // there, so it is inverted before multiplying into the alpha.
            let inv = CIFilter.colorInvert()
            inv.inputImage = Self.fit(occ, to: albedoExtent)
            if let inverted = inv.outputImage {
                let mul = CIFilter.multiplyCompositing()
                mul.inputImage = inverted
                mul.backgroundImage = alpha
                alpha = mul.outputImage ?? alpha
            }
        }

        if opacity < 0.998 {
            let o = CGFloat(opacity)
            let m = CIFilter.colorMatrix()
            m.inputImage = alpha
            m.rVector = CIVector(x: o, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: o, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: o, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            alpha = m.outputImage ?? alpha
        }

        // Apply the alpha by blending the art against transparency.
        let masked: CIImage
        do {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = relit
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = alpha
            guard let out = blend.outputImage else { return frame }
            masked = out.cropped(to: albedoExtent)
        }

        // MARK: Warp card space onto the tracked quad.
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = masked
        warp.topLeft = quad.topLeft
        warp.topRight = quad.topRight
        warp.bottomRight = quad.bottomRight
        warp.bottomLeft = quad.bottomLeft
        guard let warped = warp.outputImage else { return frame }

        let over = CIFilter.sourceOverCompositing()
        over.inputImage = warped
        over.backgroundImage = frame
        guard var result = over.outputImage else { return frame }

        // MARK: Match the frame's grain over the overlay only.
        if config.matchGrain {
            let sigma = max(lighting.noiseSigma, plan.grainSigma)
            if sigma > 0.002,
               let grained = addGrain(to: result,
                                      sigma: sigma,
                                      alphaSource: warped,
                                      bounds: frame.extent) {
                result = grained
            }
        }

        return result.cropped(to: frame.extent)
    }

    // MARK: - Grain

    /// Adds zero-mean noise, confined to the overlay by its own alpha.
    ///
    /// The noise is placed *after* the warp, at screen scale, because sensor
    /// noise lives in screen pixels. Adding it in card space would let the
    /// perspective downscale average it away — the overlay would come out
    /// smoother than the frame around it, which is the problem this solves.
    private func addGrain(to image: CIImage,
                          sigma: Float,
                          alphaSource: CIImage,
                          bounds: CGRect) -> CIImage? {
        guard let field = noiseField else { return nil }

        // Re-offset the field every frame so the grain moves like real noise.
        noisePhase = (noisePhase &+ 61) % 4096
        let offset = CGAffineTransform(translationX: CGFloat(noisePhase * 7 % 2048),
                                       y: CGFloat(noisePhase * 13 % 2048))
        let shifted = field.transformed(by: offset).cropped(to: bounds)

        // Centre the noise on zero and scale to the measured sigma. The random
        // generator is uniform on 0...1 per channel, whose standard deviation is
        // 1/sqrt(12), so the scale factor converts it to the sigma we want.
        let s = CGFloat(sigma) * 3.464   // sqrt(12)
        let centre = CIFilter.colorMatrix()
        centre.inputImage = shifted
        centre.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        centre.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        centre.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        centre.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        centre.biasVector = CIVector(x: -s / 2, y: -s / 2, z: -s / 2, w: 1)
        guard let signed = centre.outputImage else { return nil }

        // Confine the grain to where the overlay actually is, using the warped
        // overlay's alpha as a mask.
        let gate = CIFilter.blendWithMask()
        gate.inputImage = signed
        gate.backgroundImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: bounds)
        gate.maskImage = Self.alphaAsLuminance(alphaSource, bounds: bounds)
        guard let confined = gate.outputImage else { return nil }

        let add = CIFilter.additionCompositing()
        add.inputImage = confined.cropped(to: bounds)
        add.backgroundImage = image
        return add.outputImage
    }

    /// Moves an image's alpha channel into its colour channels, so it can be
    /// used as a blend mask.
    private static func alphaAsLuminance(_ image: CIImage, bounds: CGRect) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (m.outputImage ?? image).cropped(to: bounds)
    }

    // MARK: - Shape mask

    /// Scales an image so its extent matches `target`.
    private static func fit(_ image: CIImage, to target: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let sx = target.width / e.width
        let sy = target.height / e.height
        return image
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: target.origin.x,
                                               y: target.origin.y))
    }

    /// Rounded-rectangle alpha with a feathered edge, in card space.
    ///
    /// The corner radius matches a real playing card — about 1/16 of the short
    /// edge — and the feather spans a couple of card-space percent, which hides
    /// the sub-pixel corner error that always survives smoothing.
    private static func makeShapeMask() -> CIImage? {
        let w = shapeW, h = shapeH
        var buf = [UInt8](repeating: 0, count: w * h)
        let radius = Double(w) * 0.0625
        let feather = Double(w) * 0.022

        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                // Distance outside the rounded rectangle.
                let dx = max(max(radius - px, px - (Double(w) - radius)), 0)
                let dy = max(max(radius - py, py - (Double(h) - radius)), 0)
                let corner = (dx * dx + dy * dy).squareRoot()
                // Inside the straight edges, distance to the boundary.
                let edge = min(min(px, Double(w) - px), min(py, Double(h) - py))

                var a: Double
                if corner > 0 {
                    a = 1 - (corner / max(feather, 0.001))
                } else {
                    a = edge / max(feather, 0.001)
                }
                a = min(1, max(0, a))
                buf[y * w + x] = UInt8(a * 255)
            }
        }

        let data = Data(buf)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cg)
    }
}
