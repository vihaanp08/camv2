import AVFoundation
import Foundation
import os

/// Listens on the microphone and reports finger snaps.
///
/// The detection maths lives in `SnapOnsetDetector`, which is pure and tested.
/// This type owns only the awkward part: an `AVAudioEngine` that has to survive
/// everything iOS does to audio sessions in real use. A trick that stops
/// responding because someone's AirPods connected mid-performance is as broken
/// as one that never worked, so interruptions, route changes and
/// media-services resets are all handled explicitly and the engine is rebuilt
/// rather than left in a dead state.
final class SnapListener {

    var onSnap: (() -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var detector = SnapOnsetDetector()
    private let queue = DispatchQueue(label: "com.cardswap.audio")
    private var running = false
    private var installed = false
    private var sensitivity: Double = 0.5
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.cardswap", category: "audio")

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] _ in
            // A new route means a new input format; the tap must be rebuilt.
            self?.restart()
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] _ in
            self?.restart()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setSensitivity(_ value: Double) {
        queue.async { [weak self] in self?.sensitivity = value }
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            if self.installed {
                self.engine.inputNode.removeTap(onBus: 0)
                self.installed = false
            }
            if self.engine.isRunning { self.engine.stop() }
            self.detector.reset()
        }
    }

    private func restart() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            if self.installed {
                self.engine.inputNode.removeTap(onBus: 0)
                self.installed = false
            }
            if self.engine.isRunning { self.engine.stop() }
            self.detector.reset()
            self.startLocked()
        }
    }

    private func startLocked() {
        // Called whenever settings are applied, so it must be cheap to repeat.
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixing with others matters: the performer may have music playing,
            // and silencing it the moment the app opens is its own bug.
            // Bluetooth input is deliberately not requested: HFP mics are
            // narrowband, which is the worst possible input for detecting a
            // broadband click. The built-in mic is what we want.
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            report("Audio session error: \(error.localizedDescription)")
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate means the input is not actually available yet,
        // which happens if the session activated against a route still settling.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            report("No microphone input available.")
            return
        }

        if installed {
            input.removeTap(onBus: 0)
            installed = false
        }

        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))

            // The tap runs on a realtime audio thread. Detection is a handful of
            // multiply-accumulates per hop so it is safe here, but anything
            // user-facing is bounced to the main queue.
            self.queue.async {
                guard self.running else { return }
                if self.detector.process(samples: samples,
                                         sampleRate: rate,
                                         sensitivity: self.sensitivity) {
                    DispatchQueue.main.async { self.onSnap?() }
                }
            }
        }
        installed = true

        engine.prepare()
        do {
            try engine.start()
            running = true
            log.info("snap listener running at \(rate, privacy: .public) Hz")
        } catch {
            report("Audio engine error: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            installed = false
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            queue.async { [weak self] in
                guard let self else { return }
                if self.engine.isRunning { self.engine.stop() }
                self.detector.reset()
            }
        case .ended:
            restart()
        @unknown default:
            break
        }
    }

    private func report(_ message: String) {
        log.error("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
