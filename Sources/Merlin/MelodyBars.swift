import SwiftUI

// The circle of small radial bars round the Spotify record. At rest it is a ring of short ticks. With music each bar
// shows one frequency band of the sound now (`SpectrumMeter`): low notes at the bottom, high notes at the top. A bar
// rises at once and falls back with a growing speed (Cava's "gravity"), and a loud band lifts its neighbours, so a
// note shows as a group of a few bars, the middle one tallest.

/// One view's bars in motion. Pure numbers, so the tests drive it without a view. A class so the view's `TimelineView`
/// advances it in place.
final class MelodyBarsMotion {
    /// Bars on the whole circle.
    static let count = 104
    /// 2026-11-27, Merlin: "a bit more rounded, not too round" and "bounce less": a wider bar with round caps, a softer
    /// hill across neighbours, 60 % of the old reach with a soft knee at the top.
    static let lineWidth: CGFloat = 2.6
    /// A resting bar's length: almost a dot.
    static let tick = 1.5
    /// The fall's acceleration (heights per second²): a full bar is down in about 200 ms.
    static let gravity = 50.0
    /// Each bar away from a loud bar keeps this share of its height (Cava's "monstercat").
    static let spread = 0.66
    /// How much of a bar is its neighbours' average (a light blur: a peak is a soft hill, some single-bar character
    /// stays).
    static let blur = 0.35
    /// The bars reach this share of the room they had before (Merlin: they bounced too far); the knee takes the loudest
    /// down to about 85 % of that, so a loud bar goes about 55 % as far as before.
    static let reachShare = 0.65
    /// Clear space from the tip of the longest bar to every rim control, and from the record to the bars' foot.
    static let clearance = 6.0
    /// Above this height the soft knee starts: loud parts grow slower and never shoot out.
    static let knee = 0.45
    /// Under this, a band reads as 0 (the quiet rest of the spectrum stays a ring of ticks).
    static let gate = 0.4
    /// With no sound for this long, a slow soft motion takes over.
    static let quietAfter = 1.5
    static let idleHeight = 0.14

    static func angle(bar: Int) -> Double { Double(bar) * 2 * .pi / Double(count) }

    /// The half of the disc's ring past the screen edge is not drawn.
    static func visible(bar: Int, half: Bool) -> Bool { !half || cos(angle(bar: bar)) <= 0.02 }

    /// The band (0 low ... `SpectrumMeter.bands` − 1 high) that bar `bar` shows. The left half runs from the bottom
    /// (low) to the top (high); the right half (the mini window only) mirrors it.
    static func band(bar: Int) -> Int {
        let quarter = count / 4
        var b = ((bar % count) + count) % count
        if b < quarter || b > 3 * quarter { b = (count / 2 - b + count) % count } // mirror the right half
        let share = Double(b - quarter) / Double(count / 2)
        return min(SpectrumMeter.bands - 1, max(0, Int((share * Double(SpectrumMeter.bands - 1)).rounded())))
    }

    /// The first bar that shows band `band` on the left half.
    static func bar(band: Int) -> Int {
        (0..<count).first { self.band(bar: $0) == band && cos(angle(bar: $0)) <= 0.02 } ?? count / 4
    }

    /// Each bar's height, 0 (a resting tick) to 1 (the longest).
    private(set) var heights = [Double](repeating: 0, count: MelodyBarsMotion.count)
    private var speed = [Double](repeating: 0, count: MelodyBarsMotion.count)
    private var target = [Double](repeating: 0, count: MelodyBarsMotion.count)
    private var lastTime: Double?
    private var sinceSound = 0.0
    private var idle = 0.0
    private var clock = 0.0
    private(set) var energy = 0.0
    private var settleStart: Double?
    private var wasMoving = false

    /// One frame at `now` (seconds). `moving`: a song plays and the dock shows.
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
        aim(moving ? sample.spectrum : [])
        var loud = false
        for i in 0..<Self.count {
            if target[i] >= heights[i] {
                heights[i] = target[i]
                speed[i] = 0
            } else {
                speed[i] += Self.gravity * dt
                heights[i] = max(target[i], heights[i] - speed[i] * dt)
            }
            loud = loud || target[i] > 0.05
        }
        sinceSound = loud ? 0 : sinceSound + dt
        let quiet = sinceSound >= Self.quietAfter
        idle += ((quiet ? 1 : 0) - idle) * (1 - exp(-dt / (quiet ? 0.5 : 0.08)))
        for i in 0..<Self.count {
            let wave = 0.5 + 0.5 * sin(3 * Self.angle(bar: i) - 1.2 * clock)
            drawn[i] = BeatMath.clamp01(max(heights[i], Self.idleHeight * idle * wave * wave) * energy)
        }
    }

    /// What is drawn: the heights with the idle motion and the settle applied.
    private(set) var drawn = [Double](repeating: 0, count: MelodyBarsMotion.count)

    /// The targets from a spectrum: each bar its band (under `gate` is 0), then each bar lifts its neighbours.
    private func aim(_ spectrum: [Double]) {
        for i in 0..<Self.count {
            let b = Self.band(bar: i)
            let v = b < spectrum.count ? spectrum[b] : 0
            target[i] = v <= Self.gate ? 0 : (v - Self.gate) / (1 - Self.gate)
        }
        for i in 1..<Self.count { target[i] = max(target[i], target[i - 1] * Self.spread) }
        for i in stride(from: Self.count - 2, through: 0, by: -1) { target[i] = max(target[i], target[i + 1] * Self.spread) }
        // The light blur: each bar mixes in its old neighbours (the left one kept in `previous`, the first one in `first`).
        var previous = target[Self.count - 1]
        let first = target[0]
        for i in 0..<Self.count {
            let next = i == Self.count - 1 ? first : target[i + 1], here = target[i]
            target[i] = (1 - Self.blur) * here + Self.blur * (0.5 * previous + 0.5 * next)
            previous = here
        }
    }

    /// The still ring of ticks (a pause, `Motion.still`, Reduce Motion).
    func rest() {
        for i in 0..<Self.count { heights[i] = 0; speed[i] = 0; target[i] = 0; drawn[i] = 0 }
        energy = 0
        idle = 0
        sinceSound = 0
        settleStart = nil
    }

    /// A fixed frame for the pictures: a spectrum with the pinned note's band group at full height and two lower ones;
    /// a sample with no note is the still ring.
    func pin(_ sample: BeatSample, half: Bool) {
        rest()
        guard sample.lead > 0 || !sample.spectrum.isEmpty else { return }
        var spectrum = sample.spectrum
        if spectrum.isEmpty {
            spectrum = [Double](repeating: 0, count: SpectrumMeter.bands)
            let top = Double(SpectrumMeter.bands - 1)
            for (pitch, height) in [(sample.leadPitch, 1.0), (sample.leadPitch * 0.6, 0.75), (sample.leadPitch * 0.25, 0.55)] {
                let b = Int((pitch * top).rounded())
                spectrum[b] = max(spectrum[b], Self.gate + (1 - Self.gate) * height * BeatMath.clamp01(sample.lead))
            }
        }
        energy = 1
        aim(spectrum)
        heights = target
        drawn = target
    }

    /// The ticks and the raised bars as two paths: they start just outside the record and, round caps included, never
    /// pass `place.limit`.
    /// The soft knee: straight up to `knee`, then the same slope bending over (about 0.85 at 1).
    static func soften(_ h: Double) -> Double {
        guard h > knee else { return max(0, h) }
        let bend = 0.8
        return knee + bend * (1 - exp(-(min(h, 1) - knee) / bend))
    }

    /// The nearest edge of any rim control from the disc's centre: every control sits on the rim circle, so the largest
    /// one (the Agents orb, Chats, Notes, or a button) comes nearest. Read from the dock's layout, whatever the order.
    static var rimEdge: Double {
        typealias L = EdgePanelLayout
        return Double(L.discButtonRadius - max(L.itemSize, L.agentHubSize, L.plusSize) / 2)
    }

    /// Where a bar's centre line starts and the farthest its tip's centre may go (round caps add `lineWidth / 2` each
    /// way): `clearance` from the record, `reachShare` of the old room, and on the disc `clearance` short of the rim.
    static func room(_ place: BeatStrings.Place) -> (start: Double, tip: Double) {
        let cap = Double(lineWidth) / 2
        let start = Double(place.inner) - 3 + clearance + cap // `inner` is the record's edge plus 3 pt
        let old = Double(place.limit) - cap
        var tip = start + tick + reachShare * max(0, old - start - tick)
        if place != .card { tip = min(tip, rimEdge - clearance - cap) }
        return (start, max(start + tick, tip))
    }

    func paths(center c: CGPoint, place: BeatStrings.Place, half: Bool) -> (ticks: Path, raised: Path) {
        let (start, tip) = Self.room(place)
        let longest = tip - start
        var ticks = Path(), raised = Path()
        for i in 0..<Self.count where Self.visible(bar: i, half: half) {
            let a = Self.angle(bar: i), x = cos(a), y = sin(a)
            let end = start + Self.tick + Self.soften(drawn[i]) * (longest - Self.tick)
            let from = CGPoint(x: c.x + start * x, y: c.y + start * y), to = CGPoint(x: c.x + end * x, y: c.y + end * y)
            if drawn[i] < 0.04 {
                ticks.move(to: from); ticks.addLine(to: to)
            } else {
                raised.move(to: from); raised.addLine(to: to)
            }
        }
        return (ticks, raised)
    }
}

/// The bars round the record. One `TimelineView` runs only while `moving` (and for the short settle after it), at the
/// display's own rate (120 on a ProMotion screen), each frame from the newest analysis. A still ring under `Motion.still` and Reduce Motion; a pinned sample
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
                TimelineView(.animation(minimumInterval: nil, paused: !(moving || settling))) { ctx in
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
