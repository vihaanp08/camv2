import Foundation
import SwiftUI

/// User-facing settings, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let rank = "fake.rank"
        static let suit = "fake.suit"
        static let imported = "fake.importedFace"
        static let snapEnabled = "trigger.snap"
        static let snapSensitivity = "trigger.snapSensitivity"
        static let hardwareButton = "trigger.hardwareButton"
        static let haptic = "trigger.haptic"
        static let torch = "capture.torchPolicy"
        static let facesOnly = "render.facesOnly"
        static let mirrored = "render.mirrored"
        static let entryLead = "render.entryLead"
        static let occlusion = "render.occlusion"
        static let matchGrain = "render.matchGrain"
        static let debug = "render.debug"
        static let autoRearm = "trigger.autoRearm"
    }

    @Published var rank: Rank { didSet { store(rank.rawValue, Key.rank) } }
    @Published var suit: Suit { didSet { store(suit.rawValue, Key.suit) } }

    /// Filename of an imported photo of a real card, inside Application Support.
    @Published var importedFace: String? {
        didSet { store(importedFace, Key.imported) }
    }

    @Published var snapEnabled: Bool { didSet { store(snapEnabled, Key.snapEnabled) } }
    @Published var snapSensitivity: Double { didSet { store(snapSensitivity, Key.snapSensitivity) } }
    @Published var hardwareButtonEnabled: Bool { didSet { store(hardwareButtonEnabled, Key.hardwareButton) } }
    @Published var hapticOnTrigger: Bool { didSet { store(hapticOnTrigger, Key.haptic) } }
    @Published var autoRearm: Bool { didSet { store(autoRearm, Key.autoRearm) } }

    @Published var torchPolicy: TorchPolicy { didSet { store(torchPolicy.rawValue, Key.torch) } }
    @Published var facesOnly: Bool { didSet { store(facesOnly, Key.facesOnly) } }
    @Published var mirrored: Bool { didSet { store(mirrored, Key.mirrored) } }
    @Published var entryLead: Bool { didSet { store(entryLead, Key.entryLead) } }
    @Published var occlusion: Bool { didSet { store(occlusion, Key.occlusion) } }
    @Published var matchGrain: Bool { didSet { store(matchGrain, Key.matchGrain) } }
    @Published var debugOverlay: Bool { didSet { store(debugOverlay, Key.debug) } }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        // `object(forKey:)` distinguishes "never set" from "set to false", which
        // `bool(forKey:)` cannot — without it every default below would be off.
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) as? Bool ?? fallback
        }
        rank = Rank(rawValue: d.object(forKey: Key.rank) as? Int ?? Rank.queen.rawValue) ?? .queen
        suit = Suit(rawValue: d.string(forKey: Key.suit) ?? Suit.heart.rawValue) ?? .heart
        importedFace = d.string(forKey: Key.imported)
        snapEnabled = bool(Key.snapEnabled, true)
        snapSensitivity = d.object(forKey: Key.snapSensitivity) as? Double ?? 0.5
        hardwareButtonEnabled = bool(Key.hardwareButton, true)
        hapticOnTrigger = bool(Key.haptic, true)
        autoRearm = bool(Key.autoRearm, true)
        torchPolicy = TorchPolicy(rawValue: d.object(forKey: Key.torch) as? Int
                                  ?? TorchPolicy.auto.rawValue) ?? .auto
        facesOnly = bool(Key.facesOnly, true)
        mirrored = bool(Key.mirrored, false)
        entryLead = bool(Key.entryLead, true)
        occlusion = bool(Key.occlusion, true)
        matchGrain = bool(Key.matchGrain, true)
        debugOverlay = bool(Key.debug, false)
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    var renderConfig: RenderConfig {
        var c = RenderConfig()
        c.torchPolicy = torchPolicy
        c.facesOnly = facesOnly
        c.mirrored = mirrored
        c.entryLead = entryLead
        c.occlusion = occlusion
        c.matchGrain = matchGrain
        c.debugOverlay = debugOverlay
        c.snapSensitivity = snapSensitivity
        c.snapEnabled = snapEnabled
        c.hardwareButtonEnabled = hardwareButtonEnabled
        c.hapticOnTrigger = hapticOnTrigger
        c.autoRearm = autoRearm
        return c
    }

    // MARK: - Imported card storage

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("CardSwap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var importedFaceURL: URL? {
        guard let importedFace else { return nil }
        return Self.supportDirectory.appendingPathComponent(importedFace)
    }

    func deleteImportedFace() {
        if let url = importedFaceURL {
            try? FileManager.default.removeItem(at: url)
        }
        importedFace = nil
    }
}
