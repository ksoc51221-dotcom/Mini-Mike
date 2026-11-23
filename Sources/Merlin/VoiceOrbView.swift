import SwiftUI

/// The numbers behind the voice orb, kept apart from the drawing so they can be checked.
enum OrbMath {
    /// The rings follow the loudness with this spring (mass 1). Critical damping for stiffness 50 is 2·√50 ≈ 14.1;
    /// 15 is a little over it, so the rings settle without a bounce.
    static let ringStiffness: Double = 50
    static let ringDamping: Double = 15
    /// The wave follows the loudness faster (critical damping for 400 is 40).
    static let waveStiffness: Double = 400
    static let waveDamping: Double = 42

    /// The idle ripple: a 1.2 s loop, each point along the line 0.2 s behind the one before, eased in and out.
    static let idleLoop: Double = 1.2
    static let idleStagger: Double = 0.2
    static let idlePoints = 7
    /// The key-press ripple ring: scale 1 → 2.2, opacity 0.8 → 0, 0.5 s, ease-out, once.
    static let rippleDuration: Double = 0.5

    struct Spring: Equatable {
        var value: Double = 0
        var velocity: Double = 0

        /// Moves toward `target` by `dt` seconds (small fixed steps, so a long frame can't blow up).
        mutating func step(toward target: Double, dt: Double, stiffness: Double, damping: Double) {
            var left = min(max(dt, 0), 0.25)
            while left > 0 {
                let h = min(left, 1.0 / 240)
                let force = -stiffness * (value - target) - damping * velocity
                velocity += force * h
                value += velocity * h
                left -= h
            }
        }
    }

    /// cubic-bezier(0.42, 0, 0.58, 1) is close to this.
    static func easeInOut(_ p: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(max(p, 0), 1)) }
    static func easeOut(_ p: Double) -> Double { let q = 1 - min(max(p, 0), 1); return 1 - q * q * q }

    /// The key-press ripple at `elapsed` seconds: (scale, opacity), or nil once it's over.
    static func ripple(at elapsed: Double) -> (scale: Double, opacity: Double)? {
        guard elapsed >= 0, elapsed < rippleDuration else { return nil }
        let p = easeOut(elapsed / rippleDuration)
        return (1 + 1.2 * p, 0.8 * (1 - p))
    }

    /// The idle ripple's height at point `i` of `idlePoints` (−1…1), at time `t`. Each point goes up and back down once per
    /// loop (a mirrored ease-in-out), 0.2 s behind its neighbour.
    static func idleNode(_ i: Int, at t: Double) -> Double {
        var phase = (t - Double(i) * idleStagger) / idleLoop
        phase -= phase.rounded(.down)
        let tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return easeInOut(tri) * 2 - 1
    }

    /// Where the line is at `u` (0 at its left end, 1 at its right) as a share of the orb's radius. `level` (0…1) is how
    /// loud it is. Both ends stay on the centre line.
    static func wave(at u: Double, t: Double, level: Double, idle: Bool = true) -> Double {
        let u = min(max(u, 0), 1)
        let envelope = sin(.pi * u)
        // The idle ripple, smoothly joined between its points.
        var rest = 0.0
        if idle {
            let x = u * Double(idlePoints - 1)
            let i = min(Int(x), idlePoints - 2)
            let f = easeInOut(x - Double(i))
            rest = (idleNode(i, at: t) * (1 - f) + idleNode(i + 1, at: t) * f) * 0.045
        }
        let quiet = 1 - min(1, level * 3)
        let loud = level * 0.58 * (0.62 * sin(2 * .pi * 2.3 * u + 7.1 * t) + 0.38 * sin(2 * .pi * 4.1 * u - 10.3 * t + 1.3))
        return envelope * (rest * quiet + loud)
    }
}

/// The springs and the ripple's start, carried from frame to frame (a class, so drawing a frame can move them on).
final class OrbMotion {
    var ring = OrbMath.Spring()
    var wave = OrbMath.Spring()
    var lastTime: Double?
    var rippleStart: Date?

    func advance(to time: Double, level: Double) {
        let dt = lastTime.map { time - $0 } ?? 0
        lastTime = time
        ring.step(toward: level, dt: dt, stiffness: OrbMath.ringStiffness, damping: OrbMath.ringDamping)
        wave.step(toward: level, dt: dt, stiffness: OrbMath.waveStiffness, damping: OrbMath.waveDamping)
    }
}

/// A black orb with a soft glow at its edge, one white sound-wave line across its centre, and three thin rings around it.
/// Loudness lifts the wave and makes the rings wobble; while Merlin transcribes, the rings turn slowly and the line rests.
/// Drawn with `Canvas` in a `TimelineView` that only runs while listening or transcribing; Reduce Motion and pictures
/// get one fixed frame.
struct VoiceOrb: View {
    enum Mood: Equatable { case listening, working, calm }

    let mood: Mood
    let level: Float
    let pressCount: Int
    static let diameter: CGFloat = 72
    /// Room for the rings and the ripple (it grows to 2.2× the orb).
    static let canvas: CGFloat = 164

    @State private var motion = OrbMotion()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let still = Motion.still || Motion.reduceMotion
        let running = !still && mood != .calm
        TimelineView(.animation(minimumInterval: nil, paused: !running)) { timeline in
            Canvas { context, size in
                let time = still ? 0.35 : timeline.date.timeIntervalSinceReferenceDate
                if still {
                    motion.ring.value = Double(level)
                    motion.wave.value = Double(level)
                } else {
                    motion.advance(to: time, level: mood == .listening ? Double(level) : 0)
                }
                draw(in: context, size: size, time: time, still: still, now: timeline.date)
            }
        }
        .frame(width: Self.canvas, height: Self.canvas)
        .onChange(of: pressCount) { _, _ in motion.rippleStart = Date() }
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: Double, still: Bool, now: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Self.diameter / 2
        let reduce = Motion.reduceMotion && !Motion.still
        // With Reduce Motion nothing changes size or shape: loudness shows as brightness only.
        let ringLevel = mood == .listening && !reduce ? motion.ring.value : 0
        let waveLevel = mood == .listening ? max(0, motion.wave.value) : 0
        let dark = scheme == .dark

        // The glow at the edge: a blurred disc behind the orb (light in dark mode, a soft shade in light mode).
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 9 + 8 * ringLevel))
            let g = r + 3 + 3 * ringLevel
            glow.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: g * 2, height: g * 2)),
                      with: .color(dark ? Color.white.opacity(0.22 + 0.25 * ringLevel) : Color.black.opacity(0.30 + 0.15 * ringLevel)))
        }

        // The rings (behind the orb, so the orb's edge stays clean).
        let ringOpacity: [Double] = [0.62, 0.42, 0.26]
        for i in 0..<3 {
            let base = r + 6 + CGFloat(i) * 7
            let wobble: Double
            let spin: Double
            switch mood {
            case .listening: wobble = reduce ? 0 : 0.6 + 6.5 * ringLevel * (1 - 0.2 * Double(i)); spin = 0
            case .working: wobble = reduce ? 0 : 1.4; spin = reduce ? 0 : time * 0.35 * (i == 1 ? -1 : 1)
            case .calm: wobble = 0.6; spin = 0
            }
            let lift = CGFloat(1 + 0.06 * ringLevel)
            let path = ringPath(center: c, radius: base * lift, wobble: wobble, lobes: 3 + i, time: mood == .listening ? time : 0.8, index: i, spin: spin)
            var alpha = ringOpacity[i] * (mood == .calm ? 0.6 : 1)
            if reduce { alpha *= 0.55 + 0.45 * Double(level) } // with Reduce Motion, loudness shows as brightness only
            context.stroke(path, with: .color(.black.opacity(dark ? 0 : 0.34 * alpha / ringOpacity[0])), lineWidth: 2.6)
            context.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: 1)
        }

        // The key-press ripple.
        if !still, let start = motion.rippleStart, let ripple = OrbMath.ripple(at: now.timeIntervalSince(start)) {
            let rr = r * ripple.scale
            let path = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            if !dark { context.stroke(path, with: .color(.black.opacity(0.18 * ripple.opacity)), lineWidth: 2.6) }
            context.stroke(path, with: .color(.white.opacity(ripple.opacity)), lineWidth: 1.2)
        }

        // The orb: black, with a faint rim.
        let orb = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        context.fill(orb, with: .radialGradient(Gradient(colors: [Color(white: 0.13), Color(white: 0.02)]),
                                                center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35), startRadius: 0, endRadius: r * 1.3))
        context.stroke(orb, with: .color(.white.opacity(0.16 + 0.2 * ringLevel)), lineWidth: 0.8)

        // The sound-wave line across the centre.
        let span = r * 0.84
        var line = Path()
        let steps = 64
        let rests = mood != .listening || reduce
        for s in 0...steps {
            let u = Double(s) / Double(steps)
            let y = rests ? 0 : OrbMath.wave(at: u, t: time, level: waveLevel, idle: true) * Double(r)
            let p = CGPoint(x: c.x - span + CGFloat(u) * span * 2, y: c.y - CGFloat(y))
            if s == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        let lineAlpha = mood == .listening ? (reduce ? 0.6 + 0.4 * Double(level) : 0.95) : 0.6
        context.stroke(line, with: .color(.white.opacity(lineAlpha)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    /// A circle whose radius wobbles a little around `radius`.
    private func ringPath(center c: CGPoint, radius: CGFloat, wobble: Double, lobes: Int, time: Double, index: Int, spin: Double) -> Path {
        var path = Path()
        let n = 120
        let speed = 1.3 + 0.4 * Double(index)
        for k in 0...n {
            let theta = Double(k) / Double(n) * 2 * .pi
            let a = theta + spin
            let w = wobble * (0.6 * sin(Double(lobes) * a + time * speed + Double(index) * 1.7)
                              + 0.4 * sin(Double(lobes + 2) * a - time * speed * 1.3))
            let rr = Double(radius) + w
            let p = CGPoint(x: c.x + CGFloat(rr * cos(theta)), y: c.y + CGFloat(rr * sin(theta)))
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

extension FeatureTests {
    /// The orb's motion numbers: the springs don't bounce, the ripple's start and end, the wave's flat and loud shapes.
    static func voiceOrbChecks(_ check: (String, Bool) -> Void) {
        // The ring spring follows a jump in loudness without going past it.
        var s = OrbMath.Spring()
        var peak = 0.0
        for _ in 0..<600 { s.step(toward: 1, dt: 1.0 / 120, stiffness: OrbMath.ringStiffness, damping: OrbMath.ringDamping); peak = max(peak, s.value) }
        check("orb: the ring spring (stiffness 50) settles with no bounce", peak <= 1.0001 && abs(s.value - 1) < 0.01)
        check("orb: the ring damping is at or above critical", OrbMath.ringDamping >= 2 * OrbMath.ringStiffness.squareRoot())
        var w = OrbMath.Spring()
        var wavePeak = 0.0
        for _ in 0..<240 { w.step(toward: 0.8, dt: 1.0 / 120, stiffness: OrbMath.waveStiffness, damping: OrbMath.waveDamping); wavePeak = max(wavePeak, w.value) }
        check("orb: the wave spring is quick and doesn't bounce", wavePeak <= 0.8001 && abs(w.value - 0.8) < 0.01)
        var big = OrbMath.Spring()
        big.step(toward: 1, dt: 5, stiffness: OrbMath.ringStiffness, damping: OrbMath.ringDamping)
        check("orb: a long frame can't make the spring jump", big.value.isFinite && big.value <= 1.0001)

        // The key-press ripple: 1 → 2.2, 0.8 → 0, over 0.5 s.
        let first = OrbMath.ripple(at: 0)
        check("orb: the ripple starts at scale 1, opacity 0.8", first.map { abs($0.scale - 1) < 1e-9 && abs($0.opacity - 0.8) < 1e-9 } ?? false)
        let late = OrbMath.ripple(at: 0.4999)
        check("orb: the ripple ends near scale 2.2, opacity 0", late.map { $0.scale > 2.19 && $0.opacity < 0.01 } ?? false)
        check("orb: the ripple runs once, for 0.5 s", OrbMath.ripple(at: 0.5) == nil && OrbMath.ripple(at: -0.1) == nil)

        // The wave: flat ends, a small ripple when quiet, tall when loud.
        func tallest(_ level: Double, t: Double) -> Double { (0...100).map { abs(OrbMath.wave(at: Double($0) / 100, t: t, level: level)) }.max() ?? 0 }
        check("orb: the line's ends stay on the centre", abs(OrbMath.wave(at: 0, t: 1.7, level: 0.8)) < 1e-9 && abs(OrbMath.wave(at: 1, t: 1.7, level: 0.8)) < 1e-9)
        check("orb: silence is a near-flat line with a small idle ripple", tallest(0, t: 0.35) > 0.005 && tallest(0, t: 0.35) < 0.06)
        check("orb: loud (0.8) is a tall wave, inside the orb", tallest(0.8, t: 0.35) > 0.25 && tallest(0.8, t: 0.35) < 0.8)
        check("orb: without the idle ripple, silence is flat", tallest(0, t: 0.35) > 0 && (0...20).allSatisfy { OrbMath.wave(at: Double($0) / 20, t: 0.35, level: 0, idle: false) == 0 })
        check("orb: the idle ripple loops every 1.2 s", abs(OrbMath.idleNode(2, at: 0.3) - OrbMath.idleNode(2, at: 1.5)) < 1e-9)
        check("orb: each idle point is 0.2 s behind the one before", abs(OrbMath.idleNode(3, at: 0.9) - OrbMath.idleNode(2, at: 0.7)) < 1e-9)
    }
}
