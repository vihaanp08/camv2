import SwiftUI

struct PreviewRepresentable: UIViewRepresentable {
    let model: CameraModel
    var onSettings: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(device: model.metalDevice,
                               queue: model.commandQueue,
                               context: model.ciContext)
        view.frameProvider = { [weak model] in model?.currentFrame() }
        view.onTap = { [weak model] point, size in
            guard let model else { return }
            // Looks like tap-to-focus to anyone watching, and it is — the
            // reveal rides along with it.
            model.handleTap(at: point, in: size)
            model.trigger(source: "tap")
        }
        view.onRearm = { [weak model] in model?.rearm() }
        view.onSettings = onSettings
        view.onHardwareButton = { [weak model] in
            guard let model, model.settings.hardwareButtonEnabled else { return }
            model.trigger(source: "hardware-button")
        }
        view.onZoom = { [weak model] scale in
            model?.setZoom(scale)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onSettings = onSettings
    }
}
