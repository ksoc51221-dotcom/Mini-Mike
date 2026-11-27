import AppKit
import CoreAudio

/// A beat source the tests script: no Core Audio, no Apple Event, no network, no file.
private final class FakeBeatSource: SpotifyBeatSource {
    var status: BeatSourceStatus = .idle
    var scripted: BeatSourceStatus = .live(2)
    var heard = false
    var sample = BeatSample(level: 0.5, bass: 0.5, kick: 0)
    var starts = 0, stops = 0
    var running = false
    func start() { starts += 1; running = true; status = scripted }
    func stop() { stops += 1; running = false; status = .idle }
    func read(now: TimeInterval, dt: Double) -> (sample: BeatSample, heard: Bool) { (sample, heard) }
}

/// Synthetic sound for the lead-line checks: notes, noise bursts (drum hits), a bass line, a kick and a gliding tom.
private enum Synth {
    struct Note { var at, length, hz: Double }

    static func tone(_ t: Double, _ n: Note, harmonics: [Double] = [1], vibrato: Double = 0) -> Double {
        let u = t - n.at
        guard u >= 0, u < n.length else { return 0 }
        let envelope = min(1, u / 0.008) * min(1, (n.length - u) / 0.02)
        var phase = 2 * Double.pi * n.hz * u
        if vibrato > 0 { phase -= n.hz * (pow(2, vibrato / 12) - 1) / 5.5 * cos(2 * .pi * 5.5 * u) }
        var sum = 0.0
        for (i, a) in harmonics.enumerated() { sum += a * sin(Double(i + 1) * phase) }
        return envelope * sum
    }

    static func hits(_ t: Double, _ times: [Double], noise: Double, amplitude: Double = 0.6, decay: Double = 0.025) -> Double {
        var v = 0.0
        for at in times where t >= at && t < at + 0.15 { v += amplitude * noise * exp(-(t - at) / decay) }
        return v
    }

    static let melody = [440.0, 523.25, 659.25, 587.33, 392, 493.88, 698.46, 329.63].enumerated().map {
        Note(at: 0.5 + 0.5 * Double($0.offset), length: 0.4, hz: $0.element)
    }
    /// Another rhythm than the melody's.
    static let drums = (0..<12).map { 0.73 + 0.37 * Double($0) }

    struct Heard {
        var onsets: [(time: Double, hz: Double)] = []
        var strength: [(time: Double, value: Double)] = []
    }

    /// Runs `seconds` of `signal` (the second argument is white noise in -1...1) through the analysis.
    static func hear(_ seconds: Double, rate: Double = 48_000, _ signal: (Double, Double) -> Double) -> Heard {
        var random = BeatRandom(state: 42)
        let samples = (0..<Int(seconds * rate)).map { Float(signal(Double($0) / rate, random.unit() * 2 - 1)) }
        let meter = LeadMeter(sampleRate: rate)
        var heard = Heard(), count: UInt32 = 0, i = 0
        while i < samples.count {
            let n = min(512, samples.count - i)
            samples.withUnsafeBufferPointer { meter.process($0.baseAddress! + i, frames: n, channels: 1) }
            i += n
            let t = Double(i) / rate
            if meter.notes != count {
                count = meter.notes
                heard.onsets.append((t, LeadMeter.lowHz * pow(LeadMeter.highHz / LeadMeter.lowHz, meter.pitch)))
            }
            heard.strength.append((t, meter.strength))
        }
        return heard
    }

    /// How many notes were found (right pitch, within 150 ms), the extra onsets, and the largest delay.
    static func match(_ heard: Heard, _ notes: [Note]) -> (found: Int, extra: Int, worst: Double) {
        var used = Set<Int>(), worst = 0.0
        for n in notes {
            if let k = heard.onsets.indices.first(where: { k in
                let o = heard.onsets[k]
                return !used.contains(k) && o.time >= n.at && o.time < n.at + 0.15 && abs(12 * log2(o.hz / n.hz)) < 0.7
            }) {
                used.insert(k)
                worst = max(worst, heard.onsets[k].time - n.at)
            }
        }
        return (used.count, heard.onsets.count - used.count, worst)
    }
}

extension FeatureTests {
    static func leadChecks(_ check: (String, Bool) -> Void) {
        let melody = Synth.melody, drums = Synth.drums
        func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }
        for rate in [48_000.0, 44_100] {
            let name = "lead \(Int(rate / 1000)) kHz:"
            let mixed = Synth.match(Synth.hear(4.8, rate: rate) { t, noise in
                melody.reduce(0) { $0 + 0.25 * Synth.tone(t, $1) } + Synth.hits(t, drums, noise: noise)
            }, melody)
            check("\(name) a melody with drum bursts on another rhythm: every note found (\(mixed.found)/8), none on a burst (\(mixed.extra) extra), at most \(ms(mixed.worst)) late",
                  mixed.found == 8 && mixed.extra == 0 && mixed.worst <= 0.08)
            for decay in [0.025, 0.08] {
                let only = Synth.hear(4.8, rate: rate) { t, noise in Synth.hits(t, drums, noise: noise, decay: decay) }
                check("\(name) drum bursts only (decay \(ms(decay))): no note (\(only.onsets.count))", only.onsets.isEmpty)
            }
        }
        check("lead: steady noise gives no note", Synth.hear(3) { _, noise in 0.2 * noise }.onsets.isEmpty)
        check("lead: silence gives no note and no strength", { let h = Synth.hear(1) { _, _ in 0 }; return h.onsets.isEmpty && h.strength.allSatisfy { $0.value == 0 } }())
        let long = Synth.Note(at: 0.3, length: 3, hz: 440)
        let held = Synth.hear(3.6) { t, _ in 0.25 * Synth.tone(t, long) }
        let least = held.strength.filter { $0.time > 0.5 && $0.time < 3.2 }.map(\.value).min() ?? 0
        check("lead: one long held note gives one onset and stays strong (\(held.onsets.count), least \(String(format: "%.2f", least)))",
              held.onsets.count == 1 && least > 0.8)
        let vibrato = Synth.hear(3.6) { t, _ in 0.2 * Synth.tone(t, long, harmonics: [1, 0.5, 0.3], vibrato: 0.4) }
        check("lead: a held note with vibrato gives one onset (\(vibrato.onsets.count))", vibrato.onsets.count == 1)
        let over = Synth.hear(3.6) { t, noise in 0.25 * Synth.tone(t, long) + Synth.hits(t, [0.9, 1.4, 1.9, 2.4], noise: noise) }
        check("lead: drum bursts over a held note add no onset (\(over.onsets.count))", over.onsets.count == 1)
        // The closest to a song: a voice-like tone with harmonics and vibrato, a bass line on another rhythm, a kick,
        // a gliding tom and noise hits. The estimate may take a few wrong notes here.
        let bass = (0..<10).map { Synth.Note(at: 0.38 + 0.43 * Double($0), length: 0.3, hz: [82.4, 98, 110, 73.4][$0 % 4]) }
        let song = Synth.match(Synth.hear(4.8) { t, noise in
            var v = melody.reduce(0) { $0 + 0.18 * Synth.tone(t, $1, harmonics: [1, 0.6, 0.45, 0.25, 0.12], vibrato: 0.3) }
            v += bass.reduce(0) { $0 + 0.2 * Synth.tone(t, $1, harmonics: [1, 0.4, 0.15]) }
            v += Synth.hits(t, drums, noise: noise, amplitude: 0.4)
            for hit in drums {
                let tom = t - (hit + 0.18), kick = t - (hit + 0.05)
                if tom >= 0 && tom < 0.2 { v += 0.3 * exp(-tom / 0.04) * sin(2 * .pi * (230 * tom - 400 * tom * tom)) }
                if kick >= 0 && kick < 0.2 { v += 0.4 * exp(-kick / 0.05) * sin(2 * .pi * 60 * kick) }
            }
            return v
        }, melody)
        check("lead: voice, bass and drums together: every voice note found (\(song.found)/8), at most 2 wrong onsets (\(song.extra)), \(ms(song.worst)) late at most",
              song.found == 8 && song.extra <= 2 && song.worst <= 0.08)

        // Cost: the best of three runs of 10 s of sound, as a share of one core.
        var random = BeatRandom(state: 3)
        let sound = (0..<480_000).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / 48_000) + 0.1 * (random.unit() - 0.5)) }
        let meter = LeadMeter()
        var best = Double.infinity
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            var i = 0
            while i < sound.count {
                sound.withUnsafeBufferPointer { meter.process($0.baseAddress! + i, frames: min(512, sound.count - i), channels: 1) }
                i += 512
            }
            best = min(best, (ProcessInfo.processInfo.systemUptime - start) / 10)
        }
        // Timing means something only in an optimised build: a debug build runs the same code many times slower.
        #if DEBUG
        print("  [measure] lead: analysis cost \(String(format: "%.1f", best * 100)) % of one core (debug build: not checked)")
        #else
        check("lead: the analysis costs under 2 % of one core (\(String(format: "%.2f", best * 100)) %)", best < 0.02)
        #endif
        let shared = LeadMeter.unpack(UInt64(65535) << 48 | UInt64(32768) << 32 | 7)
        check("lead: the packed reading unpacks", shared.strength == 1 && abs(shared.pitch - 0.5) < 0.001 && shared.notes == 7)
    }

    static func melodyBarsChecks(_ check: (String, Bool) -> Void) {
        typealias M = MelodyBarsMotion
        func note(_ n: Int, _ pitch: Double, lead: Double = 1, kick: Double = 0) -> BeatSample {
            BeatSample(level: 0.8, bass: 0.5, kick: kick, lead: lead, leadPitch: pitch, leadNote: n)
        }
        /// Advances at 60 frames a second from `from` to `to` seconds.
        func run(_ m: M, _ from: Double, _ to: Double, _ sample: BeatSample, moving: Bool = true) {
            var t = from
            while t <= to + 1e-9 { m.advance(to: t, sample: sample, moving: moving, half: false); t += 1.0 / 60 }
        }
        var m = M()
        run(m, 0, 0.5, note(0, 0, lead: 0, kick: 1))
        check("bars: drum hits with no note raise no bar", m.spikes.isEmpty && m.heights.allSatisfy { $0 == 0 })
        let where1 = M.bar(pitch: 0.6, half: false)
        m.advance(to: 0.5 + 1.0 / 60, sample: note(1, 0.6), moving: true, half: false)
        run(m, 0.5 + 2.0 / 60, 0.5 + 5.0 / 60, note(1, 0.6))
        check("bars: a new note jumps out in about 60 ms (\(String(format: "%.2f", m.heights[where1])))", m.heights[where1] > 0.85)
        let group = (-3...3).map { m.heights[(where1 + $0 + M.count) % M.count] }
        check("bars: a spike is a group of 5 neighbour bars, the middle one tallest",
              group[0] == 0 && group[6] == 0 && group[1] > 0 && group[1] < group[2] && group[2] < group[3]
              && group[3] > group[4] && group[4] > group[5] && group[5] > 0)
        let top = m.heights[where1]
        run(m, 0.6, 1.6, note(1, 0.6))
        check("bars: a held note keeps a lower spike", m.heights[where1] > 0.4 && m.heights[where1] < top)
        run(m, 1.62, 1.62 + 0.27, note(1, 0.6, lead: 0))
        check("bars: it falls back in about 250 ms (\(String(format: "%.2f", m.heights[where1])))", m.heights[where1] < 0.12)
        run(m, 1.9, 4, note(1, 0.6, lead: 0))
        let soft = m.heights.max() ?? 0
        check("bars: with no note for 1.5 s, a low slow motion (\(String(format: "%.2f", soft)))", soft > 0.05 && soft <= M.idleHeight + 1e-9)
        run(m, 4.02, 4.6, note(1, 0.6, lead: 0), moving: false)
        check("bars: after the song stops, a still ring", m.heights.allSatisfy { $0 == 0 } && m.spikes.isEmpty)
        m = M()
        run(m, 0, 0.1, note(0, 0, lead: 0))
        var t = 0.1
        for n in 1...20 { run(m, t + 1.0 / 60, t + 0.1, note(n, Double(n % 7) / 7)); t += 0.1 }
        check("bars: many quick notes keep at most \(M.maxSpikes) spikes", m.spikes.count <= M.maxSpikes && m.spikes.count > 1)

        let discBars = stride(from: 0.0, through: 1, by: 0.01).map { M.bar(pitch: $0, half: true) }
        check("bars: on the disc every pitch lands on the visible half, low at the bottom and high at the top",
              discBars.allSatisfy { M.visible(bar: $0, half: true) } && discBars == discBars.sorted()
              && sin(M.angle(bar: discBars.first!)) > 0.9 && sin(M.angle(bar: discBars.last!)) < -0.9)
        check("bars: in the mini window different pitch heights give clearly different places",
              M.bar(pitch: 0.2, half: false) != M.bar(pitch: 0.5, half: false) && M.count >= 90 && M.count <= 120)
        var inside = true, reach = true
        for place in [BeatStrings.Place.disc, .discWithChip, .card] {
            let half = place != .card
            let full = M()
            full.pin(note(3, 1), half: half)
            let paths = full.paths(center: .zero, place: place, half: half)
            var far = 0.0, near = Double.infinity
            for path in [paths.ticks, paths.raised] {
                path.cgPath.applyWithBlock { e in
                    let type = e.pointee.type
                    guard type == .moveToPoint || type == .addLineToPoint else { return }
                    let q = e.pointee.points[0], r = Double(hypot(q.x, q.y))
                    far = max(far, r + Double(M.lineWidth) / 2)
                    near = min(near, r - Double(M.lineWidth) / 2)
                }
            }
            // 0.001: a `Path` keeps its points in less than double precision.
            inside = inside && far <= Double(place.limit) + 0.001 && near >= Double(place.inner) - 0.001
            reach = reach && far > Double(place.limit) - 1
        }
        check("bars: every bar stays between the record and the band's limit, the longest reaching it", inside && reach)
        let still = M()
        still.pin(note(0, 0, lead: 0), half: true)
        check("bars: a pinned sample with no note is the still ring", still.heights.allSatisfy { $0 == 0 })
        check("bars: they move only while a song plays and the dock shows (a paused song: still, no redraws)",
              MelodyBars.moves(playing: true, shown: true) && !MelodyBars.moves(playing: false, shown: true)
              && !MelodyBars.moves(playing: true, shown: false))
        let paused = M()
        run(paused, 0, 0.5, note(1, 0.6))
        run(paused, 0.52, 1, note(1, 0.6), moving: false)
        check("bars: after a pause they settle to the still ring", paused.heights.allSatisfy { $0 == 0 } && paused.energy == 0)
    }

    @MainActor
    static func spotifyBeatChecks(_ check: (String, Bool) -> Void) {
        let sr = 48_000.0, block = 480 // 10 ms buffers, as the audio callback gets them
        leadChecks(check)
        melodyBarsChecks(check)

        /// Runs `seconds` of a signal through the callback's meter and the analyzer; returns every sample.
        func run(_ meter: inout BeatMeter, _ analyzer: inout BeatAnalyzer, seconds: Double, from t0: Double = 0,
                 _ signal: (Double) -> Double) -> [BeatSample] {
            var out: [BeatSample] = []
            var buffer = [Float](repeating: 0, count: block * 2)
            let blocks = Int(seconds * sr) / block
            for b in 0..<blocks {
                for i in 0..<block {
                    let x = Float(signal(t0 + Double(b * block + i) / sr))
                    buffer[i * 2] = x; buffer[i * 2 + 1] = x // stereo, interleaved
                }
                let r = buffer.withUnsafeBufferPointer { meter.process($0.baseAddress!, frames: block, channels: 2) }
                out.append(analyzer.update(rms: Double(r.rms), low: Double(r.low), dt: Double(block) / sr))
            }
            return out
        }
        func sine(_ f: Double, _ a: Double) -> (Double) -> Double { { t in a * sin(2 * .pi * f * t) } }

        // Silence gives 0.
        do {
            var m = BeatMeter(sampleRate: sr), a = BeatAnalyzer()
            let s = run(&m, &a, seconds: 1) { _ in 0 }
            check("beat: silence gives level, bass and kick 0", s.allSatisfy { $0 == .zero })
        }
        // A 60 Hz burst after silence raises the bass and fires a kick; the kick decays in about 0.25 s.
        do {
            var m = BeatMeter(sampleRate: sr), a = BeatAnalyzer()
            _ = run(&m, &a, seconds: 0.5) { _ in 0 }
            let burst = run(&m, &a, seconds: 0.4, sine(60, 0.5))
            check("beat: a 60 Hz burst raises bass", (burst.last?.bass ?? 0) > 0.6)
            let peak = burst.map(\.kick).max() ?? 0
            check("beat: a 60 Hz burst fires a kick", peak > 0.6)
            let at = burst.firstIndex { $0.kick == peak } ?? 0
            let k100 = burst[min(at + 10, burst.count - 1)].kick, k300 = burst[min(at + 30, burst.count - 1)].kick
            check("beat: the kick decays in about 0.25 s (still up at 0.1 s, gone by 0.3 s)", k100 > 0.15 && k300 < 0.05)
        }
        // A 5 kHz tone raises the level but not the bass.
        do {
            var m = BeatMeter(sampleRate: sr), a = BeatAnalyzer()
            let s = run(&m, &a, seconds: 1, sine(5000, 0.4))
            check("beat: a 5 kHz tone raises level", (s.last?.level ?? 0) > 0.6)
            check("beat: a 5 kHz tone leaves bass low and fires no kick", s.allSatisfy { $0.bass < 0.15 && $0.kick < 0.05 })
        }
        // Automatic gain: a quiet song moves like a loud one, also right after a loud one.
        do {
            var m = BeatMeter(sampleRate: sr), a = BeatAnalyzer()
            let pulse: (Double) -> (Double) -> Double = { amp in { t in amp * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 2 * t)) } }
            let loud = run(&m, &a, seconds: 2, pulse(0.6))
            // The gain forgets a loud part over about 4 s (so a short quiet passage stays calm); a quiet song catches up.
            let quiet = run(&m, &a, seconds: 20, from: 2, pulse(0.03))
            let quietTail = quiet.suffix(200).map(\.level)
            check("beat: auto gain: a loud song moves", (loud.suffix(100).map(\.level).max() ?? 0) > 0.8)
            check("beat: auto gain: a quiet song after it moves too", (quietTail.max() ?? 0) > 0.8 && (quietTail.min() ?? 1) < 0.5)
            check("beat: every analyzer value stays in 0...1", (loud + quiet).allSatisfy(\.isInRange))
        }

        // The simulated beat: deterministic for a seed, in 0...1, 110 to 128 BPM, a kick on most beats.
        do {
            let a = SimulatedBeat(seed: 42), b = SimulatedBeat(seed: 42), c = SimulatedBeat(seed: 43)
            let times = stride(from: 0.0, to: 60, by: 1.0 / 60).map { $0 }
            let sa = times.map(a.sample(at:)), sb = times.map(b.sample(at:)), sc = times.map(c.sample(at:))
            check("beat sim: the same seed gives the same beat", sa == sb)
            check("beat sim: another seed gives another beat", sa != sc)
            check("beat sim: every value stays in 0...1", (sa + sc).allSatisfy(\.isInRange))
            check("beat sim: tempo 110 to 128 BPM", (0..<50).allSatisfy { (110...128).contains(SimulatedBeat(seed: UInt64($0)).bpm) })
            var onsets = 0
            for i in 1..<sa.count where sa[i].kick - sa[i - 1].kick > 0.3 { onsets += 1 }
            let beats = 60 * a.bpm / 60
            check("beat sim: a kick on most beats (\(onsets) of about \(Int(beats)))", Double(onsets) > beats * 0.7 && Double(onsets) <= beats * 1.05)
            let src = SimulatedSpotifyBeatSource(seed: 9)
            src.song("a"); let tempoA = src.bpm
            src.song("b")
            check("beat sim: each song gets its own tempo", tempoA != src.bpm)
        }

        // The source rule: live while it hears Spotify; 3 s of only zeros (a denied permission) gives the simulated beat.
        do {
            let fake = FakeBeatSource()
            var lines: [String] = []
            let beat = SpotifyBeat(live: { fake }, blocked: false, seed: 1, motionOff: { false })
            beat.log = { lines.append($0) }
            beat.update(shown: true, running: true, playing: true, song: "x")
            check("beat source: starts the live source when shown, running and playing", fake.starts == 1 && fake.running)
            var t = 1000.0
            while t < 1002.9 { _ = beat.sample(now: t); t += 1.0 / 60 }
            check("beat source: live before 3 s of silence", beat.mode == .live(2))
            while t < 1003.1 { _ = beat.sample(now: t); t += 1.0 / 60 }
            if case .simulated = beat.mode { check("beat source: 3 s of zeros switches to simulated", true) } else {
                check("beat source: 3 s of zeros switches to simulated", false)
            }
            fake.heard = true
            _ = beat.sample(now: t + 0.02)
            check("beat source: sound again returns to live", beat.mode == .live(2))
            check("beat sync: one output-delay line per live start", lines.filter { $0.hasPrefix("beat sync: output delay ") }.count == 1)
            lines.removeAll { $0.hasPrefix("beat sync: ") }
            check("beat source: one log line per change", lines == ["beat source: starting (live allowed: true)",
                                                                   "beat source: live (2 process objects)",
                                                                   "beat source: simulated (no sound from Spotify for 3 s; audio capture may be denied)",
                                                                   "beat source: live (2 process objects)"])
            let s = beat.sample(now: t + 0.04)
            check("beat source: two views at one timestamp get one sample", beat.sample(now: t + 0.04) == s)
            // Lifetime: a pause, a hide and Reduce Motion each stop it.
            beat.update(shown: true, running: true, playing: false, song: "x")
            check("beat life: a pause stops the tap", !fake.running && fake.stops == 1 && beat.mode == .off)
            check("beat life: nothing comes while stopped", beat.sample(now: t + 1) == .zero)
            beat.update(shown: true, running: true, playing: true, song: "x")
            beat.update(shown: false, running: true, playing: true, song: "x")
            check("beat life: hiding the dock stops the tap", !fake.running && fake.stops == 2)
            beat.update(shown: true, running: false, playing: true, song: "x")
            check("beat life: Spotify not running starts nothing", !fake.running && fake.starts == 2)
        }
        do {
            let fake = FakeBeatSource()
            var off = true
            let beat = SpotifyBeat(live: { fake }, blocked: false, seed: 1, motionOff: { off })
            beat.update(shown: true, running: true, playing: true, song: nil)
            check("beat life: Reduce Motion never starts the tap", fake.starts == 0 && !beat.active)
            off = false
            beat.update(shown: true, running: true, playing: true, song: nil)
            off = true
            beat.update(shown: true, running: true, playing: true, song: nil)
            check("beat life: Reduce Motion turned on stops the tap", fake.starts == 1 && fake.stops == 1 && !fake.running)
            check("beat life: shouldListen needs all four", SpotifyBeat.shouldListen(shown: true, running: true, playing: true, motionOff: false)
                  && !SpotifyBeat.shouldListen(shown: false, running: true, playing: true, motionOff: false)
                  && !SpotifyBeat.shouldListen(shown: true, running: false, playing: true, motionOff: false)
                  && !SpotifyBeat.shouldListen(shown: true, running: true, playing: false, motionOff: false)
                  && !SpotifyBeat.shouldListen(shown: true, running: true, playing: true, motionOff: true))
        }
        do {
            // Paused (2026-11-26): a softer pulse at the song's tempo, then the live source again on play.
            let fake = FakeBeatSource()
            let beat = SpotifyBeat(live: { fake }, blocked: false, seed: 3, motionOff: { false })
            beat.log = { _ in }
            beat.update(shown: true, running: true, playing: true, song: "p")
            beat.update(shown: true, running: true, playing: false, paused: true, song: "p")
            var peak = 0.0
            for k in 0..<120 { peak = max(peak, beat.sample(now: 100 + Double(k) / 60).kick) }
            check("beat paused: the strings keep a pulse (peak kick \(String(format: "%.2f", peak)), at most 0.6)",
                  beat.isPaused && beat.mode == .simulated(SpotifyBeat.pausedWhy) && peak > 0.1 && peak <= SpotifyBeat.pausedStrength + 1e-9)
            beat.update(shown: true, running: true, playing: true, song: "p")
            check("beat paused: play again restarts the live source", !beat.isPaused && fake.starts == 2)
            SpotifyBeat.pausedPulse = false
            beat.update(shown: true, running: true, playing: false, paused: true, song: "p")
            check("beat paused: with the switch off a paused song stops the beat", beat.sample(now: 200) == .zero)
            SpotifyBeat.pausedPulse = true
        }
        do {
            let fake = FakeBeatSource()
            fake.scripted = .failed("no Spotify audio process")
            var lines: [String] = []
            let beat = SpotifyBeat(live: { fake }, blocked: false, seed: 1, motionOff: { false })
            beat.log = { lines.append($0) }
            beat.update(shown: true, running: true, playing: true, song: "y")
            let s = beat.sample(now: 50)
            check("beat source: the first start attempt logs first, unconditionally; a tap that cannot be made falls back to simulated",
                  lines.filter { !$0.hasPrefix("beat sync: ") } == ["beat source: starting (live allowed: true)",
                                                                    "beat source: simulated (no Spotify audio process)"] && s.isInRange)
            beat.update(shown: false, running: true, playing: true, song: "y")
            beat.update(shown: true, running: true, playing: true, song: "y")
            check("beat source: the starting line is logged once per run", lines.filter { $0.hasPrefix("beat source: starting") }.count == 1)
        }
        // The start decision (pure): what each state does, and the line Reduce Motion leaves in the log.
        do {
            typealias B = SpotifyBeat
            check("beat start: the app (not blocked, a live source) goes live for a playing song in a shown dock",
                  B.startDecision(shown: true, running: true, playing: true, motionOff: false, blocked: false, hasLive: true) == .live)
            check("beat start: hidden, closed or paused starts nothing",
                  B.startDecision(shown: false, running: true, playing: true, motionOff: false, blocked: false, hasLive: true) == .none
                  && B.startDecision(shown: true, running: false, playing: true, motionOff: false, blocked: false, hasLive: true) == .none
                  && B.startDecision(shown: true, running: true, playing: false, motionOff: false, blocked: false, hasLive: true) == .none)
            check("beat start: Reduce Motion or still pictures: no tap",
                  B.startDecision(shown: true, running: true, playing: true, motionOff: true, blocked: false, hasLive: true) == .motionOff)
            check("beat start: blocked (test and picture runs) or no live source: simulated",
                  B.startDecision(shown: true, running: true, playing: true, motionOff: false, blocked: true, hasLive: true)
                    == .simulated("live tap blocked in a test or picture run")
                  && B.startDecision(shown: true, running: true, playing: true, motionOff: false, blocked: false, hasLive: false)
                    == .simulated("no live source"))
            var lines: [String] = []
            let beat = SpotifyBeat(live: { FakeBeatSource() }, blocked: false, seed: 1, motionOff: { true })
            beat.log = { lines.append($0) }
            beat.update(shown: true, running: true, playing: true, song: "m")
            beat.update(shown: true, running: true, playing: true, song: "m")
            check("beat start: Reduce Motion logs once why nothing starts", lines.count == 1 && lines[0].hasPrefix("beat source: not starting"))
        }
        // Through the service: the dock showing a playing song starts the beat; stop() stops it.
        do {
            let fake = FakeBeatSource()
            let beat = SpotifyBeat(live: { fake }, blocked: false, seed: 1, motionOff: { false })
            let service = SpotifyService(backend: FixtureSpotifyBackend(.track(EdgeDockFixtures.track)),
                                         loader: FixtureImageLoader(image: nil), beat: beat)
            service.start()
            EdgeDockFixtures.waitUntil { fake.running }
            check("beat life: the service starts the beat for a playing song in a shown dock", fake.running)
            service.stop()
            check("beat life: the service's stop() stops the beat", !fake.running)
        }

        // The live tap is blocked in test and picture runs: never created, the simulated beat with a fixed seed instead.
        do {
            check("beat blocked: the test run blocks the live tap", LiveSpotifyBeatSource.blocked)
            let live = LiveSpotifyBeatSource()
            live.start()
            check("beat blocked: start() refuses before touching Core Audio", live.status == .failed("live tap blocked in a test or picture run"))
            var made = 0
            var lines: [String] = []
            let beat = SpotifyBeat(live: { made += 1; return FakeBeatSource() }, motionOff: { false })
            beat.log = { lines.append($0) }
            beat.update(shown: true, running: true, playing: true, song: "z")
            _ = beat.sample(now: 1)
            check("beat blocked: no live source is made; the simulated beat logs why",
                  made == 0 && beat.live == nil && lines == ["beat source: starting (live allowed: false)",
                                                             "beat source: simulated (live tap blocked in a test or picture run)"])
            check("beat blocked: a fixed seed", beat.seed == SpotifyBeat(motionOff: { false }).seed)
            check("beat select: Spotify and its helpers only, those playing first",
                  LiveSpotifyBeatSource.select([(1, "com.spotify.client", false), (2, "com.spotify.client.helper", true),
                                                (3, "com.apple.Music", true), (4, "com.spotify.clientx", true), (5, nil, true)]) == [2]
                  && LiveSpotifyBeatSource.select([(1, "com.spotify.client", false), (3, "com.apple.Music", true)]) == [1]
                  && LiveSpotifyBeatSource.select([(3, "com.apple.Music", true)]).isEmpty)
            check("beat aggregate: the output device joins only without input streams (never a microphone)",
                  LiveSpotifyBeatSource.clockDevice(uid: "out", inputStreams: 0) == "out"
                  && LiveSpotifyBeatSource.clockDevice(uid: "out", inputStreams: 1) == nil
                  && LiveSpotifyBeatSource.clockDevice(uid: nil, inputStreams: 0) == nil)
        }

        // The strings' limits as pure geometry: at level = bass = kick = 1 (and with springs overshooting) every ring stays
        // in its band: clear of the record and its title, the disc's buttons and timer chip, the mini window's rows and edge.
        do {
            typealias L = EdgePanelLayout
            let disc = BeatStrings.Place.disc, card = BeatStrings.Place.card
            let c = L.coverCentre
            let buttonEdge = (0..<3).map { r -> CGFloat in let b = L.discButtonCentre(r); return hypot(b.x - c.x, b.y - c.y) - L.plusSize / 2 }.min()!
            check("strings band: disc clear of the record (\(disc.inner) > \(L.coverSize / 2))", disc.inner > L.coverSize / 2 + 1)
            check("strings band: disc clear of the three buttons (\(disc.outer) < \(buttonEdge))", disc.outer < buttonEdge - 1)
            check("strings band: disc clear of the timer chip", disc.outer < L.timerChipCentre.y - c.y - L.timerChipHeight / 2)
            check("strings band: disc inside its frame, its beat limit too", disc.outer <= EdgeDockArt.orbRadius && disc.limit <= EdgeDockArt.orbRadius)
            check("strings band: card clear of the record", card.inner > L.spotifyRecord / 2 + 1)
            check("strings band: card calm inside the orb, clear of the search row, the caption line and the card's edge",
                  card.outer < L.spotifyOrbRadius && card.outer < (L.listWidth - 2 * L.spotifyPad) / 2
                  && L.spotifyRecordCentreY - card.outer > L.spotifyPad + L.spotifySearchHeight
                  && L.spotifyRecordCentreY + card.outer < L.spotifyCaptionTop)
            // The beat limits, as geometry: 4 pt short of every neighbour.
            let f = L.timerChipFrame
            let chip = hypot(min(max(c.x, f.minX), f.maxX) - c.x, min(max(c.y, f.minY), f.maxY) - c.y)
            check("strings limit: disc 4 pt clear of the rim buttons' inner edges (limit \(disc.limit))",
                  disc.limit <= buttonEdge - 4 + 1e-9 && disc.limit > disc.outer + 15)
            let timed = BeatStrings.Place.discWithChip
            check("strings limit: with a timer, also 4 pt clear of the timer chip (limit \(timed.limit))",
                  timed.limit <= chip - 4 + 1e-9 && timed.limit <= disc.limit && timed.limit > disc.outer
                  && timed.inner == disc.inner && timed.outer == disc.outer)
            let y = L.spotifyRecordCentreY
            check("strings limit: card 4 pt clear of the search field, the caption line and the card's sides (limit \(card.limit))",
                  card.limit <= L.spotifyCaptionTop - y - 4 + 1e-9 && card.limit <= y - L.spotifyPad - L.spotifySearchHeight - 4 + 1e-9
                  && card.limit <= L.listWidth / 2 - 4 && card.limit > card.outer)
            var inside = true, reach = true
            for place in [disc, card, BeatStrings.Place.discWithChip] {
                for (x, shove) in [(1.0, 0.0), (1.0, 2.5), (1.6, -3.0), (5.0, 1.0)] {
                    let m = BeatStringsMotion(place: place, seed: 7)
                    m.pin(BeatSample(level: 1, bass: 1, kick: 1), place: place)
                    m.force(x, shove: shove)
                    for i in 0..<BeatStrings.rings {
                        let ring = m.ring(i), hw = place.halfWidth(i)
                        if ring.maxReach > place.excursion(i) + 1e-9 { reach = false }
                        for k in 0..<1440 {
                            let r = ring.radius(Double(k) / 1440 * 2 * .pi).r
                            if r - hw < Double(place.inner) - 1e-9 || r + hw > Double(place.limit) + 1e-9 { inside = false }
                        }
                    }
                }
            }
            check("strings: the wave and pulse never reach past the excursion (no clamp needed)", reach)
            check("strings: every ring stays inside its band at full drive", inside)
            let a = BeatStringsMotion(place: card, seed: 7), b = BeatStringsMotion(place: card, seed: 7)
            a.pin(BeatSample(level: 0.9, bass: 0.9, kick: 1), place: card)
            b.pin(BeatSample(level: 0.9, bass: 0.9, kick: 1), place: card)
            check("strings: a pinned frame is the same every run", (0..<3).allSatisfy { a.ring($0).phases == b.ring($0).phases && a.ring($0).amplitude == b.ring($0).amplitude })
            let p = a.ring(2).path(center: .zero)
            var segments = 0
            p.forEach { if case .curve = $0 { segments += 1 } }
            check("strings: \(BeatStrings.points) smooth segments per ring", segments == BeatStrings.points)
        }
        // The motion: louder music, bigger strings; a pause settles to the calm shape in one short ease.
        do {
            let m = BeatStringsMotion(place: .card, seed: 3)
            let calm = (0..<3).map { m.ring($0).amplitude }
            let sim = SimulatedBeat(seed: 5)
            var t = 0.0, peak = 0.0
            while t < 2 { m.advance(to: t, sample: sim.sample(at: t), moving: true, place: .card); peak = max(peak, m.ring(0).amplitude); t += 1.0 / 60 }
            check("strings: the beat swells the rings", peak > calm[0] * 1.5)
            var quiet = 0.0
            let q = BeatStringsMotion(place: .card, seed: 3)
            t = 0
            while t < 2 { q.advance(to: t, sample: BeatSample(level: 0.1, bass: 0.1, kick: 0), moving: true, place: .card); quiet = max(quiet, q.ring(0).amplitude); t += 1.0 / 60 }
            check("strings: a quiet passage stays calm", quiet - calm[0] < 0.25 * (peak - calm[0]))
            let stop = t
            while t < stop + Motion.edgeSettleDuration + 0.05 { m.advance(to: t, sample: .zero, moving: false, place: .card); t += 1.0 / 60 }
            check("strings: a pause settles to the calm shape", m.energy == 0 && (0..<3).allSatisfy { m.ring($0).amplitude == calm[$0] && m.ring($0).pulse == 0 })
            check("strings: the settle is within 0.3 s", Motion.edgeSettleDuration <= 0.3)
        }
        // No music: three true circles, equally spaced, one line weight, still (disc and card).
        do {
            func deviation(_ m: BeatStringsMotion, _ place: BeatStrings.Place) -> Double {
                var worst = 0.0
                for i in 0..<BeatStrings.rings {
                    let ring = m.ring(i)
                    for k in 0..<1440 { worst = max(worst, abs(ring.radius(Double(k) / 1440 * 2 * .pi).r - place.base(i))) }
                }
                return worst
            }
            for (name, place) in [("disc", BeatStrings.Place.disc), ("card", BeatStrings.Place.card), ("disc with timer", BeatStrings.Place.discWithChip)] {
                let m = BeatStringsMotion(place: place, seed: 9)
                m.rest(place: place)
                let calm = deviation(m, place)
                let spacing = (place.base(1) - place.base(0), place.base(2) - place.base(1))
                check("strings at rest (\(name)): every point is exactly on its ring's radius (max deviation \(calm))",
                      calm == 0 && (0..<3).allSatisfy { m.ring($0).amplitude == 0 && m.ring($0).pulse == 0 })
                check("strings at rest (\(name)): the three radii are equally spaced, one line weight",
                      abs(spacing.0 - spacing.1) < 1e-9 && spacing.0 > 0
                      && BeatStrings.Place.lineWidths[0] == BeatStrings.Place.lineWidths[1]
                      && BeatStrings.Place.lineWidths[1] == BeatStrings.Place.lineWidths[2])
                // Playing, then paused: back to the exact circles after the settle.
                let sim = SimulatedBeat(seed: 4)
                var t = 0.0
                while t < 1 { m.advance(to: t, sample: sim.sample(at: t), moving: true, place: place); t += 1.0 / 60 }
                let playing = deviation(m, place)
                while t < 1 + Motion.edgeSettleDuration + 0.05 { m.advance(to: t, sample: .zero, moving: false, place: place); t += 1.0 / 60 }
                check("strings (\(name)): music moves them (\(String(format: "%.2f", playing)) pt); a pause brings back exact circles",
                      playing > 0.2 && deviation(m, place) == 0)
                // Playing but silent (no sound): circles too.
                let s = BeatStringsMotion(place: place, seed: 9)
                t = 0
                while t < 1 { s.advance(to: t, sample: .zero, moving: true, place: place); t += 1.0 / 60 }
                check("strings (\(name)): no sound: still circles", deviation(s, place) == 0)
            }
        }
        // The kick: one clear thump outward past the calm extent (a radius pulse and a lobe burst), the outer ring most,
        // scaled by the loudness. The old build's outer ring on the disc reached 2.36 pt in all.
        do {
            func jump(_ place: BeatStrings.Place, _ i: Int, level: Double = 1) -> Double {
                let m = BeatStringsMotion(place: place, seed: 7)
                m.pin(BeatSample(level: level, bass: level, kick: 1), place: place)
                return m.ring(i).maxReach
            }
            let disc = BeatStrings.Place.disc, card = BeatStrings.Place.card
            let outer = jump(disc, 2), cardOuter = jump(card, 2)
            check("strings kick: the disc's outer ring jumps \(String(format: "%.2f", outer)) pt at kick = 1 (at least 15 pt; it was 6.3 before 2026-11-26)", outer >= 15)
            // The card's caption line blocks 8 pt: the largest that fits (90% of the room is the soft ceiling's reach).
            check("strings kick: the card's outer ring jumps \(String(format: "%.2f", cardOuter)) pt, the most its room allows (\(String(format: "%.2f", card.jump(2))) pt)",
                  cardOuter >= 0.9 * card.jump(2) && cardOuter > 2.36)
            let r1 = jump(disc, 1) / outer, r0 = jump(disc, 0) / outer
            check("strings kick: the inner rings jump less than the outer one, so the gaps widen on a beat (\(String(format: "%.2f / %.2f", r1, r0)))",
                  r0 < r1 && r1 < 1 && r0 > 0.3)
            // The rings never cross or touch: at full drive (springs overshooting to 1.15), with and without a kick
            // shove, at 720 angles, each ring's outer stroke edge stays under the next ring's inner stroke edge.
            var crossGap = Double.infinity
            for place in [disc, card, BeatStrings.Place.discWithChip] {
                for seed: UInt64 in [1, 7, 42, 99, 1234] {
                    for shove in [0.0, 1.0] {
                        let m = BeatStringsMotion(place: place, seed: seed)
                        m.force(1.15, shove: shove)
                        let rings = (0..<3).map { m.ring($0) }
                        for k in 0..<720 {
                            let th = Double(k) * .pi / 360
                            for i in 0..<2 {
                                let gap = (rings[i + 1].radius(th).r - place.halfWidth(i + 1)) - (rings[i].radius(th).r + place.halfWidth(i))
                                crossGap = min(crossGap, gap)
                            }
                        }
                    }
                }
            }
            check("strings: the rings never cross at full drive (closest \(String(format: "%.2f", crossGap)) pt)", crossGap > 0.5)
            let quiet = jump(disc, 2, level: 0.1)
            check("strings kick: soft music gives small jumps (\(String(format: "%.2f", quiet)) pt at level 0.1)", quiet < 0.65 * outer)
            var up = BeatSpring(), t = 0.0
            while up.x < 0.85 && t < 1 { up.step(to: 1, dt: 1.0 / 240); t += 1.0 / 240 }
            check("strings kick: a fast attack (0.85 in \(String(format: "%.0f", t * 1000)) ms)", t <= 0.07)
            var down = BeatSpring(x: 1), fall = 0.0
            while abs(down.x) > 0.12 || abs(down.v) > 0.5 { down.step(to: 0, dt: 1.0 / 240); fall += 1.0 / 240; if fall > 1 { break } }
            check("strings kick: it falls back in about 250 ms (\(String(format: "%.0f", fall * 1000)) ms)", fall >= 0.12 && fall <= 0.33)
        }
    }
}
