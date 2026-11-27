import AVFoundation
import Speech

/// Press-and-talk dictation for voice commands: English, on this Mac, nothing saved to disk.
///
/// It's built to feel instant:
/// - The microphone starts the moment you press. Everything you say is held in memory from then on, so no words are
///   lost even while the recognizer is still waking up (it hands over what it missed as soon as it's ready).
/// - The speech model is loaded once when Merlin starts (`warmUp`), and it's never "installed" again on each press
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
        await MainActor.run { startKeepFresh() }
        await allocateIfOnThisMac()
        guard let (transcriber, format) = await makeTranscriber() else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }

    /// `--voicemodelcheck`: prints what macOS says about Apple's speech model, for both ways Merlin builds a transcriber.
    /// Reads only; no microphone, no download.
    static func printModelStatus() -> Never {
        Task {
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            print("supportedLocale=\(supported?.identifier(.bcp47) ?? "nil")")
            print("installedLocales=\(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })")
            if let supported {
                let plain = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                let live = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
                print("status(download config, no reporting options)=\(await AssetInventory.status(forModules: [plain]))")
                print("status(listen config, volatileResults)=\(await AssetInventory.status(forModules: [live]))")
                print("isInstalled()=\(await isInstalled())")
                print("reservedLocales=\(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })")
                print("bestFormat(listen config)=\(String(describing: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live])))")
                let request = try? await AssetInventory.assetInstallationRequest(supporting: [live])
                print("installationRequest(listen config) is \(request == nil ? "nil (nothing to download)" : "present (macOS wants a download)")")
                if CommandLine.arguments.contains("allocate"), let request {
                    let t0 = Date()
                    do { try await request.downloadAndInstall(); print("downloadAndInstall ok in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s") } catch { print("downloadAndInstall threw \(error)") }
                    print("status after allocate=\(await AssetInventory.status(forModules: [live]))")
                    print("reservedLocales after=\(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })")
                }
                if CommandLine.arguments.contains("killhelper") { await helperKillExperiment(supported) }
                if CommandLine.arguments.contains("reserve") {
                    do { let ok = try await AssetInventory.reserve(locale: supported); print("reserve -> \(ok)") } catch { print("reserve threw \(error)") }
                    print("status after reserve=\(await AssetInventory.status(forModules: [live]))")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--voicemodelcheck killhelper`: ends this process's own speech helper (as macOS does after an idle time), then
    /// prints what each repair step gives. A test process only; never the installed app's helper.
    static func helperPIDs() -> Set<Int32> {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "localspeechrecognition"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Set(out.split(separator: "\n").compactMap { Int32($0) })
    }

    static func helperKillExperiment(_ supported: Locale) async {
        func snap(_ label: String) async {
            let t0 = Date()
            let live = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            let status = await AssetInventory.status(forModules: [live])
            let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live]) != nil
            print("EXP \(label): status=\(status) reserved=\(reserved) format=\(format) (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
        }
        let known = Set((CommandLine.arguments.first { $0.hasPrefix("known=") } ?? "known=").dropFirst(6).split(separator: ",").compactMap { Int32($0) })
        let mine = helperPIDs().subtracting(known)
        print("EXP my helper(s): \(mine.sorted())")
        await snap("before kill")
        for pid in mine { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await snap("after kill")
        await snap("after kill, again")
        let t0 = Date()
        print("EXP app path makeTranscriber after kill: \(await makeTranscriber() != nil) (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
        let t1 = Date()
        print("EXP app path allocateIfOnThisMac after kill: \(await allocateIfOnThisMac()) (\(String(format: "%.2f", Date().timeIntervalSince(t1))) s)")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await snap("after 5 s")
        let live = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do { print("EXP reserve -> \(try await AssetInventory.reserve(locale: supported))") } catch { print("EXP reserve threw \(error)") }
        await snap("after reserve")
        do {
            if let r = try await AssetInventory.assetInstallationRequest(supporting: [live]) { try await r.downloadAndInstall(); print("EXP install ok") } else { print("EXP no install request") }
        } catch { print("EXP install threw \(error)") }
        await snap("after install")
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live]) {
            let analyzer = SpeechAnalyzer(modules: [live])
            do { try await analyzer.prepareToAnalyze(in: format); print("EXP prepareToAnalyze ok") } catch { print("EXP prepareToAnalyze threw \(error)") }
            await analyzer.cancelAndFinishNow()
        }
        await snap("after analyzer")
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("audio=") })?.dropFirst(6),
           let file = try? AVAudioFile(forReading: URL(fileURLWithPath: String(path))) {
            let t = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            let analyzer = SpeechAnalyzer(modules: [t])
            let collect = Task { () -> String in
                var text = ""
                do { for try await r in t.results { text += String(r.text.characters) } } catch { text += " [results threw \(error)]" }
                return text
            }
            do {
                if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
            } catch { print("EXP transcribe threw \(error)") }
            print("EXP transcript after kill: \"\(await collect.value)\"")
        }
        print("EXP helpers now: \(helperPIDs().subtracting(known).sorted())")
    }

    /// macOS can have the English model on the Mac (other apps use it) and still say it isn't set up for Merlin: each app
    /// has to claim it once. When the model is already here, claim it quietly (about 15 seconds, nothing to agree to, no
    /// prompt). When it isn't on the Mac at all this does nothing: that download needs your OK (the Download button).
    /// Returns whether the model is ready for Merlin afterwards.
    @discardableResult
    static func allocateIfOnThisMac() async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return true }
        guard await isInstalled() else { return false }
        // A stale status (macOS ended the helper): the engine still works, and a new claim would change nothing.
        if await makeTranscriber() != nil { return true }
        do { try await Transcription.install(transcriber, reserving: supported, progress: { _ in }) }
        catch { log("claim threw: \(error)") }
        var ready = await AssetInventory.status(forModules: [transcriber]) == .installed
        if !ready { ready = await makeTranscriber() != nil }
        log("claim ended: ready=\(ready)")
        return ready
    }

    // MARK: - Why a press found no model

    /// Which of three different faults stopped a press. Only `notOnMac` may offer a download: a model that is on this
    /// Mac must never show "Download".
    enum ModelProblem: Equatable {
        /// macOS gave no English model to match (`supportedLocale` was nil): a lookup fault, not a missing model.
        case noLocale
        /// The model really isn't on this Mac: the download needs your OK.
        case notOnMac
        /// The model is on this Mac, but it isn't ready for Merlin yet (the claim failed, or is slow).
        case notReady

        static func decide(localeFound: Bool, onMac: Bool) -> ModelProblem {
            guard localeFound else { return .noLocale }
            return onMac ? .notReady : .notOnMac
        }
    }

    /// What macOS says about the model at one moment. Reads only: no download, no claim.
    struct ModelProbe: Equatable {
        var locale: String?
        var status: String
        var onMac: Bool
        var hasFormat: Bool
        var reserved: [String]

        var problem: ModelProblem { .decide(localeFound: locale != nil, onMac: onMac) }
        var line: String {
            "locale=\(locale ?? "nil") status=\(status) onMac=\(onMac) format=\(hasFormat) reserved=\(reserved) -> \(problem)"
        }
    }

    static func probe() async -> ModelProbe {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return ModelProbe(locale: nil, status: "n/a", onMac: false, hasFormat: false, reserved: [])
        }
        let live = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [live])
        let onMac = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live])
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
        return ModelProbe(locale: supported.identifier(.bcp47), status: "\(status)", onMac: onMac, hasFormat: format != nil,
                          reserved: reserved)
    }

    /// One line in ~/Library/Logs/Merlin/voice.log, only in the installed app (never in a test run). It holds model
    /// states and errors only: never words, never sound.
    static func log(_ line: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Merlin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("voice.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 200_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// Downloads the model when it isn't on this Mac at all: only when the pill's Download button is pressed.
    /// (A model that is already on the Mac is claimed for Merlin without asking: see `allocateIfOnThisMac`.)
    static func installModel(progress: @escaping (Double) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupported }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await Transcription.install(transcriber, reserving: supported, progress: progress)
    }

    /// A transcriber and the audio format it wants, if the model is installed. (A transcriber can only ever belong to
    /// one analyzer, so every press makes a fresh one; with the model warm that takes about 20 ms.)
    private static func makeTranscriber() async -> (SpeechTranscriber, AVAudioFormat)? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        let installed = await AssetInventory.status(forModules: [transcriber]) == .installed
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        if installed { staleStatus.set(false); return (transcriber, format) }
        let onMac = await isInstalled()
        guard readiness(installed: installed, onMac: onMac, hasFormat: true) == .tryEngine else { return nil }
        // macOS ends an app's speech helper after an idle time. From then on `AssetInventory` tells this process
        // "supported, nothing reserved" for ever, and a new claim changes nothing, but the engine still works
        // (measured: `--voicemodelcheck killhelper`). So the status is not the judge: an engine that starts is.
        if !staleStatus.get() {
            guard await engineStarts(supported, format: format) else { log("status not installed and the engine does not start"); return nil }
            staleStatus.set(true)
            log("status is stale (speech helper was ended by macOS); the engine starts, so voice goes on")
        }
        return (transcriber, format)
    }

    /// How to treat a model that macOS does not report as installed for Merlin.
    enum Readiness: Equatable { case ready, tryEngine, notReady }

    /// `installed`: the status answer. `onMac`: the model's files are on this Mac. `hasFormat`: the engine names an audio
    /// format. A status that is not "installed" can be stale, so a model that is on the Mac gets one engine start as proof.
    static func readiness(installed: Bool, onMac: Bool, hasFormat: Bool) -> Readiness {
        if installed && hasFormat { return .ready }
        return onMac && hasFormat ? .tryEngine : .notReady
    }

    /// True after an engine start proved that the model works although the status says it is not installed.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }
    static let staleStatus = Flag()

    /// One engine start with a new transcriber (no microphone, no sound): the proof that the model works.
    static func engineStarts(_ supported: Locale, format: AVAudioFormat) async -> Bool {
        let probe = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [probe])
        do { try await analyzer.prepareToAnalyze(in: format) } catch { log("engine start threw: \(error)"); await analyzer.cancelAndFinishNow(); return false }
        await analyzer.cancelAndFinishNow()
        return true
    }

    /// Every 5 minutes: one status question in the background. After macOS ends the helper, the first question waits
    /// about 10 s for a dead connection; this takes that wait away from the next press. Started once by `warmUp`.
    nonisolated(unsafe) private static var keepTimer: DispatchSourceTimer?
    static func startKeepFresh() {
        guard keepTimer == nil, Bundle.main.bundleIdentifier != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "merlin.voice.keepfresh", qos: .utility))
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler { Task.detached(priority: .utility) { _ = await makeTranscriber() } }
        timer.resume()
        keepTimer = timer
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
    /// The press's sound for Groq: mono samples at the microphone's rate, at most `maxClipSeconds`. Memory only, never
    /// written to disk; kept apart from `pending` (which `stop` clears) and dropped by `cancel` and `releaseClip`.
    private var captured: [Float] = []
    private var capturedRate: Double = 0
    static let maxClipSeconds: Double = 45

    /// The words so far, on the main queue.
    var onText: ((String) -> Void)?
    /// The loudness (0…1) for the meter, on the main queue.
    var onLevel: ((Float) -> Void)?
    /// The recognizer couldn't start (the model isn't installed); the microphone has already been stopped.
    var onFailure: ((Error) -> Void)?
    /// Groq will make the text (it's chosen and a key is saved), so a missing Apple model isn't a failure: the microphone
    /// stays on, the sound is kept for Groq, and no live words show. Set by `VoiceController` before `start()`.
    var recordOnlyIfNoModel = false
    /// The press is running without Apple's recognizer (see `recordOnlyIfNoModel`).
    private(set) var isRecordOnly = false

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
                    do { try await self?.startRecognizer() } catch { self?.recognizerFailed(error) }
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

    /// No Apple model: with Groq ready that's fine (keep recording); otherwise the press fails and the prompt shows.
    private func recognizerFailed(_ error: Error) {
        if recordOnlyIfNoModel, case Failure.notInstalled = error {
            lock.lock()
            isRecordOnly = true
            pending = [] // nothing will ever read what was held for the recognizer
            lock.unlock()
            return
        }
        fail(error)
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
        capture(buffer)
        if input != nil {
            yield(buffer)
        } else if !isRecordOnly, let copy = Self.copy(buffer) { // the engine may reuse its buffer, so keep our own
            pending.append(copy)
        }
    }

    /// Keeps the first channel of `buffer` for Groq, up to the longest press. Caller holds the lock.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        if capturedRate == 0 { capturedRate = rate; captured.reserveCapacity(Int(rate * 8)) }
        guard rate == capturedRate else { return }
        let room = Int(Self.maxClipSeconds * rate) - captured.count
        let n = min(Int(buffer.frameLength), room)
        guard n > 0 else { return }
        captured.append(contentsOf: UnsafeBufferPointer(start: channel, count: n))
    }

    /// Tests: hands `capture` a buffer, as the microphone tap would.
    func debugCapture(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        capture(buffer)
        lock.unlock()
    }

    /// The press's sound, after `finish()` (nil if nothing was heard). Memory only.
    var clip: VoiceClip? {
        lock.lock()
        defer { lock.unlock() }
        guard capturedRate > 0, !captured.isEmpty else { return nil }
        return VoiceClip(samples: captured, sampleRate: capturedRate)
    }

    /// Drops the held sound (call once it has been sent or is no longer needed).
    func releaseClip() {
        lock.lock()
        captured = []
        lock.unlock()
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
        releaseClip()
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
    /// recognized or sent: only these numbers. (Run through `open`, so macOS checks it as Merlin itself.)
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
