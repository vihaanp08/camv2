import SwiftUI
import AVFoundation
import Metal
import CoreImage
import Photos
import UIKit
import os

/// Main-actor state for the camera screen, and the one place triggers converge.
@MainActor
final class CameraModel: ObservableObject {

    @Published var armed = true
    @Published var band: LightBand = .bright
    @Published var message: String?
    @Published var permissionDenied = false
    @Published var lastSavedThumbnail: UIImage?
    /// Whether the active camera has a torch. Pushed from the capture queue
    /// rather than read across threads.
    @Published var torchCapable = false

    let settings = AppSettings()

    /// Metal device and queue, shared with the preview so Core Image can render
    /// straight into the view's drawable with no intermediate copy.
    let metalDevice: MTLDevice?
    let commandQueue: MTLCommandQueue?

    /// A **linear** working space is what makes the compositor's relight a real
    /// multiplication of light rather than of gamma-encoded values. Core Image
    /// does not use one by default, and getting this wrong shows up worst in the
    /// shadows — which is all a dark frame has.
    private let context: CIContext

    private lazy var engine = CameraEngine(context: context)
    private let snapListener = SnapListener()
    /// Lock-protected, because the capture queue writes it and the display loop
    /// reads it. See `FrameBox`.
    private let frameBox = FrameBox()
    private var hasStarted = false
    private let log = Logger(subsystem: "com.cardswap", category: "model")

    var ciContext: CIContext { context }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        let queue = device?.makeCommandQueue()
        metalDevice = device
        commandQueue = queue

        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        var options: [CIContextOption: Any] = [
            .workingColorSpace: linear as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ]
        if let queue {
            context = CIContext(mtlCommandQueue: queue, options: options)
        } else {
            // No Metal: the preview falls back to a Core Graphics path. Every
            // shipping iOS 17 device has Metal, so this is a safety net rather
            // than a supported configuration.
            options[.useSoftwareRenderer] = false
            context = CIContext(options: options)
        }

        engine.onFrame = { [frameBox] image, _ in
            // Capture-queue callback. Only the latest frame is kept; the preview
            // pulls it on the display loop.
            frameBox.store(image)
        }
        engine.onBandChange = { [weak self] band in
            self?.band = band
        }
        engine.onTorchCapability = { [weak self] available in
            self?.torchCapable = available
        }
        engine.onError = { [weak self] message in
            self?.message = message
        }
        snapListener.onSnap = { [weak self] in
            guard let self, self.settings.snapEnabled else { return }
            self.trigger(source: "snap")
        }
        snapListener.onError = { [weak self] message in
            self?.message = message
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Both the scene becoming active and the view appearing call this, and
        // on a cold launch both happen. Starting twice would prompt for
        // permissions twice.
        guard !hasStarted else {
            engine.start()
            return
        }
        hasStarted = true
        Task { @MainActor in
            guard await requestCameraAccess() else {
                hasStarted = false
                permissionDenied = true
                return
            }
            applySettings()
            engine.start()
            if settings.snapEnabled, await requestMicrophoneAccess() {
                snapListener.setSensitivity(settings.snapSensitivity)
                snapListener.start()
            }
        }
    }

    func stop() {
        engine.stop()
        snapListener.stop()
        frameBox.store(nil)
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Settings

    func applySettings() {
        pushConfig()
        snapListener.setSensitivity(settings.snapSensitivity)
        if settings.snapEnabled { snapListener.start() } else { snapListener.stop() }
        refreshFace()
    }

    /// Rebuilds the replacement art from settings.
    func refreshFace() {
        if let url = settings.importedFaceURL,
           let data = try? Data(contentsOf: url),
           let image = CIImage(data: data) {
            engine.setAlbedo(image)
            return
        }
        guard let cg = CardFaceRenderer.render(rank: settings.rank, suit: settings.suit) else {
            engine.setAlbedo(nil)
            return
        }
        engine.setAlbedo(CIImage(cgImage: cg))
    }

    /// Flattens a picked photo to card proportions and stores it.
    func importFace(data: Data) {
        guard let source = CIImage(data: data) else {
            message = "Couldn't read that photo."
            return
        }
        guard let flat = CardFaceRenderer.rectifyImported(source, context: context) else {
            message = "Couldn't find a card in that photo. Shoot it flat, filling the frame."
            return
        }
        guard let cg = context.createCGImage(flat, from: flat.extent),
              let png = UIImage(cgImage: cg).pngData() else {
            message = "Couldn't prepare that photo."
            return
        }
        let name = "imported-face.png"
        let url = AppSettings.supportDirectory.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            settings.importedFace = name
            refreshFace()
            message = "Imported. Check the preview: it should be flat, upright and white."
        } catch {
            message = "Couldn't save that photo: \(error.localizedDescription)"
        }
    }

    func clearImportedFace() {
        settings.deleteImportedFace()
        refreshFace()
    }

    // MARK: - Triggers

    /// Reveal the real card, or re-arm if the reveal already happened.
    func trigger(source: String) {
        log.info("trigger from \(source, privacy: .public)")
        guard armed else { rearm(); return }
        armed = false
        engine.reveal()
        pushConfig()
        if settings.hapticOnTrigger {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    func rearm() {
        armed = true
        pushConfig()
        engine.rearm()
        if settings.hapticOnTrigger {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    private func pushConfig() {
        var config = settings.renderConfig
        config.armed = armed
        engine.setConfig(config)
    }

    func handleTap(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // Convert to the capture device's coordinate space, which is normalised
        // with the origin at the top-left of the *landscape* sensor.
        let normalized = CGPoint(x: point.y / size.height,
                                 y: 1 - point.x / size.width)
        engine.focus(at: normalized)
    }

    func switchCamera() {
        engine.switchCamera()
    }

    func setZoom(_ factor: CGFloat) {
        engine.setZoom(factor)
    }

    var isTorchCapable: Bool { torchCapable }

    // MARK: - Photo

    /// Saves what is on screen, overlay included.
    ///
    /// The overlay only exists in the preview, so the saved image is rendered
    /// from the same composited frame rather than from a separate still
    /// capture — a still would come back showing the real card.
    func takePhoto() {
        guard let frame = frameBox.load() else {
            message = "Nothing to save yet."
            return
        }
        guard let cg = context.createCGImage(frame, from: frame.extent) else {
            message = "Couldn't render that frame."
            return
        }
        let image = UIImage(cgImage: cg)
        lastSavedThumbnail = image
        if settings.hapticOnTrigger {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                message = "Photos access is off, so there's nowhere to save."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } catch {
                message = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    /// Latest composited frame, for the preview renderer.
    func currentFrame() -> CIImage? { frameBox.load() }
}
