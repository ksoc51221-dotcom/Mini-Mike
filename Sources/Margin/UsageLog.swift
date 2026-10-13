import Foundation

/// A private record of what each answer used, kept on this Mac, so "Token Savings…" can show what Local mode and
/// lean calls saved. It holds numbers and labels only, never what you highlighted or asked.
enum UsageLog {
    struct Entry: Codable, Equatable {
        var time = Date()
        /// "local" (answered on this Mac), "claude", or "reask" (a local answer was sent to Claude after all).
        var engine: String
        /// A Claude call with no screenshot and no web tools.
        var lean = false
        var why = ""
        /// The chat's first answer (otherwise a follow-up).
        var first = true
        var input = 0
        var output = 0
        /// Cached input (cache reads and writes), counted in full like the rest.
        var cached = 0
        var costUSD = 0.0
        var seconds = 0.0
        /// Claude tokens this answer is estimated to have saved. Negative: it takes a saving back.
        var saved = 0

        init(engine: String, lean: Bool, why: String, first: Bool, usage: ClaudeSession.Usage, saved: Int) {
            self.engine = engine
            self.lean = lean
            self.why = why
            self.first = first
            input = usage.inputTokens
            output = usage.outputTokens
            cached = usage.cacheReadTokens + usage.cacheCreationTokens
            costUSD = usage.costUSD
            seconds = usage.apiSeconds
            self.saved = saved
        }

        init(engine: String, saved: Int = 0) {
            self.engine = engine
            self.saved = saved
        }

        /// A local answer was asked of Claude after all: its saving didn't happen.
        static func reask(saving: Int) -> Entry { Entry(engine: "reask", saved: -saving) }
    }

    // MARK: - Estimates

    // From the measurements in LOCAL-MODEL-REPORT.md (input plus output tokens, cached input counted in full): a
    // question with no screenshot and no web tools costs about 3.5k tokens; the screenshot adds about 2.0k and the
    // web tools about 1.5k.
    static let questionTokens = 3500
    static let followUpTokens = 3600
    static let screenshotTokens = 2000
    static let webToolTokens = 1500

    /// A local answer replaces a Claude call that would have carried the screenshot and web tools (if they're on).
    static func savedByLocal(followUp: Bool, screenshot: Bool, web: Bool) -> Int {
        (followUp ? followUpTokens : questionTokens) + savedByLean(screenshot: screenshot, web: web)
    }

    /// A lean Claude call leaves out the screenshot and the web tools (the ones that were on).
    static func savedByLean(screenshot: Bool, web: Bool) -> Int {
        (screenshot ? screenshotTokens : 0) + (web ? webToolTokens : 0)
    }

    // MARK: - File

    static var url: URL = ClaudeSession.workingDirectory.appendingPathComponent("usage.jsonl")
    private static let queue = DispatchQueue(label: "margin.usage")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func record(_ entry: Entry) {
        let file = url
        queue.async {
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }

    /// Everything logged so far. A line that doesn't read is skipped.
    static func load() -> [Entry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        }
    }

    // MARK: - Summary

    struct Summary: Equatable {
        var localAnswers = 0
        var localTokens = 0
        var claudeAnswers = 0
        var leanCalls = 0
        var claudeTokens = 0
        var claudeCost = 0.0
        var saved = 0

        /// What these answers would have cost without the savings.
        var wouldHaveUsed: Int { claudeTokens + saved }
        var savedPercent: Int { wouldHaveUsed > 0 ? Int((Double(saved) / Double(wouldHaveUsed) * 100).rounded()) : 0 }
    }

    static func summarize(_ entries: [Entry]) -> Summary {
        var s = Summary()
        for e in entries {
            s.saved += e.saved
            switch e.engine {
            case "local":
                s.localAnswers += 1
                s.localTokens += e.input + e.output
            case "claude":
                s.claudeAnswers += 1
                if e.lean { s.leanCalls += 1 }
                s.claudeTokens += e.input + e.cached + e.output
                s.claudeCost += e.costUSD
            default:
                break
            }
        }
        s.saved = max(0, s.saved)
        return s
    }

    /// The text of the "Token Savings" window.
    static func report(_ entries: [Entry], now: Date = Date()) -> String {
        guard !entries.isEmpty else {
            return "Nothing recorded yet. Ask Margin a few questions and come back.\n\n"
                + "Margin keeps a private count of what each answer used, on this Mac only. It never stores your text."
        }
        let week = summarize(entries.filter { now.timeIntervalSince($0.time) <= 7 * 86_400 })
        let all = summarize(entries)
        let since = entries.map(\.time).min().map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? ""
        return [section("Last 7 days", week), section("All time (since \(since))", all),
                """
                The Claude figures are counted by Claude itself, cached input included. The savings are estimates: \
                each answer on your Mac stands in for a Claude call of about 3.5k tokens, plus about 2k if a \
                screenshot would have gone with it and about 1.5k if web search would have been on. A lean call \
                saves just the screenshot and web search. Answers you sent on to Claude with "Ask Claude" count as \
                no saving.
                """].joined(separator: "\n\n")
    }

    private static func section(_ title: String, _ s: Summary) -> String {
        func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic)) }
        var lines = [title,
                     "• Claude answered \(s.claudeAnswers)" + (s.leanCalls > 0 ? " (\(s.leanCalls) of them lean)" : "")
                         + ", using \(n(s.claudeTokens)) tokens (about $\(String(format: "%.2f", s.claudeCost)) at API prices)",
                     "• Your Mac answered \(s.localAnswers), using none of your Claude tokens"]
        if s.saved > 0 {
            lines.append("• Estimated tokens saved: about \(n(s.saved)), roughly \(s.savedPercent)% of what these would have used")
        }
        return lines.joined(separator: "\n")
    }
}
