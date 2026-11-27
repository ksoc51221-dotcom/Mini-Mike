import SwiftUI

// The circle of small radial bars round the Spotify record. At rest it is a ring of short ticks; each new note of the
// lead line (`LeadMeter`) makes a group of 3 or 5 neighbour bars jump out at an angle set by its pitch height. Drum
// hits make no spike, because only notes change `BeatSample.leadNote`.

/// One view's bars in motion. Pure numbers, so the tests drive it without a view. A class so the view's `TimelineView`
/// advances it in place.
final class MelodyBarsMotion {
    /// Bars on the whole circle.
    static let count = 104
    static let lineWidth: CGFloat = 2
    /// A resting bar's length: almost a dot.
    static let tick = 1.5
    /// A spike jumps out in this time...
    static let attack = 0.06
    /// ...and falls with this time constant: about a tenth is left after 0.25 s.
    static let fallTime = 0.11
    /// A held note keeps its spike at this share of the peak.
    static let holdShare = 0.55
    /// With no clear note for this long, a slow soft motion takes over.
    static let quietAfter = 1.5
    static let idleHeight = 0.14
    static let maxSpikes = 7
    private static let wideShape = [0.32, 0.68, 1, 0.68, 0.32]
    private static let narrowShape = [0.55, 1, 0.55]

    struct Spike {
        var bar: Int
        var from: Double
        var peak: Double
        var value: Double
        var age = 0.0
        var held = true
    }

    /// The angle in radians (0 right, a quarter turn down, as `Canvas` draws) for a pitch height 0...1. The disc shows
    /// only its left half, so its notes run from the bottom (low) over the left to the top (high). The mini window uses
    /// nearly the whole circle.
    static func angle(pitch: Double, half: Bool) -> Double {
        let p = BeatMath.clamp01(pitch)
        let degrees = half ? 100 + 160 * p : 105 + 330 * p
        return degrees * .pi / 180
    }

    static func angle(bar: Int) -> Double { Double(bar) * 2 * .pi / Double(count) }

    static func bar(pitch: Double, half: Bool) -> Int {
        Int((angle(pitch: pitch, half: half) / (2 * .pi) * Double(count)).rounded()) % count
    }

    /// The half of the disc's ring past the screen edge is not drawn.
    static func visible(bar: Int, half: Bool) -> Bool { !half || cos(angle(bar: bar)) <= 0.02 }

    private(set) var spikes: [Spike] = []
    /// Each bar's height, 0 (a resting tick) to 1 (the longest).
    private(set) var heights = [Double](repeating: 0, count: MelodyBarsMotion.count)
    private var lastTime: Double?
    private var lastNote = 0
    private var sinceNote = 0.0
    private var idle = 0.0
    private var clock = 0.0
    private(set) var energy = 0.0
    private var settleStart: Double?
    private var wasMoving = false

    /// One frame at `now` (seconds). `moving`: a song plays (or pauses with the soft motion) and the dock shows.
    func advance(to now: Double, sample: BeatSample, moving: Bool, half: Bool) {
        let dt = lastTime.map { min(max(now - $0, 0), 1.0 / 20) } ?? 0
        lastTime = now
        guard dt > 0 || !moving else { return }
        if moving {
            energy = 1
            settleStart = nil
        } else if wasMoving || settleStart != nil {
            if settleStart == nil { settleStart = now }
            let p = min(1, (now - (settleStart ?? now)) / Motion.edgeSettleDuration)
            energy = 1 - Motion.edgeSettleCurve.value(at: p)
            if p >= 1 { rest() }
        }
        wasMoving = moving
        guard dt > 0 else { return }
        clock += dt
        for i in spikes.indices { step(i, dt: dt, lead: moving ? sample.lead : 0) }
        spikes.removeAll { $0.age > Self.attack && !$0.held && $0.value < 0.01 }
        if moving {
            sinceNote += dt
            if sample.leadNote != lastNote {
                lastNote = sample.leadNote
                if sample.lead > 0.05 { add(pitch: sample.leadPitch, strength: sample.lead, half: half) }
            }
            if sample.lead > 0.1 { sinceNote = 0 }
        }
        let quiet = sinceNote >= Self.quietAfter
        idle += ((quiet ? 1 : 0) - idle) * (1 - exp(-dt / (quiet ? 0.5 : 0.08)))
        shape()
    }

    private func step(_ i: Int, dt: Double, lead: Double) {
        spikes[i].age += dt
        let s = spikes[i]
        if s.age <= Self.attack {
            let u = 1 - s.age / Self.attack
            spikes[i].value = s.from + (s.peak - s.from) * (1 - u * u * u)
        } else {
            if s.held && lead <= 0.1 { spikes[i].held = false }
            let target = spikes[i].held ? s.peak * Self.holdShare : 0
            // The frame that ends the attack starts from the peak.
            let start = s.age - dt < Self.attack ? s.peak : s.value
            spikes[i].value = target + (start - target) * exp(-dt / Self.fallTime)
        }
    }

    private func add(pitch: Double, strength: Double, half: Bool) {
        let bar = Self.bar(pitch: pitch, half: half)
        for i in spikes.indices { spikes[i].held = false }
        // The same place again: grow from where that spike stands, so it never snaps down.
        var from = 0.0
        if let same = spikes.firstIndex(where: { abs($0.bar - bar) <= 1 }) {
            from = spikes[same].value
            spikes.remove(at: same)
        }
        if spikes.count >= Self.maxSpikes { spikes.removeFirst() }
        let peak = 0.55 + 0.45 * BeatMath.clamp01(strength)
        spikes.append(Spike(bar: bar, from: from, peak: peak, value: from))
        sinceNote = 0
    }

    private func shape() {
        for i in 0..<Self.count {
            let wave = 0.5 + 0.5 * sin(3 * Self.angle(bar: i) - 1.2 * clock)
            heights[i] = Self.idleHeight * idle * wave * wave
        }
        for s in spikes {
            let shape = s.peak > 0.72 ? Self.wideShape : Self.narrowShape
            for (k, weight) in shape.enumerated() {
                let i = (s.bar + k - shape.count / 2 + Self.count) % Self.count
                heights[i] = max(heights[i], s.value * weight)
            }
        }
        for i in 0..<Self.count { heights[i] = BeatMath.clamp01(heights[i] * energy) }
    }

    /// The still ring of ticks (a pause, `Motion.still`, Reduce Motion).
    func rest() {
        spikes.removeAll(keepingCapacity: true)
        heights.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        energy = 0
        idle = 0
        sinceNote = 0
        settleStart = nil
    }

    /// A fixed frame for the pictures: the pinned note at full height and two earlier ones still falling; a sample with
    /// no note is the still ring.
    func pin(_ sample: BeatSample, half: Bool) {
        rest()
        guard sample.lead > 0 else { return }
        energy = 1
        for (pitch, value) in [(sample.leadPitch * 0.35, 0.4), (sample.leadPitch * 0.65, 0.65), (sample.leadPitch, 1.0)] {
            let peak = 0.55 + 0.45 * sample.lead
            spikes.append(Spike(bar: Self.bar(pitch: pitch, half: half), from: 0, peak: peak, value: peak * value))
        }
        shape()
    }

    /// The ticks and the raised bars as two paths: they start just outside the record and, round caps included, never
    /// pass `place.limit`.
    func paths(center c: CGPoint, place: BeatStrings.Place, half: Bool) -> (ticks: Path, raised: Path) {
        let start = Double(place.inner) + Double(Self.lineWidth) / 2
        let longest = Double(place.limit - Self.lineWidth / 2) - start
        var ticks = Path(), raised = Path()
        for i in 0..<Self.count where Self.visible(bar: i, half: half) {
            let a = Self.angle(bar: i), x = cos(a), y = sin(a)
            let end = start + Self.tick + heights[i] * (longest - Self.tick)
            let from = CGPoint(x: c.x + start * x, y: c.y + start * y), to = CGPoint(x: c.x + end * x, y: c.y + end * y)
            if heights[i] < 0.04 {
                ticks.move(to: from); ticks.addLine(to: to)
            } else {
                raised.move(to: from); raised.addLine(to: to)
            }
        }
        return (ticks, raised)
    }
}

/// The bars round the record. One `TimelineView` runs only while `moving` (and for the short settle after it), at 60
/// frames a second at most. A still ring under `Motion.still` and Reduce Motion; a pinned sample
/// (the pictures) draws one fixed frame.
struct MelodyBars: View {
    let palette: DockPalette
    var place: BeatStrings.Place = .disc
    var beat: SpotifyBeat?
    var moving = false
    @State private var motion = MelodyBarsMotion()
    @State private var settling = false
    @State private var settleToken = 0

    /// The bars move only while a song plays and the dock shows. A paused song (and no song) gives a still ring and
    /// no redraws once it settles: the paused pulse of the old strings is not kept.
    static func moves(playing: Bool, shown: Bool) -> Bool { playing && shown }

    /// Only the mini window shows the whole circle.
    private var half: Bool { place != .card }

    var body: some View {
        Group {
            if let pinned = beat?.pinned, moving {
                bars { motion.pin(pinned, half: half) }
            } else if beat?.pinned != nil || Motion.still || Motion.reduceMotion {
                bars { motion.rest() }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !(moving || settling))) { ctx in
                    let now = ctx.date.timeIntervalSinceReferenceDate
                    bars {
                        let sample = moving ? (beat?.sample(now: now) ?? .zero) : .zero
                        motion.advance(to: now, sample: sample, moving: moving, half: half)
                    }
                }
            }
        }
        .onChange(of: moving) { _, on in
            settleToken += 1
            settling = !on
            guard !on else { return }
            let token = settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.edgeSettleDuration + 0.1) {
                if settleToken == token { settling = false }
            }
        }
        .allowsHitTesting(false)
    }

    private func bars(_ prepare: @escaping () -> Void) -> some View {
        let p = palette, m = motion, place = place, half = half
        return Canvas { gc, size in
            prepare()
            DockPerf.tick("bars")
            let paths = m.paths(center: CGPoint(x: size.width / 2, y: size.height / 2), place: place, half: half)
            let style = StrokeStyle(lineWidth: MelodyBarsMotion.lineWidth, lineCap: .round)
            gc.stroke(paths.ticks, with: .color(p.accentColor.opacity(0.65)), style: style)
            gc.stroke(paths.raised, with: .color(p.accentColor), style: style)
        }
    }
}
