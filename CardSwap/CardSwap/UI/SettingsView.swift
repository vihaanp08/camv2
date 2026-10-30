import SwiftUI
import PhotosUI
import CoreImage

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickedItem: PhotosPickerItem?
    @State private var importing = false
    /// Decoded once, not re-read from disk on every render pass.
    @State private var importedPreview: UIImage?

    private var settings: AppSettings { model.settings }

    var body: some View {
        NavigationStack {
            Form {
                fakeCardSection
                importSection
                lightSection
                triggerSection
                realismSection
                advancedSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                importing = true
                Task {
                    defer { importing = false }
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        model.message = "Couldn't read that photo."
                        return
                    }
                    model.importFace(data: data)
                    loadImportedPreview()
                }
            }
            .task { loadImportedPreview() }
            .onDisappear { model.applySettings() }
        }
    }

    /// Loads the imported card's preview from disk, once.
    private func loadImportedPreview() {
        guard let url = settings.importedFaceURL,
              let data = try? Data(contentsOf: url) else {
            importedPreview = nil
            return
        }
        importedPreview = UIImage(data: data)
    }

    // MARK: - Sections

    private var fakeCardSection: some View {
        Section {
            Picker("Suit", selection: Binding(
                get: { settings.suit },
                set: { settings.suit = $0; model.refreshFace() })) {
                ForEach(Suit.allCases, id: \.self) { suit in
                    Label(suit.display, systemImage: suit.symbolName).tag(suit)
                }
            }

            Picker("Rank", selection: Binding(
                get: { settings.rank },
                set: { settings.rank = $0; model.refreshFace() })) {
                ForEach(Rank.allCases, id: \.self) { rank in
                    Text(rank.display).tag(rank)
                }
            }
        } header: {
            Text("Fake card (what they see first)")
        } footer: {
            Text("Court cards are drawn plainly, because no two decks draw them alike. For your deck's exact art, import a photo below.")
        }
    }

    private var importSection: some View {
        // Read out of main-actor state here rather than inside the picker's
        // label, which the SDK types as a Sendable closure.
        let title = settings.importedFace == nil
            ? "Import a photo of a real card"
            : "Replace the imported card"

        return Section {
            PhotosPicker(selection: $pickedItem, matching: .images, preferredItemEncoding: .automatic) {
                Label(title, systemImage: "photo.on.rectangle.angled")
            }
            .disabled(importing)

            if let image = importedPreview {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    Button(role: .destructive) {
                        model.clearImportedFace()
                        importedPreview = nil
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                }
                Text("It should look flat, upright and white. If it doesn't, reshoot it square-on, filling the frame, on a dark surface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Your deck")
        }
    }

    private var lightSection: some View {
        Section {
            Picker("Fill light", selection: Binding(
                get: { settings.torchPolicy },
                set: { settings.torchPolicy = $0; model.applySettings() })) {
                Text("Off").tag(TorchPolicy.off)
                Text("Auto").tag(TorchPolicy.auto)
                Text("On").tag(TorchPolicy.on)
            }
            .pickerStyle(.segmented)
            .disabled(!model.isTorchCapable)
        } header: {
            Text("Light")
        } footer: {
            if model.isTorchCapable {
                Text("On Auto, the torch comes up gently once the room gets dark and stays at the lowest level that keeps the card trackable. This is the single biggest difference between the trick working outdoors at night and not working at all. Set it Off if the light would be noticed.")
            } else {
                Text("This camera has no torch.")
            }
        }
    }

    private var triggerSection: some View {
        Section {
            Toggle("Snap to reveal", isOn: Binding(
                get: { settings.snapEnabled },
                set: { settings.snapEnabled = $0; model.applySettings() }))

            if settings.snapEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snap sensitivity").font(.subheadline)
                    Slider(value: Binding(
                        get: { settings.snapSensitivity },
                        set: { settings.snapSensitivity = $0; model.applySettings() }),
                           in: 0...1)
                    Text("The trigger level floats on whatever the room already sounds like, so this only shifts it up or down from there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Volume / Camera Control buttons", isOn: Binding(
                get: { settings.hardwareButtonEnabled },
                set: { settings.hardwareButtonEnabled = $0; model.applySettings() }))

            Toggle("Arm again when the card leaves", isOn: Binding(
                get: { settings.autoRearm },
                set: { settings.autoRearm = $0; model.applySettings() }))

            Toggle("Haptic tick on reveal", isOn: Binding(
                get: { settings.hapticOnTrigger },
                set: { settings.hapticOnTrigger = $0 }))
        } header: {
            Text("Triggers")
        }
    }

    private var realismSection: some View {
        Section {
            Toggle("Only replace card faces", isOn: Binding(
                get: { settings.facesOnly },
                set: { settings.facesOnly = $0; model.applySettings() }))

            Toggle("Keep fingers in front", isOn: Binding(
                get: { settings.occlusion },
                set: { settings.occlusion = $0; model.applySettings() }))

            Toggle("Match the camera's grain", isOn: Binding(
                get: { settings.matchGrain },
                set: { settings.matchGrain = $0; model.applySettings() }))

            Toggle("Mirror selfie view", isOn: Binding(
                get: { settings.mirrored },
                set: { settings.mirrored = $0; model.applySettings() }))
        } header: {
            Text("Realism")
        } footer: {
            Text("Fingers are found by the shape of the hand rather than by skin colour, which is what lets it keep working under a streetlight or the torch. Grain matching stops the fake card looking suspiciously cleaner than the picture around it — the giveaway in a dark room.")
        }
    }

    private var advancedSection: some View {
        Section {
            Toggle("Paint the fake before the card arrives", isOn: Binding(
                get: { settings.entryLead },
                set: { settings.entryLead = $0; model.applySettings() }))

            Toggle("Show tracking diagnostics", isOn: Binding(
                get: { settings.debugOverlay },
                set: { settings.debugOverlay = $0; model.applySettings() }))
        } header: {
            Text("Advanced")
        } footer: {
            Text("While it waits for a card the picture runs about an eighth of a second behind, so the fake is already on the card the instant it comes into view; it catches up to live once the fake is on. Diagnostics draw the tracked outline with its confidence, which is the quickest way to see why a reveal misfired.")
        }
    }
}
