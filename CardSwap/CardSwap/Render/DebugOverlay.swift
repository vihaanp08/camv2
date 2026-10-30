import CoreImage
import CoreGraphics
import UIKit

/// Tracking diagnostics, drawn only when the user turns them on in settings.
///
/// Worth having because the failure modes this app cares about are invisible
/// otherwise: you cannot tell by eye whether the overlay vanished because
/// detection failed, because confidence fell, or because the gate chose to fade.
enum DebugOverlay {

    static func draw(on image: CIImage,
                     quad: Quad,
                     confidence: Double,
                     opacity: Double,
                     plan: LowLightPlan,
                     context: CIContext) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: extent.size, format: format)

        let overlay = renderer.image { ctx in
            let cg = ctx.cgContext
            // UIKit's y axis points down; Core Image's points up.
            func flip(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x - extent.origin.x, y: extent.height - (p.y - extent.origin.y))
            }
            cg.setLineWidth(2)
            cg.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.9).cgColor)
            let pts = quad.corners.map(flip)
            cg.move(to: pts[0])
            for p in pts.dropFirst() { cg.addLine(to: p) }
            cg.closePath()
            cg.strokePath()

            let labels = ["TL", "TR", "BR", "BL"]
            for (i, p) in pts.enumerated() {
                cg.setFillColor(UIColor.systemYellow.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                NSAttributedString(
                    string: labels[i],
                    attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                 .foregroundColor: UIColor.systemYellow]
                ).draw(at: CGPoint(x: p.x + 6, y: p.y - 6))
            }

            let text = String(format: "%@  conf %.2f  op %.2f  torch %.2f  aspect %.2f",
                              plan.band.name, confidence, opacity,
                              plan.torchLevel, Double(quad.aspect))
            NSAttributedString(
                string: text,
                attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: UIColor.white,
                             .backgroundColor: UIColor.black.withAlphaComponent(0.55)]
            ).draw(at: CGPoint(x: 12, y: 12))
        }

        guard let cg = overlay.cgImage else { return image }
        let top = CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        let f = CIFilter(name: "CISourceOverCompositing")
        f?.setValue(top, forKey: kCIInputImageKey)
        f?.setValue(image, forKey: kCIInputBackgroundImageKey)
        return f?.outputImage ?? image
    }
}
