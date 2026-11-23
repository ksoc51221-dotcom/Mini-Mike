import Foundation
import Security

/// Which engine turned the voice into the final text.
enum VoiceEngine: String, CaseIterable {
    /// Groq's Whisper (large-v3), over the internet. Used only when chosen in Settings and a key is saved.
    case groq
    /// Apple's speech model, on this Mac.
    case onDevice

    var title: String {
        switch self {
        case .groq: return "Groq Whisper"
        case .onDevice: return "On this Mac"
        }
    }
}

/// The sound of one press, held in memory only: mono samples at the microphone's own rate.
struct VoiceClip: Equatable {
    var samples: [Float]
    var sampleRate: Double
    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

// MARK: - The key

/// Where the Groq key is kept. The app uses the macOS Keychain; tests and pictures use a copy in memory.
protocol GroqKeyStore: AnyObject {
    func read() -> String?
    @discardableResult func save(_ key: String) -> Bool
    func remove()
}

extension GroqKeyStore {
    var hasKey: Bool { !(read() ?? "").isEmpty }
}

enum GroqKeys {
    /// The store the app uses. Tests (`--unittest`) and pictures (`--uishots`, `--settingsshots`) get one in memory, so
    /// they never read or write your real Keychain.
    nonisolated(unsafe) static var shared: GroqKeyStore = {
        let args = CommandLine.arguments
        let throwaway = ["--unittest", "--uishots", "--settingsshots"].contains { args.contains($0) }
        return throwaway ? MemoryGroqKeyStore() : KeychainGroqKeyStore()
    }()
}

/// The Groq key in the macOS Keychain, as a generic password. Never logged or printed.
final class KeychainGroqKeyStore: GroqKeyStore {
    let service: String
    let account = "groq-api-key"
    init(service: String = "com.kien.merlin.groq") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    @discardableResult
    func save(_ key: String) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let data = clean.data(using: .utf8) else { return false }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// A key kept in memory only (tests and pictures).
final class MemoryGroqKeyStore: GroqKeyStore {
    private var key: String?
    init(key: String? = nil) { self.key = key }
    func read() -> String? { key }
    @discardableResult func save(_ key: String) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        self.key = clean
        return true
    }
    func remove() { key = nil }
}

// MARK: - Groq

/// Sends one request and returns the answer. The app uses URLSession; tests pass a fake, so they never touch the network.
typealias GroqTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Turns a press's sound into text with Groq's Whisper. The sound is made into a WAV in memory (never written to disk),
/// sent once, and dropped.
enum GroqTranscriber {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let modelsEndpoint = URL(string: "https://api.groq.com/openai/v1/models")!
    static let model = "whisper-large-v3"
    /// Whisper's own rate.
    static let targetRate: Double = 16_000

    enum Outcome: Equatable {
        case text(String)
        /// 401: the key was refused.
        case badKey
        /// Offline, any other error, an empty answer, or too slow.
        case failed
    }

    enum KeyCheck: Equatable {
        case works, refused, noConnection
        var message: String {
            switch self {
            case .works: return "Key works"
            case .refused: return "Key refused"
            case .noConnection: return "No connection"
            }
        }
    }

    static let liveTransport: GroqTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// How long to wait for Groq before using the on-device text: 4 s plus half the clip's length.
    static func timeout(forClip seconds: TimeInterval) -> TimeInterval { 4 + max(0, seconds) / 2 }

    // MARK: The WAV

    /// Linear resampling to `to` Hz.
    static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, !samples.isEmpty else { return [] }
        if from == to { return samples }
        let count = Int((Double(samples.count) * to / from).rounded())
        guard count > 0 else { return [] }
        let step = from / to
        var out = [Float](repeating: 0, count: count)
        let last = samples.count - 1
        for i in 0..<count {
            let pos = Double(i) * step
            let j = min(Int(pos), last)
            let k = min(j + 1, last)
            let f = Float(pos - Double(j))
            out[i] = samples[j] + (samples[k] - samples[j]) * f
        }
        return out
    }

    /// A 16 kHz, mono, 16-bit PCM WAV file, in memory.
    static func wav(samples: [Float], sampleRate: Double) -> Data {
        let pcm = resample(samples, from: sampleRate, to: targetRate)
        let rate = UInt32(targetRate)
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data(capacity: 44 + Int(dataBytes))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(rate)
        u32(rate * 2) // bytes per second
        u16(2) // block align
        u16(16) // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in pcm {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    // MARK: The request

    static func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("model", model)
        field("language", "en")
        field("response_format", "json")
        field("temperature", "0")
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    static func request(wav: Data, key: String, timeout: TimeInterval, boundary: String = "merlin-\(UUID().uuidString)") -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = multipartBody(wav: wav, boundary: boundary)
        return r
    }

    /// Reads `{"text": "..."}`.
    static func text(fromJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One transcription. Never throws, never waits longer than `timeout`.
    static func transcribe(_ clip: VoiceClip, key: String, transport: @escaping GroqTransport, timeout: TimeInterval) async -> Outcome {
        let request = request(wav: wav(samples: clip.samples, sampleRate: clip.sampleRate), key: key, timeout: timeout)
        guard let (data, response) = await race(timeout, { try await transport(request) }) else { return .failed }
        if response.statusCode == 401 { return .badKey }
        guard (200..<300).contains(response.statusCode), let text = text(fromJSON: data), !text.isEmpty else { return .failed }
        return .text(text)
    }

    /// The Settings "Test" button: lists Groq's models with the key.
    static func check(key: String, transport: @escaping GroqTransport, timeout: TimeInterval = 8) async -> KeyCheck {
        var r = URLRequest(url: modelsEndpoint)
        r.timeoutInterval = timeout
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let request = r
        guard let (_, response) = await race(timeout, { try await transport(request) }) else { return .noConnection }
        switch response.statusCode {
        case 200..<300: return .works
        case 401, 403: return .refused
        default: return .noConnection
        }
    }

    /// `work`'s answer, or nil if it threw or took longer than `seconds` (it is then cancelled; nothing waits for it).
    static func race<T>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let box = RaceBox<T>()
        var tasks: [Task<Void, Never>] = []
        let result: T? = await withCheckedContinuation { continuation in
            box.continuation = continuation
            tasks.append(Task.detached { box.finish(try? await work()) })
            tasks.append(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                box.finish(nil)
            })
        }
        tasks.forEach { $0.cancel() }
        return result
    }
}

/// The first of two finishers wins; the other is ignored.
private final class RaceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T?, Never>?
    func finish(_ value: T?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - Deciding the final text

/// What happens to a press once you let go. Values in, a decision out: no main thread, no microphone, no UI.
enum VoiceDecision {
    /// Shorter than this is a tap, not a command (Whisper also invents words for silence).
    static let shortestClip: TimeInterval = 0.4

    enum Result: Equatable {
        /// Nothing worth sending: no request, no chat.
        case discard
        /// `badKey`: Groq refused the key (the text is the on-device one).
        case deliver(String, VoiceEngine, badKey: Bool)
        /// Groq was the only source of text (Apple's model had none) and it didn't answer: say so, open no chat.
        case noAnswer(badKey: Bool)
    }

    /// Is there speech-like sound in the clip? Whisper invents words for silence, so a clip with no words from Apple only
    /// goes to Groq when it's loud enough for long enough: at least 200 ms of 50 ms windows whose loudness (RMS) is over a
    /// small floor. A whole-clip average would be watered down by a pause; a single peak would fire on the key's click.
    static let speechFloor: Float = 0.01
    static func hasSpeech(_ clip: VoiceClip) -> Bool {
        let window = max(1, Int(clip.sampleRate * 0.05))
        guard clip.samples.count >= window else { return false }
        var loud = 0, i = 0
        while i + window <= clip.samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += clip.samples[j] * clip.samples[j] }
            if (sum / Float(window)).squareRoot() >= speechFloor { loud += 1; if loud >= 4 { return true } }
            i += window
        }
        return false
    }

    /// The one-line "key refused" notice shows once per app run.
    static func shouldTellBadKey(_ badKey: Bool, alreadyTold: Bool) -> Bool { badKey && !alreadyTold }

    /// Groq runs only when chosen and a key is saved.
    static func usesGroq(choice: VoiceEngine, keys: GroqKeyStore) -> Bool { choice == .groq && keys.hasKey }

    static func resolve(appleText: String, clip: VoiceClip?, choice: VoiceEngine, keys: GroqKeyStore,
                        transport: @escaping GroqTransport, timeout: ((TimeInterval) -> TimeInterval)? = nil) async -> Result {
        let spoken = appleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let clip, clip.duration >= shortestClip else {
            // No sound held (a very old path) still delivers the words Apple heard.
            if !spoken.isEmpty, clip == nil { return .deliver(spoken, .onDevice, badKey: false) }
            return .discard
        }
        let key = choice == .groq ? keys.read().flatMap { $0.isEmpty ? nil : $0 } : nil
        guard let key else { return spoken.isEmpty ? .discard : .deliver(spoken, .onDevice, badKey: false) }
        // Apple gave no words (its model may not be on this Mac): Groq alone decides, but only for a clip with real sound in it.
        if spoken.isEmpty, !hasSpeech(clip) { return .discard }
        let wait = timeout?(clip.duration) ?? GroqTranscriber.timeout(forClip: clip.duration)
        switch await GroqTranscriber.transcribe(clip, key: key, transport: transport, timeout: wait) {
        case .text(let text): return .deliver(text, .groq, badKey: false)
        case .badKey: return spoken.isEmpty ? .noAnswer(badKey: true) : .deliver(spoken, .onDevice, badKey: true)
        case .failed: return spoken.isEmpty ? .noAnswer(badKey: false) : .deliver(spoken, .onDevice, badKey: false)
        }
    }

    /// The Settings "Save" button: saves the key, and the first time a key is saved, picks Groq.
    @discardableResult
    static func saveKey(_ key: String, keys: GroqKeyStore, settings: Settings) -> Bool {
        let hadKey = keys.hasKey
        guard keys.save(key) else { return false }
        if !hadKey { settings.voiceEngine = .groq }
        return true
    }

    /// The Settings "Remove" button: forgets the key and goes back to the on-device engine.
    static func removeKey(keys: GroqKeyStore, settings: Settings) {
        keys.remove()
        settings.voiceEngine = .onDevice
    }
}
