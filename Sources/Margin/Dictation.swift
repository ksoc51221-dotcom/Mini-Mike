import AVFoundation
import Speech

/// Press-and-talk dictation for voice commands: English, on this Mac, nothing saved to disk.
///
/// It's built to feel instant:
/// - The microphone starts the moment you press. Everything you say is held in memory from then on, so no words are
///   lost even while the recognizer is still waking up (it hands over what it missed as soon as it's ready).
/// - The speech model is loaded once when Margin starts (`warmUp`), and it's never "installed" again on each press
///   (that check used to cost about 3 seconds every time).
/// - Words appear while you talk, and the text is ready a moment after you let go.
final class Dictation {
    enum Failure: LocalizedError {
        case noMicrophone, notInstalled, unsupported

        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "No microphone found."
            case .notInstalled: return "Apple's English speech model isn't on this Mac yet."
            case .unsupported: return "This Mac can't turn speech into text."
            }
        }
    }

    static let locale = Locale(identifier: "en-US")

    // MARK: - Once per launch

    /// Is Apple's English model on this Mac? (A quick look; never downloads anything.)
    static func isInstalled() async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
    }

    /// Loads the speech model into memory so the first press doesn't wait for it. Safe to call any time; it does nothing
    /// if the model isn't installed.
    static func warmUp() async {
        guard let (transcriber, format) = await makeTranscriber() else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }

    /// The one place that downloads the model, and only when the pill's Download button is pressed.
    static func installModel(progress: @escaping (Double) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupported }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            _ = try? await AssetInventory.reserve(locale: supported)
            let poll = Task {
                while !Task.isCancelled {
                    let fraction = request.progress.fractionCompleted
                    await MainActor.run { progress(fraction) }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
    }

    /// A transcriber and the audio format it wants, if the model is installed. (A transcriber can only ever belong to
    /// one analyzer, so every press makes a fresh one; with the model warm that takes about 20 ms.)
    private static func makeTranscriber() async -> (SpeechTranscriber, AVAudioFormat)? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        return (transcriber, format)
    }

    // MARK: - One press

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var micFormat: AVAudioFormat?
    private var recognizerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// What was heard before the recognizer was ready (held in memory only).
    private var pending: [AVAudioPCMBuffer] = []
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var recognizerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var finals: [String] = []
    private var partial = ""
    private var stopped = false
    /// How much sound has come in at all (a tap that heard nothing has nothing to wait for).
    private var heardFrames = 0

    /// The words so far, on the main queue.
    var onText: ((String) -> Void)?
    /// The loudness (0…1) for the meter, on the main queue.
    var onLevel: ((Float) -> Void)?
    /// The recognizer couldn't start (the model isn't installed); the microphone has already been stopped.
    var onFailure: ((Error) -> Void)?

    /// Turns the microphone on. Returns at once; `onFailure` says if it didn't work.
    func start() {
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await Self.startEngine { [weak self] buffer in self?.heard(buffer) }
                guard self.adopt(engine) else { // you let go before it was even on
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    return
                }
                self.recognizerTask = Task { [weak self] in
                    do { try await self?.startRecognizer() } catch { self?.fail(error) }
                }
            } catch {
                self.fail(error)
            }
        }
    }

    /// The microphone, started off the main thread (waking the audio hardware can take a moment, and the pill shouldn't wait).
    private static func startEngine(tap: @escaping (AVAudioPCMBuffer) -> Void) async throws -> AVAudioEngine {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { return continuation.resume(throwing: Failure.noMicrophone) }
                node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in tap(buffer) }
                engine.prepare()
                do {
                    try engine.start()
                    continuation.resume(returning: engine)
                } catch {
                    node.removeTap(onBus: 0)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func adopt(_ engine: AVAudioEngine) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.engine = engine
        micFormat = engine.inputNode.outputFormat(forBus: 0)
        return true
    }

    /// Hands the recognizer what was heard while it was waking up, and everything after. False if you've let go.
    private func attach(_ analyzer: SpeechAnalyzer, format: AVAudioFormat, input continuation: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let mic = micFormat else { return false }
        self.analyzer = analyzer
        recognizerFormat = format
        converter = mic == format ? nil : AVAudioConverter(from: mic, to: format)
        input = continuation
        for buffer in pending { yield(buffer) }
        pending = []
        return true
    }

    private func noSoundYet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heardFrames == 0
    }

    private func snapshotText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return currentText()
    }

    /// Gets a recognizer going; whatever was heard in the meantime is handed to it.
    private func startRecognizer() async throws {
        guard let (transcriber, format) = await Self.makeTranscriber() else { throw Failure.notInstalled }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.recognized(String(result.text.characters), isFinal: result.isFinal) }
            } catch {}
        }
        try await analyzer.start(inputSequence: sequence)
        if !attach(analyzer, format: format, input: continuation) {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
        }
    }

    /// Runs on the audio thread for every little chunk of sound.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            let level = min(1, rms * 8)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        heardFrames += Int(buffer.frameLength)
        if input != nil {
            yield(buffer)
        } else if let copy = Self.copy(buffer) { // the engine may reuse its buffer, so keep our own
            pending.append(copy)
        }
    }

    /// Caller holds the lock.
    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard let input, let format = recognizerFormat else { return }
        if let converter {
            if let out = Self.convert(buffer, with: converter, to: format) { input.yield(AnalyzerInput(buffer: out)) }
        } else {
            input.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private func recognized(_ text: String, isFinal: Bool) {
        lock.lock()
        if isFinal {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { finals.append(clean) }
            partial = ""
        } else {
            partial = text
        }
        let all = currentText()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onText?(all) }
    }

    /// Caller holds the lock.
    private func currentText() -> String {
        (finals + [partial]).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ error: Error) {
        stop(cancelRecognizer: true)
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    /// Turns the microphone off. Returns the engine so the caller can wait for the recognizer separately.
    private func stop(cancelRecognizer: Bool) {
        lock.lock()
        stopped = true
        let engine = self.engine
        self.engine = nil
        let input = self.input
        self.input = nil
        pending = []
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        if cancelRecognizer {
            let analyzer = self.analyzer
            Task { await analyzer?.cancelAndFinishNow() }
        }
    }

    /// You let go: stops the microphone and returns everything that was said. Never waits more than a few seconds;
    /// if the recognizer is slow, you get the words it had already shown.
    func finish() async -> String {
        _ = try? await startTask?.value // a very quick tap: let the microphone finish starting before stopping it
        if noSoundYet() { // let go before any sound arrived: nothing to recognize
            stop(cancelRecognizer: true)
            return ""
        }
        // The recognizer may still be waking up; give it a moment so it can read what was held for it.
        _ = await Self.within(2) { [weak self] in _ = try? await self?.recognizerTask?.value }
        let analyzer = self.analyzer
        stop(cancelRecognizer: false)
        _ = await Self.within(3) { [weak self] in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            _ = await self?.resultsTask?.value
        }
        return snapshotText()
    }

    /// Throws everything away (the pill was dismissed).
    func cancel() {
        stop(cancelRecognizer: true)
    }

    // MARK: - Helpers

    /// Runs `work`, giving up on waiting for it after `seconds` (it's left to finish on its own). Plain task groups
    /// won't do: they wait for every child, so a stuck recognizer would hold the timeout hostage.
    private static func within(_ seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                await work()
                if once.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { done = true }
            return !done
        }
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData { memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))) }
        }
        return out
    }

    /// Resamples to what the speech model wants. The converter is kept between chunks so the sound stays continuous.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    // MARK: - For --micprobe

    /// Turns the microphone on for `seconds` and reports how quickly it started and how loud it was. Nothing is kept,
    /// recognized or sent: only these numbers. (Run through `open`, so macOS checks it as Margin itself.)
    static func probe(seconds: Double) async -> String {
        final class Tally: @unchecked Sendable {
            private let lock = NSLock()
            private var firstSound: Double?
            private var frames = 0
            private var peak: Float = 0
            private var format = ""
            func add(_ buffer: AVAudioPCMBuffer, since began: Date) {
                lock.lock()
                defer { lock.unlock() }
                if firstSound == nil {
                    firstSound = Date().timeIntervalSince(began)
                    let f = buffer.format
                    format = "\(f.commonFormat.rawValue) (1 float32, 2 float64, 3 int16, 4 int32), \(f.channelCount) ch, \(f.isInterleaved ? "interleaved" : "separate")"
                }
                frames += Int(buffer.frameLength)
                // Read the level whatever the sample format is.
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for b in list {
                    guard let data = b.mData else { continue }
                    switch buffer.format.commonFormat {
                    case .pcmFormatFloat32:
                        let p = data.assumingMemoryBound(to: Float.self)
                        for i in 0..<Int(b.mDataByteSize) / 4 { peak = max(peak, abs(p[i])) }
                    case .pcmFormatInt16:
                        let p = data.assumingMemoryBound(to: Int16.self)
                        for i in 0..<Int(b.mDataByteSize) / 2 { peak = max(peak, abs(Float(p[i])) / 32768) }
                    case .pcmFormatInt32:
                        let p = data.assumingMemoryBound(to: Int32.self)
                        for i in 0..<Int(b.mDataByteSize) / 4 { peak = max(peak, abs(Float(p[i])) / 2147483648) }
                    default: break
                    }
                }
            }
            var snapshot: (first: Double, frames: Int, peak: Float, format: String) {
                lock.lock()
                defer { lock.unlock() }
                return (firstSound ?? -1, frames, peak, format)
            }
        }
        let tally = Tally()
        let began = Date()
        do {
            let engine = try await startEngine { buffer in tally.add(buffer, since: began) }
            let on = Date().timeIntervalSince(began)
            let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            let t = tally.snapshot
            return String(format: "microphone on after %.0f ms; first sound after %.0f ms; %d frames at %.0f Hz (%.1f s); loudest %.5f; format %@",
                          on * 1000, t.first * 1000, t.frames, rate, Double(t.frames) / max(rate, 1), t.peak, t.format)
        } catch {
            return "microphone failed: \(error.localizedDescription)"
        }
    }

    // MARK: - For --voicedictation (no microphone)

    /// Starts as if the microphone were already on, with sound in `format`; feed sound in with `debugFeed`.
    func debugStart(format: AVAudioFormat) {
        setMicFormat(format)
        recognizerTask = Task { [weak self] in
            do { try await self?.startRecognizer() } catch { self?.fail(error) }
        }
    }

    func debugFeed(_ buffer: AVAudioPCMBuffer) { heard(buffer) }

    private func setMicFormat(_ format: AVAudioFormat) {
        lock.lock()
        micFormat = format
        lock.unlock()
    }
}
