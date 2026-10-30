import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import QuartzCore
import os

/// Owns the capture session and, critically, how the sensor is driven when the
/// light goes away.
///
/// The original build left capture entirely on automatic. That is what breaks
/// outdoors at night, for three compounding reasons:
///
/// 1. **Unbounded exposure.** Auto-exposure buys brightness with integration
///    time, so a dark scene pushes frame duration out to 1/15 s or longer. A
///    handheld card smears across the frame, and motion blur is far more
///    damaging to a corner detector than noise is — blur destroys the gradients
///    the detector needs, while noise merely buries them. We cap duration and
///    let the sensor take the hit as gain instead.
/// 2. **Collapsing frame rate.** The same mechanism drops the stream to a rate
///    the rest of the pipeline was never tuned for.
/// 3. **No fill light.** The device has a torch and the original never touches
///    it. A card held at arm's length is trivially lit by it at a low level.
///
/// Format choice also matters and is done once, at start: **binned** formats
/// combine adjacent photosites, which roughly doubles low-light signal-to-noise
/// for a resolution we do not need anyway. Switching `activeFormat` later causes
/// a visible hitch, so only exposure, frame duration and torch are adjusted
/// per frame.
final class CameraEngine: NSObject {

    // MARK: Output
    /// Called on `queue` for every processed frame, with the image to display.
    var onFrame: ((CIImage, CMTime) -> Void)?
    /// Called when the scene-brightness band changes, for the UI badge.
    var onBandChange: ((LightBand) -> Void)?
    /// Reports whether the active camera has a usable torch, on the main queue.
    var onTorchCapability: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: Session
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.cardswap.capture", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private(set) var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back

    private let context: CIContext
    private let pipeline: FramePipeline
    private var lowLight = LowLightController()

    private var lastFrameTime: Double = 0
    private var lastBand: LightBand = .bright
    private var lastTorchApplied: Float = -1
    private var lastExposureApplied: Double = -1
    private var configuration = RenderConfig()

    private let log = Logger(subsystem: "com.cardswap", category: "capture")

    init(context: CIContext) {
        self.context = context
        self.pipeline = FramePipeline(context: context)
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty {
                self.configure(position: self.position)
            }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            // Always extinguish the torch on the way out. Leaving it lit when
            // the app backgrounds is both alarming and a battery drain.
            self.applyTorch(0)
            if self.session.isRunning { self.session.stopRunning() }
            self.pipeline.reset()
        }
    }

    func setConfig(_ cfg: RenderConfig) {
        queue.async { [weak self] in self?.configuration = cfg }
    }

    func rearm() {
        queue.async { [weak self] in self?.pipeline.rearm() }
    }

    /// Show the real card.
    func reveal() {
        queue.async { [weak self] in self?.pipeline.reveal() }
    }

    func setAlbedo(_ image: CIImage?) {
        queue.async { [weak self] in self?.pipeline.setAlbedo(image) }
    }

    // MARK: - Configuration

    private func configure(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }

        guard let device = Self.bestDevice(for: position) else {
            report("No camera available on this device.")
            return
        }
        self.device = device
        self.position = position

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                report("Could not attach the camera input.")
                return
            }
            session.addInput(input)
            self.input = input
        } catch {
            report("Camera input error: \(error.localizedDescription)")
            return
        }

        if session.outputs.isEmpty {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                report("Could not attach the video output.")
                return
            }
            session.addOutput(output)
        }

        selectFormat(on: device)
        applyConnectionSettings()

        let torch = device.hasTorch
        DispatchQueue.main.async { [weak self] in self?.onTorchCapability?(torch) }
    }

    /// Picks the camera best suited to low light: the widest-aperture
    /// (lowest f-number) back camera, which on multi-camera devices is the main
    /// wide rather than the ultra-wide or telephoto.
    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: position)
        // Prefer a plain wide-angle: on a multi-camera device the virtual
        // device can switch lenses mid-stream, and an ultra-wide has a much
        // smaller sensor and a slower lens — both bad at night, and a lens
        // switch mid-trick would jump the tracked quad.
        if let wide = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return wide
        }
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    /// Chooses the capture format once, favouring binned sensor readout.
    ///
    /// Binning averages adjacent photosites in hardware, which buys roughly a
    /// stop of signal-to-noise for resolution the tracker does not use. We want
    /// around 1280x720 and a format capable of at least 30 fps.
    private func selectFormat(on device: AVCaptureDevice) {
        let wanted: Int32 = 1280
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.greatestFiniteMagnitude

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard CMFormatDescriptionGetMediaSubType(desc) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || CMFormatDescriptionGetMediaSubType(desc) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            else { continue }

            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxRate >= 30 else { continue }

            var score = 0.0
            // Binning is the single biggest low-light win available here.
            if format.isVideoBinned { score += 1000 }
            // Prefer a long side near our target; oversized formats cost
            // bandwidth and thermal headroom for nothing.
            score -= abs(Double(max(dims.width, dims.height) - wanted)) * 0.5
            // Headroom above 30 fps helps, but only a little.
            score += min(maxRate, 60) * 2
            // A format that can also sustain a long exposure gives AE more room.
            score += Double(format.maxISO) * 0.001
            // Avoid formats that force video HDR, which flickers frame to frame
            // and upsets both the tracker and the lighting estimate.
            if format.isVideoHDRSupported { score -= 50 }

            if score > bestScore { bestScore = score; best = format }
        }

        guard let format = best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format

            // Pin the frame rate so a dark scene cannot trade it away. Both
            // bounds are clamped into the format's supported range; asking for a
            // rate it cannot deliver throws.
            let ranges = format.videoSupportedFrameRateRanges
            let hi = min(60.0, ranges.map(\.maxFrameRate).max() ?? 30.0)
            let formatFloor = ranges.map(\.minFrameRate).min() ?? 1.0
            let lo = max(formatFloor, min(hi, Tuning.minFrameRate))
            // Min *duration* is the fastest rate; max duration is the slowest.
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(hi.rounded()))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(lo.rounded()))

            // Video HDR fuses differently exposed lines; the resulting frame-to
            // -frame variation shows up as overlay shimmer. Off.
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            // Hardware low-light boost is free signal when it is offered.
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            // A card is held close; bias focus to the near range so the lens
            // does not hunt out to infinity in the dark, where it has little
            // contrast to lock onto.
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
            log.info("format \(format.description, privacy: .public) binned=\(format.isVideoBinned)")
        } catch {
            report("Device config error: \(error.localizedDescription)")
        }
    }

    private func applyConnectionSettings() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Mirror the front camera so a selfie view behaves like the stock
            // camera app and the performer's own movements read correctly.
            connection.isVideoMirrored = (position == .front)
        }
        // The app is portrait-only (see Info.plist), so the sensor's landscape
        // frame needs a fixed quarter turn. With a locked orientation there is
        // nothing for a rotation coordinator to track.
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    // MARK: - Per-frame sensor control

    /// Applies the low-light plan to the device. Called once per frame but only
    /// touches hardware when a value has meaningfully moved — locking the device
    /// for configuration on every frame would stall the capture queue.
    private func apply(plan: LowLightPlan) {
        guard let device else { return }

        let torchChanged = abs(plan.torchLevel - lastTorchApplied) > 0.02
        let exposureChanged = abs(plan.maxExposure - lastExposureApplied) > 0.0005
        guard torchChanged || exposureChanged else { return }

        // Record the attempt before making it. If a capability turns out to be
        // unsupported these would otherwise never advance, and we would lock the
        // device for configuration on every frame forever — a steady drain on
        // the capture queue for no effect.
        if exposureChanged { lastExposureApplied = plan.maxExposure }
        if torchChanged { lastTorchApplied = plan.torchLevel }

        do {
            try device.lockForConfiguration()
            if exposureChanged, device.isExposureModeSupported(.continuousAutoExposure) {
                // Cap how long auto-exposure may integrate. The sensor answers
                // with gain instead, trading noise (which we can denoise and
                // match) for blur (which we cannot undo).
                //
                // The cap has to stay inside the format's own range: ask for a
                // duration shorter than `minExposureDuration` and the setter is
                // out of contract.
                let wanted = CMTime(seconds: plan.maxExposure, preferredTimescale: 1_000_000)
                let format = device.activeFormat
                let bounded = CMTimeMaximum(CMTimeMinimum(wanted, format.maxExposureDuration),
                                            format.minExposureDuration)
                device.activeMaxExposureDuration = bounded
            }
            if torchChanged {
                applyTorchLocked(plan.torchLevel, device: device)
            }
            device.unlockForConfiguration()
        } catch {
            log.error("sensor update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyTorch(_ level: Float) {
        guard let device, device.hasTorch else { return }
        lastTorchApplied = level
        do {
            try device.lockForConfiguration()
            applyTorchLocked(level, device: device)
            device.unlockForConfiguration()
        } catch { }
    }

    private func applyTorchLocked(_ level: Float, device: AVCaptureDevice) {
        guard device.hasTorch, device.isTorchAvailable else { return }
        if level <= 0.001 {
            if device.torchMode != .off { device.torchMode = .off }
        } else {
            // AVCaptureMaxAvailableTorchLevel is 1.0; clamp just below it
            // because passing exactly the max throws on some devices.
            let clamped = min(max(level, 0.01), 0.99)
            do { try device.setTorchModeOn(level: clamped) }
            catch { device.torchMode = .on }
        }
    }

    // MARK: - Controls

    func focus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setZoom(_ factor: CGFloat) {
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                let f = min(max(factor, device.minAvailableVideoZoomFactor),
                            device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = f
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func switchCamera() {
        queue.async { [weak self] in
            guard let self else { return }
            self.applyTorch(0)
            self.lastTorchApplied = -1
            self.lastExposureApplied = -1
            self.lowLight = LowLightController()
            self.pipeline.reset()
            self.configure(position: self.position == .back ? .front : .back)
        }
    }

    private func report(_ message: String) {
        log.error("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}

// MARK: - Frame delivery

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = pts.seconds.isFinite ? pts.seconds : CACurrentMediaTime()

        // Measured dt. Every time constant in the pipeline is driven from this
        // rather than from a frame count, so a 12 fps dark-room stream behaves
        // exactly like a 60 fps one.
        let dt = lastFrameTime > 0 ? max(1.0 / 240.0, min(now - lastFrameTime, 0.25)) : 1.0 / 30.0
        lastFrameTime = now

        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Meter the scene, then let the controller decide torch, exposure and
        // how hard the tracker must work.
        let luma = SceneMeter.meanLuma(pixelBuffer: pixelBuffer)
        let plan = lowLight.update(luma: luma,
                                   dt: dt,
                                   policy: configuration.torchPolicy,
                                   torchAvailable: device?.hasTorch == true
                                       && device?.isTorchAvailable == true)
        apply(plan: plan)

        if plan.band != lastBand {
            lastBand = plan.band
            DispatchQueue.main.async { [weak self] in self?.onBandChange?(plan.band) }
        }

        image = pipeline.process(pixelBuffer: pixelBuffer,
                                 image: image,
                                 time: now,
                                 dt: dt,
                                 plan: plan,
                                 config: configuration)

        onFrame?(image, pts)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // A dropped frame means we are behind; the time-based filters absorb the
        // gap on their own, but the tracker should not treat the next frame as
        // temporally adjacent for optical-flow purposes.
        pipeline.noteDroppedFrame()
    }
}
