import CoreVideo
import CoreGraphics
import Foundation

/// Fast scene-brightness metering straight off the pixel buffer.
///
/// Deliberately CPU-side and sparse. The obvious alternative — a `CIAreaAverage`
/// filter — forces a GPU render and a readback every frame, and that readback
/// stalls the capture queue, costing frames exactly when the frame rate is
/// already scarce. Sampling a coarse grid of a few thousand pixels gives a mean
/// that is far more precise than the banding thresholds need.
enum SceneMeter {

    /// Mean luminance in **linear** light, 0...1.
    ///
    /// Linearisation matters here. Pixel values are gamma-encoded, and gamma
    /// compresses the shadows: a scene at 1% real light sits near 0.07 in
    /// encoded units, so thresholds set on raw pixel values are wrong by nearly
    /// an order of magnitude in precisely the range we care about.
    static func meanLuma(pixelBuffer: CVPixelBuffer, targetSamples: Int = 3000) -> Float {
        let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch type {
        case kCVPixelFormatType_32BGRA:
            return meanLumaBGRA(pixelBuffer, targetSamples: targetSamples)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return meanLumaPlanarY(pixelBuffer, targetSamples: targetSamples,
                                   videoRange: type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        default:
            return 0.2
        }
    }

    private static func meanLumaBGRA(_ pb: CVPixelBuffer, targetSamples: Int) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0.2 }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard width > 0, height > 0 else { return 0.2 }

        let step = max(1, Int((Double(width * height) / Double(targetSamples)).squareRoot()))
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum: Float = 0
        var count = 0
        var y = 0
        while y < height {
            let row = ptr + y * stride
            var x = 0
            while x < width {
                let p = row + x * 4
                // BGRA byte order.
                let b = Float(p[0]) / 255
                let g = Float(p[1]) / 255
                let r = Float(p[2]) / 255
                sum += srgbToLinear(r) * 0.2126
                     + srgbToLinear(g) * 0.7152
                     + srgbToLinear(b) * 0.0722
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? max(0, min(1, sum / Float(count))) : 0.2
    }

    private static func meanLumaPlanarY(_ pb: CVPixelBuffer, targetSamples: Int, videoRange: Bool) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0.2 }

        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard width > 0, height > 0 else { return 0.2 }

        let step = max(1, Int((Double(width * height) / Double(targetSamples)).squareRoot()))
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum: Float = 0
        var count = 0
        var y = 0
        while y < height {
            let row = ptr + y * stride
            var x = 0
            while x < width {
                var v = Float(row[x]) / 255
                // Video-range luma uses 16...235; rescale before linearising or
                // every reading is biased bright.
                if videoRange { v = max(0, min(1, (v * 255 - 16) / 219)) }
                sum += srgbToLinear(v)
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? max(0, min(1, sum / Float(count))) : 0.2
    }

    /// sRGB transfer function, encoded -> linear.
    @inline(__always)
    static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSRGB(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
