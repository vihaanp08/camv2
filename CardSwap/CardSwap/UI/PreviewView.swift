import UIKit
import MetalKit
import CoreImage
import AVFoundation
import AVKit  // AVCaptureEventInteraction lives here, not in AVFoundation

/// Metal-backed preview.
///
/// The composited frame is a `CIImage`, and Core Image renders it directly into
/// the view's drawable using the same command queue — no intermediate
/// `UIImage`, no CPU round trip. At 60 fps on a frame this size an extra copy
/// per frame would cost real thermal headroom, which in turn costs frame rate,
/// which is already the scarce resource in a dark room.
final class PreviewView: MTKView {

    var onTap: ((CGPoint, CGSize) -> Void)?
    var onRearm: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHardwareButton: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    /// Pulled on the display loop; returns the frame to draw, if any.
    var frameProvider: (() -> CIImage?)?

    private let context: CIContext
    private let queue: MTLCommandQueue?
    private var zoomAtGestureStart: CGFloat = 1

    init(device: MTLDevice?, queue: MTLCommandQueue?, context: CIContext) {
        self.context = context
        self.queue = queue
        super.init(frame: .zero, device: device ?? MTLCreateSystemDefaultDevice())
        framebufferOnly = false        // Core Image needs to write to the texture
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        colorPixelFormat = .bgra8Unorm
        // Matches the capture rate; the drawable is presented whenever a new
        // composited frame is ready.
        preferredFramesPerSecond = 60
        backgroundColor = .black
        delegate = self
        installGestures()
        installHardwareButtons()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        // Two-finger double tap re-arms: deliberately awkward, so it cannot be
        // hit by accident mid-performance.
        let rearm = UITapGestureRecognizer(target: self, action: #selector(handleRearm))
        rearm.numberOfTouchesRequired = 2
        rearm.numberOfTapsRequired = 2
        addGestureRecognizer(rearm)
        tap.require(toFail: rearm)

        let settings = UILongPressGestureRecognizer(target: self, action: #selector(handleSettings))
        settings.numberOfTouchesRequired = 2
        settings.minimumPressDuration = 0.6
        addGestureRecognizer(settings)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        onTap?(g.location(in: self), bounds.size)
    }

    @objc private func handleRearm(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        onRearm?()
    }

    @objc private func handleSettings(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        onSettings?()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            zoomAtGestureStart = 1
        case .changed:
            onZoom?(g.scale)
        default:
            break
        }
    }

    /// Volume buttons and, on supporting hardware, the Camera Control.
    private func installHardwareButtons() {
        let interaction = AVCaptureEventInteraction { [weak self] event in
            // Fire on release, matching the shutter behaviour people expect,
            // and so a long press does not repeat.
            guard event.phase == .ended else { return }
            self?.onHardwareButton?()
        }
        addInteraction(interaction)
    }
}

// MARK: - Drawing

extension PreviewView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let queue,
              let buffer = queue.makeCommandBuffer() else { return }

        let target = CGRect(x: 0, y: 0,
                            width: drawable.texture.width,
                            height: drawable.texture.height)

        guard let image = frameProvider?() else {
            // Nothing to show yet: clear to black rather than presenting an
            // uninitialised drawable, which flashes garbage.
            if let pass = view.currentRenderPassDescriptor,
               let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.endEncoding()
            }
            buffer.present(drawable)
            buffer.commit()
            return
        }

        // Aspect-fill: scale so the frame covers the drawable, then centre it.
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = max(target.width / extent.width, target.height / extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                               y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (target.width - extent.width * scale) / 2
        let dy = (target.height - extent.height * scale) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        context.render(placed,
                       to: drawable.texture,
                       commandBuffer: buffer,
                       bounds: target,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                           ?? CGColorSpaceCreateDeviceRGB())

        buffer.present(drawable)
        buffer.commit()
    }
}
