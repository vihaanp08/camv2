import CoreImage
import Foundation

/// Hands the latest composited frame from the capture queue to the display loop.
///
/// These are two different threads: `AVCaptureVideoDataOutput` delivers on its
/// own serial queue, and `MTKView` draws on the main thread. Passing the frame
/// through a plain property would be an unsynchronised cross-thread access to a
/// reference — a real race, and one that bites hardest under exactly the load
/// this app runs at.
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CIImage?

    func store(_ image: CIImage?) {
        lock.lock()
        self.image = image
        lock.unlock()
    }

    func load() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }
}
