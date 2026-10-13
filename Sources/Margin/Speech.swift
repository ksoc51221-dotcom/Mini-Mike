import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A word or short phrase Claude wants spoken: `<say lang="ru-RU" ipa="zɐˈmok">замо́к</say>`.
/// Claude decides *how* it should sound (the IPA carries the stress); a native macOS voice speaks it.
struct SayRequest: Hashable {
    /// As displayed, possibly with stress marks (замо́к).
    let text: String
    /// BCP-47 language, e.g. ru-RU.
    let lang: String
    let ipa: String?

    /// What the voice reads. Stress marks are dropped: the voice ignores them; the IPA does the work.
    var spokenText: String { text.replacingOccurrences(of: "\u{301}", with: "") }

    /// IPA without the /slashes/ or [brackets] Claude sometimes adds.
    var cleanIPA: String? {
        let trimmed = ipa?.trimmingCharacters(in: CharacterSet(charactersIn: "/[] ").union(.whitespacesAndNewlines))
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

// MARK: - Synthesis

enum Speech {
    struct Rendered {
        let url: URL
        let duration: TimeInterval
        let waveform: [CGFloat]
    }

    enum Failure: LocalizedError {
        case noVoice(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noVoice(let lang): return "No \(lang) voice on this Mac. Add one in System Settings → Accessibility → Spoken Content."
            case .timedOut: return "The voice didn't respond. Try again."
            }
        }
    }

    static let bars = 30

    static var audioDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/audio", isDirectory: true)
    }

    /// Clips are thrown away with their chat; this clears anything left from a previous run.
    static func clearLeftovers() {
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    /// The best installed voice for the language (premium > enhanced > default).
    static func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let exact = all.filter { $0.language.caseInsensitiveCompare(lang) == .orderedSame }
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        let candidates = exact.isEmpty ? all.filter { $0.language.lowercased().hasPrefix(base.lowercased()) } : exact
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// The utterance, with Claude's IPA attached word by word so the voice stresses the right syllable.
    static func utterance(for request: SayRequest, slow: Bool) -> AVSpeechUtterance {
        let plain = request.spokenText
        let text = NSMutableAttributedString(string: plain)
        if let ipa = request.cleanIPA {
            let key = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
            let words = wordRanges(plain)
            // Sentences: Claude gives one IPA word per spoken word; dashes and other bare punctuation
            // are skipped on both sides so they don't throw the pairing off.
            let parts = ipa.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: Self.punctuation) }
                .filter { !$0.isEmpty }
            if parts.count == words.count {
                for (range, part) in zip(words, parts) { text.addAttribute(key, value: part, range: range) }
            } else if words.count == 1 {
                text.addAttribute(key, value: ipa, range: NSRange(location: 0, length: (plain as NSString).length))
            }
            // Otherwise the counts don't line up; let the voice read it on its own rather than misapply IPA.
        }
        let utterance = AVSpeechUtterance(attributedString: text)
        utterance.voice = voice(for: request.lang)
        utterance.rate = slow ? 0.3 : AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    /// Punctuation that isn't spoken (IPA's own ˈ ˌ ː marks are letters, not punctuation, so they stay).
    static let punctuation = CharacterSet(charactersIn: ".,!?;:…—–-«»\"“”„()[]/")

    /// Ranges of the spoken words (tokens that are only punctuation, like a dash, are left out).
    static func wordRanges(_ s: String) -> [NSRange] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map(\.range).filter {
            !ns.substring(with: $0).trimmingCharacters(in: punctuation).isEmpty
        }
    }

    /// Kept alive while they write (the synthesizer stops if released).
    private static var active: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

    /// Speaks into an .m4a file and measures its waveform. Completion runs on main.
    static func render(_ request: SayRequest, slow: Bool, to url: URL,
                       completion: @escaping (Result<Rendered, Error>) -> Void) {
        guard voice(for: request.lang) != nil else { return completion(.failure(Failure.noVoice(request.lang))) }
        let synth = AVSpeechSynthesizer()
        let id = ObjectIdentifier(synth)
        active[id] = synth
        var samples: [Float] = []
        var sampleRate = 22_050.0
        var finished = false

        func finish(_ result: Result<Rendered, Error>) {
            DispatchQueue.main.async {
                guard active[id] != nil else { return } // already finished or timed out
                active[id] = nil
                completion(result)
            }
        }

        // Collect the whole take first, so the silence the voice adds around the word can be trimmed:
        // the clip then ends when the word ends, and the waveform is all word.
        synth.write(utterance(for: request, slow: slow)) { buffer in
            guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                sampleRate = pcm.format.sampleRate
                let count = Int(pcm.frameLength)
                if let ch = pcm.floatChannelData {
                    samples += UnsafeBufferPointer(start: ch[0], count: count)
                } else if let ch = pcm.int16ChannelData {
                    samples += UnsafeBufferPointer(start: ch[0], count: count).map { Float($0) / 32_768 }
                }
                return
            }
            finished = true
            let speech = trimSilence(samples, sampleRate: sampleRate)
            guard !speech.isEmpty else { return finish(.failure(Failure.noVoice(request.lang))) }
            do {
                try writeM4A(speech, sampleRate: sampleRate, to: url)
                finish(.success(Rendered(url: url, duration: Double(speech.count) / sampleRate,
                                         waveform: waveform(speech, bars: bars))))
            } catch {
                finish(.failure(error))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard active[id] != nil else { return }
            active[id] = nil
            completion(.failure(Failure.timedOut))
        }
    }

    /// Drops the quiet lead-in and tail (measured in 10 ms windows against the word's own peak, so the
    /// voice's faint noise floor counts as silence), keeping 50 ms so the word doesn't start abruptly.
    static func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        let window = max(1, Int(sampleRate * 0.01))
        let windows = samples.count / window
        guard windows > 0 else { return [] }
        let loudness: [Float] = (0..<windows).map { i in
            let slice = samples[(i * window)..<((i + 1) * window)]
            return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
        }
        let peak = loudness.max() ?? 0
        guard peak > 0.0005,
              let first = loudness.firstIndex(where: { $0 > peak * 0.06 }),
              let last = loudness.lastIndex(where: { $0 > peak * 0.06 }) else { return [] }
        let pad = Int(sampleRate * 0.05)
        return Array(samples[max(0, first * window - pad)..<min(samples.count, (last + 1) * window + pad)])
    }

    /// Mono float samples → AAC .m4a (plays anywhere, small to drag around).
    static func writeM4A(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Failure.timedOut }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: sampleRate,
                                              AVNumberOfChannelsKey: 1],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Bar heights 0…1 (loudness per slice, gently compressed so quiet sounds still show).
    static func waveform(_ samples: [Float], bars: Int) -> [CGFloat] {
        guard !samples.isEmpty else { return Array(repeating: 0.12, count: bars) }
        let chunk = max(1, samples.count / bars)
        let levels: [Float] = (0..<bars).map { i in
            let lo = min(samples.count, i * chunk), hi = min(samples.count, (i + 1) * chunk)
            guard hi > lo else { return 0 }
            let slice = samples[lo..<hi]
            return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
        }
        let peak = max(levels.max() ?? 1, 0.0001)
        return levels.map { CGFloat(max(0.12, sqrt($0 / peak))) }
    }
}

// MARK: - Playback

/// One voice message: renders itself, then plays like a chat voice note.
final class SpeechClip: ObservableObject {
    enum State: Equatable {
        case rendering
        case ready
        case failed(String)
    }

    let request: SayRequest
    @Published private(set) var state: State = .rendering
    @Published private(set) var waveform = Array(repeating: CGFloat(0.12), count: Speech.bars)
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var slow = false

    /// Called once, when the normal-speed take is ready (used for auto-play).
    var onReady: (() -> Void)?
    weak var store: SpeechStore?

    private let directory: URL
    private var takes: [Bool: Speech.Rendered] = [:]
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    init(request: SayRequest, directory: URL) {
        self.request = request
        self.directory = directory
        render(slow: false)
    }

    /// The normal-speed audio file (for drag-out / Save As).
    var fileURL: URL? { takes[false]?.url }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Plays from the start, or from `fraction` (tapping the waveform).
    func play(from fraction: Double? = nil) {
        guard let take = takes[slow] else { return }
        store?.stopAll(except: self)
        if player?.url != take.url {
            player = try? AVAudioPlayer(contentsOf: take.url)
            player?.prepareToPlay()
        }
        guard let player else { return }
        if let fraction {
            player.currentTime = fraction * player.duration
        } else if !isPlaying, progress == 0 {
            player.currentTime = 0
        }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        progress = 0
        ticker?.invalidate()
    }

    /// 🐢: switch to the slow take (rendered the first time it's needed) and play it.
    func toggleSlow() {
        stop()
        slow.toggle()
        if let take = takes[slow] {
            show(take)
            play()
        } else {
            state = .rendering
            render(slow: slow) { [weak self] in self?.play() }
        }
    }

    func saveAs() {
        guard let url = fileURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.spokenText.replacingOccurrences(of: "/", with: "-") + ".m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    func debugSetProgress(_ p: Double) { progress = p }

    private func render(slow: Bool, then: (() -> Void)? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        Speech.render(request, slow: slow, to: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let take):
                self.takes[slow] = take
                if slow == self.slow { self.show(take) }
                self.state = .ready
                then?()
                if !slow {
                    self.onReady?()
                    self.onReady = nil
                }
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func show(_ take: Speech.Rendered) {
        duration = take.duration
        waveform = take.waveform
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            if player.isPlaying {
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            } else {
                // Finished: rewind like a chat voice note.
                self.ticker?.invalidate()
                self.isPlaying = false
                self.progress = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}

/// All the voice clips in one chat. Thrown away (files included) when the chat closes.
final class SpeechStore {
    /// Set when a new question is asked: the first clip in the answer plays by itself.
    var autoPlayNext = false
    var canAutoPlay: () -> Bool = { true }

    private var clips: [SayRequest: SpeechClip] = [:]
    private let directory = Speech.audioDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    func clip(for request: SayRequest) -> SpeechClip {
        if let clip = clips[request] { return clip }
        let clip = SpeechClip(request: request, directory: directory)
        clip.store = self
        clip.onReady = { [weak self, weak clip] in
            guard let self, let clip, self.autoPlayNext, self.canAutoPlay() else { return }
            self.autoPlayNext = false
            clip.play()
        }
        clips[request] = clip
        return clip
    }

    var debugClips: [SpeechClip] { Array(clips.values) }

    func stopAll(except keep: SpeechClip? = nil) {
        for clip in clips.values where clip !== keep { clip.stop() }
    }

    func cleanup() {
        stopAll()
        clips.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
