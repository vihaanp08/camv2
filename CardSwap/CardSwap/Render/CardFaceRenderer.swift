import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum Suit: String, CaseIterable, Codable, Sendable {
    case spade, heart, diamond, club

    var symbolName: String {
        switch self {
        case .spade: "suit.spade.fill"
        case .heart: "suit.heart.fill"
        case .diamond: "suit.diamond.fill"
        case .club: "suit.club.fill"
        }
    }
    var isRed: Bool { self == .heart || self == .diamond }
    var display: String {
        switch self {
        case .spade: "Spades"
        case .heart: "Hearts"
        case .diamond: "Diamonds"
        case .club: "Clubs"
        }
    }
}

enum Rank: Int, CaseIterable, Codable, Sendable {
    case ace = 1, two, three, four, five, six, seven, eight, nine, ten, jack, queen, king

    var label: String {
        switch self {
        case .ace: "A"
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        default: String(rawValue)
        }
    }
    var display: String {
        switch self {
        case .ace: "Ace"
        case .jack: "Jack"
        case .queen: "Queen"
        case .king: "King"
        default: String(rawValue)
        }
    }
    var isCourt: Bool { self == .jack || self == .queen || self == .king }
}

/// Draws replacement card faces, and rectifies photographs of real cards.
///
/// Court cards are drawn as a large suit glyph with the rank letter rather than
/// as illustrated figures — no two decks draw those the same way, so a generic
/// drawing would clash with whatever deck is actually in hand. Importing a photo
/// of the real card is the way to get an exact match, which is why the importer
/// below exists.
enum CardFaceRenderer {

    /// A playing card is 2.5 x 3.5 inches. Art is rendered at this ratio so the
    /// compositor's warp introduces no stretch of its own.
    static let aspect: CGFloat = 1.4
    static let renderWidth: CGFloat = 300

    static func render(rank: Rank, suit: Suit) -> CGImage? {
        let size = CGSize(width: renderWidth, height: renderWidth * aspect)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Card stock. Slightly off-white: pure white reads as a synthetic
            // block once it is relit and sat next to real paper.
            cg.setFillColor(UIColor(white: 0.965, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let ink: UIColor = suit.isRed
                ? UIColor(red: 0.78, green: 0.09, blue: 0.13, alpha: 1)
                : UIColor(white: 0.08, alpha: 1)

            drawCorners(in: cg, size: size, rank: rank, suit: suit, ink: ink)

            if rank.isCourt {
                drawCourt(in: cg, size: size, rank: rank, suit: suit, ink: ink)
            } else {
                drawPips(in: cg, size: size, rank: rank, suit: suit, ink: ink)
            }
        }
        return image.cgImage
    }

    // MARK: - Drawing

    private static func suitImage(_ suit: Suit, size: CGFloat, color: UIColor) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .black)
        return UIImage(systemName: suit.symbolName, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private static func drawCorners(in cg: CGContext, size: CGSize,
                                    rank: Rank, suit: Suit, ink: UIColor) {
        let inset = size.width * 0.075
        let rankSize = size.width * 0.155
        let pipSize = size.width * 0.095

        let font = UIFont.systemFont(ofSize: rankSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let text = NSAttributedString(string: rank.label, attributes: attrs)
        let textSize = text.size()
        let pip = suitImage(suit, size: pipSize, color: ink)

        // Top-left, then the same block rotated 180 degrees into the
        // bottom-right, as a real card is printed.
        for flipped in [false, true] {
            cg.saveGState()
            if flipped {
                cg.translateBy(x: size.width, y: size.height)
                cg.rotate(by: .pi)
            }
            text.draw(at: CGPoint(x: inset - textSize.width / 2 + size.width * 0.045,
                                  y: inset))
            if let pip {
                let x = inset + size.width * 0.045 - pip.size.width / 2
                pip.draw(at: CGPoint(x: x, y: inset + textSize.height + size.height * 0.004))
            }
            cg.restoreGState()
        }
    }

    /// Traditional pip layout for ace through ten.
    private static func drawPips(in cg: CGContext, size: CGSize,
                                 rank: Rank, suit: Suit, ink: UIColor) {
        let n = rank.rawValue
        let pipSize = n == 1 ? size.width * 0.34 : size.width * 0.16
        guard let pip = suitImage(suit, size: pipSize, color: ink) else { return }

        // Columns at 30% / 50% / 70% across; rows evenly spaced down the face.
        let left: CGFloat = 0.295, mid: CGFloat = 0.5, right: CGFloat = 0.705
        let top: CGFloat = 0.225, bottom: CGFloat = 0.775
        let upper: CGFloat = 0.408, lower: CGFloat = 0.592
        let centre: CGFloat = 0.5

        // Positions as (x, y) fractions, and whether the pip is inverted — the
        // lower half of a real card's pips point down.
        var spots: [(CGFloat, CGFloat)] = []
        switch n {
        case 1:  spots = [(mid, centre)]
        case 2:  spots = [(mid, top), (mid, bottom)]
        case 3:  spots = [(mid, top), (mid, centre), (mid, bottom)]
        case 4:  spots = [(left, top), (right, top), (left, bottom), (right, bottom)]
        case 5:  spots = [(left, top), (right, top), (mid, centre), (left, bottom), (right, bottom)]
        case 6:  spots = [(left, top), (right, top), (left, centre), (right, centre),
                          (left, bottom), (right, bottom)]
        case 7:  spots = [(left, top), (right, top), (mid, 0.362), (left, centre), (right, centre),
                          (left, bottom), (right, bottom)]
        case 8:  spots = [(left, top), (right, top), (mid, 0.362), (left, centre), (right, centre),
                          (mid, 0.638), (left, bottom), (right, bottom)]
        case 9:  spots = [(left, top), (right, top), (left, upper), (right, upper), (mid, centre),
                          (left, lower), (right, lower), (left, bottom), (right, bottom)]
        case 10: spots = [(left, top), (right, top), (mid, 0.318), (left, upper), (right, upper),
                          (left, lower), (right, lower), (mid, 0.682),
                          (left, bottom), (right, bottom)]
        default: return
        }

        for (fx, fy) in spots {
            let cx = size.width * fx
            let cy = size.height * fy
            cg.saveGState()
            cg.translateBy(x: cx, y: cy)
            // Pips below the midline are printed upside down.
            if fy > 0.5 + 0.001 { cg.rotate(by: .pi) }
            pip.draw(at: CGPoint(x: -pip.size.width / 2, y: -pip.size.height / 2))
            cg.restoreGState()
        }
    }

    private static func drawCourt(in cg: CGContext, size: CGSize,
                                  rank: Rank, suit: Suit, ink: UIColor) {
        // A framed panel with a large glyph and the rank letter. Deliberately
        // plain: see the note on the enclosing type.
        let inset = size.width * 0.185
        let panel = CGRect(x: inset, y: size.height * 0.145,
                           width: size.width - inset * 2,
                           height: size.height * 0.71)
        let path = UIBezierPath(roundedRect: panel, cornerRadius: size.width * 0.035)
        cg.setStrokeColor(ink.withAlphaComponent(0.65).cgColor)
        cg.setLineWidth(size.width * 0.012)
        cg.addPath(path.cgPath)
        cg.strokePath()

        if let pip = suitImage(suit, size: size.width * 0.30, color: ink) {
            pip.draw(at: CGPoint(x: panel.midX - pip.size.width / 2,
                                 y: panel.minY + panel.height * 0.10))
        }
        let font = UIFont.systemFont(ofSize: size.width * 0.30, weight: .heavy)
        let text = NSAttributedString(string: rank.label,
                                      attributes: [.font: font, .foregroundColor: ink])
        let ts = text.size()
        text.draw(at: CGPoint(x: panel.midX - ts.width / 2,
                              y: panel.maxY - ts.height - panel.height * 0.08))
    }

    // MARK: - Importing a photograph of a real card

    /// Finds the card in a photograph and flattens it to card proportions.
    ///
    /// Without this an imported photo carries the perspective and lighting of
    /// the shot it came from; warping *that* onto a tracked card compounds two
    /// perspectives and the result looks wrong from every angle.
    static func rectifyImported(_ image: CIImage, context: CIContext) -> CIImage? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 35
        request.minimumSize = 0.15
        request.minimumConfidence = 0.3
        request.maximumObservations = 8

        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        try? handler.perform([request])

        let extent = image.extent
        var chosen: Quad?

        if let results = request.results, !results.isEmpty {
            var bestScore = -Double.greatestFiniteMagnitude
            for obs in results {
                func pt(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: extent.origin.x + p.x * extent.width,
                            y: extent.origin.y + p.y * extent.height)
                }
                let quad = Quad(topLeft: pt(obs.topLeft), topRight: pt(obs.topRight),
                                bottomRight: pt(obs.bottomRight), bottomLeft: pt(obs.bottomLeft))
                guard quad.isConvex, quad.minAngleDegrees > 30 else { continue }
                let aspectError = abs(quad.aspect - aspect) / aspect
                let score = Double(obs.confidence) - Double(aspectError) * 1.2
                           + Double(quad.area / (extent.width * extent.height)) * 0.5
                if score > bestScore { bestScore = score; chosen = quad }
            }
        }

        // No rectangle found — the user may have cropped the card themselves,
        // so fall back to using the whole image rather than refusing it.
        let quad = chosen ?? Quad(topLeft: CGPoint(x: extent.minX, y: extent.maxY),
                                  topRight: CGPoint(x: extent.maxX, y: extent.maxY),
                                  bottomRight: CGPoint(x: extent.maxX, y: extent.minY),
                                  bottomLeft: CGPoint(x: extent.minX, y: extent.minY))

        let correct = CIFilter(name: "CIPerspectiveCorrection")
        correct?.setValue(image, forKey: kCIInputImageKey)
        correct?.setValue(CIVector(cgPoint: quad.topLeft), forKey: "inputTopLeft")
        correct?.setValue(CIVector(cgPoint: quad.topRight), forKey: "inputTopRight")
        correct?.setValue(CIVector(cgPoint: quad.bottomRight), forKey: "inputBottomRight")
        correct?.setValue(CIVector(cgPoint: quad.bottomLeft), forKey: "inputBottomLeft")
        guard let flat = correct?.outputImage, flat.extent.width > 8 else { return nil }

        // Normalise to the standard art size so relighting has a predictable
        // reference and the compositor's warp adds no stretch.
        let target = CGSize(width: renderWidth, height: renderWidth * aspect)
        let sx = target.width / flat.extent.width
        let sy = target.height / flat.extent.height
        let scaled = flat
            .transformed(by: CGAffineTransform(translationX: -flat.extent.origin.x,
                                               y: -flat.extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // Neutralise the colour cast of whatever light the photo was taken
        // under, so the card reads as white stock before the compositor relights
        // it. `CIWhitePointAdjust` is no help here: its default input colour is
        // white, which makes it a no-op.
        return neutralizeWhite(scaled, context: context)
    }

    /// White-balances the art against its own card stock.
    ///
    /// Uses a white-patch estimate — the near-brightest value in each channel —
    /// rather than the usual grey-world average. On a playing card grey-world is
    /// simply wrong: the face is mostly white stock with a little ink, so the
    /// average is near-white already, and on a hearts or diamonds card the red
    /// pips drag the average warm and the correction then pushes the whole card
    /// cyan. The brightest pixels *are* the stock, which makes them the correct
    /// reference for what "white" was under that light.
    private static func neutralizeWhite(_ image: CIImage, context: CIContext) -> CIImage {
        let w = 24, h = 34
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let e = image.extent
        guard e.width > 1, e.height > 1 else { return image }

        let sampled = image
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width,
                                               y: CGFloat(h) / e.height))
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(sampled, toBitmap: base, rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        // Per-channel 92nd percentile, in linear light. A percentile rather than
        // the maximum, so one blown-out specular pixel cannot set the reference.
        var channels = [[Float]](repeating: [], count: 3)
        for c in 0..<3 {
            channels[c].reserveCapacity(w * h)
            for i in 0..<(w * h) {
                channels[c].append(SceneMeter.srgbToLinear(Float(buf[i * 4 + c]) / 255))
            }
            channels[c].sort()
        }
        let index = Int(Float(w * h - 1) * 0.92)
        let white = (0..<3).map { channels[$0][index] }
        guard white.allSatisfy({ $0 > 0.02 }) else { return image }

        // Scale each channel so its white reference lands on the brightest of
        // the three, preserving overall level instead of darkening the art.
        let peak = white.max() ?? 1
        let gains = white.map { min(2.5, max(0.4, peak / $0)) }

        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: CGFloat(gains[0]), y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: CGFloat(gains[1]), z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains[2]), w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    /// Mean linear luminance of the art, used as the relight reference.
    static func referenceLuminance(of image: CIImage, context: CIContext) -> Float {
        let w = 16, h = 22
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let e = image.extent
        guard e.width > 1, e.height > 1 else { return 0.5 }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width,
                                               y: CGFloat(h) / e.height))
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled, toBitmap: base, rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        var sum: Float = 0
        for i in 0..<(w * h) {
            let r = SceneMeter.srgbToLinear(Float(buf[i * 4]) / 255)
            let g = SceneMeter.srgbToLinear(Float(buf[i * 4 + 1]) / 255)
            let b = SceneMeter.srgbToLinear(Float(buf[i * 4 + 2]) / 255)
            sum += r * 0.2126 + g * 0.7152 + b * 0.0722
        }
        return max(0.02, sum / Float(w * h))
    }
}
