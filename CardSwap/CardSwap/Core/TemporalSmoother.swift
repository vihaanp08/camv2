import Foundation
import CoreGraphics

/// Exponential smoothing driven by elapsed time rather than frame count.
///
/// `alpha = 1 - exp(-dt / tau)` makes the response depend only on wall-clock
/// time, so a filter tuned at 60 fps behaves identically on the 15 fps stream
/// iOS hands back in a dark room. A fixed per-frame alpha — the usual shortcut —
/// silently becomes two to four times slower when the frame rate drops, which is
/// why the original's tracking felt sluggish and laggy at night.
public struct ExpSmoother: Sendable {
    private var value: Double?
    public init() {}
    public var current: Double? { value }
    public mutating func reset() { value = nil }

    public mutating func update(_ x: Double, dt: Double, tau: Double) -> Double {
        guard let v = value else { value = x; return x }
        guard tau > 1e-6, dt > 0 else { value = x; return x }
        let alpha = 1 - exp(-dt / tau)
        let out = v + (x - v) * alpha
        value = out
        return out
    }
}

/// Four-corner smoother that separates *where* the card is from *what shape*
/// it is. Translation is tracked tightly so the overlay never lags the hand;
/// the shape (perspective) is smoothed harder because corner estimates are the
/// noisiest part of the measurement, especially at high ISO.
public struct QuadSmoother: Sendable {
    private var centerX = ExpSmoother()
    private var centerY = ExpSmoother()
    private var offsets: [ExpSmoother] = (0..<8).map { _ in ExpSmoother() }
    private var seeded = false

    public init() {}

    public mutating func reset() {
        centerX.reset(); centerY.reset()
        offsets = (0..<8).map { _ in ExpSmoother() }
        seeded = false
    }

    public mutating func smooth(_ quad: Quad, dt: Double, scale: Double) -> Quad {
        let c = quad.center
        let tauPos = Tuning.quadTauPosition * scale
        let tauShape = Tuning.quadTauShape * scale

        // A fresh acquisition must land exactly where it was measured; easing
        // in from a stale center would visibly slide the overlay onto the card.
        if !seeded {
            seeded = true
            _ = centerX.update(c.x, dt: dt, tau: tauPos)
            _ = centerY.update(c.y, dt: dt, tau: tauPos)
            for i in 0..<4 {
                _ = offsets[i * 2].update(quad.corners[i].x - c.x, dt: dt, tau: tauShape)
                _ = offsets[i * 2 + 1].update(quad.corners[i].y - c.y, dt: dt, tau: tauShape)
            }
            return quad
        }

        let sx = centerX.update(c.x, dt: dt, tau: tauPos)
        let sy = centerY.update(c.y, dt: dt, tau: tauPos)
        var pts: [CGPoint] = []
        pts.reserveCapacity(4)
        for i in 0..<4 {
            let ox = offsets[i * 2].update(quad.corners[i].x - c.x, dt: dt, tau: tauShape)
            let oy = offsets[i * 2 + 1].update(quad.corners[i].y - c.y, dt: dt, tau: tauShape)
            pts.append(CGPoint(x: sx + ox, y: sy + oy))
        }
        return Quad(corners: pts)
    }
}
