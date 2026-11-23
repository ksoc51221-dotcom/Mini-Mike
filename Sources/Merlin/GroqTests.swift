import AVFoundation
import Foundation

/// A fake Groq: counts requests, keeps the last one, and answers as told. Never touches the network.
private final class FakeGroq: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _last: URLRequest?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return _last }
    let answer: @Sendable () async throws -> (Int, String)
    init(_ answer: @escaping @Sendable () async throws -> (Int, String)) { self.answer = answer }
    init(status: Int, body: String) { self.answer = { (status, body) } }

    private func record(_ request: URLRequest) { lock.lock(); _calls += 1; _last = request; lock.unlock() }

    var transport: GroqTransport {
        { [self] request in
            record(request)
            let (status, body) = try await answer()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

private final class TestSlot<T>: @unchecked Sendable { var value: T? }

/// Runs async work from a synchronous check, off the main thread (nothing here needs it).
private func waitFor<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let slot = TestSlot<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached { slot.value = await work(); done.signal() }
    done.wait()
    return slot.value!
}

extension FeatureTests {
    /// Groq Whisper: the WAV, the request, the fallbacks and the junk guard, all with a fake Groq and a key in memory.
    static func groqChecks(_ check: (String, Bool) -> Void) {
        // The key store the app would use in a test run is never the real Keychain.
        check("groq: tests use a key store in memory, not the Keychain", GroqKeys.shared is MemoryGroqKeyStore)

        // Timeout: 4 s plus half the clip.
        check("groq: the timeout is 4 s plus half the clip", GroqTranscriber.timeout(forClip: 0) == 4
              && GroqTranscriber.timeout(forClip: 10) == 9 && GroqTranscriber.timeout(forClip: 45) == 26.5)

        // The WAV.
        let second48k = [Float](repeating: 0.5, count: 48_000)
        let wav = GroqTranscriber.wav(samples: second48k, sampleRate: 48_000)
        func u32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ at: Int) -> UInt16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        func tag(_ at: Int) -> String { String(data: wav.subdata(in: at..<at + 4), encoding: .ascii) ?? "" }
        check("groq wav: RIFF / WAVE / fmt / data tags", tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && tag(36) == "data")
        check("groq wav: PCM, mono, 16 kHz, 16-bit", u32(16) == 16 && u16(20) == 1 && u16(22) == 1 && u32(24) == 16_000
              && u32(28) == 32_000 && u16(32) == 2 && u16(34) == 16)
        check("groq wav: one second at 48 kHz becomes 16 000 samples", u32(40) == 32_000 && wav.count == 44 + 32_000 && u32(4) == 36 + 32_000)
        let firstSample = wav.subdata(in: 44..<46).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        check("groq wav: a steady 0.5 stays 0.5 (16383)", firstSample == 16383)
        let loud = GroqTranscriber.wav(samples: [2, -2], sampleRate: 16_000)
        let hi = loud.subdata(in: 44..<46).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        let lo = loud.subdata(in: 46..<48).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        check("groq wav: too-loud samples are clipped, not wrapped", hi == 32767 && lo == -32767)
        let ramp = GroqTranscriber.resample([0, 1, 2, 3, 4, 5], from: 48_000, to: 16_000)
        check("groq wav: resampling 48 kHz to 16 kHz keeps every third sample", ramp == [0, 3])
        check("groq wav: 44.1 kHz resamples to the right length", GroqTranscriber.resample([Float](repeating: 0, count: 44_100), from: 44_100, to: 16_000).count == 16_000)
        check("groq wav: 16 kHz is left as it is", GroqTranscriber.resample([0.1, 0.2], from: 16_000, to: 16_000) == [0.1, 0.2])

        // The request.
        let request = GroqTranscriber.request(wav: Data([1, 2, 3, 0, 255]), key: "gsk_test", timeout: 6, boundary: "BOUND")
        let body = request.httpBody ?? Data()
        func has(_ s: String) -> Bool { body.range(of: Data(s.utf8)) != nil }
        check("groq request: POST to the transcriptions URL with the key", request.httpMethod == "POST"
              && request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions"
              && request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test"
              && request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND")
        check("groq request: the file field is a .wav with audio/wav", has("--BOUND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
              && body.range(of: Data([1, 2, 3, 0, 255])) != nil)
        check("groq request: model, language, format and temperature fields", has("name=\"model\"\r\n\r\nwhisper-large-v3\r\n")
              && has("name=\"language\"\r\n\r\nen\r\n") && has("name=\"response_format\"\r\n\r\njson\r\n")
              && has("name=\"temperature\"\r\n\r\n0\r\n") && has("--BOUND--\r\n"))

        // Deciding the final text.
        let clip = VoiceClip(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000) // 1 s
        let keys = MemoryGroqKeyStore(key: "gsk_test")
        func run(_ fake: FakeGroq, apple: String = "add lunch to my calendar", clip: VoiceClip? = clip, choice: VoiceEngine = .groq,
                 keys: GroqKeyStore = keys, timeout: TimeInterval? = nil) -> VoiceDecision.Result {
            let transport = fake.transport
            let wait: ((TimeInterval) -> TimeInterval)? = timeout.map { t in { _ in t } }
            return waitFor { await VoiceDecision.resolve(appleText: apple, clip: clip, choice: choice, keys: keys, transport: transport, timeout: wait) }
        }

        let ok = FakeGroq(status: 200, body: #"{"text": " Add lunch with Anna to my calendar. ", "x_groq": {"id": "r"}}"#)
        check("groq: Groq's text replaces Apple's", run(ok) == .deliver("Add lunch with Anna to my calendar.", .groq, badKey: false) && ok.calls == 1)
        check("groq: the request carries the key and the WAV", ok.last?.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test"
              && (ok.last?.httpBody?.range(of: Data("RIFF".utf8)) != nil))

        let refused = FakeGroq(status: 401, body: #"{"error": {"message": "Invalid API Key", "type": "invalid_request_error"}}"#)
        check("groq: a refused key (401) falls back to Apple's text and says so", run(refused) == .deliver("add lunch to my calendar", .onDevice, badKey: true))
        check("groq: the refused-key line shows once per run", VoiceDecision.shouldTellBadKey(true, alreadyTold: false)
              && !VoiceDecision.shouldTellBadKey(true, alreadyTold: true) && !VoiceDecision.shouldTellBadKey(false, alreadyTold: false))

        let slow = FakeGroq { try await Task.sleep(nanoseconds: 5_000_000_000); return (200, #"{"text": "late"}"#) }
        let began = Date()
        let timedOut = run(slow, timeout: 0.05)
        check("groq: too slow falls back to Apple's text, without waiting", timedOut == .deliver("add lunch to my calendar", .onDevice, badKey: false)
              && Date().timeIntervalSince(began) < 1.5)

        let offline = FakeGroq { throw URLError(.notConnectedToInternet) }
        check("groq: offline falls back to Apple's text", run(offline) == .deliver("add lunch to my calendar", .onDevice, badKey: false))
        let broken = FakeGroq(status: 500, body: #"{"error": {"message": "down"}}"#)
        check("groq: a server error falls back to Apple's text", run(broken) == .deliver("add lunch to my calendar", .onDevice, badKey: false))
        let blank = FakeGroq(status: 200, body: #"{"text": "  "}"#)
        check("groq: an empty Groq text falls back to Apple's text", run(blank) == .deliver("add lunch to my calendar", .onDevice, badKey: false))
        let garbage = FakeGroq(status: 200, body: "not json")
        check("groq: an unreadable answer falls back to Apple's text", run(garbage) == .deliver("add lunch to my calendar", .onDevice, badKey: false))

        let noKey = FakeGroq(status: 200, body: #"{"text": "x"}"#)
        check("groq: no key, no request", run(noKey, keys: MemoryGroqKeyStore()) == .deliver("add lunch to my calendar", .onDevice, badKey: false) && noKey.calls == 0)
        let onMac = FakeGroq(status: 200, body: #"{"text": "x"}"#)
        check("groq: 'On this Mac' never calls Groq, even with a key", run(onMac, choice: .onDevice) == .deliver("add lunch to my calendar", .onDevice, badKey: false) && onMac.calls == 0)

        let tap = FakeGroq(status: 200, body: #"{"text": "Thank you."}"#)
        let short = VoiceClip(samples: [Float](repeating: 0.1, count: 6_000), sampleRate: 16_000) // 0.375 s
        check("groq: a press under 0.4 s is dropped, with no request", run(tap, clip: short) == .discard && tap.calls == 0)
        check("groq: a press under 0.4 s is dropped on this Mac too", run(tap, clip: short, choice: .onDevice) == .discard)
        // Apple heard no words. On this Mac that is the end of it. With Groq ready (Apple's model may not even be installed),
        // the clip goes to Groq, but only when it has real sound in it: Whisper invents words for silence.
        let rate = 16_000.0
        func samples(_ seconds: Double, _ value: Float) -> [Float] { [Float](repeating: value, count: Int(seconds * rate)) }
        func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * rate)).map { 0.2 * sin(Float($0) * 2 * .pi * 220 / Float(rate)) } }
        let silence = VoiceClip(samples: samples(1.5, 0), sampleRate: rate)
        let hiss = VoiceClip(samples: (0..<24_000).map { $0 % 2 == 0 ? 0.003 : -0.003 }, sampleRate: rate) // a quiet room
        var clicked = samples(1.5, 0); for i in 8_000..<8_200 { clicked[i] = 0.9 } // one key click (12 ms)
        let click = VoiceClip(samples: clicked, sampleRate: rate)
        let speech = VoiceClip(samples: samples(0.6, 0) + tone(0.3) + samples(0.6, 0), sampleRate: rate) // 300 ms of sound in a pause
        check("speech guard: silence, a quiet room and a lone key click have no speech; 300 ms of sound has",
              !VoiceDecision.hasSpeech(silence) && !VoiceDecision.hasSpeech(hiss) && !VoiceDecision.hasSpeech(click) && VoiceDecision.hasSpeech(speech))
        check("groq: on this Mac, no words from Apple means nothing is sent or delivered", run(tap, apple: "  ", clip: speech, choice: .onDevice) == .discard
              && run(tap, apple: "  ", clip: speech, keys: MemoryGroqKeyStore()) == .discard && tap.calls == 0)
        check("groq: no words from Apple and a silent clip: dropped, no Groq call",
              run(tap, apple: "", clip: silence) == .discard && run(tap, apple: "", clip: click) == .discard && tap.calls == 0)
        let alone = FakeGroq(status: 200, body: #"{"text": "What is marginal cost?"}"#)
        check("groq: Apple's model absent + a key: the clip goes to Groq and its text is delivered",
              run(alone, apple: "", clip: speech) == .deliver("What is marginal cost?", .groq, badKey: false) && alone.calls == 1)
        check("groq: Groq fails and Apple has no text: a message, no chat",
              run(FakeGroq(status: 500, body: "{}"), apple: "", clip: speech) == .noAnswer(badKey: false)
              && run(FakeGroq { throw URLError(.notConnectedToInternet) }, apple: "", clip: speech) == .noAnswer(badKey: false)
              && run(FakeGroq(status: 200, body: #"{"text": " "}"#), apple: "", clip: speech) == .noAnswer(badKey: false))
        check("groq: Groq refuses the key and Apple has no text: says the key was refused, no chat",
              run(FakeGroq(status: 401, body: #"{"error": {"message": "Invalid API Key"}}"#), apple: "", clip: speech) == .noAnswer(badKey: true))
        check("groq: the two no-answer lines are plain and different", VoiceController.groqSilentMessage == "Groq did not answer. Try again."
              && VoiceController.groqRefusedMessage != VoiceController.groqSilentMessage)

        // Record-only: with Groq ready a missing Apple model is not a failure; without it, it is (and the prompt shows).
        let readyKeys = MemoryGroqKeyStore(key: "gsk_test")
        check("record-only: allowed with Groq chosen and a key; not with no key, and not on this Mac",
              VoiceDecision.usesGroq(choice: .groq, keys: readyKeys) && !VoiceDecision.usesGroq(choice: .groq, keys: MemoryGroqKeyStore())
              && !VoiceDecision.usesGroq(choice: .onDevice, keys: readyKeys))
        let fresh = Dictation()
        check("record-only: off unless the voice controller turns it on", !fresh.recordOnlyIfNoModel && !fresh.isRecordOnly)
        check("groq: exactly 0.4 s is long enough", run(FakeGroq(status: 200, body: #"{"text": "Yes."}"#),
                                                       clip: VoiceClip(samples: [Float](repeating: 0, count: 6_400), sampleRate: 16_000)) == .deliver("Yes.", .groq, badKey: false))

        // The Settings key test.
        func keyCheck(_ fake: FakeGroq) -> GroqTranscriber.KeyCheck {
            let transport = fake.transport
            return waitFor { await GroqTranscriber.check(key: "gsk_test", transport: transport, timeout: 2) }
        }
        let models = FakeGroq(status: 200, body: #"{"data": []}"#)
        check("groq key test: 200 means the key works, via the models URL", keyCheck(models) == .works
              && models.last?.url?.absoluteString == "https://api.groq.com/openai/v1/models" && (models.last?.httpMethod ?? "GET") == "GET")
        check("groq key test: 401 means refused", keyCheck(FakeGroq(status: 401, body: "{}")) == .refused)
        check("groq key test: offline means no connection", keyCheck(FakeGroq { throw URLError(.notConnectedToInternet) }) == .noConnection)
        check("groq key test: the three messages", GroqTranscriber.KeyCheck.works.message == "Key works"
              && GroqTranscriber.KeyCheck.refused.message == "Key refused" && GroqTranscriber.KeyCheck.noConnection.message == "No connection")

        // The engine setting: on this Mac until the first key is saved, then Groq.
        let suite = "com.kien.merlin.tests.groq-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let store = MemoryGroqKeyStore()
        check("groq setting: the engine starts as On this Mac", settings.voiceEngine == .onDevice)
        check("groq setting: an empty key isn't saved", !VoiceDecision.saveKey("   ", keys: store, settings: settings) && !store.hasKey && settings.voiceEngine == .onDevice)
        check("groq setting: the first saved key switches to Groq", VoiceDecision.saveKey(" gsk_new \n", keys: store, settings: settings)
              && store.read() == "gsk_new" && settings.voiceEngine == .groq)
        settings.voiceEngine = .onDevice
        _ = VoiceDecision.saveKey("gsk_other", keys: store, settings: settings)
        check("groq setting: replacing a key keeps your engine choice", settings.voiceEngine == .onDevice && store.read() == "gsk_other")
        VoiceDecision.removeKey(keys: store, settings: settings)
        check("groq setting: Remove forgets the key and goes back to On this Mac", !store.hasKey && settings.voiceEngine == .onDevice)
        check("groq: the refused-key notice is one short line", VoiceController.badKeyMessage.count <= 48)

        // The sound kept for Groq: the first channel, at the microphone's rate, at most 45 s, in memory.
        let d = Dictation()
        check("groq capture: nothing heard, no clip", d.clip == nil)
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        func chunk(_ format: AVAudioFormat, frames: Int, left: Float, right: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            b.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                b.floatChannelData![0][i] = left
                if format.channelCount > 1 { b.floatChannelData![1][i] = right }
            }
            return b
        }
        d.debugCapture(chunk(stereo, frames: 4_800, left: 0.25, right: -0.5))
        let tenth = d.clip
        check("groq capture: keeps the first channel at the mic's rate", tenth?.sampleRate == 48_000 && tenth?.samples.count == 4_800
              && (tenth?.samples.allSatisfy { $0 == 0.25 } ?? false) && abs((tenth?.duration ?? 0) - 0.1) < 1e-9)
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        d.debugCapture(chunk(other, frames: 441, left: 0.9, right: 0))
        check("groq capture: a chunk at another rate is skipped, not mixed in", d.clip?.samples.count == 4_800)
        let second = chunk(stereo, frames: 48_000, left: 0.25, right: -0.5)
        for _ in 0..<50 { d.debugCapture(second) }
        check("groq capture: stops at 45 s", d.clip?.samples.count == 45 * 48_000 && abs((d.clip?.duration ?? 0) - 45) < 1e-9)
        d.releaseClip()
        check("groq capture: released once used", d.clip == nil)
        d.debugCapture(chunk(stereo, frames: 480, left: 0.1, right: 0))
        d.cancel()
        check("groq capture: dismissing drops it", d.clip == nil)

        check("groq setting: the engine labels", VoiceEngine.groq.title == "Groq Whisper" && VoiceEngine.onDevice.title == "On this Mac")
    }
}
