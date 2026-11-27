import Foundation

/// "Hey Merlin, make this a note of a list of SUVAT equations": words that ask for a note whose content Claude writes.
/// `parse` is a strict rule (zero tokens); `perform` makes one model call and saves the sheet. A miss goes on to the
/// agent / quick / chat decision as before, so the rules only say yes to a clear request.
enum VoiceNote {
    struct Request: Equatable {
        /// The subject as spoken: "a list of SUVAT equations".
        let topic: String
        /// The sheet name: "SUVAT Equations".
        let title: String
    }

    static let maxWords = 20
    static let maxTitleWords = 5
    /// A topic may not start with one of these: it points at something Merlin cannot write from ("make a note of this").
    static let pointingWords: Set<String> = ["this", "that", "it", "these", "those", "what", "my", "me", "i", "to", "if", "when", "how", "why"]
    static let smallWords: Set<String> = ["of", "and", "the", "for", "in", "on", "a", "an", "to", "or", "at", "by", "vs"]

    // "make / create / write / take (this) (a) note of|on|about|… X", "make this a note of X"
    private static let makeNote = #"^(?:make|create|write|take|turn|start|do)\s+(?:(?:this|that|it|me|us)\s+)?(?:into\s+)?(?:a\s+|an\s+|my\s+|the\s+)?(?:new\s+)?note\s+(?:of|on|about|with|listing|for|containing|covering)\s+(.+)$"#
    // "put / write / jot X in my notes"
    private static let putIn = #"^(?:put|write|jot)\s+(.+?)\s+(?:in|into|to|on)\s+(?:my\s+|the\s+|a\s+)?(?:notes|note|new\s+note)$"#
    // "note down X", "jot down X"
    private static let noteDown = #"^(?:note|jot|write)\s+down\s+(.+)$"#
    private static let polite = #"^(?:(?:can|could|would|will)\s+you\s+|(?:i\s+want\s+you\s+to|i\s+need\s+you\s+to|i'd\s+like\s+you\s+to|i\s+would\s+like\s+you\s+to)\s+)"#
    private static let leadIn = #"^(?:(?:a|an|the|some|all)\s+)?(?:(?:list|table|summary|overview|set|collection|rundown|cheat\s+sheet|sheet)\s+(?:of|on|for)\s+)?(?:(?:all\s+)?(?:the\s+)?|(?:a|an|some)\s+)"#

    static func parse(_ spoken: String) -> Request? {
        var s = CommandCenter.cleaned(spoken)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!,;:"))
        s = s.replacingOccurrences(of: #"^please\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[\s,]+please$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: polite, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?,;:"))
        let words = s.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, words.count >= 3, words.count <= maxWords else { return nil }
        guard !NoteCommand.questionWords.contains(first.lowercased()), !s.contains("?") else { return nil }
        // A sentence a note command already handles ("new note called physics", "open my notes") is never mine.
        let whole = CommandCenter.cleaned(spoken)
        if NoteCommand.parse(whole, sheets: []) != nil || NoteCommand.parse(s, sheets: []) != nil { return nil }

        for pattern in [makeNote, putIn, noteDown] {
            guard let topic = capture(pattern, in: s) else { continue }
            if let request = request(fromTopic: topic) { return request }
        }
        return nil
    }

    static func request(fromTopic raw: String) -> Request? {
        let topic = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?,;:\"'"))
        let topicWords = topic.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard topicWords.count >= 2, !pointingWords.contains(topicWords[0]) else { return nil }
        guard let title = title(from: topic) else { return nil }
        return Request(topic: topic, title: title)
    }

    /// "a list of SUVAT equations" → "SUVAT Equations". Leading list/article words off, at most 5 words, Title Case
    /// (words with their own capitals, like "SUVAT" or "pH", stay as they are).
    static func title(from topic: String) -> String? {
        var t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: leadIn, with: "", options: [.regularExpression, .caseInsensitive])
        var words = t.split(whereSeparator: \.isWhitespace).map { w -> String in
            String(w).trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-+=²")).inverted)
        }.filter { !$0.isEmpty }
        if words.count > maxTitleWords { words = Array(words.prefix(maxTitleWords)) }
        while let last = words.last, smallWords.contains(last.lowercased()), words.count > 1 { words.removeLast() }
        guard !words.isEmpty else { return nil }
        let cased = words.enumerated().map { i, w -> String in
            if w.dropFirst().contains(where: \.isUppercase) || w.allSatisfy({ !$0.isLetter }) { return w }
            if i > 0, smallWords.contains(w.lowercased()) { return w.lowercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        return cased.joined(separator: " ")
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // MARK: - Doing it

    /// Where the note goes. Tests use a fake; the app uses `LiveStore`.
    protocol Store {
        /// The sheet with this title (case-insensitive), if there is one.
        func sheetID(titled title: String) -> UUID?
        func create(title: String, markup: String) -> Bool
        func append(to id: UUID, markup: String) -> Bool
    }

    static let system = "You write the body of one note for a student's notebook. Reply with the note only, in Markdown. No preamble, no closing remark, no code fence around the whole answer. Be concise. Use lists, tables or equations where they fit (equations in plain text or LaTeX between $ signs)."

    static func prompt(for request: Request) -> String {
        "Write a note: \(request.topic). Title: \(request.title). Give the note body only (no title line, no preamble). Keep it short and correct."
    }

    static let failureLine = "Merlin could not write that note. Nothing was saved."

    /// One model call, then the sheet. Returns the one line Merlin says. A failed call creates nothing.
    static func perform(_ request: Request, generate: (String) async throws -> String, store: Store) async -> String {
        let body: String?
        do { body = try await generate(prompt(for: request)) } catch { body = nil }
        return finish(request, body: body, store: store)
    }

    /// The saving half (sync, so a test can run it without a model).
    static func finish(_ request: Request, body: String?, store: Store) -> String {
        guard let body, case let md = Answer.noteMarkup(stripFence(body)).trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty else {
            return failureLine
        }
        if let id = store.sheetID(titled: request.title) {
            return store.append(to: id, markup: md) ? "Added to the note \"\(request.title)\"" : failureLine
        }
        return store.create(title: request.title, markup: md) ? "Saved to the note \"\(request.title)\"" : failureLine
    }

    /// A reply wrapped whole in a ``` fence loses the fence.
    static func stripFence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
        var lines = t.components(separatedBy: "\n")
        guard lines.count >= 2 else { return t }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    // MARK: - Live

    /// The real Library. Library calls run on the main thread.
    struct LiveStore: Store {
        func sheetID(titled title: String) -> UUID? {
            onMain { Library.shared.sheets.first { $0.name.caseInsensitiveCompare(title) == .orderedSame }?.id }
        }
        func create(title: String, markup: String) -> Bool { onMain { Library.shared.createSheet(named: title, markup: markup) != nil } }
        func append(to id: UUID, markup: String) -> Bool { onMain { Library.shared.appendToSheet(id, markup) } }
        private func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
    }

    struct Failure: Error {}

    /// The real model call: one Sonnet call, no tools, low effort.
    static func liveGenerate(_ prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            ClaudeOneShot.run(prompt, system: system, model: .sonnet, effort: "low", timeout: 120) { result in
                switch result {
                case .success(let reply): cont.resume(returning: reply.text)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }

    /// The one-line hook for the routing code: nil when the words are not a make-a-note request, otherwise the line to say.
    static func live(_ spoken: String) async -> String? {
        guard let request = parse(spoken) else { return nil }
        return await perform(request, generate: liveGenerate, store: LiveStore())
    }
}
