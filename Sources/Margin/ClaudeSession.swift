import Foundation

/// Whatever is answering a chat: Claude (`ClaudeSession`) or a model on this Mac (`LocalSession`).
protocol AnswerSession: AnyObject {
    /// Always delivered on the main queue.
    var onEvent: ((ClaudeSession.Event) -> Void)? { get set }
    var onUsage: ((ClaudeSession.Usage) -> Void)? { get set }
    var isAlive: Bool { get }
    func start() throws
    func send(_ text: String, images: [Data])
    func stop()
}

/// One `claude -p` process per popup, kept alive for the popup's lifetime so follow-ups
/// reuse the same conversation. Talks stream-json over stdin/stdout.
final class ClaudeSession: AnswerSession {
    enum Event {
        case delta(String)
        /// A tool (web search / fetch) started; any text so far was narration and should be dropped.
        case activity(String)
        case turnDone
        case error(String)
        /// The local model couldn't start this answer (Ollama off, model missing…); nothing was shown, so
        /// the question can go to Claude instead. Only `LocalSession` sends this.
        case unavailable(String)
    }

    enum StartError: LocalizedError {
        case cliNotFound

        var errorDescription: String? {
            "Couldn't find the `claude` command. Install Claude Code and run `claude` once in Terminal to log in."
        }
    }

    /// What a finished turn used (Claude reports it; the local model's counts are mapped onto it). Delivered just
    /// before `.turnDone`.
    struct Usage {
        var inputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var costUSD = 0.0
        var apiSeconds = 0.0
    }

    /// Always delivered on the main queue.
    var onEvent: ((Event) -> Void)?
    var onUsage: ((Usage) -> Void)?

    private let model: ModelChoice
    private let webSearch: Bool
    /// Which long parts of the system prompt this chat started with (a later question can add the rest).
    private(set) var features: Prompts.Features
    private var process: Process?
    /// Writes can block until the CLI reads stdin (it may still be starting), so keep them off main.
    private let writeQueue = DispatchQueue(label: "margin.claude.stdin")
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var stopped = false
    private var lastTotalCost = 0.0
    private var lastTotalApi = 0.0

    init(model: ModelChoice, webSearch: Bool, features: Prompts.Features = .all) {
        self.model = model
        self.webSearch = webSearch
        self.features = features
    }

    /// A question needed a part of the prompt this chat started without; it was sent along with that question.
    func didSendExtra(_ added: Prompts.Features) { features.formUnion(added) }

    var isAlive: Bool { !stopped }

    func start() throws {
        guard let cli = Self.claudePath else { throw StartError.cliNotFound }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        let tools = webSearch ? ["WebSearch", "WebFetch"] : []
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model.rawValue,
            "--tools", tools.joined(separator: ","),
        ]
        if !tools.isEmpty { args += ["--allowedTools"] + tools }
        args += [
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence",
            "--system-prompt", Prompts.system(webSearch: webSearch, sectors: Library.shared.sectorsForPrompt, features: features),
        ]
        p.arguments = args
        p.currentDirectoryURL = Self.workingDirectory
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(600))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.processExited(code: proc.terminationStatus) }
        }

        try p.run()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
    }

    func send(_ text: String, images: [Data] = []) {
        guard let stdinHandle, !stopped else { return }
        var content: Any = text
        if !images.isEmpty {
            var blocks: [[String: Any]] = images.map { jpeg in
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
            }
            blocks.append(["type": "text", "text": text])
            content = blocks
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        writeQueue.async { [weak self] in
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                DispatchQueue.main.async {
                    self?.onEvent?(.error("Lost connection to Claude. Close this and try again."))
                }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? stdinHandle?.close()
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: - Output parsing

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if !line.isEmpty { handle(line: Data(line)) }
        }
    }

    private func handle(line: Data) {
        guard !stopped,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let name = block["name"] as? String {
                onEvent?(.activity(Self.activityLabel(tool: name, input: nil)))
                return
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            onEvent?(.delta(text))

        case "assistant":
            // The complete tool call arrives here, with the query / URL filled in.
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String {
                    onEvent?(.activity(Self.activityLabel(tool: name, input: block["input"] as? [String: Any])))
                }
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) == true || (obj["subtype"] as? String) != "success"
            if isError {
                let detail = (obj["result"] as? String)
                    ?? (obj["errors"] as? [String])?.joined(separator: " ")
                    ?? "Claude returned an error."
                onEvent?(.error(Self.friendly(detail)))
            } else {
                // Token counts are for this turn; cost and API time are running totals for the session, so take the difference.
                let u = obj["usage"] as? [String: Any] ?? [:]
                func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let totalCost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0
                let totalApi = ((obj["duration_api_ms"] as? NSNumber)?.doubleValue ?? 0) / 1000
                let usage = Usage(inputTokens: int("input_tokens"), cacheCreationTokens: int("cache_creation_input_tokens"),
                                  cacheReadTokens: int("cache_read_input_tokens"), outputTokens: int("output_tokens"),
                                  costUSD: max(0, totalCost - lastTotalCost), apiSeconds: max(0, totalApi - lastTotalApi))
                lastTotalCost = totalCost
                lastTotalApi = totalApi
                onUsage?(usage)
                onEvent?(.turnDone)
            }

        default:
            break
        }
    }

    private func processExited(code: Int32) {
        guard !stopped else { return }
        stopped = true
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = tail.isEmpty ? "Claude exited unexpectedly (code \(code))." : tail
        onEvent?(.error(Self.friendly(detail)))
    }

    static func activityLabel(tool: String, input: [String: Any]?) -> String {
        switch tool {
        case "WebSearch":
            if let q = input?["query"] as? String, !q.isEmpty { return "Searching “\(q)”" }
            return "Searching the web…"
        case "WebFetch":
            if let u = input?["url"] as? String, let host = URL(string: u)?.host {
                return "Reading " + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
            return "Reading a page…"
        default:
            return "Working…"
        }
    }

    private static func friendly(_ detail: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("login") || lower.contains("api key") || lower.contains("auth") {
            return "Claude isn't logged in. Run `claude` in Terminal once and log in, then try again.\n\n(\(detail))"
        }
        if lower.contains("rate") || lower.contains("limit") {
            return "You've hit a usage limit for now.\n\n(\(detail))"
        }
        return detail
    }

    // MARK: - Environment

    static let claudePath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // Apps launched from Finder don't inherit the shell PATH, so ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// An empty folder so no project CLAUDE.md gets picked up.
    static let workingDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
