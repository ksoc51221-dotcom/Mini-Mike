import AVFoundation
import ScreenCaptureKit
import Speech

/// The languages Margin can listen to.
enum SpokenLanguage: String, CaseIterable {
    case english = "en-US"
    case russian = "ru-RU"

    var title: String { self == .english ? "English" : "Русский" }
    var code: String { String(rawValue.prefix(2)) }
}

/// On-device speech-to-text with Apple's SpeechAnalyzer: the long-form SpeechTranscriber where it
/// supports the language (English and ~30 others), DictationTranscriber otherwise (e.g. Russian).
/// The first time a language is used, macOS downloads Apple's model for it.
final class Transcription: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Failure: LocalizedError {
        case unsupported(String)
        case notPrepared
        case noDisplay
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .unsupported(let lang): return "This Mac can't transcribe \(lang) yet."
            case .notPrepared: return "The speech model isn't ready."
            case .noDisplay: return "Couldn't find a display to listen through."
            case .noAudioTrack: return "That file has no sound to transcribe."
            }
        }
    }

    /// Finished lines so far, and the words still being recognized. Main queue.
    var onUpdate: ((_ lines: [VideoTranscript.Segment], _ partial: String) -> Void)?
    private(set) var lines: [VideoTranscript.Segment] = []
    private var partial = ""
    private var latestTime: TimeInterval = 0

    private let locale: Locale
    private var module: (any SpeechModule)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Error>?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var capture: SCStream?
    private var engine: AVAudioEngine?
    private let audioQueue = DispatchQueue(label: "margin.listen.audio")

    init(language: SpokenLanguage) {
        locale = Locale(identifier: language.rawValue)
    }

    /// Picks the engine and makes sure its model is on this Mac (downloading it the first time).
    func prepare(progress: @escaping (Double) -> Void) async throws {
        let module: any SpeechModule
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [.audioTimeRange])
            module = transcriber
            resultsTask = Task { [weak self] in
                for try await r in transcriber.results {
                    self?.receive(start: r.range.start.seconds, end: r.range.end.seconds,
                                  text: String(r.text.characters), isFinal: r.isFinal)
                }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, contentHints: [],
                                                   transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults],
                                                   attributeOptions: [.audioTimeRange])
            module = transcriber
            resultsTask = Task { [weak self] in
                for try await r in transcriber.results {
                    self?.receive(start: r.range.start.seconds, end: r.range.end.seconds,
                                  text: String(r.text.characters), isFinal: r.isFinal)
                }
            }
        } else {
            throw Failure.unsupported(locale.identifier)
        }
        self.module = module

        // Only ask macOS to install when the model really isn't there: asking when it is cost about 3 seconds every time.
        if await AssetInventory.status(forModules: [module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            _ = try? await AssetInventory.reserve(locale: locale)
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
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    // MARK: Listen along

    /// Transcribes the Mac's sound (Margin's own sounds excluded) until `stopListening`.
    func startListening() async throws {
        guard let module, analyzerFormat != nil else { throw Failure.notPrepared }
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: sequence)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure.noDisplay }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Audio is all we want; keep the (required) video side as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue) // ignored frames
        try await stream.startCapture()
        capture = stream
    }

    func stopListening() async throws {
        try? await capture?.stopCapture()
        capture = nil
        input?.finish()
        input = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(sampleBuffer), let converted = convert(pcm) else { return }
        input?.yield(AnalyzerInput(buffer: converted))
    }

    /// Is Apple's speech model for this language already on this Mac? (Never downloads anything.)
    static func isInstalled(_ language: SpokenLanguage) async -> Bool {
        let locale = Locale(identifier: language.rawValue)
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        }
        return false
    }

    // MARK: Files

    /// Transcribes a video or audio file, faster than real time. `progress` is 0…1 on main.
    func transcribeFile(_ url: URL, progress: @escaping (Double) -> Void) async throws {
        guard let module else { throw Failure.notPrepared }
        let audioURL = try await Self.soundtrack(of: url)
        let file = try AVAudioFile(forReading: audioURL)
        let total = max(1, Double(file.length) / file.processingFormat.sampleRate)
        fileProgress = { progress(min(0.99, $0 / total)) }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        _ = try? await resultsTask?.value
        if audioURL != url { try? FileManager.default.removeItem(at: audioURL) }
    }

    private var fileProgress: ((TimeInterval) -> Void)?

    /// Audio files are read directly; for videos, the soundtrack is copied out first (no re-encoding of video).
    static func soundtrack(of url: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw Failure.noAudioTrack }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("margin-\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }

    func cancel() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? await capture?.stopCapture()
        capture = nil
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    // MARK: Plumbing

    private func receive(start: TimeInterval, end: TimeInterval, text: String, isFinal: Bool) {
        DispatchQueue.main.async {
            if isFinal {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { self.lines.append(.init(start: start.isFinite ? start : self.latestTime, text: clean)) }
                self.partial = ""
            } else {
                self.partial = text
            }
            if end.isFinite { self.latestTime = max(self.latestTime, end) }
            self.fileProgress?(self.latestTime)
            self.onUpdate?(self.lines, self.partial)
        }
    }

    static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<Int(frames), into: buffer.mutableAudioBufferList)
        } catch {
            return nil
        }
        return buffer
    }

    /// Resamples to what the speech model wants (kept across calls so the resampler stays continuous).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = analyzerFormat else { return nil }
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
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
}
