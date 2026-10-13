import Foundation

/// The local server that runs the on-Mac model (Ollama). Margin only ever talks to 127.0.0.1.
final class OllamaClient {
    static let shared = OllamaClient()
    static var baseURL = URL(string: "http://127.0.0.1:11434")! // a var only so tests can point it elsewhere

    enum Status: Equatable {
        case unknown      // not checked yet
        case ready
        case notRunning   // nothing answered on the port
        case modelMissing // Ollama is up but doesn't have the model

        /// Worth trying: it works, or we haven't looked yet (a failed try falls back to Claude on its own).
        var isUsable: Bool { self == .unknown || self == .ready }
    }

    /// Talks to this Mac directly, never through a proxy.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120 // the model may need a while to load before the first word
        return URLSession(configuration: config)
    }()

    /// The size of the model's working memory. One value everywhere: a different size makes Ollama reload the model.
    static let contextTokens = 8192

    private(set) var status = Status.unknown

    /// Looks at the server and lists what's installed. `completion` runs on the main queue.
    func refresh(completion: ((Status) -> Void)? = nil) {
        let model = Settings.shared.localModel
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        Self.session.dataTask(with: request) { [weak self] data, response, _ in
            var result = Status.notRunning
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                result = Self.hasModel(model, inTags: data) ? .ready : .modelMissing
            }
            DispatchQueue.main.async {
                self?.status = result
                completion?(result)
            }
        }.resume()
    }

    /// Loads the model into memory ahead of the first question, so the answer doesn't wait for it.
    /// `completion` gets what the check found (main queue).
    func warmUp(completion: ((Status) -> Void)? = nil) {
        let model = Settings.shared.localModel
        refresh { status in
            completion?(status)
            guard status == .ready else { return }
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // No messages: Ollama just loads the model (and keeps it for a few minutes).
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "messages": [[String: String]](), "stream": false,
                "options": ["num_ctx": Self.contextTokens],
            ] as [String: Any])
            Self.session.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    /// One short, non-streamed answer from the on-Mac model (for small jobs like naming a chat). `completion` runs on the
    /// main queue with the text, or nil if Ollama isn't there, doesn't have the model, or says nothing useful.
    func generate(system: String, prompt: String, maxTokens: Int = 80, json: Bool = true, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = json ? 45 : 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": Settings.shared.localModel, "stream": false, "think": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["num_ctx": Self.contextTokens, "num_predict": maxTokens, "temperature": 0.2],
        ]
        if json { body["format"] = "json" }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Self.session.dataTask(with: request) { [weak self] data, response, _ in
            var text: String?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? [String: Any], let content = message["content"] as? String {
                var filter = ThinkFilter()
                var out = filter.feed(content)
                out += filter.finish()
                let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
                text = t.isEmpty ? nil : t
            } else {
                self?.noteFailure(.notRunning)
            }
            DispatchQueue.main.async { completion(text) }
        }.resume()
    }

    /// `generate`, for use in an async task (main actor).
    @MainActor
    func generateText(system: String, prompt: String, maxTokens: Int) async -> String? {
        await withCheckedContinuation { continuation in
            generate(system: system, prompt: prompt, maxTokens: maxTokens, json: false) { continuation.resume(returning: $0) }
        }
    }

    /// A try just failed for this reason: stop offering Local mode until the next check says otherwise.
    func noteFailure(_ status: Status) {
        guard status != .ready else { return }
        self.status = status
    }

    /// The model names in an `/api/tags` reply. A name without a tag means its `:latest`.
    static func hasModel(_ model: String, inTags data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        let names = models.compactMap { $0["name"] as? String }
        return names.contains(model) || (!model.contains(":") && names.contains(model + ":latest"))
    }
}

/// An answer written by the model on this Mac. It keeps the conversation itself (Ollama is stateless), so
/// follow-ups work, and it speaks the same events as `ClaudeSession`.
final class LocalSession: AnswerSession {
    var onEvent: ((ClaudeSession.Event) -> Void)?
    var onUsage: ((ClaudeSession.Usage) -> Void)?

    let model: String
    private var messages: [[String: String]]
    private var task: Task<Void, Never>?
    private var stopped = false

    /// How long an answer may be (a video summary is longer than a quick answer).
    let maxTokens: Int

    init(model: String, system: String = Prompts.localSystem, maxTokens: Int = 700) {
        self.model = model
        self.maxTokens = maxTokens
        messages = [["role": "system", "content": system]]
    }

    /// After a long first message has been answered (a video's notes), keep only a short stand-in for it, so follow-ups
    /// don't carry it (the model's memory is small).
    func replaceFirstUserMessage(with text: String) {
        if let i = messages.firstIndex(where: { $0["role"] == "user" }) { messages[i]["content"] = text }
    }

    var isAlive: Bool { !stopped }

    func start() throws {}

    /// Text only: the local model never sees images.
    func send(_ text: String, images: [Data]) {
        guard !stopped else { return }
        messages.append(["role": "user", "content": text])
        task?.cancel()
        let snapshot = messages
        task = Task { @MainActor [weak self] in await self?.run(snapshot) }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    // MARK: - One turn

    @MainActor
    private func run(_ history: [[String: String]]) async {
        var filter = ThinkFilter()
        var shown = ""      // everything the user has been shown this turn
        var usage = ClaudeSession.Usage()
        do {
            var request = URLRequest(url: OllamaClient.baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": history, "stream": true, "think": false,
                "options": ["num_ctx": OllamaClient.contextTokens, "num_predict": maxTokens],
            ] as [String: Any])

            let (bytes, response) = try await OllamaClient.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var body = ""
                for try await line in bytes.lines { body += line }
                throw ServerError(status: http.statusCode, message: Self.errorMessage(in: body))
            }
            for try await line in bytes.lines {
                guard !stopped else { return }
                guard let chunk = Self.chunk(from: line) else { continue }
                if let message = chunk.error { throw ServerError(status: 500, message: message) }
                let visible = filter.feed(chunk.text)
                if !visible.isEmpty {
                    shown += visible
                    onEvent?(.delta(visible))
                }
                if chunk.done {
                    usage = ClaudeSession.Usage(inputTokens: chunk.promptTokens, outputTokens: chunk.outputTokens,
                                                apiSeconds: chunk.totalSeconds)
                }
            }
            guard !stopped else { return }
            let tail = filter.finish()
            if !tail.isEmpty {
                shown += tail
                onEvent?(.delta(tail))
            }
            guard !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerError(status: 200, message: "The local model returned nothing.")
            }
            messages.append(["role": "assistant", "content": shown])
            onUsage?(usage)
            onEvent?(.turnDone)
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            if messages.last?["role"] == "user" { messages.removeLast() } // so asking again doesn't repeat it
            let (reason, status) = Self.explain(error)
            OllamaClient.shared.noteFailure(status)
            // Nothing shown yet: the question can still go to Claude. Otherwise the half-answer stays and says why.
            onEvent?(shown.isEmpty ? .unavailable(reason) : .error(reason))
        }
    }

    // MARK: - Parsing and errors

    struct ServerError: Error {
        let status: Int
        let message: String
    }

    /// One line of Ollama's streaming reply.
    struct Chunk: Equatable {
        var text = ""
        var done = false
        var error: String?
        var promptTokens = 0
        var outputTokens = 0
        var totalSeconds = 0.0
    }

    static func chunk(from line: String) -> Chunk? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var chunk = Chunk()
        chunk.error = json["error"] as? String
        chunk.text = (json["message"] as? [String: Any])?["content"] as? String ?? ""
        chunk.done = (json["done"] as? NSNumber)?.boolValue ?? false
        chunk.promptTokens = (json["prompt_eval_count"] as? NSNumber)?.intValue ?? 0
        chunk.outputTokens = (json["eval_count"] as? NSNumber)?.intValue ?? 0
        chunk.totalSeconds = ((json["total_duration"] as? NSNumber)?.doubleValue ?? 0) / 1e9
        return chunk
    }

    private static func errorMessage(in body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["error"] as? String { return message }
        return body.isEmpty ? "Ollama returned an error." : body
    }

    /// A message for the user, and what it says about Ollama's state.
    static func explain(_ error: Error) -> (String, OllamaClient.Status) {
        let model = Settings.shared.localModel
        if let server = error as? ServerError {
            let lower = server.message.lowercased()
            if server.status == 404 || lower.contains("not found") {
                return ("The local model \(model) isn't installed. Run `ollama pull \(model)` in Terminal.", .modelMissing)
            }
            return (server.message, .ready)
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .timedOut:
                return ("Ollama isn't running. Open the Ollama app, or turn off Local Mode.", .notRunning)
            default: break
            }
        }
        return (error.localizedDescription, .ready)
    }
}

/// Drops `<think>…</think>` blocks from streamed text, even when a tag is split across chunks, and the blank
/// lines right after them. (Qwen3 is asked not to think; this is for models, or settings, that do anyway.)
struct ThinkFilter {
    private var held = ""        // text that might be the start of a tag
    private var inside = false
    private var atStart = true   // still skipping leading whitespace

    mutating func feed(_ piece: String) -> String {
        held += piece
        var out = ""
        while true {
            if inside {
                guard let end = held.range(of: "</think>") else {
                    held = Self.partialTail(held, of: "</think>")
                    break
                }
                held.removeSubrange(held.startIndex..<end.upperBound)
                inside = false
                atStart = true
            } else if let start = held.range(of: "<think>") {
                out += held[held.startIndex..<start.lowerBound]
                held.removeSubrange(held.startIndex..<start.upperBound)
                inside = true
            } else {
                let tail = Self.partialTail(held, of: "<think>")
                out += held.dropLast(tail.count)
                held = tail
                break
            }
        }
        if atStart {
            out = String(out.drop { $0.isWhitespace || $0.isNewline })
            if !out.isEmpty { atStart = false }
        }
        return out
    }

    /// The stream ended: release anything held back, unless it was inside a think block.
    mutating func finish() -> String {
        defer { held = "" }
        if inside { return "" }
        return atStart ? String(held.drop { $0.isWhitespace || $0.isNewline }) : held
    }

    /// The longest end of `text` that is the beginning of `tag` (so a half-arrived tag isn't shown).
    private static func partialTail(_ text: String, of tag: String) -> String {
        for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1) {
            let tail = String(text.suffix(length))
            if tag.hasPrefix(tail) { return tail }
        }
        return ""
    }
}
