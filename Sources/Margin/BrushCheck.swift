import AppKit

/// A dry-brush checkmark, painted procedurally: a short heavy stroke down, then a long sweep up
/// that frays into bristle streaks toward its tip, like a check made with a nearly-dry brush.
/// It uses a fixed seed, so every circle gets the same "hand-painted" check.
enum BrushCheck {
    // The brush's path, in units of the circle's radius (y up).
    private static let top = CGPoint(x: -0.44, y: 0.10)
    private static let corner = CGPoint(x: -0.12, y: -0.34)
    private static let bend = CGPoint(x: 0.10, y: -0.12) // pulls the long stroke into a gentle curve
    private static let tip = CGPoint(x: 0.48, y: 0.38)

    /// Where the brush travels (used as the draw-in mask). `overshoot` extends it past the tip.
    static func centerline(in rect: CGRect, overshoot: CGFloat = 0) -> CGPath {
        let map = mapper(rect)
        let path = CGMutablePath()
        path.move(to: map(top))
        path.addLine(to: map(corner))
        path.addQuadCurve(to: map(tip), control: map(bend))
        if overshoot > 0 {
            path.addLine(to: map(tip + unit(tip - bend) * overshoot))
        }
        return path
    }

    /// The painted check's ink bounds, in units of the radius from the center (y up).
    static func inkBox(side: CGFloat) -> CGRect? {
        guard let img = image(side: side, scale: 1, color: .white),
              let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<img.height {
            for x in 0..<img.width where bytes[y * img.bytesPerRow + x * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        let r = side / 2
        // Bitmap rows run top to bottom; flip so y is up like the brush path.
        return CGRect(x: (CGFloat(minX) - r) / r, y: (r - CGFloat(maxY + 1)) / r,
                      width: CGFloat(maxX + 1 - minX) / r, height: CGFloat(maxY + 1 - minY) / r)
    }

    /// The painted check, `side` points square, rendered at `scale`.
    static func image(side: CGFloat, scale: CGFloat, color: NSColor) -> CGImage? {
        let px = Int((side * scale).rounded())
        guard px > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let map = mapper(CGRect(x: 0, y: 0, width: side, height: side))
        let r = side / 2
        var rng = SeededRandom(seed: 0xC1A0DE)

        let shortLeg = samples(40) { lerp(top, corner, $0) }.map(map)
        let longLeg = samples(90) { quad(corner, bend, tip, $0) }.map(map)
        // Like a real brush check: the long sweep is the boldest part and only thins a little.
        let shortWidth: (CGFloat) -> CGFloat = { (0.17 + 0.04 * $0) * r }
        let longWidth: (CGFloat) -> CGFloat = { (0.31 - 0.08 * $0) * r }

        // The body: two strokes with ragged edges, joined by a blob of paint at the corner.
        ctx.setFillColor(color.cgColor)
        ctx.addPath(ragged(shortLeg, width: shortWidth, rng: &rng))
        ctx.fillPath()
        ctx.addPath(ragged(longLeg, width: longWidth, rng: &rng))
        ctx.fillPath()
        // A little paint where the brush turns, so the bottom of the V reads as one stroke.
        let v = map(corner + CGPoint(x: 0.02, y: 0.05)), blob = 0.1 * r
        ctx.fillEllipse(in: CGRect(x: v.x - blob, y: v.y - blob, width: blob * 2, height: blob * 2))

        // Dry streaks: the brush runs out of paint along the long stroke, mostly on its lower edge.
        ctx.setBlendMode(.clear)
        ctx.setLineCap(.round)
        // Fine streaks, starting partway along and mostly in the lower half, so the stroke stays bold.
        for k in 0..<8 {
            let offset = k < 6 ? CGFloat.random(in: -0.42 ... -0.04, using: &rng) // negative = lower edge
                               : CGFloat.random(in: -0.04 ... 0.3, using: &rng)
            let from = CGFloat.random(in: 0.35 ... 0.75, using: &rng)
            let to = from + CGFloat.random(in: 0.3 ... 0.8, using: &rng)
            ctx.setLineWidth(CGFloat.random(in: 0.018 ... 0.035, using: &rng) * r)
            streak(longLeg, from: from, to: to, offset: offset, width: longWidth, reach: 0.05 * r, rng: &rng, ctx: ctx)
        }
        // A few dry specks where the long stroke thins out.
        for _ in 0..<6 {
            let i = Int.random(in: 45 ..< longLeg.count, using: &rng)
            let t = CGFloat(i) / CGFloat(longLeg.count - 1)
            let p = longLeg[i] + normal(longLeg, i) * (CGFloat.random(in: -0.4 ... 0.3, using: &rng) * longWidth(t))
            let d = CGFloat.random(in: 0.015 ... 0.035, using: &rng) * r
            ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d * 1.6, height: d))
        }

        // Flecks of paint flicked off the bristles along the top edge, near the tip.
        ctx.setBlendMode(.normal)
        for _ in 0..<6 {
            let i = Int.random(in: 55 ..< longLeg.count, using: &rng)
            let t = CGFloat(i) / CGFloat(longLeg.count - 1)
            let p = longLeg[i] + normal(longLeg, i) * (longWidth(t) * CGFloat.random(in: 0.6 ... 0.85, using: &rng))
            let d = CGFloat.random(in: 0.015 ... 0.04, using: &rng) * r
            ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        }
        return ctx.makeImage()
    }

    // MARK: - Brush helpers

    /// A stroke outline whose two edges wobble slightly, like paint on rough paper.
    private static func ragged(_ pts: [CGPoint], width: (CGFloat) -> CGFloat, rng: inout SeededRandom) -> CGPath {
        let phaseA = CGFloat.random(in: 0 ... 6.28, using: &rng)
        let phaseB = CGFloat.random(in: 0 ... 6.28, using: &rng)
        // Organic roughness: smoothed random wobble plus a slow wave, with only a little fine grain,
        // so edges look like paint on paper rather than a saw blade.
        func wobble(_ amount: CGFloat) -> [CGFloat] {
            var w = pts.indices.map { _ in CGFloat.random(in: -amount ... amount, using: &rng) }
            for _ in 0..<2 {
                w = w.indices.map { i in (w[max(i - 1, 0)] + w[i] + w[min(i + 1, w.count - 1)]) / 3 }
            }
            return w
        }
        let wobbleLeft = wobble(0.22), wobbleRight = wobble(0.28)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in pts.indices {
            let t = CGFloat(i) / CGFloat(pts.count - 1)
            let n = normal(pts, i)
            let half = width(t) / 2
            let grainLeft = CGFloat.random(in: -0.025 ... 0.025, using: &rng)
            let grainRight = CGFloat.random(in: -0.035 ... 0.035, using: &rng)
            let roughLeft = 1 + 0.05 * sin(CGFloat(i) * 0.35 + phaseA) + wobbleLeft[i] + grainLeft
            let roughRight = 1 + 0.06 * sin(CGFloat(i) * 0.45 + phaseB) + wobbleRight[i] + grainRight
            left.append(pts[i] + n * (half * roughLeft))
            right.append(pts[i] - n * (half * roughRight))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    /// Erases a thin, slightly broken line running along the stroke: a gap between bristles.
    /// With `to` past 1 it continues off the tip, splitting the end into bristle "fingers".
    private static func streak(_ pts: [CGPoint], from: CGFloat, to: CGFloat, offset: CGFloat,
                               width: (CGFloat) -> CGFloat, reach: CGFloat,
                               rng: inout SeededRandom, ctx: CGContext) {
        let last = pts.count - 1
        let first = max(0, Int(from * CGFloat(last)))
        let end = min(last, Int(to * CGFloat(last)))
        guard end > first else { return }
        var segment: [CGPoint] = []
        func flush() {
            if segment.count > 1 {
                ctx.addLines(between: segment)
                ctx.strokePath()
            }
            segment.removeAll()
        }
        for i in first...end {
            if Double.random(in: 0 ... 1, using: &rng) < 0.06 { flush() } // the bristle catches paint again briefly
            let t = CGFloat(i) / CGFloat(last)
            let wobble = CGFloat.random(in: -0.03 ... 0.03, using: &rng)
            segment.append(pts[i] + normal(pts, i) * ((offset + wobble) * width(t)))
        }
        if to > 1, reach > 0, let lastPoint = segment.last {
            segment.append(lastPoint + unit(pts[last] - pts[last - 1]) * reach)
        }
        flush()
    }

    private static func mapper(_ rect: CGRect) -> (CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        return { CGPoint(x: c.x + $0.x * r, y: c.y + $0.y * r) }
    }

    private static func samples(_ n: Int, _ f: (CGFloat) -> CGPoint) -> [CGPoint] {
        (0...n).map { f(CGFloat($0) / CGFloat(n)) }
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { a + (b - a) * t }

    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        a * ((1 - t) * (1 - t)) + c * (2 * (1 - t) * t) + b * (t * t)
    }

    /// Unit normal to the left of the direction of travel at point `i`.
    private static func normal(_ pts: [CGPoint], _ i: Int) -> CGPoint {
        let d = unit(pts[min(i + 1, pts.count - 1)] - pts[max(i - 1, 0)])
        return CGPoint(x: -d.y, y: d.x)
    }

    private static func unit(_ p: CGPoint) -> CGPoint {
        let len = max(hypot(p.x, p.y), 0.0001)
        return CGPoint(x: p.x / len, y: p.y / len)
    }
}

fileprivate extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
}

/// Small deterministic random generator (SplitMix64), so the brush texture never changes.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
