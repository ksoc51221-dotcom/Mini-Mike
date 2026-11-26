import AppKit
import CoreAudio
import Foundation
import os
import Synchronization
import SwiftUI

// The beat behind the strings round the Spotify record. A Core Audio process tap reads ONLY Spotify's sound (never the
// microphone, never another app, never a global tap), computes two numbers per buffer and keeps no audio. When the tap
// cannot run (no permission, no Spotify audio process, a test or picture run) a believable simulated beat takes over.

/// One reading of the music, every value 0...1.
struct BeatSample: Equatable {
    /// How loud, with automatic gain (quiet and loud songs both move).
    var level: Double
    /// The low band (under about 150 Hz) on the same gain.
    var bass: Double
    /// An onset: jumps when the bass rises sharply above its recent mean, then decays in about 0.25 s.
    var kick: Double

    static let zero = BeatSample(level: 0, bass: 0, kick: 0)

    var isInRange: Bool { [level, bass, kick].allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite } }
}

enum BeatMath {
    static func clamp01(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 1) : 0 }

    /// A 0...1 hash of a seed and an integer (SplitMix64's finaliser).
    static func hash(_ seed: UInt64, _ i: Int64) -> Double {
        var z = seed &+ UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Smooth value noise in -1...1: random values on whole numbers, eased between them.
    static func noise(_ seed: UInt64, _ x: Double) -> Double {
        let i = x.rounded(.down), f = x - i, n = Int64(i)
        let u = f * f * (3 - 2 * f)
        let a = hash(seed, n) * 2 - 1, b = hash(seed, n &+ 1) * 2 - 1
        return a + (b - a) * u
    }

    /// A string's own seed (FNV-1a), so each song gets its own simulated beat.
    static func seed(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

/// A seedable random generator (SplitMix64).
struct BeatRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - The numbers (pure)

/// The real-time half: runs inside the audio callback. No allocation, no lock, no main actor: a one-pole low-pass at
/// about 150 Hz and two envelopes (instant attack, 60 ms release), nothing else. The same code runs in the tests.
struct BeatMeter {
    private(set) var sampleRate: Double
    private var a: Float
    private var lp: Float = 0
    private var rmsEnv: Float = 0
    private var lowEnv: Float = 0
    static let lowCutoff: Double = 150
    static let release: Double = 0.06

    init(sampleRate: Double = 48_000) {
        let sr = sampleRate > 1000 ? sampleRate : 48_000
        self.sampleRate = sr
        a = Float(1 - exp(-2 * Double.pi * Self.lowCutoff / sr))
    }

    /// One buffer of `frames` frames with `channels` interleaved channels (averaged to mono). Returns the overall and the
    /// low-band envelope, and the buffer's peak (0 only for digital silence).
    mutating func process(_ p: UnsafePointer<Float>, frames: Int, channels: Int) -> (rms: Float, low: Float, peak: Float) {
        guard frames > 0, channels > 0 else { return (rmsEnv, lowEnv, 0) }
        var s2: Float = 0, l2: Float = 0, peak: Float = 0
        let inv = 1 / Float(channels)
        for i in 0..<frames {
            var x: Float = 0
            for c in 0..<channels { x += p[i * channels + c] }
            x *= inv
            lp += a * (x - lp)
            s2 += x * x
            l2 += lp * lp
            peak = max(peak, abs(x))
        }
        let n = Float(frames)
        let rms = (s2 / n).squareRoot(), low = (l2 / n).squareRoot()
        guard rms.isFinite, low.isFinite, lp.isFinite else {
            lp = 0; rmsEnv = 0; lowEnv = 0
            return (0, 0, 0)
        }
        let k = Float(exp(-Double(frames) / (sampleRate * Self.release)))
        rmsEnv = max(rms, rmsEnv * k)
        lowEnv = max(low, lowEnv * k)
        return (rmsEnv, lowEnv, peak)
    }
}

/// The main-thread half: turns the two envelopes into `level`, `bass` and `kick` at the animation rate.
struct BeatAnalyzer {
    /// The loudest recent level (the automatic gain's reference), never under `floor` (about -50 dBFS) so silence stays 0.
    private(set) var reference: Double = BeatAnalyzer.floor
    private var mean: Double = 0
    private var previousBass: Double = 0
    private var kick: Double = 0
    private var sinceKick: Double = 1
    static let floor = 0.003
    /// The gain's memory: a loud part is forgotten over about 4 s.
    static let gainRelease = 4.0
    /// The kick's decay constant: 1 falls under 0.05 in about 0.21 s.
    static let kickDecay = 0.07
    static let meanTime = 0.4
    static let bassBoost = 1.5

    mutating func update(rms: Double, low: Double, dt: Double) -> BeatSample {
        let dt = min(max(dt, 0), 0.25)
        let rms = rms.isFinite ? max(rms, 0) : 0, low = low.isFinite ? max(low, 0) : 0
        reference = max(rms, Self.floor, reference * exp(-dt / Self.gainRelease))
        let level = BeatMath.clamp01(rms / reference)
        let bass = BeatMath.clamp01(low / reference * Self.bassBoost)
        kick *= exp(-dt / Self.kickDecay)
        sinceKick += dt
        let rise = bass - mean
        // A lower bar and a stronger answer (2026-11-26: "much more dramatic"): most beats now give a full jump.
        if rise > 0.15, bass - previousBass > 0.04, sinceKick > 0.12 {
            kick = max(kick, BeatMath.clamp01(rise * 2.4))
            sinceKick = 0
        }
        mean += (bass - mean) * (1 - exp(-dt / Self.meanTime))
        previousBass = bass
        return BeatSample(level: level, bass: bass, kick: BeatMath.clamp01(kick))
    }
}

/// A believable random beat: a tempo of 110 to 128 BPM picked per song, a kick on most beats, random accents, an
/// off-beat lift, slow swells and a small tempo drift. A pure function of the seed and the time.
struct SimulatedBeat {
    let seed: UInt64
    let bpm: Double

    /// `bpm`: a measured tempo (a paused song keeps the tempo it played at); nil picks 110 to 128 from the seed.
    init(seed: UInt64, bpm: Double? = nil) {
        self.seed = seed
        if let bpm, bpm.isFinite, bpm >= 60, bpm <= 200 { self.bpm = bpm } else { self.bpm = 110 + 18 * BeatMath.hash(seed, 1) }
    }

    func sample(at time: Double) -> BeatSample {
        let t = max(0, time.isFinite ? time : 0)
        let beat = 60 / bpm
        // The drift moves the beat by at most 0.6 of a beat over many seconds (the phase still only grows).
        let phase = t / beat + 0.6 * BeatMath.noise(seed ^ 0xA1, t * 0.07)
        let whole = phase.rounded(.down), f = phase - whole, n = Int64(whole)
        let hasKick = n % 4 == 0 || BeatMath.hash(seed ^ 0xB2, n) < 0.8
        let accent = 0.55 + 0.45 * BeatMath.hash(seed ^ 0xC3, n)
        let kick = hasKick ? accent * exp(-f * beat / BeatAnalyzer.kickDecay) : 0
        let off = exp(-abs(f - 0.5) * beat / 0.05) * (0.3 + 0.4 * BeatMath.hash(seed ^ 0xD4, n))
        let swell = 0.6 + 0.4 * (0.5 + 0.5 * BeatMath.noise(seed ^ 0xE5, t * 0.15))
        return BeatSample(level: BeatMath.clamp01(swell * (0.55 + 0.3 * kick + 0.15 * off)),
                          bass: BeatMath.clamp01(swell * (0.3 + 0.65 * kick)),
                          kick: BeatMath.clamp01(kick))
    }
}

// MARK: - Sources

enum BeatSourceStatus: Equatable {
    case idle, starting
    /// Reading `n` Spotify process objects.
    case live(Int)
    case failed(String)
}

/// Where the beat comes from: the live tap, the simulated beat, or a test fake.
protocol SpotifyBeatSource: AnyObject {
    var status: BeatSourceStatus { get }
    func start()
    func stop()
    /// The newest sample. `heard`: non-zero audio arrived since the last read.
    func read(now: TimeInterval, dt: Double) -> (sample: BeatSample, heard: Bool)
}

final class SimulatedSpotifyBeatSource: SpotifyBeatSource {
    private let baseSeed: UInt64
    private var beat: SimulatedBeat
    private var origin: TimeInterval?
    private(set) var status: BeatSourceStatus = .idle

    init(seed: UInt64) {
        baseSeed = seed
        beat = SimulatedBeat(seed: seed)
    }

    var bpm: Double { beat.bpm }

    /// A new song: a new tempo and pattern from the song's key, starting on a beat.
    func song(_ key: String?) {
        beat = SimulatedBeat(seed: baseSeed ^ BeatMath.seed(key ?? ""))
        origin = nil
    }

    /// The same pattern at a measured tempo (the paused pulse).
    func tempo(_ bpm: Double) {
        beat = SimulatedBeat(seed: beat.seed, bpm: bpm)
        origin = nil
    }

    func start() { status = .live(0) }
    func stop() { status = .idle; origin = nil }

    func read(now: TimeInterval, dt: Double) -> (sample: BeatSample, heard: Bool) {
        if origin == nil { origin = now }
        return (beat.sample(at: now - (origin ?? now)), true)
    }
}

/// The song's tempo from the live kicks: the median gap between kick onsets (the last 16), folded into 80...170 BPM.
struct BeatTempo {
    private var lastOnset: Double?
    private var previous = 0.0
    private var gaps: [Double] = []

    mutating func reset() { lastOnset = nil; previous = 0; gaps.removeAll() }

    mutating func observe(_ kick: Double, now: Double) {
        defer { previous = kick }
        guard kick > 0.5, previous <= 0.5 else { return }
        if let l = lastOnset, now - l >= 0.25, now - l <= 1.5 {
            gaps.append(now - l)
            if gaps.count > 16 { gaps.removeFirst() }
        }
        lastOnset = now
    }

    /// Nil until four gaps are known.
    var bpm: Double? {
        guard gaps.count >= 4 else { return nil }
        let g = gaps.sorted()[gaps.count / 2]
        var bpm = 60 / g
        while bpm < 80 { bpm *= 2 }
        while bpm > 170 { bpm /= 2 }
        return bpm
    }
}

/// Seconds from Spotify's sound at the tap to the speakers: the default output device's latency, safety offset and
/// buffer, and its first output stream's latency. 0 when a read fails.
enum OutputLatency {
    static func current() -> Double {
        func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                     _ zero: T) -> T? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = zero
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        let output = kAudioObjectPropertyScopeOutput, global = kAudioObjectPropertyScopeGlobal
        guard let device = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, global,
                                AudioObjectID(0)), device != 0,
              let rate = read(device, kAudioDevicePropertyNominalSampleRate, global, Float64(0)), rate > 0 else { return 0 }
        var frames = Double(read(device, kAudioDevicePropertyLatency, output, UInt32(0)) ?? 0)
        frames += Double(read(device, kAudioDevicePropertySafetyOffset, output, UInt32(0)) ?? 0)
        frames += Double(read(device, kAudioDevicePropertyBufferFrameSize, global, UInt32(0)) ?? 0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: output,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                frames += Double(read(first, kAudioStreamPropertyLatency, global, UInt32(0)) ?? 0)
            }
        }
        let seconds = frames / rate
        return seconds.isFinite ? seconds : 0
    }
}

/// The values the audio callback shares with the main thread: atomics and one preallocated meter.
final class BeatTapShared: @unchecked Sendable {
    /// The two envelopes as Float bit patterns: overall in the high half, low band in the low half.
    let levels = Atomic<UInt64>(0)
    let heard = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    /// Written only by the audio thread while the device runs, and by the tap queue while it is stopped.
    let meter: UnsafeMutablePointer<BeatMeter>

    init() {
        meter = .allocate(capacity: 1)
        meter.initialize(to: BeatMeter())
    }

    deinit {
        meter.deinitialize(count: 1)
        meter.deallocate()
    }

    /// The audio callback's whole job. Real-time safe: no allocation, no lock, nothing kept past this call.
    func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0, let data = buffers[0].mData else { return }
        let channels = Int(max(1, buffers[0].mNumberChannels))
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        let r = meter.pointee.process(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
        levels.store(UInt64(r.rms.bitPattern) << 32 | UInt64(r.low.bitPattern), ordering: .relaxed)
        if r.peak > 0 { heard.store(true, ordering: .relaxed) }
        callbacks.wrappingAdd(1, ordering: .relaxed)
    }

    func load() -> (rms: Double, low: Double) {
        let v = levels.load(ordering: .relaxed)
        return (Double(Float(bitPattern: UInt32(v >> 32))), Double(Float(bitPattern: UInt32(v & 0xFFFF_FFFF))))
    }
}

/// The live source: a private, unmuted Core Audio process tap on Spotify's process objects only, in a private aggregate
/// device. Built and destroyed on its own serial queue (never on the main thread), rebuilt when the process list changes.
final class LiveSpotifyBeatSource: SpotifyBeatSource {
    /// The test and picture runs never create a tap (the same rule as `LiveURLOpener.blocked`).
    static let blocked = CommandLine.arguments.contains { ["--unittest", "--uishots", "--edgeglasscheck", "--sidebartest"].contains($0) }
    static let bundleID = LiveSpotifyBackend.bundleID

    /// Spotify's process objects: its own bundle id or a helper's (`com.spotify.client.…`), those with running output
    /// first. Pure, so the tests check it.
    static func select(_ processes: [(id: AudioObjectID, bundleID: String?, runningOutput: Bool)]) -> [AudioObjectID] {
        let spotify = processes.filter { p in
            guard let b = p.bundleID else { return false }
            return b == bundleID || b.hasPrefix(bundleID + ".")
        }
        let playing = spotify.filter(\.runningOutput)
        return (playing.isEmpty ? spotify : playing).map(\.id)
    }

    private let queue = DispatchQueue(label: "merlin.beat.tap", qos: .userInitiated)
    private let shared = BeatTapShared()
    private let statusLock = OSAllocatedUnfairLock<BeatSourceStatus>(initialState: .idle)
    private var analyzer = BeatAnalyzer() // main thread only
    // The tap queue's own state.
    private var wanted = false
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private var listener: AudioObjectPropertyListenerBlock?

    var status: BeatSourceStatus { statusLock.withLock { $0 } }
    private func setStatus(_ s: BeatSourceStatus) { statusLock.withLock { $0 = s } }

    func start() {
        guard !Self.blocked else { return setStatus(.failed("live tap blocked in a test or picture run")) }
        setStatus(.starting)
        queue.async { [self] in
            wanted = true
            addListener()
            rebuild()
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            removeListener()
            teardown()
            setStatus(.idle)
        }
    }

    deinit {
        // No queued block can still hold `self` here, so this runs alone.
        removeListener()
        teardown()
    }

    func read(now: TimeInterval, dt: Double) -> (sample: BeatSample, heard: Bool) {
        let heard = shared.heard.exchange(false, ordering: .relaxed)
        let v = shared.load()
        return (analyzer.update(rms: v.rms, low: v.low, dt: dt), heard)
    }

    // MARK: Tap queue

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func addListener() {
        guard listener == nil else { return }
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processListChanged() }
        if AudioObjectAddPropertyListenerBlock(Self.system, &addr, queue, block) == noErr { listener = block }
    }

    private func removeListener() {
        guard let block = listener else { return }
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        _ = AudioObjectRemovePropertyListenerBlock(Self.system, &addr, queue, block)
        listener = nil
    }

    private func processListChanged() {
        guard wanted else { return }
        rebuild()
    }

    /// Re-selects Spotify's process objects; rebuilds the tap only when they changed (or no tap runs).
    private func rebuild() {
        guard wanted else { return }
        let ids = Self.select(Self.processObjects())
        if ids == tapped && aggregate != AudioObjectID(kAudioObjectUnknown) { return }
        teardown()
        guard !ids.isEmpty else { return setStatus(.failed("no Spotify audio process")) }
        if let why = createTap(ids) {
            teardown()
            setStatus(.failed(why))
        } else {
            tapped = ids
            setStatus(.live(ids.count))
        }
    }

    private static func processObjects() -> [(id: AudioObjectID, bundleID: String?, runningOutput: Bool)] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = address(kAudioProcessPropertyIsRunningOutput)
            let ok = AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running) == noErr
            return (id, string(id, kAudioProcessPropertyBundleID), ok && running != 0)
        }
    }

    /// A CFString property (the caller owns it, as the header says).
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// The default output device's UID and how many input streams it has (unknown counts as some).
    private static func defaultOutput() -> (uid: String?, inputStreams: Int) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return (nil, 1) }
        var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
        var ssize: UInt32 = 0
        let streams = AudioObjectGetPropertyDataSize(device, &saddr, 0, nil, &ssize) == noErr
            ? Int(ssize) / MemoryLayout<AudioStreamID>.size : 1
        return (string(device, kAudioDevicePropertyDeviceUID), streams)
    }

    /// The output device joins the aggregate as its clock only when it has NO input streams, so the aggregate's input is
    /// the tap alone and never a microphone. Otherwise: a tap-only aggregate. Pure, so the tests check it.
    static func clockDevice(uid: String?, inputStreams: Int) -> String? {
        guard let uid, inputStreams == 0 else { return nil }
        return uid
    }

    /// nil when the tap runs, else why not (with the failing call's OSStatus).
    private func createTap(_ ids: [AudioObjectID]) -> String? {
        guard !Self.blocked else { return "live tap blocked in a test or picture run" }
        let description = CATapDescription(stereoMixdownOfProcesses: ids)
        description.name = "Merlin beat"
        description.uuid = UUID()
        description.isPrivate = true          // only Merlin sees it
        description.muteBehavior = .unmuted   // Spotify stays audible
        description.isExclusive = false      // these processes only, never "everything but"
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else { return "AudioHardwareCreateProcessTap failed (OSStatus \(err))" }
        tap = tapID

        guard let tapUID = Self.string(tapID, kAudioTapPropertyUID) else { return "no tap UID" }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var faddr = Self.address(kAudioTapPropertyFormat)
        err = AudioObjectGetPropertyData(tapID, &faddr, 0, nil, &size, &format)
        guard err == noErr else { return "kAudioTapPropertyFormat failed (OSStatus \(err))" }
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return "tap format is not 32-bit float" }
        shared.meter.pointee = BeatMeter(sampleRate: format.mSampleRate) // the device is not running yet

        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Merlin beat",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,       // not in the user's sound device list
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]],
        ]
        let out = Self.defaultOutput()
        if let output = Self.clockDevice(uid: out.uid, inputStreams: out.inputStreams) {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = output
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID)
        guard err == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return "AudioHardwareCreateAggregateDevice failed (OSStatus \(err))" }
        aggregate = deviceID

        let shared = shared
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) { _, input, _, _, _ in shared.consume(input) }
        guard err == noErr, let proc else { return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(err))" }
        ioProc = proc
        err = AudioDeviceStart(deviceID, proc)
        guard err == noErr else { return "AudioDeviceStart failed (OSStatus \(err))" }
        return nil
    }

    /// Stop the device, destroy the IOProc, the aggregate device, then the tap. Safe to call twice.
    private func teardown() {
        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            if let ioProc {
                _ = AudioDeviceStop(aggregate, ioProc)
                _ = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregate)
        }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != AudioObjectID(kAudioObjectUnknown) { _ = AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        tapped = []
        shared.levels.store(0, ordering: .relaxed)
        shared.meter.pointee = BeatMeter()
    }
}

// MARK: - The shared beat

/// The one beat shared by the disc and the mini window. Listens only while the dock shows, Spotify runs and a song plays
/// (never under `Motion.still` or Reduce Motion). Pulled by the views once a frame; the same timestamp gives the same
/// sample, so two views never advance it twice.
final class SpotifyBeat {
    enum Mode: Equatable {
        case off
        case live(Int)
        case simulated(String)

        var logLine: String? {
            switch self {
            case .off: return nil
            case .live(let n): return "beat source: live (\(n) process objects)"
            case .simulated(let why): return "beat source: simulated (\(why))"
            }
        }
    }

    static let logger = Logger(subsystem: "com.kien.merlin", category: "beat")
    /// The tap gave only zeros (or nothing) for this long while a song played: use the simulated beat.
    static let silenceLimit: TimeInterval = 3

    /// The switch for the paused pulse (the user's choice, 2026-11-26: "Song paused: keep the beat effect"). Off: a
    /// paused song's strings settle to still circles.
    nonisolated(unsafe) static var pausedPulse = true
    static let pausedWhy = "paused: a softer pulse at the song's tempo"
    /// The paused pulse's strength (of a playing song's).
    static let pausedStrength = 0.6
    /// What the picture already adds after the sound (the attack spring and one frame), taken off the output delay.
    static let pictureLag: TimeInterval = 0.03

    static func shouldListen(shown: Bool, running: Bool, playing: Bool, motionOff: Bool) -> Bool {
        shown && running && playing && !motionOff
    }

    /// What a start attempt does. Pure, so the tests check it.
    enum StartDecision: Equatable {
        /// Not listening: the dock hidden, Spotify closed or paused.
        case none
        /// A song plays with the dock shown, but motion is off (`Motion.still`, Reduce Motion): no tap, still circles.
        case motionOff
        case simulated(String)
        case live
    }

    static func startDecision(shown: Bool, running: Bool, playing: Bool, motionOff: Bool, blocked: Bool,
                              hasLive: Bool, paused: Bool = false) -> StartDecision {
        guard shown && running && (playing || (paused && pausedPulse)) else { return .none }
        if motionOff { return .motionOff }
        // A paused song has no sound: the strings keep a softer pulse at the tempo the song played at.
        if !playing { return .simulated(pausedWhy) }
        if blocked { return .simulated("live tap blocked in a test or picture run") }
        return hasLive ? .live : .simulated("no live source")
    }

    private(set) var mode: Mode = .off
    private(set) var active = false
    /// A fixed frame for the pictures (edge-18): the strings draw this sample, even under `Motion.still`.
    var pinned: BeatSample?
    let liveBlocked: Bool
    let seed: UInt64
    private let makeLive: (() -> SpotifyBeatSource)?
    private(set) var live: SpotifyBeatSource?
    let simulated: SimulatedSpotifyBeatSource
    private let motionOff: () -> Bool
    var log: (String) -> Void = { line in SpotifyBeat.logger.notice("\(line, privacy: .public)") }
    private var song: String?
    private var lastNow: TimeInterval?
    private var last = BeatSample.zero
    private var liveSince: TimeInterval?
    private var lastHeard: TimeInterval?
    private var lastStatus: BeatSourceStatus = .idle
    private var loggedStart = false
    private var loggedMotionOff = false
    private var current: StartDecision = .none
    /// The paused pulse runs (simulated, softer, at the measured tempo).
    private(set) var isPaused = false
    /// The song's tempo, measured from the live kicks.
    private(set) var tempo = BeatTempo()
    /// How long the sound takes from the tap to the speakers (less `pictureLag`): the live samples wait this long, so the
    /// strings move when you hear the beat, not before (Bluetooth headphones add 0.1 to 0.3 s).
    private(set) var outputDelay: TimeInterval = 0
    private var delayed: [(time: TimeInterval, sample: BeatSample)] = []

    init(live: (() -> SpotifyBeatSource)? = { LiveSpotifyBeatSource() }, blocked: Bool = LiveSpotifyBeatSource.blocked,
         seed: UInt64? = nil, motionOff: @escaping () -> Bool = { Motion.still || Motion.reduceMotion }) {
        makeLive = live
        liveBlocked = blocked
        // Test and picture runs use a fixed seed, so every run draws the same.
        self.seed = seed ?? (blocked ? 0x5EED_B0A7 : UInt64.random(in: 1...UInt64.max))
        simulated = SimulatedSpotifyBeatSource(seed: self.seed)
        self.motionOff = motionOff
    }

    deinit { live?.stop() }

    /// Called by `SpotifyService` when the dock shows or hides, the song or its play state changes, or Reduce Motion
    /// changes.
    func update(shown: Bool, running: Bool, playing: Bool, paused: Bool = false, song: String?) {
        if song != self.song {
            self.song = song
            simulated.song(song)
            tempo.reset()
        }
        let decision = Self.startDecision(shown: shown, running: running, playing: playing, motionOff: motionOff(),
                                          blocked: liveBlocked, hasLive: makeLive != nil, paused: paused)
        if decision == .motionOff, !loggedMotionOff {
            loggedMotionOff = true
            log("beat source: not starting (Reduce Motion or still pictures: the strings stay still circles)")
        }
        let want = decision != .none && decision != .motionOff
        // A new decision (play to pause, pause to play) restarts the sources; the same one changes nothing.
        guard want != active || (want && decision != current) else { return }
        if active && want { // a restart (the stop below handles a plain stop)
            live?.stop()
            simulated.stop()
        }
        active = want
        current = want ? decision : .none
        isPaused = want && decision == .simulated(Self.pausedWhy)
        lastNow = nil
        last = .zero
        liveSince = nil
        lastHeard = nil
        lastStatus = .idle
        delayed.removeAll()
        if isPaused, let bpm = tempo.bpm { simulated.tempo(bpm) }
        if want, decision == .live {
            outputDelay = max(0, min(0.4, OutputLatency.current() - Self.pictureLag))
        }
        if want {
            // Unconditional, before anything can fail: the first sign in the log that a start was tried.
            if !loggedStart {
                loggedStart = true
                log("beat source: starting (live allowed: \(decision == .live))")
            }
            simulated.start()
            if case .simulated(let why) = decision {
                setMode(.simulated(why))
            } else {
                if live == nil { live = makeLive?() }
                live?.start()
            }
            if decision == .live {
                log(String(format: "beat sync: output delay %.0f ms (the strings wait this long after the tap)", outputDelay * 1000))
            }
        } else {
            live?.stop()
            simulated.stop()
            mode = .off // silent: the next start logs its source again
        }
    }

    /// The beat at `now` (seconds). Zero while not listening.
    func sample(now: TimeInterval) -> BeatSample {
        guard active else { return .zero }
        if let l = lastNow, now == l { return last }
        let dt = lastNow.map { min(max(now - $0, 0), 0.1) } ?? 1.0 / 60
        lastNow = now
        var next = mode
        var out = BeatSample.zero
        if let live, !liveBlocked {
            let reading = live.read(now: now, dt: dt)
            let status = live.status
            if status != lastStatus { lastStatus = status; liveSince = now; lastHeard = nil }
            if reading.heard { lastHeard = now }
            switch status {
            case .failed(let why):
                next = .simulated(why)
            case .idle, .starting, .live:
                let since = liveSince ?? now
                if now - max(since, lastHeard ?? since) >= Self.silenceLimit {
                    next = .simulated("no sound from Spotify for 3 s; audio capture may be denied")
                } else if case .live(let n) = status, lastHeard != nil {
                    next = .live(n)
                } else if case .live(let n) = status, mode == .off {
                    next = .live(n)
                }
            }
            if case .live = next {
                tempo.observe(reading.sample.kick, now: now)
                out = delay(reading.sample, now: now)
            }
        }
        if case .simulated = next { out = simulated.read(now: now, dt: dt).sample }
        if isPaused {
            let k = Self.pausedStrength
            out = BeatSample(level: out.level * k, bass: out.bass * k, kick: out.kick * k)
        }
        setMode(next)
        last = out
        return out
    }

    /// The live sample from `outputDelay` ago (the newest one when no delay is needed).
    private func delay(_ s: BeatSample, now: TimeInterval) -> BeatSample {
        guard outputDelay > 0.005 else { return s }
        delayed.append((now, s))
        let due = now - outputDelay
        // The first entry stays the newest sample that is due (so a frame between two samples never drops to zero).
        while delayed.count > 1, delayed[1].time <= due { delayed.removeFirst() }
        return delayed[0].time <= due ? delayed[0].sample : .zero
    }

    private func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        if let line = m.logLine { log(line) }
    }
}

// MARK: - The strings (pure geometry and motion)

/// Three rings round the record, driven by the beat. Each ring's radius is
/// `base + pulse + amplitude · Σ wⱼ sin(nⱼ θ + φⱼ)` with Σ wⱼ = 1, so |shape| ≤ 1 and the ring stays in its band by
/// construction (and a final clamp keeps it there even if a spring overshoots).
enum BeatStrings {
    static let rings = 3
    /// Points per ring (cubic segments with exact tangents, so the outline stays smooth).
    static let points = 96

    /// Where the strings may go: the stroke's inner and outer edge limits from the centre.
    struct Place: Equatable {
        /// Nearest the stroke may come to the centre (clear of the record and its rim).
        let inner: CGFloat
        /// The calm look's outer edge (the Stitch wave extent): the three rings rest at 10, 46 and 82 % of
        /// `inner`...`outer`.
        let outer: CGFloat
        /// How far a stroke's edge may travel on a beat: `clearance` short of the nearest neighbour (the disc's rim
        /// buttons and timer chip, or the card's search field, caption line and edges).
        let limit: CGFloat

        /// Line widths inner to outer: one weight for all three, so the calm rings look the same.
        static let lineWidth = 1.25
        static let lineWidths: SIMD3<Double> = [lineWidth, lineWidth, lineWidth]
        /// The strings keep at least this from every neighbour, even at full drive with springs overshooting.
        static let clearance: CGFloat = 4
        /// Each ring's share of the outer ring's jump (inner, middle, outer).
        static let jumpShares: SIMD3<Double> = [0.45, 0.7, 1]

        /// The dock's disc: the record (`coverSize`), the three rim buttons (`discButtonCentre`, `plusSize`), the timer
        /// chip's nearest point. (The disc's search field never shows with the record: the strings hide while it does.)
        static var disc: Place {
            typealias L = EdgePanelLayout
            let c = L.coverCentre
            let buttons = (0..<3).map { row -> CGFloat in
                let b = L.discButtonCentre(row)
                return hypot(b.x - c.x, b.y - c.y) - L.plusSize / 2
            }.min() ?? 0
            let f = L.timerChipFrame
            let chip = hypot(min(max(c.x, f.minX), f.maxX) - c.x, min(max(c.y, f.minY), f.maxY) - c.y)
            return Place(inner: L.coverSize / 2 + 3, outer: L.discWavesRadius, limit: min(buttons, chip) - clearance)
        }

        /// The mini window: the record (`spotifyRecord`); calm out to the orb's frame (`spotifyOrbRadius`); on a beat up to
        /// `clearance` short of the search field, the caption line and the card's sides.
        static var card: Place {
            typealias L = EdgePanelLayout
            let y = L.spotifyRecordCentreY
            let caption = L.spotifyCaptionTop - y, field = y - L.spotifyPad - L.spotifySearchHeight
            return Place(inner: L.spotifyRecord / 2 + 3, outer: min(L.spotifyOrbRadius - 1, caption - 1),
                         limit: min(caption, field, L.listWidth / 2) - clearance)
        }

        /// Ring `i`'s largest jump outward on a beat (pulse plus lobes), from its calm radius: the outer ring's room up to
        /// `limit`, times its share.
        func jump(_ i: Int) -> Double {
            let outerRoom = Double(limit) - base(2) - halfWidth(2)
            return max(0, outerRoom) * Place.jumpShares[i]
        }

        func halfWidth(_ i: Int) -> Double { Place.lineWidths[i] / 2 }
        /// The most a ring's lobes may swing either way: under half the gap at rest (less the stroke and 1 pt), so two
        /// neighbours swinging toward each other never meet. The outward beat jump (the pulse) is not capped by this.
        var lobeCap: Double { max(0, (Double(outer - inner) * Place.gapShare - Place.lineWidth - 1) / 2) }
        /// The gap between neighbouring rings at rest, as a share of the band: 0.36 (2026-11-26: 20 % more than 0.30).
        static let gapShare = 0.36
        /// Ring `i`'s centre line: at 10 %, 46 % and 82 % of the band. On a beat the outer rings move further than the
        /// inner ones (`jumpShares`), so the gaps only grow.
        func base(_ i: Int) -> Double { Double(inner) + Double(outer - inner) * (0.10 + Place.gapShare * Double(i)) }
        /// How far ring `i`'s centre line may move on a beat (its jump: outward past the calm extent, toward `limit`).
        func excursion(_ i: Int) -> Double { jump(i) }
    }

    /// Lobe counts per ring (inner to outer): the main one first, two quieter ones mixed in.
    static let lobes: [SIMD3<Double>] = [[11, 6, 16], [9, 5, 13], [7, 4, 11]]
    /// How strongly each ring follows the music (inner strongest) and the kick (OUTER strongest, so a beat reads as one
    /// jump outward), and its delay in frames (inner fastest).
    static let gain: SIMD3<Double> = [1, 0.85, 0.72]
    /// The kick's weight per ring (the rings' sizes come from `Place.jumpShares`, outer most).
    static let kickGain: SIMD3<Double> = [1, 1, 1]
    /// The lobes' delay per ring. The kick's radius pulse has NO delay on any ring, so the jump lands on the beat.
    static let delayFrames = [0, 1, 2]
    /// Of a ring's jump (`Place.jump`): the lobe burst's share and the radius pulse's share (they add to 1).
    static let waveShare = 0.4
    static let pulseShare = 0.6
    /// The kick's share of the lobes' drive (the ragged edge of a thump).
    static let kickDrive = 0.85

    /// A kick scaled by the loudness: soft music gives small jumps, loud music full ones.
    static func kick(_ s: BeatSample) -> Double { s.kick * (0.55 + 0.45 * s.level) }

    /// What ring `i`'s lobes follow: the level, lifted by the bass, plus a share of the kick (the soft ceiling caps it).
    /// Zero in silence, so the rings are circles then.
    static func drive(_ s: BeatSample, ring i: Int) -> Double {
        s.level * (0.45 + 0.75 * s.bass) * gain[i] + kickDrive * kick(s) * kickGain[i]
    }

    /// Soft ceiling: 1:1 up to 0.8, then eases toward (never past) 1, so a spring's overshoot never hits the clamp hard.
    static func soft(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        if x <= 0.8 { return max(x, 0) }
        return 0.8 + 0.2 * tanh((x - 0.8) / 0.2)
    }

    /// One ring's numbers for one frame.
    struct Ring {
        var base: Double
        var amplitude: Double
        var pulse: Double
        var weights: SIMD3<Double>
        var lobes: SIMD3<Double>
        var phases: SIMD3<Double>
        var low: Double
        var high: Double

        /// The radius and its slope at angle θ, clamped to the band (flat where clamped).
        func radius(_ theta: Double) -> (r: Double, slope: Double) {
            let a = lobes * theta + phases
            var s = 0.0, d = 0.0
            for j in 0..<3 {
                s += weights[j] * sin(a[j])
                d += weights[j] * lobes[j] * cos(a[j])
            }
            let r = base + pulse + amplitude * s
            if r < low { return (low, 0) }
            if r > high { return (high, 0) }
            return (r, amplitude * d)
        }

        /// The largest distance from the base the formula can reach (before the clamp).
        var maxReach: Double { pulse + abs(amplitude) }

        func path(center c: CGPoint, points n: Int = BeatStrings.points) -> Path {
            var p = Path()
            let h = 2 * Double.pi / Double(n)
            func point(_ theta: Double) -> (CGPoint, CGVector) {
                let (r, dr) = radius(theta)
                let cs = cos(theta), sn = sin(theta)
                return (CGPoint(x: c.x + r * cs, y: c.y + r * sn), CGVector(dx: dr * cs - r * sn, dy: dr * sn + r * cs))
            }
            var (p0, d0) = point(0)
            p.move(to: p0)
            for i in 1...n {
                let (p1, d1) = point(Double(i) * h)
                p.addCurve(to: p1,
                           control1: CGPoint(x: p0.x + d0.dx * h / 3, y: p0.y + d0.dy * h / 3),
                           control2: CGPoint(x: p1.x - d1.dx * h / 3, y: p1.y - d1.dy * h / 3))
                p0 = p1; d0 = d1
            }
            p.closeSubpath()
            return p
        }
    }
}

/// A spring follower with unit mass: the attack spring while the target is above, the release spring while below.
/// Switching keeps the velocity, so a new beat never jolts it.
struct BeatSpring {
    var x = 0.0
    var v = 0.0

    mutating func step(to target: Double, dt: Double) {
        let p = target > x ? Motion.stringsAttack : Motion.stringsRelease
        let h = dt / 4
        for _ in 0..<4 {
            v += (p.stiffness * (target - x) - p.damping * v) * h
            x += v * h
        }
    }
}

/// One view's strings in motion: the followers, the wandering noise, the kick shoves and the settle. A class so the
/// view's `TimelineView` advances it in place (no copies, no allocation per frame).
final class BeatStringsMotion {
    private(set) var place: BeatStrings.Place
    let seed: UInt64
    private var rng: BeatRandom
    /// Noise time: runs faster with the music, stops when calm.
    private(set) var clock = 0.0
    private var amp = [BeatSpring](repeating: .init(), count: BeatStrings.rings)
    private var pulse = [BeatSpring](repeating: .init(), count: BeatStrings.rings)
    private var shoveSpeed = [Double](repeating: 0, count: BeatStrings.rings)
    private var shoveAngle = [Double](repeating: 0, count: BeatStrings.rings)
    private var history = [BeatSample](repeating: .zero, count: 8)
    private var head = 0
    private var lastTime: Double?
    private var previousKick = 0.0
    private var sinceShove = 1.0
    /// 1 while playing; eases to 0 over `Motion.edgeSettleDuration` after a pause.
    private(set) var energy = 0.0
    private var settleStart: Double?
    private var wasMoving = false

    init(place: BeatStrings.Place = .disc, seed: UInt64 = LiveSpotifyBeatSource.blocked ? 7 : UInt64.random(in: 1...UInt64.max)) {
        self.place = place
        self.seed = seed
        rng = BeatRandom(state: seed)
    }

    /// One frame at `now` (seconds). `moving`: a song plays and the dock shows.
    func advance(to now: Double, sample: BeatSample, moving: Bool, place: BeatStrings.Place) {
        self.place = place
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
            if p >= 1 { calm() }
        }
        wasMoving = moving
        guard dt > 0 else { return }

        head = (head + 1) % history.count
        history[head] = moving ? sample : .zero
        let s0 = history[head]
        // A kick's rising edge shoves each ring's phase a random way; the shove decays in about 0.25 s.
        if moving, s0.kick > 0.6, previousKick <= 0.6 || s0.kick - previousKick > 0.3, sinceShove > 0.15 {
            for i in 0..<BeatStrings.rings {
                let sign: Double = rng.unit() < 0.5 ? -1 : 1
                shoveSpeed[i] += sign * (3 + 4.5 * rng.unit()) * (1 - 0.2 * Double(i)) * s0.kick
            }
            sinceShove = 0
        }
        previousKick = s0.kick
        sinceShove += dt
        for i in 0..<BeatStrings.rings {
            let s = history[(head - BeatStrings.delayFrames[i] + history.count) % history.count]
            amp[i].step(to: BeatStrings.drive(s, ring: i), dt: dt)
            pulse[i].step(to: BeatStrings.kick(s0) * BeatStrings.kickGain[i], dt: dt)
            shoveAngle[i] += shoveSpeed[i] * dt
            shoveSpeed[i] *= exp(-dt / 0.25)
        }
        clock += dt * (0.35 + 1.4 * BeatStrings.soft(amp[0].x)) * energy
    }

    /// The calm shape: no drive, phases where they are.
    private func calm() {
        energy = 0
        settleStart = nil
        for i in 0..<BeatStrings.rings {
            amp[i] = .init(); pulse[i] = .init(); shoveSpeed[i] = 0
        }
        history = [BeatSample](repeating: .zero, count: history.count)
    }

    /// The still picture (`Motion.still`, Reduce Motion): the calm shape at the seed's phases.
    func rest(place: BeatStrings.Place) {
        self.place = place
        calm()
        clock = 0
        for i in 0..<BeatStrings.rings { shoveAngle[i] = 0 }
    }

    /// A fixed frame for the pictures: the followers at rest on `sample` (springs settled, no overshoot), a fixed clock.
    func pin(_ sample: BeatSample, place: BeatStrings.Place, clock: Double = 1.7) {
        self.place = place
        energy = 1
        self.clock = clock
        var r = BeatRandom(state: seed ^ 0x51CE)
        for i in 0..<BeatStrings.rings {
            amp[i] = BeatSpring(x: BeatStrings.drive(sample, ring: i))
            pulse[i] = BeatSpring(x: BeatStrings.kick(sample) * BeatStrings.kickGain[i])
            shoveAngle[i] = (r.unit() - 0.5) * 1.6 * sample.kick
        }
    }

    /// For the tests: drive every follower to `x` (1 or more: a spring overshooting).
    func force(_ x: Double, shove: Double = 0) {
        energy = 1
        for i in 0..<BeatStrings.rings {
            amp[i].x = x; pulse[i].x = x; shoveAngle[i] = shove * Double(i + 1)
        }
    }

    /// Ring `i` (0 inner, 2 outer) for this frame.
    func ring(_ i: Int) -> BeatStrings.Ring {
        let t = clock
        let rs = seed &+ UInt64(i) &* 0x1000
        func n(_ k: UInt64, _ speed: Double) -> Double { BeatMath.noise(rs ^ k, t * speed) }
        var w = SIMD3<Double>(0.62 + 0.3 * n(1, 0.21), 0.22 + 0.2 * n(2, 0.27), 0.16 + 0.16 * n(3, 0.33))
        w /= w.sum()
        let dir: Double = i == 1 ? -1 : 1
        let shove = shoveAngle[i]
        let phases = SIMD3<Double>(
            BeatMath.hash(rs, 11) * 2 * .pi + dir * 0.9 * t + 1.4 * n(4, 0.17) + shove,
            BeatMath.hash(rs, 12) * 2 * .pi - dir * 1.3 * t + 1.2 * n(5, 0.19) - 0.6 * shove,
            BeatMath.hash(rs, 13) * 2 * .pi + dir * 1.7 * t + 1.0 * n(6, 0.23) + 0.4 * shove)
        let e = place.jump(i)
        let drive = BeatStrings.soft(amp[i].x) * energy
        let kick = BeatStrings.soft(pulse[i].x) * energy
        // No calm wobble: with no drive (silence, a pause, the settle's end, Motion.still, Reduce Motion) the amplitude
        // and the pulse are exactly 0, so each ring is a true circle at its base radius. A beat: the radius pulse
        // (outward) and the lobe burst (the ragged edge) together reach at most the ring's jump.
        return BeatStrings.Ring(
            base: place.base(i),
            amplitude: min(e * BeatStrings.waveShare * drive, place.lobeCap * max(drive, 0) / 0.8),
            pulse: e * BeatStrings.pulseShare * kick,
            weights: w, lobes: BeatStrings.lobes[i], phases: phases,
            low: Double(place.inner) + place.halfWidth(i), high: Double(place.limit) - place.halfWidth(i))
    }
}
