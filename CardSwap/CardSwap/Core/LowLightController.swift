import Foundation

public enum LightBand: Int, Sendable, Comparable, CaseIterable {
    case bright = 0, dim = 1, dark = 2, veryDark = 3
    public static func < (a: LightBand, b: LightBand) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .bright: "bright"
        case .dim: "dim"
        case .dark: "dark"
        case .veryDark: "very dark"
        }
    }
}

public enum TorchPolicy: Int, Sendable, CaseIterable {
    case off = 0, auto = 1, on = 2
}

/// Everything the capture and render stages need to know about how dark it is.
public struct LowLightPlan: Sendable, Equatable {
    public var band: LightBand = .bright
    /// 0 means off. Levels are ramped, never stepped.
    public var torchLevel: Float = 0
    /// Ceiling for auto-exposure integration time, seconds.
    public var maxExposure: Double = Tuning.maxExposureBright
    /// Long side of the grayscale image the tracker runs on.
    public var trackLongSide: Int = Tuning.trackLongSideBright
    /// Frames blended into the tracking image.
    public var denoiseFrames: Int = 1
    /// Multiplier on every quad-smoothing time constant.
    public var smoothingScale: Double = 1.0
    /// Fraction trimmed from each tail of the lighting samples.
    public var lightingTrim: Float = Tuning.lightingTrimBright
    /// Time constant for the lighting estimate.
    public var lightingTau: Double = Tuning.lightingTau
    /// Noise sigma the compositor should add to the overlay so the fake card
    /// carries the same grain as the frame it sits in.
    public var grainSigma: Float = 0
}

/// Decides how the pipeline should behave for the current scene brightness.
///
/// Two things here are load-bearing, and both exist to stop oscillation:
///
/// 1. **Band hysteresis with a dwell timer.** Descending into a darker band
///    uses a lower threshold than climbing out of it, and the candidate band
///    must hold for `Tuning.bandHold` before it is adopted.
///
/// 2. **Torch luma credit.** Our own torch brightens the scene we are metering,
///    so a naive controller reads "bright now" and switches the torch off,
///    which darkens the scene, which switches it back on. Before banding we
///    subtract an estimate of the light *we* contributed, and once lit the
///    torch is held for `Tuning.torchMinOn` regardless.
public struct LowLightController: Sendable {

    private var band: LightBand = .bright
    private var candidate: LightBand = .bright
    private var candidateAge: Double = 0

    private var torchOnFor: Double = 0
    private var torchLevel: Float = 0
    private var torchTarget: Float = 0
    /// Luma observed just before the torch lit, used to size its contribution.
    private var lumaBeforeTorch: Float = 0

    public init() {}

    public var currentBand: LightBand { band }
    public var currentTorchLevel: Float { torchLevel }

    /// - Parameters:
    ///   - luma: mean scene luminance in linear light, 0...1.
    ///   - dt: seconds since the previous call.
    ///   - policy: user's torch preference.
    ///   - torchAvailable: whether the active device can light its torch.
    public mutating func update(luma: Float,
                                dt: Double,
                                policy: TorchPolicy,
                                torchAvailable: Bool) -> LowLightPlan {
        let step = max(0, min(dt, 0.25))

        // Discount the light the torch is currently adding, so banding tracks
        // *ambient* brightness. Without this the controller fights itself.
        let ambient: Float
        if torchLevel > 0.001 {
            let added = max(0, luma - lumaBeforeTorch) * Tuning.torchLumaCredit
            ambient = max(0, luma - added)
        } else {
            ambient = luma
            lumaBeforeTorch = luma
        }

        // Hysteretic banding: a darker band is entered on the low threshold, a
        // brighter one only once the higher exit threshold is cleared.
        let proposed = Self.band(for: ambient, current: band)
        if proposed == band {
            candidate = band
            candidateAge = 0
        } else if proposed == candidate {
            candidateAge += step
            if candidateAge >= Tuning.bandHold {
                band = candidate
                candidateAge = 0
            }
        } else {
            candidate = proposed
            candidateAge = 0
        }

        // Torch target for the settled band.
        var wanted: Float = 0
        if torchAvailable {
            switch policy {
            case .off:
                wanted = 0
            case .on:
                wanted = Tuning.torchLevelVeryDark
            case .auto:
                switch band {
                case .bright:   wanted = 0
                case .dim:      wanted = Tuning.torchLevelDim
                case .dark:     wanted = Tuning.torchLevelDark
                case .veryDark: wanted = Tuning.torchLevelVeryDark
                }
            }
        }

        // Hold the torch on for a minimum dwell, so a transient bright reading
        // cannot blink it off mid-trick.
        if wanted > 0.001 {
            if torchLevel <= 0.001 { lumaBeforeTorch = ambient }
            torchTarget = wanted
            torchOnFor = 0
        } else if torchLevel > 0.001 {
            torchOnFor += step
            if torchOnFor >= Tuning.torchMinOn { torchTarget = 0 }
        } else {
            torchTarget = 0
        }

        // Ramp toward the target rather than stepping, so fill light eases in.
        let rate = Float(step / max(Tuning.torchRamp, 1e-4))
        if torchLevel < torchTarget {
            torchLevel = min(torchTarget, torchLevel + rate)
        } else if torchLevel > torchTarget {
            torchLevel = max(torchTarget, torchLevel - rate)
        }
        if torchLevel < 0.002 { torchLevel = 0 }

        return plan(torchLevel: torchLevel)
    }

    private func plan(torchLevel: Float) -> LowLightPlan {
        var p = LowLightPlan()
        p.band = band
        p.torchLevel = torchLevel
        switch band {
        case .bright:
            p.maxExposure = Tuning.maxExposureBright
            p.trackLongSide = Tuning.trackLongSideBright
            p.denoiseFrames = Tuning.denoiseFramesBright
            p.smoothingScale = 1.0
            p.grainSigma = 0.004
        case .dim:
            p.maxExposure = Tuning.maxExposureDim
            p.trackLongSide = Tuning.trackLongSideDim
            p.denoiseFrames = Tuning.denoiseFramesDim
            p.smoothingScale = Tuning.quadTauScaleDim
            p.grainSigma = 0.010
        case .dark:
            p.maxExposure = Tuning.maxExposureDark
            p.trackLongSide = Tuning.trackLongSideDark
            p.denoiseFrames = Tuning.denoiseFramesDark
            p.smoothingScale = Tuning.quadTauScaleDark
            p.grainSigma = 0.020
        case .veryDark:
            p.maxExposure = Tuning.maxExposureVeryDark
            p.trackLongSide = Tuning.trackLongSideVeryDark
            p.denoiseFrames = Tuning.denoiseFramesVeryDark
            p.smoothingScale = Tuning.quadTauScaleVeryDark
            p.grainSigma = 0.034
        }
        // The torch locally relights the card even when the room is dark, so a
        // lit scene behaves closer to its brighter neighbour: shorten exposure
        // and ease off the denoise that costs us motion fidelity.
        if torchLevel > 0.30 {
            p.maxExposure = min(p.maxExposure, Tuning.maxExposureDim)
            p.denoiseFrames = max(1, p.denoiseFrames - 1)
            p.grainSigma *= 0.65
        }
        let darkish = band >= .dark
        p.lightingTrim = darkish ? Tuning.lightingTrimDark : Tuning.lightingTrimBright
        p.lightingTau = darkish ? Tuning.lightingTauDark : Tuning.lightingTau
        return p
    }

    /// Hysteretic band selection. Descending uses `*Enter`, climbing uses `*Exit`.
    static func band(for luma: Float, current: LightBand) -> LightBand {
        // Candidate from the "enter" (descending) thresholds.
        let descending: LightBand
        if luma <= Tuning.veryDarkEnter      { descending = .veryDark }
        else if luma <= Tuning.darkEnter     { descending = .dark }
        else if luma <= Tuning.dimEnter      { descending = .dim }
        else                                 { descending = .bright }

        if descending >= current { return descending }

        // Climbing out requires clearing the higher exit threshold of the band
        // we are currently in.
        switch current {
        case .veryDark: return luma >= Tuning.veryDarkExit ? descending : .veryDark
        case .dark:     return luma >= Tuning.darkExit     ? descending : .dark
        case .dim:      return luma >= Tuning.dimExit      ? descending : .dim
        case .bright:   return .bright
        }
    }
}
