import Foundation

// Sheets: named notes you keep adding to ("Microeconomics terms"). A sheet is a `Note` with `kind == .sheet`; it keeps its
// Markdown (tables too) in `markup`. Adding to a sheet never calls Claude; only Tidy does, and only when you click it.

// MARK: - Names

/// Which sheet a spoken or typed name means. Case and accents don't matter, and filler words ("my", "the", "note",
/// "notes", "terms", "sheet") are ignored. Only an exact match (after that) counts: otherwise there is no match, and the
/// two closest names are offered. It never guesses.
enum SheetNames {
    static let filler: Set<String> = ["note", "notes", "terms", "my", "the", "sheet", "sheets"]

    struct Result: Equatable {
        /// The sheet's name as stored, when exactly one sheet matches.
        var match: String?
        /// Up to two names to offer when there is no single match (closest first).
        var closest: [String] = []
    }

    /// "My Microeconomics Terms!" → "microeconomics". A name made only of filler words keeps them ("My notes" → "my notes"),
    /// so it can still be found.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let kept = words.filter { !filler.contains($0) }
        return (kept.isEmpty ? words : kept).joined(separator: " ")
    }

    static func match(_ query: String, in names: [String]) -> Result {
        let q = normalize(query)
        guard !q.isEmpty, !names.isEmpty else { return Result(match: nil, closest: Array(names.prefix(2))) }
        let exact = names.filter { normalize($0) == q }
        if exact.count == 1 { return Result(match: exact[0]) }
        // Two sheets read the same: say both, pick neither.
        if exact.count > 1 { return Result(match: nil, closest: Array(exact.prefix(2))) }
        let qWords = Set(q.split(separator: " "))
        let ranked = names.map { name -> (name: String, distance: Int, overlap: Int) in
            let n = normalize(name)
            return (name, editDistance(q, n), qWords.intersection(n.split(separator: " ")).count)
        }.sorted {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return Result(match: nil, closest: ranked.prefix(2).map(\.name))
    }

    /// Levenshtein distance (letters added, removed or changed).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Adding to a sheet

/// Puts new content into a sheet without Claude. If the sheet's last table and a table in the new content have the same
/// header cells (case and spaces ignored), the new rows join that table (a row already there is skipped). Everything else
/// (prose, or a table with other columns) goes at the end under a dated divider. An empty sheet takes the content as it is.
/// The sheet's own text is never rewritten: only new lines are inserted.
enum SheetMerge {
    /// "23 Nov 2026" (English month names on every Mac, so the divider reads the same everywhere).
    static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return "*\(f.string(from: date))*"
    }

    /// Where a table sits in a list of lines: `start` is its header row, `end` is just past its last row.
    struct Span: Equatable {
        var start: Int
        var end: Int
        var header: [String]
        /// Line numbers of the body rows.
        var rows: Range<Int> { (start + 2)..<end }
    }

    /// Every table in `lines`, in order. Lines inside a ``` code fence are never a table.
    static func tables(in lines: [String]) -> [Span] {
        var out: [Span] = []
        var inFence = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); i += 1; continue }
            if !inFence, i + 1 < lines.count, MarkdownTable.hasPipe(line), MarkdownTable.isDelimiter(lines[i + 1]) {
                var j = i + 2
                while j < lines.count {
                    let row = lines[j]
                    let t = row.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !t.hasPrefix("```"), MarkdownTable.hasPipe(row) else { break }
                    j += 1
                }
                out.append(Span(start: i, end: j, header: MarkdownTable.cells(line)))
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    /// Cells compared the forgiving way: trimmed, inner spaces collapsed, trailing empty cells dropped.
    static func key(_ cells: [String], caseFree: Bool) -> [String] {
        var k = cells.map { c -> String in
            let t = c.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return caseFree ? t.lowercased() : t
        }
        while k.last?.isEmpty == true { k.removeLast() }
        return k
    }

    static func append(markup: String, adding: String, date: Date = Date()) -> String {
        let incoming = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return markup }
        guard !markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return incoming }

        var lines = markup.components(separatedBy: "\n")
        let newLines = incoming.components(separatedBy: "\n")
        var used = Set<Int>() // lines of the new content that went into the sheet's table
        if let last = tables(in: lines).last {
            let header = key(last.header, caseFree: true)
            var seen = Set(last.rows.map { key(MarkdownTable.cells(lines[$0]), caseFree: false) })
            var rowsToAdd: [String] = []
            for t in tables(in: newLines) where key(t.header, caseFree: true) == header {
                for i in t.start..<t.end { used.insert(i) }
                for r in t.rows {
                    let k = key(MarkdownTable.cells(newLines[r]), caseFree: false)
                    guard !k.isEmpty, !seen.contains(k) else { continue } // already in the table
                    seen.insert(k)
                    rowsToAdd.append(newLines[r].trimmingCharacters(in: .whitespaces))
                }
            }
            lines.insert(contentsOf: rowsToAdd, at: last.end)
        }
        var out = lines.joined(separator: "\n")
        let rest = newLines.enumerated().filter { !used.contains($0.offset) }.map(\.element).joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            while out.last?.isWhitespace == true { out.removeLast() }
            out += "\n\n---\n\n" + dateLine(date) + "\n\n" + rest
        }
        return out
    }
}

// MARK: - The store

extension Library {
    /// Every sheet, most recently changed first.
    var sheets: [Note] { notes.filter(\.isSheet).sorted { $0.lastChanged > $1.lastChanged } }

    func sheet(_ id: UUID) -> Note? { notes.first { $0.id == id && $0.isSheet } }

    /// The sheet a name means (see `SheetNames`): exactly one, or none with the two closest names.
    func findSheet(_ query: String) -> (sheet: Note?, closest: [String]) {
        let all = sheets
        let r = SheetNames.match(query, in: all.map(\.name))
        return (r.match.flatMap { name in all.first { $0.name == name } }, r.closest)
    }

    /// A new, empty (or pre-filled) sheet. A name already used by a sheet (after `SheetNames.normalize`) gives that
    /// sheet back instead of a second one with the same name. Nil for an empty name.
    @discardableResult
    func createSheet(named name: String, markup: String = "") -> Note? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let same = sheets.first(where: { SheetNames.normalize($0.name) == SheetNames.normalize(n) }) {
            if !markup.isEmpty { appendToSheet(same.id, markup) }
            return sheet(same.id)
        }
        let s = Note(kind: .sheet, title: n, sector: Sector.other, app: "", quote: "", question: n, body: "", name: n, markup: markup)
        writeSheet(s)
        return sheet(s.id)
    }

    /// False for an empty name, or one another sheet already has.
    @discardableResult
    func renameSheet(_ id: UUID, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var s = sheet(id), !n.isEmpty else { return false }
        guard !sheets.contains(where: { $0.id != id && SheetNames.normalize($0.name) == SheetNames.normalize(n) }) else { return false }
        s.name = n
        writeSheet(s)
        return true
    }

    /// Replaces a sheet's Markdown (Edit → Done, Tidy, Undo).
    @discardableResult
    func setMarkup(_ id: UUID, _ markup: String) -> Bool {
        guard var s = sheet(id) else { return false }
        guard s.markup != markup else { return true }
        s.markup = markup
        writeSheet(s)
        return true
    }

    /// Adds content to a sheet (see `SheetMerge`). Zero Claude calls.
    @discardableResult
    func appendToSheet(_ id: UUID, _ content: String, date: Date = Date()) -> Bool {
        guard let s = sheet(id) else { return false }
        return setMarkup(id, SheetMerge.append(markup: s.markup, adding: content, date: date))
    }

    /// Moves a sheet to the Bin, like any note (notes have no star, so nothing holds one back).
    func deleteSheet(_ id: UUID) {
        guard sheet(id) != nil else { return }
        delete(note: id)
    }
}

// MARK: - Saving an answer

enum SheetActions {
    enum AppendResult: Equatable {
        case saved(name: String)
        /// No sheet has that name: the two closest names, to offer with "New note".
        case noMatch(closest: [String])
        case nothingToSave
    }

    /// An answer's Markdown for a sheet (tables kept, Merlin's tags handled by `Answer.noteMarkup`).
    static func markup(fromAnswer answer: String) -> String { Answer.noteMarkup(answer) }

    /// "Save to note" → an existing sheet. Nil if the sheet is gone or the answer has nothing to keep.
    @discardableResult
    static func saveAnswer(_ answer: String, toSheet id: UUID, library: Library = .shared, date: Date = Date()) -> Note? {
        let md = markup(fromAnswer: answer)
        guard !md.isEmpty, library.appendToSheet(id, md, date: date) else { return nil }
        return library.sheet(id)
    }

    /// "Save to note" → "New note…".
    @discardableResult
    static func saveAnswer(_ answer: String, toNewSheet name: String, library: Library = .shared) -> Note? {
        let md = markup(fromAnswer: answer)
        guard !md.isEmpty else { return nil }
        return library.createSheet(named: name, markup: md)
    }

    /// "Add this to microeconomics terms" (R4): the answer goes to the sheet the name means, or nowhere (never a guess).
    static func append(answer: String?, toSheetNamed query: String, library: Library = .shared, date: Date = Date()) -> AppendResult {
        guard let answer, !markup(fromAnswer: answer).isEmpty else { return .nothingToSave }
        let found = library.findSheet(query)
        guard let s = found.sheet else { return .noMatch(closest: found.closest) }
        return saveAnswer(answer, toSheet: s.id, library: library, date: date) != nil ? .saved(name: s.name) : .nothingToSave
    }
}

// MARK: - Tidy

/// "Tidy": one Claude call, only when you click it. Claude reformats the sheet; the old text is kept for Undo. If the call
/// fails, the reply is empty, or the sheet changed while Claude worked, the sheet keeps its text.
enum SheetTidy {
    static let defaultInstruction = "Tidy this note into clean Markdown; make tables of terms with definitions where it fits; keep every fact; reply with the Markdown only."

    enum Outcome: Equatable {
        /// The sheet now holds `new`; `old` is what Undo puts back.
        case tidied(old: String, new: String)
        case failed(String)
    }

    /// How Claude is reached (tests swap in a fake, so they never call Claude). Haiku: a reformat, kept cheap.
    nonisolated(unsafe) static var claudeRun: (_ prompt: String, _ system: String, _ done: @escaping (Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) -> Void) -> Void = { prompt, system, done in
        ClaudeOneShot.run(prompt, system: system, model: .haiku, timeout: 120) { result in
            if case .success(let reply) = result {
                UsageLog.record(UsageLog.Entry(engine: "claude", lean: true, why: "tidy note", first: false, usage: reply.usage, saved: 0))
            }
            done(result)
        }
    }

    static func system(instruction: String) -> String {
        let extra = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return defaultInstruction + (extra.isEmpty ? "" : " The user also asks: \(extra)")
            + " Use GitHub tables (header row, |---| row). No # headings. Never add facts that are not in the note."
    }

    /// The reply without a ``` fence around all of it.
    static func cleaned(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 {
            var lines = t.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                else if var last = lines.popLast() { last.removeLast(3); lines.append(last) }
                t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    /// `done` runs on the main queue (or at once when the fake answers at once).
    static func run(sheet id: UUID, instruction: String = "", library: Library = .shared, done: @escaping (Outcome) -> Void) {
        guard let s = library.sheet(id) else { done(.failed("That note is gone.")); return }
        let sent = s.markup
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { done(.failed("Nothing to tidy yet.")); return }
        claudeRun(sent, system(instruction: instruction)) { result in
            switch result {
            case .failure(let f):
                done(.failed("Tidy didn't work (\(f.localizedDescription)). Your note is unchanged."))
            case .success(let reply):
                let text = cleaned(reply.text)
                guard !text.isEmpty else { done(.failed("Claude sent back nothing. Your note is unchanged.")); return }
                guard let now = library.sheet(id), now.markup == sent else {
                    done(.failed("The note changed while Claude worked, so Tidy kept your version."))
                    return
                }
                library.setMarkup(id, text)
                lastTidy[id] = .tidied(old: sent, new: text)
                done(.tidied(old: sent, new: text))
            }
        }
    }

    /// Puts the text from before Tidy back, if the sheet still holds what Tidy wrote (an edit since then is never undone).
    @discardableResult
    static func undo(_ outcome: Outcome, sheet id: UUID, library: Library = .shared) -> Bool {
        guard case .tidied(let old, let new) = outcome, let s = library.sheet(id), s.markup == new else { return false }
        if lastTidy[id] == outcome { lastTidy[id] = nil }
        return library.setMarkup(id, old)
    }

    /// Each sheet's last Tidy, kept outside the page (you may look at another note while Claude works, and come back).
    nonisolated(unsafe) static var lastTidy: [UUID: Outcome] = [:]

    /// The sheet's last Tidy can still be undone: it is still the text Tidy wrote.
    static func undoable(_ id: UUID, library: Library = .shared) -> Outcome? {
        guard let o = lastTidy[id], case .tidied(_, let new) = o, library.sheet(id)?.markup == new else { return nil }
        return o
    }

    /// The Undo bar was closed: that Tidy stays.
    static func forget(_ id: UUID) { lastTidy[id] = nil }
}
