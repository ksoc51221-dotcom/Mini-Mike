import Foundation

/// A hint that helps Groq's Whisper hear the right words: its `prompt`, which Whisper treats as what was said just
/// before, so it keeps names and spellings the same ("Giffen goods", not "giving goods").
/// The prompt is Merlin's name and the presses that Groq itself turned into text, so Groq gets nothing it hasn't
/// already heard. Memory only: gone when Merlin quits.
/// (Apple's on-device model is not given a word list: tested 2026-11-23, its `AnalysisContext` changed nothing.)
struct SpeechContext: Equatable {
    private(set) var recent: [String] = []

    static let fixedNames = ["Merlin"]
    static let maxRecent = 3
    /// Whisper reads only about the last 224 tokens of a prompt; 600 characters stays well inside that.
    static let maxPromptCharacters = 600

    /// Keeps the last few presses that Groq made (oldest dropped first). Apple's text is never kept, so never sent.
    mutating func remember(_ spoken: String, sentToGroq: Bool) {
        let clean = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentToGroq, !clean.isEmpty else { return }
        recent.append(clean)
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
    }

    /// "Merlin. " then what Groq heard lately. When too long, the oldest speech is cut (Whisper weighs the end).
    var whisperPrompt: String {
        let head = Self.fixedNames.joined(separator: ", ") + ". "
        var speech = recent.joined(separator: " ")
        let room = max(0, Self.maxPromptCharacters - head.count)
        if speech.count > room {
            speech = String(speech.suffix(room))
            if let space = speech.firstIndex(of: " ") { speech = String(speech[speech.index(after: space)...]) } // no half word
        }
        return String((head + speech).trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxPromptCharacters))
    }

    /// Whisper sometimes answers a short or unclear clip with its prompt (or a piece of it) instead of what was said.
    /// Such a text would repeat an old command, so it is not trusted, unless Apple heard much the same words this time
    /// (then you really did say it again). With no Apple words the two can't be told apart, so it is not trusted.
    static func isEcho(_ text: String, of prompt: String?, apple: String = "") -> Bool {
        guard let prompt else { return false }
        let heard = letters(text)
        guard !heard.isEmpty, letters(prompt).contains(heard) else { return false }
        return !DictationFix.isClose(text, apple)
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Decides whether Claude's corrected question (its <heard> tag) may replace what the speech engine wrote.
/// Only a small fix passes: a few words swapped, joined or split. A rewrite, an answer, or anything with markup is refused,
/// so the chat never shows words you didn't say.
enum DictationFix {
    /// The corrected question to show, or nil to keep the original.
    static func accept(original: String, corrected: String?) -> String? {
        guard let corrected else { return nil }
        let fixed = corrected.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        let o = words(original), c = words(fixed)
        guard !fixed.isEmpty, !o.isEmpty, !c.isEmpty, o != c else { return nil }   // empty, or no real change
        guard !fixed.contains("\n"), !fixed.contains("<"), !fixed.contains(">") else { return nil }
        guard fixed.count <= original.count * 3 / 2 + 12 else { return nil }
        guard abs(c.count - o.count) <= max(2, o.count / 3) else { return nil }
        // Either at least half the words stay, both ways ("giving goods" → "Giffen goods"), or the letters barely change
        // ("elastic city" → "elasticity"). A new sentence passes neither.
        let kept = commonWords(o, c)
        let wordsKept = kept * 2 >= o.count && kept * 2 >= c.count
        guard wordsKept || isClose(original, fixed) else { return nil }
        return fixed
    }

    /// The letters of the two barely differ (at most 35% changed): "giving goods" and "Giffen goods".
    static func isClose(_ x: String, _ y: String) -> Bool {
        let a = Array(words(x).joined()), b = Array(words(y).joined())
        guard !a.isEmpty, !b.isEmpty else { return false }
        return distance(a, b) * 100 <= max(a.count, b.count) * 35
    }

    /// Edit distance between two letter runs (insertions, deletions, swaps).
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = a[i - 1] == b[j - 1] ? diagonal : 1 + min(diagonal, row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Lowercased words without punctuation, so "Goods?" and "goods" match.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }.filter { !$0.isEmpty }
    }

    /// How many words the two share in order (longest common subsequence).
    private static func commonWords(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }
}
