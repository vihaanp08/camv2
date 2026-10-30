import Foundation

/// Central tuning constants.
///
/// Everything here is expressed in **seconds**, never in frames. The original
/// app timed its pipeline in frame counts ("4 frames is about 0.13 s"), which
/// silently assumes a 30 fps stream. In low light iOS stretches frame duration
/// to gather photons, so that stream can fall to 15, 10, even 8 fps — and every
/// frame-counted delay, smoothing window and timeout stretches with it. Timing
/// in seconds against a measured `dt` keeps behaviour identical at any rate.
public struct Tuning: Sendable {

    // MARK: - Scene luminance bands
    //
    // Mean scene luma in *linear* light, 0...1. Thresholds come in pairs: the
    // `enter` value must be crossed to descend into a darker band and the
    // `exit` value to climb back out. The gap between them is deliberate — a
    // single threshold makes the band flap when luma hovers on it, and a
    // flapping band means flickering torch and pumping grain, which is exactly
    // the "glitch" this rewrite exists to remove.
    public static let dimEnter:      Float = 0.180
    public static let dimExit:       Float = 0.225
    public static let darkEnter:     Float = 0.060
    public static let darkExit:      Float = 0.080
    public static let veryDarkEnter: Float = 0.015
    public static let veryDarkExit:  Float = 0.022

    /// A band must hold for this long before it is adopted. Stops a single
    /// noisy frame — common when the sensor is at high gain — from reconfiguring
    /// the whole pipeline.
    public static let bandHold: Double = 0.40

    // MARK: - Torch
    /// Minimum time the torch stays on once lit. The torch raises scene luma,
    /// which would read as "bright enough, turn the torch off", which darkens
    /// the scene again: a feedback oscillation. A long floor plus the luma
    /// compensation in `LowLightController` breaks that loop.
    public static let torchMinOn: Double = 1.50
    /// Ramp time for torch level changes, so fill light eases in.
    public static let torchRamp: Double = 0.25
    public static let torchLevelDim:      Float = 0.25
    public static let torchLevelDark:     Float = 0.60
    public static let torchLevelVeryDark: Float = 1.00
    /// How much of the luma gain we attribute to our own torch when deciding
    /// whether the *ambient* scene has brightened. Without this the torch
    /// talks itself off.
    public static let torchLumaCredit: Float = 0.75

    // MARK: - Exposure
    /// Hard ceiling on auto-exposure integration time. Past roughly 1/30 s a
    /// handheld card smears badly, and motion blur destroys corner features far
    /// faster than sensor noise does — blur removes the gradients the tracker
    /// needs, while noise only buries them. Capping duration forces iOS to take
    /// the hit as ISO/gain instead, which the denoiser can fight.
    public static let maxExposureBright:   Double = 1.0 / 60.0
    public static let maxExposureDim:      Double = 1.0 / 48.0
    public static let maxExposureDark:     Double = 1.0 / 32.0
    public static let maxExposureVeryDark: Double = 1.0 / 24.0

    /// Frame-rate floor. Tracking logic is time-based so it survives a slow
    /// stream, but below this the preview itself reads as broken, so we refuse
    /// to let AE trade any more frame rate for brightness.
    public static let minFrameRate: Double = 24.0

    // MARK: - Tracking / denoise
    /// Long side of the grayscale image the tracker runs on, per band. Shrinking
    /// is itself a strong denoiser: averaging an NxN block cuts the noise
    /// standard deviation by N, so a dark frame tracked small is cleaner than a
    /// big noisy one, and cheaper.
    public static let trackLongSideBright:   Int = 480
    public static let trackLongSideDim:      Int = 420
    public static let trackLongSideDark:     Int = 360
    public static let trackLongSideVeryDark: Int = 288

    /// Frames blended into the tracking image. Temporal averaging trades a
    /// little motion smear for a large noise reduction; only worth it when the
    /// per-frame noise is actually hurting detection.
    public static let denoiseFramesBright:   Int = 1
    public static let denoiseFramesDim:      Int = 2
    public static let denoiseFramesDark:     Int = 3
    public static let denoiseFramesVeryDark: Int = 4

    // MARK: - Quad smoothing (time constants, seconds)
    public static let quadTauPosition: Double = 0.055
    public static let quadTauShape:    Double = 0.085
    /// Smoothing is lengthened in dark bands: noisy corner estimates jitter, and
    /// a jittering overlay is the most visible tell there is.
    public static let quadTauScaleDim:      Double = 1.35
    public static let quadTauScaleDark:     Double = 1.90
    public static let quadTauScaleVeryDark: Double = 2.50

    // MARK: - Confidence gate
    public static let confidenceOn:  Double = 0.55
    public static let confidenceOff: Double = 0.35
    public static let fadeInTau:     Double = 0.070
    public static let fadeOutTau:    Double = 0.160
    /// A confidence dropout shorter than this is treated as measurement noise:
    /// the last good quad is held and the overlay keeps its opacity. Brief
    /// dropouts are routine at high ISO, and reacting to them is what makes the
    /// overlay strobe.
    public static let coastTime: Double = 0.26
    /// Absolute ceiling on coasting. Past this the quad is stale and the overlay
    /// must fade rather than sit on empty space.
    public static let maxCoast: Double = 0.55

    // MARK: - Lighting match
    public static let lightingTau:          Double = 0.14
    public static let lightingTauDark:      Double = 0.30
    /// Bounds on the relight factor. These exist only to reject absurd
    /// estimates, **not** to enforce a minimum brightness. The floor has to sit
    /// very low: a card in a dark room genuinely reads around 0.05 in linear
    /// light against reference art near 0.5, so the honest gain is about 0.1.
    /// A floor anywhere near that value would force the overlay brighter than
    /// the card it covers and the fake would visibly glow — the exact low-light
    /// tell this rewrite exists to remove.
    public static let lightingGainMin:      Float  = 0.02
    public static let lightingGainMax:      Float  = 2.20
    /// Fraction trimmed from each end before averaging card-region samples.
    /// Specular glints and shadow pits are both outliers; in the dark the tails
    /// are fatter, so we trim harder.
    public static let lightingTrimBright:   Float  = 0.10
    public static let lightingTrimDark:     Float  = 0.25

    // MARK: - Snap detection
    public static let snapRefractory:   Double = 0.45
    public static let snapBackgroundTau: Double = 1.60
    public static let snapHopSeconds:    Double = 0.005
    public static let snapAttackMax:     Double = 0.030

    // MARK: - Entry prediction
    /// How far behind live the preview may run while waiting for a card, so the
    /// fake is already painted the instant the card enters frame. Seconds, not
    /// frames — see the note at the top.
    public static let entryLeadSeconds: Double = 0.13
    public static let entryLeadMax:     Double = 0.25
}
