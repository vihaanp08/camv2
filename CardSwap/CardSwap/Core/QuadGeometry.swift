import Foundation
import CoreGraphics

/// A tracked quadrilateral, corners in **clockwise** order starting top-left,
/// in image coordinates with the origin at bottom-left (Core Image convention).
public struct Quad: Sendable, Equatable {
    public var corners: [CGPoint]

    public init(corners: [CGPoint]) {
        precondition(corners.count == 4, "a quad has four corners")
        self.corners = corners
    }

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.corners = [topLeft, topRight, bottomRight, bottomLeft]
    }

    public var topLeft: CGPoint     { corners[0] }
    public var topRight: CGPoint    { corners[1] }
    public var bottomRight: CGPoint { corners[2] }
    public var bottomLeft: CGPoint  { corners[3] }

    public var center: CGPoint {
        CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4,
                y: corners.reduce(0) { $0 + $1.y } / 4)
    }

    /// Shoelace area; always positive.
    public var area: CGFloat {
        var s: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// Mean of the two opposing edge pairs, as (width, height).
    public var edgeLengths: (w: CGFloat, h: CGFloat) {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let top = d(topLeft, topRight), bottom = d(bottomLeft, bottomRight)
        let left = d(topLeft, bottomLeft), right = d(topRight, bottomRight)
        return ((top + bottom) / 2, (left + right) / 2)
    }

    /// Long-side / short-side ratio, always >= 1.
    public var aspect: CGFloat {
        let (w, h) = edgeLengths
        guard min(w, h) > 0.001 else { return 0 }
        return max(w, h) / min(w, h)
    }

    /// True when all four cross products share a sign, i.e. the quad has not
    /// folded over itself. A tracker running on noisy dark frames will
    /// occasionally emit a bow-tie; drawing a warp through one produces a
    /// spectacular visual glitch, so these are rejected outright.
    public var isConvex: Bool {
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            let c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross > 0 ? 1 : -1 }
            else if (cross > 0 ? 1 : -1) != sign { return false }
        }
        return sign != 0
    }

    /// Smallest interior angle in degrees — a cheap degeneracy guard. Near-zero
    /// angles mean a sliver, which warps into garbage.
    public var minAngleDegrees: CGFloat {
        var smallest: CGFloat = 180
        for i in 0..<4 {
            let p = corners[(i + 3) % 4], c = corners[i], n = corners[(i + 1) % 4]
            let v1 = CGPoint(x: p.x - c.x, y: p.y - c.y)
            let v2 = CGPoint(x: n.x - c.x, y: n.y - c.y)
            let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
            guard l1 > 1e-6, l2 > 1e-6 else { return 0 }
            let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
            smallest = min(smallest, acos(cosA) * 180 / .pi)
        }
        return smallest
    }

    /// Reorders corners so index 0 is the top-left and the winding is clockwise.
    /// Detectors return corners in arbitrary order; a consistent order is what
    /// keeps the overlay from flipping between frames.
    public func canonicalized() -> Quad {
        let c = center
        // Sort by angle about the centroid to guarantee a simple polygon, then
        // rotate so the corner nearest the top-left leads.
        let sorted = corners.sorted {
            atan2($0.y - c.y, $0.x - c.x) > atan2($1.y - c.y, $1.x - c.x)
        }
        var best = 0
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (i, p) in sorted.enumerated() {
            let score = (p.x - c.x) + (c.y - p.y) // left and high wins
            if score < bestScore { bestScore = score; best = i }
        }
        let rotated = (0..<4).map { sorted[(best + $0) % 4] }
        return Quad(corners: rotated)
    }

    /// Rotates the corner labels without moving the geometry.
    public func rotatedLabels(_ by: Int) -> Quad {
        let n = ((by % 4) + 4) % 4
        return Quad(corners: (0..<4).map { corners[($0 + n) % 4] })
    }

    /// Relabels so this quad's corners line up with `other`'s, minimising total
    /// corner travel. Prevents a 90-degree label flip from spinning the overlay.
    public func aligned(to other: Quad) -> Quad {
        var bestQuad = self
        var bestCost = CGFloat.greatestFiniteMagnitude
        for r in 0..<4 {
            let cand = rotatedLabels(r)
            var cost: CGFloat = 0
            for i in 0..<4 {
                cost += hypot(cand.corners[i].x - other.corners[i].x,
                              cand.corners[i].y - other.corners[i].y)
            }
            if cost < bestCost { bestCost = cost; bestQuad = cand }
        }
        return bestQuad
    }

    /// Expands (or with a negative value, shrinks) the quad about its centroid.
    public func scaled(by f: CGFloat) -> Quad {
        let c = center
        return Quad(corners: corners.map {
            CGPoint(x: c.x + ($0.x - c.x) * f, y: c.y + ($0.y - c.y) * f)
        })
    }

    public func contains(_ p: CGPoint) -> Bool {
        var inside = false
        var j = 3
        for i in 0..<4 {
            let a = corners[i], b = corners[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Mean corner-to-corner distance, used as a motion and agreement metric.
    public func distance(to other: Quad) -> CGFloat {
        var s: CGFloat = 0
        for i in 0..<4 {
            s += hypot(corners[i].x - other.corners[i].x, corners[i].y - other.corners[i].y)
        }
        return s / 4
    }
}

/// 3x3 projective transform, row-major.
public struct Homography: Sendable {
    public var m: [Double]   // 9 entries

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// Maps the unit square (0,0)-(1,1) onto `quad`, with (0,1) going to the
    /// top-left corner so card art lands upright.
    public static func unitSquare(to quad: Quad) -> Homography? {
        let src = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                   CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)]
        return solve(from: src, to: quad.corners)
    }

    /// Inverse of the 3x3 matrix, or nil if singular.
    public func inverted() -> Homography? {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7]
        let c1 = a[5] * a[6] - a[3] * a[8]
        let c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-14 else { return nil }
        let i = 1.0 / det
        let out: [Double] = [
            c0 * i,
            (a[2] * a[7] - a[1] * a[8]) * i,
            (a[1] * a[5] - a[2] * a[4]) * i,
            c1 * i,
            (a[0] * a[8] - a[2] * a[6]) * i,
            (a[2] * a[3] - a[0] * a[5]) * i,
            c2 * i,
            (a[1] * a[6] - a[0] * a[7]) * i,
            (a[0] * a[4] - a[1] * a[3]) * i,
        ]
        guard out.allSatisfy({ $0.isFinite }) else { return nil }
        return Homography(m: out)
    }

    /// Direct linear transform for four point correspondences.
    ///
    /// Solves the 8x8 system for h with h22 fixed at 1 via Gaussian elimination
    /// with partial pivoting. Returns nil on a singular system — which is what a
    /// degenerate or collapsed quad produces, and is precisely the case that must
    /// not reach the renderer.
    public static func solve(from src: [CGPoint], to dst: [CGPoint]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [Double](repeating: 0, count: 8 * 9)   // augmented 8x(8+1)

        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            let r0 = (i * 2) * 9
            a[r0 + 0] = x;  a[r0 + 1] = y;  a[r0 + 2] = 1
            a[r0 + 6] = -u * x; a[r0 + 7] = -u * y; a[r0 + 8] = u
            let r1 = (i * 2 + 1) * 9
            a[r1 + 3] = x;  a[r1 + 4] = y;  a[r1 + 5] = 1
            a[r1 + 6] = -v * x; a[r1 + 7] = -v * y; a[r1 + 8] = v
        }

        // Forward elimination with partial pivoting.
        for col in 0..<8 {
            var pivot = col
            var best = abs(a[col * 9 + col])
            for r in (col + 1)..<8 {
                let val = abs(a[r * 9 + col])
                if val > best { best = val; pivot = r }
            }
            guard best > 1e-11 else { return nil }
            if pivot != col {
                for k in 0...8 {
                    let t = a[col * 9 + k]
                    a[col * 9 + k] = a[pivot * 9 + k]
                    a[pivot * 9 + k] = t
                }
            }
            let d = a[col * 9 + col]
            for r in (col + 1)..<8 {
                let f = a[r * 9 + col] / d
                if f == 0 { continue }
                for k in col...8 {
                    a[r * 9 + k] -= f * a[col * 9 + k]
                }
            }
        }

        // Back substitution.
        var h = [Double](repeating: 0, count: 9)
        for r in stride(from: 7, through: 0, by: -1) {
            var sum = a[r * 9 + 8]
            for k in (r + 1)..<8 {
                sum -= a[r * 9 + k] * h[k]
            }
            let d = a[r * 9 + r]
            guard abs(d) > 1e-12 else { return nil }
            h[r] = sum / d
        }
        h[8] = 1
        guard h.allSatisfy({ $0.isFinite }) else { return nil }
        return Homography(m: h)
    }
}
