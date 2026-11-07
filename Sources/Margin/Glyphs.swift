import SwiftUI
import AppKit

// MARK: - The set

/// Margin's own monochrome icon set. Drawn in code on a 24x24 grid, one colour, round caps and joins.
enum GlyphKind: String, Codable, CaseIterable {
    // Sector defaults
    case blackHole, sigma, flask, helix, brackets, graphUp, glyphA, hourglass, nib, pulse, cube, void
    // Extras for user sectors
    case atom, planet, comet, galaxy, neuron, chip, terminal, globe, compass, prism, wave
    case infinity, key, music, leaf, lightning, eye, scales, rocket, gear, star
    // Status and empty states
    case orbit, scan, emptyVoid, spark, check, warning

    /// The twelve glyphs the built-in sectors wear.
    static let sectorDefaults: [GlyphKind] = [.sigma, .blackHole, .flask, .helix, .brackets, .graphUp, .glyphA, .hourglass, .nib, .pulse, .cube, .void]
    static let extras: [GlyphKind] = [.atom, .planet, .comet, .galaxy, .neuron, .chip, .terminal, .globe, .compass, .prism, .wave,
                                      .infinity, .key, .music, .leaf, .lightning, .eye, .scales, .rocket, .gear, .star]
    static let status: [GlyphKind] = [.orbit, .scan, .emptyVoid, .spark, .check, .warning]

    /// What the sector picker offers: the defaults and the extras, not the status glyphs.
    static var sectorPickable: [GlyphKind] { sectorDefaults + extras }

    /// The built-in sectors get their own glyph; any other name gets a steady pick from the extras.
    static func defaultFor(sector name: String) -> GlyphKind {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "math": return .sigma
        case "physics": return .blackHole
        case "chemistry": return .flask
        case "biology": return .helix
        case "computer science": return .brackets
        case "economics": return .graphUp
        case "language": return .glyphA
        case "history": return .hourglass
        case "writing": return .nib
        case "health": return .pulse
        case "business": return .cube
        case "other": return .void
        default:
            // (hashValue changes every launch, so fold the scalars by hand.)
            let stable = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return extras[stable % extras.count]
        }
    }

    var title: String {
        switch self {
        case .blackHole: return "Black hole"
        case .sigma: return "Sigma"
        case .flask: return "Flask"
        case .helix: return "Helix"
        case .brackets: return "Braces"
        case .graphUp: return "Graph"
        case .glyphA: return "Letters"
        case .hourglass: return "Hourglass"
        case .nib: return "Nib"
        case .pulse: return "Pulse"
        case .cube: return "Cube"
        case .void: return "Void"
        case .atom: return "Atom"
        case .planet: return "Planet"
        case .comet: return "Comet"
        case .galaxy: return "Galaxy"
        case .neuron: return "Neuron"
        case .chip: return "Chip"
        case .terminal: return "Terminal"
        case .globe: return "Globe"
        case .compass: return "Compass"
        case .prism: return "Prism"
        case .wave: return "Wave"
        case .infinity: return "Infinity"
        case .key: return "Key"
        case .music: return "Music"
        case .leaf: return "Leaf"
        case .lightning: return "Lightning"
        case .eye: return "Eye"
        case .scales: return "Scales"
        case .rocket: return "Rocket"
        case .gear: return "Gear"
        case .star: return "Star"
        case .orbit: return "Orbit"
        case .scan: return "Scan"
        case .emptyVoid: return "Empty"
        case .spark: return "Spark"
        case .check: return "Check"
        case .warning: return "Warning"
        }
    }

    /// The pose shown when nothing is animating (also what the sidebar shows).
    fileprivate var restPhase: Double {
        switch self {
        case .helix: return 0.3
        case .cube: return 0.0
        case .hourglass: return 0.35
        case .nib: return 0.7
        case .globe: return 0.2
        default: return 0
        }
    }
}

// MARK: - The view

/// One glyph. `animated` loops slowly (only while on screen); `active` is the livelier hover/selected state.
/// Reduce Motion freezes everything. Pass `phase` (0...1) to draw one fixed frame (used by the gallery).
struct Glyph: View {
    let kind: GlyphKind
    var size: CGFloat = 16
    /// nil = ink (or the alert colour for `.warning`).
    var color: Color?
    var animated = false
    var active = false
    var phase: Double?

    init(kind: GlyphKind, size: CGFloat = 16, color: Color? = nil, animated: Bool = false, active: Bool = false, phase: Double? = nil) {
        self.kind = kind
        self.size = size
        self.color = color
        self.animated = animated
        self.active = active
        self.phase = phase
    }

    private var resolved: Color { color ?? (kind == .warning ? Theme.alert.color : Theme.ink.color) }

    var body: some View {
        Group {
            if let phase {
                canvas(phase: phase, live: true)
            } else if (animated || active) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let period: Double = active ? 2.8 : 5.0
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate / period
                    canvas(phase: t - t.rounded(.down), live: true)
                }
            } else {
                canvas(phase: kind.restPhase, live: false)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func canvas(phase: Double, live: Bool) -> some View {
        let kind = kind, size = size, color = resolved, active = active
        return Canvas { ctx, sz in
            var c = ctx
            let s = min(sz.width, sz.height) / 24
            c.scaleBy(x: s, y: s)
            let lw = max(1.5, 24 / max(size, 1))
            let pen = GlyphPen(c: c, color: color, lw: lw, small: size < 20, active: active, live: live)
            GlyphArt.draw(kind, pen, CGFloat(phase))
        }
    }
}

// MARK: - Drawing helpers

struct GlyphPen {
    var c: GraphicsContext
    let color: Color
    /// Line width in grid units (1.5 at 24pt and up, never under 1pt on screen).
    let lw: CGFloat
    let small: Bool
    let active: Bool
    let live: Bool
    var alpha: Double = 1

    func stroke(_ p: Path, _ w: CGFloat = 1, _ o: Double = 1, dash: [CGFloat] = []) {
        c.stroke(p, with: .color(color.opacity(o * alpha)),
                 style: StrokeStyle(lineWidth: lw * w, lineCap: .round, lineJoin: .round, dash: dash))
    }

    func fill(_ p: Path, _ o: Double = 1) { c.fill(p, with: .color(color.opacity(o * alpha))) }

    /// Draws with a private copy of the context (transforms and clips stay inside).
    func scope(_ f: (inout GlyphPen) -> Void) { var q = self; f(&q) }

    func faded(_ a: Double) -> GlyphPen { var q = self; q.alpha = alpha * a; return q }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func circ(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
private func seg(_ a: CGPoint, _ b: CGPoint) -> Path { Path { $0.move(to: a); $0.addLine(to: b) } }
private func poly(_ pts: [CGPoint], closed: Bool = false) -> Path {
    Path { p in
        guard let f = pts.first else { return }
        p.move(to: f)
        for q in pts.dropFirst() { p.addLine(to: q) }
        if closed { p.closeSubpath() }
    }
}
private func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }
private func ease(_ t: CGFloat) -> CGFloat { let x = min(max(t, 0), 1); return x * x * (3 - 2 * x) }
private func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, r: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerRadius: r)
}
private func ellipseArc(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ tilt: CGFloat, _ t0: CGFloat, _ t1: CGFloat) -> Path {
    Path { p in
        let n = 56
        for i in 0...n {
            let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(n)
            let x = rx * cos(t), y = ry * sin(t)
            let q = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
    }
}
private func rotated(_ p: CGPoint, _ a: CGFloat, about c: CGPoint) -> CGPoint {
    let dx = p.x - c.x, dy = p.y - c.y
    return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
}

// MARK: - The drawings

enum GlyphArt {
    static func draw(_ kind: GlyphKind, _ g: GlyphPen, _ p: CGFloat) {
        let tau = CGFloat.pi * 2
        let boost: CGFloat = g.active ? 1.5 : 1
        let c0 = pt(12, 12)
        switch kind {

        case .blackHole:
            if g.small {
                // Small sizes: a heavy hollow photon ring (empty centre, so it can't read as a planet), a lensed arc over its top and a
                // thin tilted band that stays inside the arc's width, crossing in front.
                let tilt = rad(-14 + 1.6 * boost * sin(tau * p))
                let band = ellipseArc(pt(12, 12.4), 9.4, 1.7, tilt, 0, .pi)
                let gap = band.strokedPath(StrokeStyle(lineWidth: g.lw * 2.4, lineCap: .butt))
                g.scope { q in
                    q.c.clip(to: gap, options: .inverse)
                    q.stroke(circ(pt(12, 12.4), 6.2), 1.5, 1) // photon ring
                }
                g.stroke(ellipseArc(pt(12, 12.4), 9.6, 9.0, 0, rad(200), rad(340)), 0.6, 0.7) // lensed far side of the disc
                g.stroke(band, 0.9, 1)
                return
            }
            // Gargantua: an EMPTY event horizon (nothing is drawn there, so the background shows through), a thin photon ring hugging
            // it, a thick accretion band crossing in FRONT, and the far side of the disc lensed over the top (fainter under the bottom).
            let wob = 1.6 * boost * sin(tau * p)
            let tilt = rad(-9 + wob)
            let bc = pt(12, 12.6)
            let front = ellipseArc(bc, 11, g.small ? 2.3 : 2.0, tilt, 0, .pi)
            let tips = ellipseArc(bc, 11, g.small ? 2.3 : 2.0, tilt, .pi, 2 * .pi)
            let hr: CGFloat = g.small ? 5.4 : 5.2
            let gap = front.strokedPath(StrokeStyle(lineWidth: g.lw * 2.4, lineCap: .butt))
            g.scope { q in
                q.c.clip(to: gap, options: .inverse)
                q.stroke(circ(pt(12, 12.4), hr + 1.0), 0.5, 0.5) // photon ring
                let over = Path { b in
                    for i in 0...32 {
                        let a = rad(185) + rad(170) * CGFloat(i) / 32
                        let r: CGFloat = 9.4
                        let x = 12 + r * cos(a), y = 12.4 + r * 0.92 * sin(a)
                        if i == 0 { b.move(to: pt(x, y)) } else { b.addLine(to: pt(x, y)) }
                    }
                }
                q.stroke(over, 1.25, 1) // lensed far side of the disc
                if !g.small {
                    let under = Path { b in
                        for i in 0...20 {
                            let a = rad(40) + rad(100) * CGFloat(i) / 20
                            let r: CGFloat = 8.0
                            let x = 12 + r * cos(a), y = 12.4 + r * 0.9 * sin(a)
                            if i == 0 { b.move(to: pt(x, y)) } else { b.addLine(to: pt(x, y)) }
                        }
                    }
                    q.stroke(under, 0.6, 0.35)
                }
            }
            g.stroke(front, g.small ? 1.7 : 1.9, 1) // accretion band, in front of the horizon
            g.scope { q in // the back half only shows past the lens: the two tips
                let cut = circ(pt(12, 12.4), hr + 3.2)
                q.c.clip(to: cut, options: .inverse)
                q.stroke(tips, 0.7, 0.55)
            }
            if g.live { // a hot spot rides the band
                let t = .pi * ((p * 2).truncatingRemainder(dividingBy: 1))
                let pos = ellipseArc(bc, 11, g.small ? 2.3 : 2.0, tilt, t, t + 0.001)
                if let at = pos.currentPoint { g.fill(circ(at, g.small ? 1.3 : 1.0)) }
            }

        case .sigma:
            g.stroke(poly([pt(16.5, 5), pt(7.5, 5), pt(13.5, 12), pt(7.5, 19), pt(16.5, 19)]))
            let step = g.live ? Int(p * 4) % 4 : 3
            let y = 5 + CGFloat(step) * 14.0 / 3
            if !g.small { for i in 0..<4 { g.fill(circ(pt(20.5, 5 + CGFloat(i) * 14.0 / 3), 0.5), 0.35) } }
            if !g.small || g.live { g.fill(circ(pt(20.5, y), 1.1)) }

        case .flask:
            let body = Path { q in
                q.move(to: pt(9.5, 3.5)); q.addLine(to: pt(9.5, 10))
                q.addLine(to: pt(4.8, 18.4)); q.addQuadCurve(to: pt(6.4, 20.5), control: pt(3.8, 20.5))
                q.addLine(to: pt(17.6, 20.5)); q.addQuadCurve(to: pt(19.2, 18.4), control: pt(20.2, 20.5))
                q.addLine(to: pt(14.5, 10)); q.addLine(to: pt(14.5, 3.5))
            }
            g.stroke(body)
            g.stroke(seg(pt(8, 3.5), pt(16, 3.5)))
            g.stroke(seg(pt(6.7, 15.2), pt(17.3, 15.2)), 1, 0.55)
            let n = g.small ? 1 : 3
            for i in 0..<n {
                let off = CGFloat(i) / CGFloat(n)
                let u = g.live ? ((p * (g.active ? 1.6 : 1) + off).truncatingRemainder(dividingBy: 1)) : (0.25 + off * 0.3)
                let x: CGFloat = n == 1 ? 12 : [10.5, 13.5, 12][i]
                let y = 18.5 - u * 9
                g.fill(circ(pt(x, y), g.small ? 1.1 : 0.95), Double(1 - u * 0.7))
            }

        case .helix:
            let ph = tau * p * boost.rounded(.up) + 0
            func x(_ y: CGFloat, _ s: CGFloat) -> CGFloat { 12 + s * 5 * sin(y * 0.52 + ph) }
            func strand(_ s: CGFloat) -> Path {
                Path { q in
                    for i in 0...44 {
                        let y = 2.5 + CGFloat(i) * 19.0 / 44
                        let pnt = pt(x(y, s), y)
                        if i == 0 { q.move(to: pnt) } else { q.addLine(to: pnt) }
                    }
                }
            }
            let rungs: [CGFloat] = g.small ? [6, 12, 18] : [4.6, 7.6, 10.6, 13.6, 16.6, 19.6]
            for y in rungs where abs(x(y, 1) - x(y, -1)) > 2.5 { g.stroke(seg(pt(x(y, 1), y), pt(x(y, -1), y)), 0.7, 0.5) }
            g.stroke(strand(1)); g.stroke(strand(-1))

        case .brackets:
            let left = Path { q in
                q.move(to: pt(9, 4)); q.addQuadCurve(to: pt(6.5, 6.5), control: pt(6.5, 4))
                q.addLine(to: pt(6.5, 9.8)); q.addQuadCurve(to: pt(4, 12), control: pt(6.5, 12))
                q.addQuadCurve(to: pt(6.5, 14.2), control: pt(6.5, 12))
                q.addLine(to: pt(6.5, 17.5)); q.addQuadCurve(to: pt(9, 20), control: pt(6.5, 20))
            }
            g.stroke(left)
            g.stroke(left.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0)))
            let blink: Double = g.live ? (p < 0.5 ? 1 : 0.1) : 1
            g.stroke(seg(pt(12, 8), pt(12, 16)), 1, blink)

        case .graphUp:
            g.stroke(poly([pt(4, 3.5), pt(4, 20), pt(20.5, 20)]), 1, 0.5)
            let line = poly([pt(7, 16.5), pt(11, 12), pt(14, 14.5), pt(20, 6.5)])
            let t: CGFloat = g.live ? ease(p / 0.6) : 1
            g.stroke(line.trimmedPath(from: 0, to: max(t, 0.001)), 1.1)
            if !g.small, t > 0.98 { g.fill(circ(pt(20, 6.5), 1.5)) }

        case .glyphA:
            var s: CGFloat = 0
            if g.live { let w = 0.5 - 0.5 * cos(tau * p); s = ease((w - 0.3) / 0.4) }
            let latin = Path { q in
                q.move(to: pt(2.5, 19)); q.addLine(to: pt(7.5, 5)); q.addLine(to: pt(12.5, 19))
                q.move(to: pt(4.4, 14.4)); q.addLine(to: pt(10.6, 14.4))
                q.addEllipse(in: CGRect(x: 13.5, y: 12, width: 7, height: 7))
                q.move(to: pt(20.5, 12.5)); q.addLine(to: pt(20.5, 19))
            }
            let cyr = Path { q in
                q.move(to: pt(12.5, 5)); q.addLine(to: pt(8.5, 5)); q.addQuadCurve(to: pt(4.4, 8.75), control: pt(4.4, 5))
                q.addQuadCurve(to: pt(8.5, 12.5), control: pt(4.4, 12.5)); q.addLine(to: pt(12.5, 12.5))
                q.move(to: pt(12.5, 5)); q.addLine(to: pt(12.5, 19))
                q.move(to: pt(8.5, 12.5)); q.addLine(to: pt(4.2, 19))
                q.move(to: pt(20.5, 12)); q.addLine(to: pt(17.5, 12)); q.addQuadCurve(to: pt(14.5, 14.2), control: pt(14.5, 12))
                q.addQuadCurve(to: pt(17.5, 16.5), control: pt(14.5, 16.5)); q.addLine(to: pt(20.5, 16.5))
                q.move(to: pt(20.5, 12)); q.addLine(to: pt(20.5, 19))
                q.move(to: pt(17.5, 16.5)); q.addLine(to: pt(14.5, 19))
            }
            g.stroke(latin, 1, Double(1 - s))
            g.stroke(cyr, 1, Double(s))

        case .hourglass:
            let f: CGFloat = g.live ? (p < 0.9 ? p / 0.9 : 1) : 0.35
            g.stroke(seg(pt(6, 3.5), pt(18, 3.5))); g.stroke(seg(pt(6, 20.5), pt(18, 20.5)))
            let body = Path { q in
                q.move(to: pt(7.5, 3.5)); q.addLine(to: pt(7.5, 5.5)); q.addLine(to: pt(12, 12)); q.addLine(to: pt(7.5, 18.5)); q.addLine(to: pt(7.5, 20.5))
                q.move(to: pt(16.5, 3.5)); q.addLine(to: pt(16.5, 5.5)); q.addLine(to: pt(12, 12)); q.addLine(to: pt(16.5, 18.5)); q.addLine(to: pt(16.5, 20.5))
            }
            g.stroke(body)
            func halfW(_ y: CGFloat) -> CGFloat { 4.5 * (12 - y) / 6.5 }
            let ys = 6.9 + f * 4.6
            g.fill(poly([pt(12 - halfW(ys), ys), pt(12 + halfW(ys), ys), pt(12, 11.6)], closed: true))
            let top = 19.4 - f * 5.2
            g.fill(poly([pt(8.4, 19.4), pt(15.6, 19.4), pt(12, top)], closed: true))
            if g.live, f < 0.98, !g.small { g.stroke(seg(pt(12, 12), pt(12, top)), 0.5) }

        case .nib:
            let t: CGFloat = g.live ? ease(p / 0.8) : 0.7
            let nx = 8 + 8 * t
            let fade = g.live && p > 0.9 ? Double(1 - (p - 0.9) * 10) : 1
            let q = g.faded(fade)
            q.stroke(seg(pt(3, 21.6), pt(nx, 21.6)), 0.9)
            let nib = Path { b in
                b.move(to: pt(nx, 19.2)); b.addLine(to: pt(nx - 4.2, 10.5))
                b.addQuadCurve(to: pt(nx, 2.8), control: pt(nx - 3.6, 4.8))
                b.addQuadCurve(to: pt(nx + 4.2, 10.5), control: pt(nx + 3.6, 4.8))
                b.closeSubpath()
            }
            q.stroke(nib)
            q.stroke(seg(pt(nx, 19.2), pt(nx, 13)), 0.8)
            if !g.small { q.fill(circ(pt(nx, 11.6), 1.1)) }

        case .pulse:
            let path = poly([pt(2, 12.5), pt(7, 12.5), pt(9.2, 6), pt(12.6, 19), pt(15, 9.5), pt(16.6, 12.5), pt(22, 12.5)])
            if g.live {
                g.stroke(path, 1, 0.35)
                let head = p * 1.5
                g.stroke(path.trimmedPath(from: max(0, head - 0.45), to: min(1, max(0.001, head))), 1.15)
            } else {
                g.stroke(path, 1.1)
            }

        case .cube:
            let yaw = rad(35) + (.pi / 2) * p * boost.rounded(.up)
            let pitch = rad(-24)
            let s: CGFloat = 5.6
            var v: [(CGPoint, CGFloat)] = []
            for i in 0..<8 {
                let x = (i & 1 == 0 ? -1 : 1) * s, y = (i & 2 == 0 ? -1 : 1) * s, z = (i & 4 == 0 ? -1 : 1) * s
                let x1 = x * cos(yaw) + z * sin(yaw), z1 = -x * sin(yaw) + z * cos(yaw)
                let y1 = y * cos(pitch) - z1 * sin(pitch), z2 = y * sin(pitch) + z1 * cos(pitch)
                v.append((pt(12 + x1, 12.3 + y1), z2))
            }
            var edges: [(Int, Int, CGFloat)] = []
            for i in 0..<8 { for b in [1, 2, 4] where i & b == 0 { edges.append((i, i | b, (v[i].1 + v[i | b].1) / 2)) } }
            for e in edges.sorted(by: { $0.2 < $1.2 }) {
                let near = min(max((e.2 / s + 1) / 2, 0), 1)
                g.stroke(seg(v[e.0].0, v[e.1].0), 1, Double(0.3 + 0.7 * near))
            }

        case .void:
            let n = g.small ? 10 : 14
            let r: CGFloat = 8.6
            let gap = 2 * .pi * r / CGFloat(n)
            g.scope { q in
                q.c.translateBy(x: 12, y: 12)
                q.c.rotate(by: .radians(Double(tau * p * (g.active ? 1 : 1))))
                q.stroke(circ(.zero, r), g.small ? 1.35 : 1.05, 1, dash: [0.01, gap])
            }
            if !g.small { g.fill(circ(c0, 0.9), 0.5) }

        case .atom:
            let spin = (.pi / 3) * p * boost.rounded(.up)
            for i in 0..<(g.small ? 2 : 3) {
                let base = g.small ? CGFloat(i) * .pi / 2 + rad(35) : CGFloat(i) * .pi / 3
                g.stroke(ellipseArc(c0, 10, 3.9, base + spin + rad(-30), 0, tau), 0.9)
            }
            g.fill(circ(c0, g.small ? 2.2 : 1.9))
            if g.live && !g.small {
                let a = tau * p * 2
                let q = pt(12 + 10 * cos(a), 12 + 3.9 * sin(a))
                g.fill(circ(rotated(q, spin + rad(-30), about: c0), 1.2))
            }

        case .planet:
            let tilt = rad(-22 + 5 * boost * sin(tau * p))
            let planet = circ(c0, 5.8)
            let back = ellipseArc(c0, 10.8, 3.4, tilt, .pi, tau)
            let front = ellipseArc(c0, 10.8, 3.4, tilt, 0, .pi)
            g.scope { q in
                q.c.clip(to: planet, options: .inverse)
                q.stroke(back, 0.9, 0.55)
            }
            g.stroke(planet)
            g.stroke(front)

        case .comet:
            let d = CGPoint(x: -0.7071, y: 0.7071), n = CGPoint(x: 0.7071, y: 0.7071)
            let sh = (g.live ? sin(tau * p) : 0) * 1.2 * boost
            let head = pt(16.5 - sh * 0.7071, 7.5 + sh * 0.7071)
            g.fill(circ(head, g.small ? 3.0 : 2.7))
            let lens: [CGFloat] = [12.5, 9, 8]
            for (i, k) in [CGFloat(0), -2.4, 2.4].enumerated() {
                let start = pt(head.x + n.x * k + d.x * 3.4, head.y + n.y * k + d.y * 3.4)
                let l = lens[i] + (g.live ? 1.2 * cos(tau * p + CGFloat(i)) : 0)
                g.stroke(seg(start, pt(start.x + d.x * l, start.y + d.y * l)), i == 0 ? 1 : 0.8, i == 0 ? 1 : 0.55)
            }

        case .galaxy:
            let rot = tau * p * (g.active ? 1 : 0.5) + 0.4
            for k in 0..<2 {
                let arm = Path { q in
                    for i in 0...46 {
                        let t = CGFloat(i) / 46
                        let a = rot + CGFloat(k) * .pi + t * 2.3 * .pi
                        let r = 1.8 + t * 8.4
                        let pnt = pt(12 + r * cos(a), 12 + r * sin(a))
                        if i == 0 { q.move(to: pnt) } else { q.addLine(to: pnt) }
                    }
                }
                g.stroke(arm, 1, k == 0 ? 1 : 0.6)
            }
            g.fill(circ(c0, 1.7))

        case .neuron:
            let angles: [CGFloat] = [-80, -15, 45, 115, 190]
            let lens: [CGFloat] = [9.5, 8.6, 9.2, 8.4, 9.6]
            for (i, a) in angles.enumerated() {
                let r0 = rad(a)
                let from = pt(12 + 3 * cos(r0), 12 + 3 * sin(r0))
                let to = pt(12 + lens[i] * cos(r0), 12 + lens[i] * sin(r0))
                g.stroke(seg(from, to), 0.9, 0.7)
                g.fill(circ(to, g.small ? 1.4 : 1.2))
                if !g.small && i % 2 == 0 {
                    let mid = pt(12 + lens[i] * 0.62 * cos(r0), 12 + lens[i] * 0.62 * sin(r0))
                    let b = r0 + rad(i == 2 ? -38 : 38)
                    g.stroke(seg(mid, pt(mid.x + 3.6 * cos(b), mid.y + 3.6 * sin(b))), 0.8, 0.7)
                }
            }
            g.fill(circ(c0, 3.2))
            if g.live {
                let k = Int(p * 5) % 5, u = p * 5 - floor(p * 5)
                let r0 = rad(angles[k]), rr = 3 + (lens[k] - 3) * (1 - u)
                g.fill(circ(pt(12 + rr * cos(r0), 12 + rr * sin(r0)), 1.5))
            }

        case .chip:
            g.stroke(rect(7, 7, 17, 17, r: 1.8))
            let pins: [CGFloat] = g.small ? [10, 14] : [9.5, 12, 14.5]
            for v in pins {
                g.stroke(seg(pt(v, 3.5), pt(v, 7)), 0.9); g.stroke(seg(pt(v, 17), pt(v, 20.5)), 0.9)
                g.stroke(seg(pt(3.5, v), pt(7, v)), 0.9); g.stroke(seg(pt(17, v), pt(20.5, v)), 0.9)
            }
            let beat: Double = g.live ? 0.35 + 0.65 * Double(0.5 + 0.5 * sin(tau * p * 2)) : 1
            g.fill(rect(10.2, 10.2, 13.8, 13.8, r: 0.8), beat)

        case .terminal:
            g.stroke(rect(3, 4.5, 21, 19.5, r: 2.6))
            g.stroke(poly([pt(7, 9.6), pt(10.6, 12), pt(7, 14.4)]))
            let blink: Double = g.live ? (p < 0.5 ? 1 : 0.1) : 1
            g.stroke(seg(pt(13, 15), pt(17, 15)), 1, blink)

        case .globe:
            let r: CGFloat = 9.3
            g.stroke(circ(c0, r))
            g.stroke(seg(pt(12 - r, 12), pt(12 + r, 12)), 0.8, 0.8)
            let th = g.live ? .pi * p : (g.small ? 0 : 0.2) * .pi
            func mer(_ a: CGFloat, _ o: Double) {
                let rx = r * abs(cos(a))
                if rx > 0.8 { g.stroke(ellipseArc(c0, rx, r, 0, 0, tau), 0.8, o) }
            }
            mer(g.small ? .pi / 2 * 0.62 : 1.12 + th, 1)
            if !g.small { mer(1.12 + th + .pi / 2, 0.55) }

        case .compass:
            g.stroke(circ(c0, 9.6))
            if !g.small { g.stroke(seg(pt(12, 3.2), pt(12, 5)), 0.8) }
            let swing = g.live ? 24 * boost * sin(tau * p) : 0
            let a = rad(38 + swing)
            func r(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rotated(pt(12 + x, 12 + y), a, about: c0) }
            g.fill(poly([r(0, -6.8), r(2.3, 0), r(-2.3, 0)], closed: true))
            g.stroke(poly([r(0, 6.8), r(2.3, 0), r(-2.3, 0)], closed: true), 0.8)

        case .prism:
            g.stroke(poly([pt(11, 4.5), pt(19, 18.5), pt(3.5, 18.5)], closed: true))
            g.stroke(seg(pt(1.5, 13.4), pt(7.3, 11.6)), 1, 1)
            if !g.small { g.stroke(seg(pt(7.3, 11.6), pt(15.1, 12.2)), 0.7, 0.4) }
            let sh: CGFloat = g.live ? sin(tau * p) * 0.5 * boost : 0
            let ends: [(CGFloat, Double)] = [(8.3, 1), (12.4, 0.6), (16.6, 0.3)]
            for (i, e) in ends.enumerated() {
                let wob = i == 1 ? 0 : (i == 0 ? sh : -sh)
                g.stroke(seg(pt(15.1, 12.2), pt(22.5, e.0 + wob)), 1, e.1)
            }

        case .wave:
            let ph = tau * p * (g.live ? 1 : 0) + 0.2
            func sine(_ amp: CGFloat, _ shift: CGFloat) -> Path {
                Path { q in
                    for i in 0...60 {
                        let x = 2 + CGFloat(i) * 20.0 / 60
                        let y = 12 + amp * sin((x - 2) / 20 * tau * 1.5 + ph + shift)
                        if i == 0 { q.move(to: pt(x, y)) } else { q.addLine(to: pt(x, y)) }
                    }
                }
            }
            if !g.small { g.stroke(sine(3, .pi / 2), 0.8, 0.35) }
            g.stroke(sine(6, 0))

        case .infinity:
            let path = Path { q in
                for i in 0...90 {
                    let t = CGFloat(i) / 90 * tau
                    let den = 1 + sin(t) * sin(t)
                    let pnt = pt(12 + 9.6 * cos(t) / den, 12 + 9.6 * 1.45 * sin(t) * cos(t) / den)
                    if i == 0 { q.move(to: pnt) } else { q.addLine(to: pnt) }
                }
                q.closeSubpath()
            }
            if g.live {
                g.stroke(path, 1, 0.35)
                let a = p, b = min(1, p + 0.3)
                g.stroke(path.trimmedPath(from: a, to: b), 1.1)
                if p > 0.7 { g.stroke(path.trimmedPath(from: 0, to: p + 0.3 - 1), 1.1) }
            } else {
                g.stroke(path)
            }

        case .key:
            let sway = g.live ? rad(7 * boost) * sin(tau * p) : 0
            g.scope { q in
                q.c.translateBy(x: 12, y: 12)
                q.c.rotate(by: .radians(Double(rad(-40) + sway)))
                q.c.translateBy(x: -12, y: -12)
                q.stroke(circ(pt(6.4, 12), 3.7))
                q.stroke(seg(pt(10.1, 12), pt(21.5, 12)))
                q.stroke(seg(pt(17.2, 12), pt(17.2, 16)))
                q.stroke(seg(pt(20.6, 12), pt(20.6, 15)))
            }

        case .music:
            let bob: CGFloat = g.live ? 0.9 * sin(tau * p) * boost : 0
            let h1 = pt(7.4, 18.2 + bob), h2 = pt(16.4, 16.4 - bob)
            for h in [h1, h2] {
                g.scope { q in
                    q.c.translateBy(x: h.x, y: h.y)
                    q.c.rotate(by: .radians(Double(rad(-20))))
                    q.fill(Path(ellipseIn: CGRect(x: -2.9, y: -2.1, width: 5.8, height: 4.2)))
                }
            }
            g.stroke(seg(pt(h1.x + 2.5, h1.y - 0.6), pt(9.9, 6.3)))
            g.stroke(seg(pt(h2.x + 2.5, h2.y - 0.6), pt(18.9, 4.3)))
            g.stroke(seg(pt(9.9, 6.3), pt(18.9, 4.3)), 1.9)

        case .leaf:
            let sway = g.live ? rad(5 * boost) * sin(tau * p) : 0
            g.scope { q in
                q.c.translateBy(x: 4.5, y: 19.5)
                q.c.rotate(by: .radians(Double(sway)))
                q.c.translateBy(x: -4.5, y: -19.5)
                let leaf = Path { b in
                    b.move(to: pt(4.5, 19.5))
                    b.addCurve(to: pt(19.5, 4.5), control1: pt(4.5, 10), control2: pt(10, 4.5))
                    b.addCurve(to: pt(4.5, 19.5), control1: pt(19.5, 14), control2: pt(14, 19.5))
                    b.closeSubpath()
                }
                q.stroke(leaf)
                q.stroke(seg(pt(2.8, 21.2), pt(14, 10)))
                if !g.small {
                    q.stroke(seg(pt(9, 15), pt(9.6, 11.4)), 0.8, 0.7)
                    q.stroke(seg(pt(12.2, 11.8), pt(15.6, 11.2)), 0.8, 0.7)
                }
            }

        case .lightning:
            var q = g
            if g.live { q.alpha = (p > 0.62 && p < 0.7) || (p > 0.76 && p < 0.79) ? 0.25 : 1 }
            let bolt = poly([pt(13.8, 2.8), pt(5.6, 13.4), pt(11.4, 13.4), pt(10, 21.2), pt(18.4, 10.2), pt(12.6, 10.2)], closed: true)
            q.fill(bolt)
            q.stroke(bolt, 0.6)

        case .eye:
            let blinkAmt: CGFloat = g.live ? (p > 0.88 ? sin((p - 0.88) / 0.12 * .pi) : 0) : 0
            let look: CGFloat = g.live ? 2.2 * sin(tau * p * 1) * (p > 0.88 ? 0 : 1) : 0
            g.scope { q in
                q.c.translateBy(x: 12, y: 12)
                q.c.scaleBy(x: 1, y: 1 - 0.92 * blinkAmt)
                q.c.translateBy(x: -12, y: -12)
                q.stroke(Path { b in
                    b.move(to: pt(2, 12)); b.addQuadCurve(to: pt(22, 12), control: pt(12, 2.6))
                    b.addQuadCurve(to: pt(2, 12), control: pt(12, 21.4))
                })
                q.stroke(circ(pt(12 + look, 12), 3.5), 1)
                q.fill(circ(pt(12 + look, 12), 1.4))
            }

        case .scales:
            let ang = g.live ? rad(7 * boost) * sin(tau * p) : rad(5)
            g.stroke(seg(pt(12, 4), pt(12, 20))); g.stroke(seg(pt(8, 20.5), pt(16, 20.5)))
            let l = rotated(pt(3.6, 7.2), ang, about: pt(12, 7.2)), r = rotated(pt(20.4, 7.2), ang, about: pt(12, 7.2))
            g.stroke(seg(l, r))
            for e in [l, r] {
                g.stroke(poly([pt(e.x - 3, e.y + 6.6), e, pt(e.x + 3, e.y + 6.6)]), 0.8, 0.8)
                g.stroke(Path { b in
                    b.move(to: pt(e.x - 3.6, e.y + 6.6)); b.addLine(to: pt(e.x + 3.6, e.y + 6.6))
                    b.addQuadCurve(to: pt(e.x - 3.6, e.y + 6.6), control: pt(e.x, e.y + 10.6))
                })
            }

        case .rocket:
            let shake: CGFloat = g.live ? 0.5 * sin(tau * p * 6) * boost : 0
            g.scope { q in
                q.c.translateBy(x: 12 + shake, y: 12)
                q.c.rotate(by: .radians(Double(rad(45))))
                q.c.translateBy(x: -12, y: -12)
                q.stroke(Path { b in
                    b.move(to: pt(12, 2.2)); b.addQuadCurve(to: pt(16, 12.5), control: pt(16, 6.8))
                    b.addLine(to: pt(16, 16.6)); b.addLine(to: pt(8, 16.6)); b.addLine(to: pt(8, 12.5))
                    b.addQuadCurve(to: pt(12, 2.2), control: pt(8, 6.8))
                })
                q.stroke(poly([pt(8, 12.6), pt(5.2, 17), pt(8, 16.6)]))
                q.stroke(poly([pt(16, 12.6), pt(18.8, 17), pt(16, 16.6)]))
                if !g.small { q.stroke(circ(pt(12, 9.6), 1.7), 0.9) }
                let flame: CGFloat = g.live ? 1 + 0.35 * sin(tau * p * 5) : 1
                q.stroke(poly([pt(10.4, 19), pt(12, 19 + 3.4 * flame), pt(13.6, 19)]), 1, 0.9)
            }

        case .gear:
            let teeth = g.small ? 6 : 8
            let step = tau / CGFloat(teeth)
            let rot = step * p * boost.rounded(.up)
            let outline = Path { b in
                for i in 0..<teeth {
                    let a = CGFloat(i) * step + rot
                    let ws: [(CGFloat, CGFloat)] = [(-0.30, 7.3), (-0.17, 9.7), (0.17, 9.7), (0.30, 7.3)]
                    for w in ws {
                        let pnt = pt(12 + w.1 * cos(a + w.0 * step * 1.4), 12 + w.1 * sin(a + w.0 * step * 1.4))
                        if i == 0 && w.0 == -0.30 { b.move(to: pnt) } else { b.addLine(to: pnt) }
                    }
                }
                b.closeSubpath()
            }
            g.stroke(outline)
            g.stroke(circ(c0, 2.8))

        case .star:
            let pulse: CGFloat = g.live ? 1 + 0.08 * boost * sin(tau * p * 2) : 1
            let rot: CGFloat = g.live ? rad(6 * boost) * sin(tau * p) : 0
            g.scope { q in
                q.c.translateBy(x: 12, y: 12.8)
                q.c.rotate(by: .radians(Double(rot)))
                q.c.scaleBy(x: pulse, y: pulse)
                var pts: [CGPoint] = []
                for i in 0..<10 {
                    let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                    let r: CGFloat = i % 2 == 0 ? 9.6 : 4.4
                    pts.append(pt(r * cos(a), r * sin(a)))
                }
                q.stroke(poly(pts, closed: true))
            }

        case .orbit:
            if !g.small { g.stroke(circ(c0, 7.6), 0.6, 0.3) }
            g.fill(circ(c0, g.small ? 2.0 : 1.7))
            let start: [CGFloat] = [-90, 30, 150]
            for (i, a0) in start.enumerated() {
                let a = rad(a0) + (g.live ? tau * p : 0)
                g.fill(circ(pt(12 + 7.6 * cos(a), 12 + 7.6 * sin(a)), (i == 0 ? 2.1 : 1.6) * (g.small ? 1.25 : 1)), i == 0 ? 1 : 0.8)
            }

        case .scan:
            let m = g.small ? 4.0 : 4.6
            let k: CGFloat = 3.2
            let lo: CGFloat = k, hi: CGFloat = 24 - k
            for (cx, cy, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                g.stroke(poly([pt(cx, cy + dy * CGFloat(m)), pt(cx, cy), pt(cx + dx * CGFloat(m), cy)]))
            }
            let y = 12 + (g.live ? 5.5 * sin(tau * p) : 0)
            g.stroke(seg(pt(6.2, y), pt(17.8, y)), 1)
            if !g.small {
                g.stroke(seg(pt(8, y - 1.8), pt(16, y - 1.8)), 0.6, 0.3)
                g.stroke(seg(pt(8, y + 1.8), pt(16, y + 1.8)), 0.6, 0.3)
            }

        case .emptyVoid:
            // The horizon with nothing falling in: dark centre, a hairline photon ring, one lensed arc, a faint breathing halo.
            let br: CGFloat = g.live ? sin(tau * p) : 0
            let hr: CGFloat = g.small ? 5.2 : 4.9
            g.stroke(circ(pt(12, 12), hr + 1.0), 0.85, 1)
            let over = Path { b in
                for i in 0...32 {
                    let a = rad(200) + rad(140) * CGFloat(i) / 32
                    let x = 12 + 8.2 * cos(a), y = 12 + 8.0 * sin(a)
                    if i == 0 { b.move(to: pt(x, y)) } else { b.addLine(to: pt(x, y)) }
                }
            }
            g.stroke(over, 0.9, 0.75)
            if !g.small { g.stroke(circ(c0, 10.2 + br * 0.9), 0.55, Double(0.28 + 0.12 * br)) }

        case .spark:
            let pulse: CGFloat = g.live ? 1 + 0.1 * sin(tau * p) * boost : 1
            func star4(_ c: CGPoint, _ r: CGFloat) -> Path {
                let k = r * 0.12
                return Path { b in
                    b.move(to: pt(c.x, c.y - r)); b.addQuadCurve(to: pt(c.x + r, c.y), control: pt(c.x + k, c.y - k))
                    b.addQuadCurve(to: pt(c.x, c.y + r), control: pt(c.x + k, c.y + k))
                    b.addQuadCurve(to: pt(c.x - r, c.y), control: pt(c.x - k, c.y + k))
                    b.addQuadCurve(to: pt(c.x, c.y - r), control: pt(c.x - k, c.y - k))
                    b.closeSubpath()
                }
            }
            let big = star4(pt(10.8, 13.2), 8.6 * pulse)
            g.fill(big); g.stroke(big, 0.5)
            let tw: Double = g.live ? 0.4 + 0.6 * Double(0.5 + 0.5 * sin(tau * p * 2 + 1)) : 1
            g.fill(star4(pt(19, 5.2), 3.4), tw)

        case .check:
            if !g.small { g.stroke(circ(c0, 9.8), 0.7, 0.35) }
            let ck = poly([pt(6.6, 12.6), pt(10.6, 16.6), pt(17.6, 8)])
            let t: CGFloat = g.live ? min(1, ease(p / 0.45)) : 1
            let fade: Double = g.live && p > 0.88 ? Double(max(0, 1 - (p - 0.88) / 0.12)) : 1
            g.faded(fade).stroke(ck.trimmedPath(from: 0, to: max(0.001, t)), 1.15)

        case .warning:
            let tri = Path { b in
                b.move(to: pt(12, 3.6)); b.addLine(to: pt(21, 19.4)); b.addLine(to: pt(3, 19.4)); b.closeSubpath()
            }
            g.stroke(tri)
            let mark: Double = g.live ? 0.55 + 0.45 * Double(0.5 + 0.5 * sin(tau * p * 2)) : 1
            g.stroke(seg(pt(12, 9.6), pt(12, 14)), 1.1, mark)
            g.fill(circ(pt(12, 16.8), g.small ? 1.1 : 1.0), mark)
        }
    }
}

// MARK: - Gallery (--glyphshots)

enum GlyphGallery {
    private struct Sheet: View {
        let dark: Bool

        var body: some View {
            let bg = dark ? Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255) : Color(red: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF3 / 255)
            let ink = dark ? Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xEE / 255) : Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255)
            let cols = 6
            let kinds = GlyphKind.allCases
            let rows = stride(from: 0, to: kinds.count, by: cols).map { Array(kinds[$0..<min($0 + cols, kinds.count)]) }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(rows[r], id: \.self) { k in
                            VStack(spacing: 8) {
                                HStack(alignment: .center, spacing: 14) {
                                    Glyph(kind: k, size: 16, color: k == .warning ? nil : ink)
                                    Glyph(kind: k, size: 24, color: k == .warning ? nil : ink)
                                    Glyph(kind: k, size: 48, color: k == .warning ? nil : ink)
                                }
                                .frame(height: 48)
                                Text(k.title.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(ink.opacity(0.55))
                            }
                            .frame(width: 150)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 150 * CGFloat(cols) + 48, alignment: .leading)
            .background(bg)
        }
    }

    private struct Strips: View {
        let dark: Bool
        let kinds: [GlyphKind]

        var body: some View {
            let bg = dark ? Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255) : Color(red: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF3 / 255)
            let ink = dark ? Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xEE / 255) : Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(kinds, id: \.self) { k in
                    HStack(spacing: 12) {
                        Text(k.title.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(ink.opacity(0.55))
                            .frame(width: 70, alignment: .leading)
                        ForEach([0.0, 0.25, 0.5, 0.75], id: \.self) { ph in
                            Glyph(kind: k, size: 48, color: k == .warning ? nil : ink, phase: ph)
                        }
                    }
                }
            }
            .padding(20)
            .background(bg)
        }
    }

    @MainActor
    static func renderShots(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modes: [(String, Bool, NSAppearance)] = [("dark", true, NSAppearance(named: .darkAqua)!), ("light", false, NSAppearance(named: .aqua)!)]
        let all = GlyphKind.allCases
        let half = (all.count + 1) / 2
        var written = 0
        func write(_ image: CGImage?, _ name: String) {
            let file = dir.appendingPathComponent(name)
            if let image, (try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)) != nil {
                written += 1
                print("wrote \(file.path)")
            } else {
                print("FAILED \(file.path)")
            }
        }
        for (mode, dark, appearance) in modes {
            NSApp.appearance = appearance
            let cols = 6
            let sheetSize = CGSize(width: 150 * CGFloat(cols) + 48, height: CGFloat((all.count + cols - 1) / cols) * 82 + 48)
            write(image(Sheet(dark: dark), size: sheetSize, appearance: appearance), "glyphs-\(mode).png")
            let stripSize = CGSize(width: 70 + 4 * 60 + 12 * 4 + 40, height: CGFloat(half) * 58 + 40)
            write(image(Strips(dark: dark, kinds: Array(all[..<half])), size: stripSize, appearance: appearance), "strips-1-\(mode).png")
            write(image(Strips(dark: dark, kinds: Array(all[half...])), size: stripSize, appearance: appearance), "strips-2-\(mode).png")
        }
        print("glyph shots: \(written) written to \(dir.path)")
    }

    /// Rendered at 2x so 16pt glyphs show their real retina pixels.
    @MainActor
    private static func image<V: View>(_ view: V, size: CGSize, appearance: NSAppearance) -> CGImage? {
        let scaled = view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(2, anchor: .topLeading)
            .frame(width: size.width * 2, height: size.height * 2, alignment: .topLeading)
        let host = NSHostingView(rootView: scaled)
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}
