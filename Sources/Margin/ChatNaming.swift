import Foundation

/// Names a chat once it's closed. While you talk, Claude already titles and files each chat for free (a hidden line at the
/// end of its first answer). When you close a chat that went on for a while, one small extra call reads what was actually
/// said and gives it a better name and sector. Anything you named or filed yourself is never touched.
enum ChatNaming {
    /// A tidy title: one line, no quotes, no trailing full stop, at most 60 characters. nil if there's nothing usable.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’`*# "))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard t.count >= 2 else { return nil }
        if t.count > 60 {
            let cut = t.prefix(60)
            t = String(cut.range(of: " ", options: .backwards).map { cut[..<$0.lowerBound] } ?? cut)
        }
        return t
    }

    /// Whether a closed chat is worth a naming call: it has to be saved, not named by you, and either have gone on for more
    /// than one exchange or have no better name than its first question.
    static func shouldRename(_ record: ChatRecord?, hadClaudeTitle: Bool) -> Bool {
        guard let record, !(record.titleLocked && record.sectorLocked) else { return false }
        return record.turns.count >= 2 || !hadClaudeTitle
    }

    /// What Claude reads: the highlight and, for each exchange, the question and the start of the answer (about 500 tokens).
    static func digest(_ record: ChatRecord, limit: Int = 1800) -> String {
        var parts: [String] = []
        if !record.quote.isEmpty { parts.append("Highlighted: " + String(record.quote.prefix(220))) }
        let perTurn = max(160, (limit - 240) / max(1, min(record.turns.count, 8)))
        for t in record.turns.prefix(8) {
            let answer = Answer.plainText(t.answer).replacingOccurrences(of: "\n", with: " ")
            let q = String(t.question.prefix(140))
            let a = String(answer.prefix(max(60, perTurn - q.count)))
            parts.append("Q: \(q)\nA: \(a)")
        }
        return String(parts.joined(separator: "\n").prefix(limit))
    }

    static func system(sectors: [String]) -> String {
        """
        You name a finished chat for a history list. Reply with ONLY JSON: {"title": "…", "sector": "…"}.
        title: 3 to 6 plain words that say what the chat was about, as specific as the content allows. No quotes, no full stop.
        sector: the subject it belongs under, one of: \(sectors.joined(separator: ", ")). Use another short subject name only if none of those fits.
        """
    }

    /// Reads Claude's JSON reply.
    static func parse(_ reply: String) -> (title: String?, sector: String?)? {
        guard let object = ClaudeOneShot.json(from: reply) as? [String: Any] else { return nil }
        let title = cleanTitle(object["title"] as? String)
        let sector = (object["sector"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard title != nil || sector != nil else { return nil }
        return (title, sector)
    }

    /// How the two engines are reached (replaced in tests).
    static var useLocal: () -> Bool = { Settings.shared.localMode && OllamaClient.shared.status.isUsable }
    static var localGenerate: (_ system: String, _ prompt: String, _ done: @escaping (String?) -> Void) -> Void = { system, prompt, done in
        OllamaClient.shared.generate(system: system, prompt: prompt, completion: done)
    }
    static var claudeRun: (_ prompt: String, _ system: String, _ model: ModelChoice, _ done: @escaping (Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) -> Void) -> Void = { prompt, system, model, done in
        ClaudeOneShot.run(prompt, system: system, model: model, timeout: 60, completion: done)
    }

    /// Names the saved chat `id` in the background. With Local Mode on and Ollama there, the on-Mac model does it (no Claude
    /// tokens); if it isn't there or its answer is no good, Haiku does. `done` (main queue) says what it cost in Claude tokens.
    static func rename(_ id: UUID, in library: Library = .shared, model: ModelChoice = .haiku, done: ((Int) -> Void)? = nil) {
        guard let record = library.chat(id) else { return }
        let prompt = digest(record)
        let system = system(sectors: library.allSectors)
        func viaClaude() {
            claudeRun(prompt, system, model) { result in
                guard case .success(let reply) = result else { return done?(0) ?? () }
                if let named = parse(reply.text) { library.applyAutoName(id, title: named.title, sector: named.sector) }
                done?(reply.tokens)
            }
        }
        guard useLocal() else { return viaClaude() }
        localGenerate(system, prompt) { text in
            if let text, let named = parse(text), named.title != nil {
                library.applyAutoName(id, title: named.title, sector: named.sector)
                done?(0)
            } else {
                viaClaude()
            }
        }
    }
}
