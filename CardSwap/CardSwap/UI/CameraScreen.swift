import SwiftUI
import PhotosUI

/// The camera screen.
///
/// Deliberately indistinguishable from a stock camera at a glance: shutter,
/// thumbnail, lens chips, a mode strip. The app is a prop that gets handed to
/// someone, and visible controls for the trick would give it away. Everything
/// the performer needs is on a gesture or a hardware button instead:
///
/// - tap anywhere — reveal the real card (and focus, which is what it looks like)
/// - a snap of the fingers — the same reveal, hands-free
/// - volume or Camera Control button — the same reveal
/// - two-finger double tap — arm it again
/// - two-finger long press — settings
struct CameraScreen: View {
    @ObservedObject var model: CameraModel
    @State private var showSettings = false
    @State private var showCheatSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewRepresentable(model: model) { showSettings = true }
                .ignoresSafeArea()

            if model.permissionDenied {
                permissionPrompt
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomControls
                }
                .padding(.horizontal, 20)
            }

            if let message = model.message {
                toast(message)
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showCheatSheet) {
            CheatSheetView()
        }
        .onAppear { model.start() }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack {
            Button {
                model.settings.torchPolicy = nextTorchPolicy()
                model.applySettings()
            } label: {
                Image(systemName: torchIcon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
                    .foregroundStyle(model.settings.torchPolicy == .off ? .white : .yellow)
            }

            Spacer()

            // A quiet indicator that fill light is doing something, so the
            // performer is never surprised by the torch.
            if model.band >= .dark {
                Label(model.band.name, systemImage: "moon.stars.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer()

            // Looks like a stock camera affordance; opens the cheat sheet.
            Button { showCheatSheet = true } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 8)
    }

    private var torchIcon: String {
        switch model.settings.torchPolicy {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.a.fill"
        case .on: "bolt.fill"
        }
    }

    private func nextTorchPolicy() -> TorchPolicy {
        switch model.settings.torchPolicy {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }

    // MARK: - Bottom

    private var bottomControls: some View {
        VStack(spacing: 14) {
            lensChips
            modeStrip
            HStack {
                thumbnail
                Spacer()
                shutter
                Spacer()
                flipButton
            }
            .padding(.bottom, 10)
        }
    }

    private struct Lens: Identifiable {
        let id: String
        let factor: CGFloat
    }

    private static let lenses = [
        Lens(id: "0.5", factor: 0.5),
        Lens(id: "1x", factor: 1.0),
        Lens(id: "2", factor: 2.0),
    ]

    private var lensChips: some View {
        HStack(spacing: 8) {
            ForEach(Self.lenses) { lens in
                Button {
                    model.setZoom(lens.factor)
                } label: {
                    Text(lens.id)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.4), in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.22), in: Capsule())
    }

    private var modeStrip: some View {
        HStack(spacing: 22) {
            ForEach(["CINEMATIC", "PHOTO", "PORTRAIT"], id: \.self) { mode in
                Text(mode)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mode == "PHOTO" ? .yellow : .white.opacity(0.65))
            }
        }
    }

    private var shutter: some View {
        Button {
            model.takePhoto()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                Circle().fill(.white).frame(width: 60, height: 60)
            }
        }
        .buttonStyle(PressStyle())
    }

    private var thumbnail: some View {
        Group {
            if let image = model.lastSavedThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.35)))
    }

    private var flipButton: some View {
        Button {
            model.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.14), in: Circle())
                .foregroundStyle(.white)
        }
    }

    // MARK: - Overlays

    private var permissionPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 40))
            Text("Camera access is off")
                .font(.headline)
            Text("Turn it on in Settings to use the camera.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .padding(32)
    }

    private func toast(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.78), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 200)
                .transition(.opacity)
        }
        .task(id: message) {
            // Clear after a moment; these are advisory, never blocking. Keyed on
            // the message so a new one resets the timer instead of inheriting
            // the previous one's.
            try? await Task.sleep(for: .seconds(3.5))
            model.message = nil
        }
    }
}

/// Gives the shutter a press response, as the stock camera has.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// How to work the thing. Reachable from the chevron so the gestures are
/// discoverable without putting trick controls on the camera screen.
struct CheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rows = [
        Row(icon: "hand.tap.fill", title: "Tap the screen",
            detail: "Reveals the real card. Looks like tap-to-focus."),
        Row(icon: "hand.raised.fingers.spread.fill", title: "Snap your fingers",
            detail: "Same reveal, hands-free."),
        Row(icon: "button.programmable", title: "Volume or Camera Control",
            detail: "Same reveal, without touching the screen."),
        Row(icon: "hand.point.up.left.fill", title: "Two-finger double tap",
            detail: "Arms it again, ready for the next one."),
        Row(icon: "gearshape.fill", title: "Two-finger long press",
            detail: "Opens settings."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 14) {
                            Image(systemName: row.icon)
                                .font(.system(size: 18))
                                .frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.subheadline.weight(.semibold))
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("It arms itself when a card leaves the frame, so you can run the same trick again without touching anything.")
                }
            }
            .navigationTitle("Controls")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
