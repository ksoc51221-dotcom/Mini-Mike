import Foundation

/// One question to Claude with no conversation: the engine behind the background agents (naming screenshots, writing
/// study notes). No tools, no settings files, no saved session, and the answer comes back as text with its token count.
enum ClaudeOneShot {
    struct Reply {
        var text: String
        var usage: ClaudeSession.Usage
        /// What the call used, all told (cached input counted in full).
        var tokens: Int { usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens + usage.outputTokens }
    }

    enum Failure: LocalizedError {
        case cliNotFound, failed(String), timedOut

        var errorDescription: String? {
            switch self {
            case .cliNotFound: return ClaudeSession.StartError.cliNotFound.errorDescription
            case .failed(let m): return m
            case .timedOut: return "Claude didn't answer in time."
            }
        }
    }

    /// Runs on a background queue; `completion` is called on the main queue.
    static func run(_ prompt: String, system: String, model: ModelChoice, timeout: TimeInterval = 180,
                    completion: @escaping (Result<Reply, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSync(prompt, system: system, model: model, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocks until the answer is in. Never call it on the main thread.
    static func runSync(_ prompt: String, system: String, model: ModelChoice, timeout: TimeInterval = 180) -> Result<Reply, Failure> {
        guard let cli = ClaudeSession.claudePath else { return .failure(.cliNotFound) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-p", "--output-format", "json", "--model", model.rawValue, "--tools", "",
                       "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence", "--system-prompt", system]
        p.currentDirectoryURL = ClaudeSession.workingDirectory
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(.failed(error.localizedDescription)) }

        // Read the output while it runs (a full pipe would stall the process).
        let outBox = DataBox(), errBox = DataBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            readers.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return .failure(.timedOut)
        }
        _ = readers.wait(timeout: .now() + 5)
        return parse(outBox.data, stderr: String(decoding: errBox.data, as: UTF8.self), exit: p.terminationStatus)
    }

    static func parse(_ data: Data, stderr: String = "", exit: Int32 = 0) -> Result<Reply, Failure> {
        // `--output-format json` prints one JSON object (older versions: an array whose last item is the result).
        var object = try? JSONSerialization.jsonObject(with: data)
        if let list = object as? [[String: Any]] { object = list.last(where: { $0["type"] as? String == "result" }) ?? list.last }
        guard let obj = object as? [String: Any] else {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(tail.isEmpty ? "Claude returned nothing (code \(exit))." : String(tail.suffix(300))))
        }
        if (obj["is_error"] as? Bool) == true || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
            return .failure(.failed((obj["result"] as? String) ?? "Claude returned an error."))
        }
        let text = (obj["result"] as? String) ?? ""
        let u = obj["usage"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let usage = ClaudeSession.Usage(inputTokens: int("input_tokens"), cacheCreationTokens: int("cache_creation_input_tokens"),
                                        cacheReadTokens: int("cache_read_input_tokens"), outputTokens: int("output_tokens"),
                                        costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                                        apiSeconds: ((obj["duration_api_ms"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        return .success(Reply(text: text, usage: usage))
    }

    /// Pulls a JSON value out of an answer that may have a code fence or a sentence around it.
    static func json(from text: String) -> Any? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            s = String(s[fence]).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let v = try? JSONSerialization.jsonObject(with: Data(s.utf8)) { return v }
        // From the first [ or { to the matching last one.
        for (open, close) in [("[", "]"), ("{", "}")] {
            if let a = s.firstIndex(of: Character(open)), let b = s.lastIndex(of: Character(close)), a < b,
               let v = try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8)) { return v }
        }
        return nil
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
