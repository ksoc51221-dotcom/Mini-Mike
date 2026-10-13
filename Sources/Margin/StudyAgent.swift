import Foundation
import PDFKit

/// Study notes from a textbook, paper or lecture file. The file is read on this Mac and cut into chapters; you pick the
/// chapters and what to make (summary, key terms, practice questions, flashcards), see about how many Claude tokens
/// that will use, and Claude writes the notes chapter by chapter. Nothing is made until you say go.
enum Study {
    struct Section {
        var title: String
        var pages: ClosedRange<Int>?
        var text: String

        var pageLabel: String {
            guard let pages else { return "" }
            return pages.lowerBound == pages.upperBound ? "page \(pages.lowerBound)" : "pages \(pages.lowerBound)–\(pages.upperBound)"
        }
    }

    struct Source {
        var title: String
        var sections: [Section]
        var note: String?
    }

    enum Output: String, CaseIterable {
        case summary, keywords, questions, flashcards

        var title: String {
            switch self {
            case .summary: return "Summary"
            case .keywords: return "Key terms"
            case .questions: return "Practice questions"
            case .flashcards: return "Flashcards (CSV for Anki)"
            }
        }
        /// About how many output tokens one section of this costs.
        var outputTokens: Int {
            switch self {
            case .summary: return 350
            case .keywords: return 300
            case .questions: return 450
            case .flashcards: return 500
            }
        }
    }

    /// The most text of a section that's sent (longer ones are cut to excerpts spread through it).
    static let maxSectionChars = 24_000

    // MARK: Reading

    static func read(_ url: URL) -> Source? {
        guard let doc = PageReader.readFile(url), !doc.isEmpty else { return nil }
        var sections: [Section] = []
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            let chapters = outline(pdf)
            if chapters.count >= 2 {
                for (i, c) in chapters.enumerated() {
                    let end = i + 1 < chapters.count ? max(c.page, chapters[i + 1].page - 1) : pdf.pageCount - 1
                    sections.append(section(title: c.title, pages: (c.page + 1)...(end + 1), from: doc))
                }
            } else {
                var start = 1
                while start <= pdf.pageCount {
                    let end = min(pdf.pageCount, start + 11)
                    sections.append(section(title: "Pages \(start)–\(end)", pages: start...end, from: doc))
                    start = end + 1
                }
            }
        } else {
            // No pages: parts of about the same length.
            var current = "", n = 1
            for p in doc.passages {
                current += p.text + "\n\n"
                if current.count > 9000 { sections.append(Section(title: "Part \(n)", pages: nil, text: current)); current = ""; n += 1 }
            }
            if current.count > 200 || sections.isEmpty { sections.append(Section(title: sections.isEmpty ? doc.title : "Part \(n)", pages: nil, text: current)) }
        }
        sections.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 }
        return sections.isEmpty ? nil : Source(title: doc.title, sections: sections, note: doc.note)
    }

    /// The PDF's own table of contents (top level), as (title, 0-based page).
    static func outline(_ pdf: PDFDocument) -> [(title: String, page: Int)] {
        guard let root = pdf.outlineRoot else { return [] }
        var out: [(String, Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i), let label = child.label, let page = child.destination?.page else { continue }
            let index = pdf.index(for: page)
            if index != NSNotFound { out.append((label.trimmingCharacters(in: .whitespacesAndNewlines), index)) }
        }
        // Several entries on one page (title pages, parts) collapse to the first.
        var seen = Set<Int>()
        return out.filter { seen.insert($0.1).inserted }
    }

    private static func section(title: String, pages: ClosedRange<Int>, from doc: DocIndex) -> Section {
        let text = doc.passages.filter { $0.page.map(pages.contains) ?? false }.map(\.text).joined(separator: "\n\n")
        return Section(title: title, pages: pages, text: text)
    }

    /// The text that's sent for a section: all of it, or excerpts spread through it if it's long.
    static func sent(_ s: Section) -> (text: String, excerpted: Bool) {
        guard s.text.count > maxSectionChars else { return (s.text, false) }
        let passages = DocIndex.passages(from: s.text, page: nil)
        let index = DocIndex(title: s.title, kind: "", pageCount: nil, passages: passages)
        return (index.overview(budget: maxSectionChars).map(\.text).joined(separator: "\n\n"), true)
    }

    /// About how many Claude tokens this will use: each section is one call (3.5k of fixed overhead plus its text
    /// and what's written back).
    static func estimate(sections: [Section], outputs: Set<Output>) -> Int {
        let out = outputs.reduce(0) { $0 + $1.outputTokens }
        return sections.reduce(0) { $0 + 3500 + min($1.text.count, maxSectionChars) * 10 / 36 + 150 + out }
    }

    // MARK: Asking Claude

    static let system = "You write careful study notes. Use only the text you are given; never add facts that aren't in it. "
        + "Reply with ONLY valid JSON, with no other text before or after."

    static func prompt(docTitle: String, section: Section, outputs: Set<Output>, excerpted: Bool, text: String) -> String {
        var keys: [String] = []
        if outputs.contains(.summary) {
            keys.append(#""summary": "the main idea in two sentences, then 3-5 short bullet points, each starting with '- ', separated by newlines""#)
        }
        if outputs.contains(.keywords) { keys.append(#""keywords": [{"term": "…", "meaning": "one short line"}] (5-10 of the most important)"#) }
        if outputs.contains(.questions) { keys.append(#""questions": [{"q": "…", "a": "the answer in one or two sentences"}] (5 questions that test understanding, not trivia)"#) }
        if outputs.contains(.flashcards) { keys.append(#""flashcards": [{"front": "a term or question", "back": "a short answer"}] (8-12 cards)"#) }
        return """
        Document: «\(docTitle)»
        Section: \(section.title)\(section.pages == nil ? "" : " (\(section.pageLabel))")
        \(excerpted ? "(This section is long, so these are excerpts spread evenly through it.)" : "")

        \(text)

        Write study notes for this section as one JSON object with exactly these keys:
        \(keys.map { "- " + $0 }.joined(separator: "\n"))
        """
    }

    struct Notes {
        var summary = ""
        var keywords: [(term: String, meaning: String)] = []
        var questions: [(q: String, a: String)] = []
        var flashcards: [(front: String, back: String)] = []
    }

    static func parse(_ reply: String) -> Notes? {
        guard let obj = ClaudeOneShot.json(from: reply) as? [String: Any] else { return nil }
        var n = Notes()
        n.summary = (obj["summary"] as? String) ?? ""
        for k in obj["keywords"] as? [[String: Any]] ?? [] { if let t = k["term"] as? String, let m = k["meaning"] as? String { n.keywords.append((t, m)) } }
        for q in obj["questions"] as? [[String: Any]] ?? [] { if let a = q["q"] as? String, let b = q["a"] as? String { n.questions.append((a, b)) } }
        for c in obj["flashcards"] as? [[String: Any]] ?? [] { if let a = c["front"] as? String, let b = c["back"] as? String { n.flashcards.append((a, b)) } }
        return n.summary.isEmpty && n.keywords.isEmpty && n.questions.isEmpty && n.flashcards.isEmpty ? nil : n
    }

    // MARK: Writing files

    static func markdown(_ n: Notes, doc: String, section: Section) -> String {
        var s = "# \(section.title)\n\n*From “\(doc)”\(section.pages != nil ? ", \(section.pageLabel)" : "")*\n"
        if !n.summary.isEmpty { s += "\n## Summary\n\n\(n.summary)\n" }
        if !n.keywords.isEmpty { s += "\n## Key terms\n\n" + n.keywords.map { "- **\($0.term)**: \($0.meaning)" }.joined(separator: "\n") + "\n" }
        if !n.questions.isEmpty {
            s += "\n## Practice questions\n\n" + n.questions.enumerated().map { "\($0.offset + 1). \($0.element.q)\n   - *Answer:* \($0.element.a)" }.joined(separator: "\n") + "\n"
        }
        if !n.flashcards.isEmpty { s += "\n## Flashcards\n\n" + n.flashcards.map { "- **\($0.front)** → \($0.back)" }.joined(separator: "\n") + "\n" }
        return s
    }

    /// Anki's import format: tab-separated front and back.
    static func flashcardsCSV(_ cards: [(front: String, back: String)]) -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " <br> ") }
        return cards.map { clean($0.front) + "\t" + clean($0.back) }.joined(separator: "\n") + "\n"
    }

    static func fileName(_ s: String) -> String {
        let t = Tidy.sanitize(s, limit: 60)
        return t.isEmpty ? "Notes" : t
    }
}

final class StudyAgent {
    private let file: URL?
    private let hint: String
    private var source: Study.Source?
    private var url: URL?
    private var ledgerBox = FileSafety.Ledger(title: "")

    init(file: URL?, hint: String) {
        self.file = file
        self.hint = hint
    }

    func run(_ task: BackgroundTask) {
        task.onCancel = { task.cancelRequested = true }
        task.progress("Finding the file…")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let found = resolveFile() else {
                return task.fail("I couldn't tell which file. Drop it on the task box, or open it and ask again.")
            }
            url = found
            task.progress("Reading \(found.lastPathComponent)…")
            guard let src = Study.read(found) else {
                return task.fail("I couldn't read any text in \(found.lastPathComponent).")
            }
            source = src
            DispatchQueue.main.async {
                task.title = "Study: " + src.title
                let shown = Array(src.sections.prefix(60))
                let items = shown.enumerated().map { i, s in
                    TaskChooser.Choice(id: String(i), title: s.title, detail: s.pageLabel, on: i < 6)
                }
                let options = Study.Output.allCases.map { TaskChooser.Choice(id: $0.rawValue, title: $0.title, on: $0 == .summary || $0 == .keywords) }
                var chooser = TaskChooser(heading: "Which parts of “\(src.title)”?", items: items, optionsHeading: "Make", options: options)
                chooser.estimate = { [self] picked, outs in
                    guard let src = self.source else { return "" }
                    let sections = picked.compactMap(Int.init).filter { $0 < src.sections.count }.map { src.sections[$0] }
                    let tokens = Study.estimate(sections: sections, outputs: Set(outs.compactMap(Study.Output.init(rawValue:))))
                    return sections.isEmpty ? "" : "About \(tokens / 1000)k Claude tokens for \(sections.count) part\(sections.count == 1 ? "" : "s"). Long parts are cut to excerpts."
                }
                task.chooser = chooser
                task.detail = "Waiting for your choices" + (src.note.map { " · \($0)" } ?? "")
                task.state = .needsApproval
                task.onApprove = { [self] t in self.approve(t) }
            }
        }
    }

    /// The dropped file, else the document open in the front app, else the best Spotlight match for the words used.
    private func resolveFile() -> URL? {
        if let file { return file }
        if let app = NSWorkspace.shared.frontmostApplication, let doc = PageReader.documentURL(pid: app.processIdentifier), doc.isFileURL, PageReader.isReadable(doc) { return doc }
        let (found, _) = Find.search(hint + " pdf", roots: [FileManager.default.homeDirectoryForCurrentUser], limit: 1)
        return found.first?.url
    }

    private func approve(_ task: BackgroundTask) {
        guard let chooser = task.chooser, let src = source else { return }
        let picked = chooser.items.filter(\.on).compactMap { Int($0.id) }.filter { $0 < src.sections.count }
        let outputs = Set(chooser.options.filter(\.on).compactMap { Study.Output(rawValue: $0.id) })
        guard !picked.isEmpty, !outputs.isEmpty else { return }
        task.chooser = nil
        task.state = .working
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var ledger = FileSafety.Ledger(title: task.title)
            let folder = Notebook.folder.appendingPathComponent("Study", isDirectory: true).appendingPathComponent(Study.fileName(src.title), isDirectory: true)
            var written: [URL] = []
            var summaries: [(String, String)] = []
            var cards: [(front: String, back: String)] = []
            var problems: [String] = []
            var tokens = 0
            let model = Settings.shared.model
            for (n, index) in picked.enumerated() {
                if task.cancelRequested { break }
                let section = src.sections[index]
                task.progress("\(section.title): \(n + 1) of \(picked.count)", Double(n) / Double(picked.count))
                let (text, excerpted) = Study.sent(section)
                let prompt = Study.prompt(docTitle: src.title, section: section, outputs: outputs, excerpted: excerpted, text: text)
                var notes: Study.Notes?
                var failure: String?
                for _ in 0..<2 where notes == nil && failure == nil { // one retry if the reply wasn't usable JSON
                    switch ClaudeOneShot.runSync(prompt, system: Study.system, model: model) {
                    case .success(let reply):
                        tokens += reply.tokens
                        notes = Study.parse(reply.text)
                    case .failure(let error):
                        failure = error.localizedDescription
                    }
                }
                guard let notes else {
                    problems.append("\(section.title): " + (failure ?? "the notes didn't come back in a usable form"))
                    continue
                }
                let name = String(format: "%02d ", n + 1) + Study.fileName(section.title) + ".md"
                if let md = try? FileSafety.createFile(Data(Study.markdown(notes, doc: src.title, section: section).utf8), at: folder.appendingPathComponent(name), ledger: &ledger) {
                    written.append(md)
                }
                if !notes.summary.isEmpty { summaries.append((section.title, notes.summary)) }
                cards += notes.flashcards
                let body = notes.summary + (notes.keywords.isEmpty ? "" : "\n\n" + notes.keywords.map { "• \($0.term): \($0.meaning)" }.joined(separator: "\n"))
                let sector = Sector.guess(from: src.title + " " + notes.summary) ?? Sector.other
                DispatchQueue.main.sync {
                    Library.shared.add(Note(title: src.title, sector: sector, app: "Study", quote: "", question: section.title, body: body))
                }
            }
            if !summaries.isEmpty {
                let index = "# \(src.title): study notes\n\n" + summaries.map { "## \($0.0)\n\n\($0.1)\n" }.joined(separator: "\n")
                if let u = try? FileSafety.createFile(Data(index.utf8), at: folder.appendingPathComponent("Summary.md"), ledger: &ledger) { written.insert(u, at: 0) }
            }
            if !cards.isEmpty, let u = try? FileSafety.createFile(Data(Study.flashcardsCSV(cards).utf8), at: folder.appendingPathComponent("Flashcards.txt"), ledger: &ledger) {
                written.append(u)
            }
            FileSafety.save(ledger)
            ledgerBox = ledger
            DispatchQueue.main.async {
                task.tokens += tokens
                var lines = ["Notes for \(picked.count - problems.count) of \(picked.count) parts, in Documents/Margin Notes/Study", "Claude used about \(tokens / 1000)k tokens"]
                if !cards.isEmpty { lines.append("\(cards.count) flashcards: import Flashcards.txt into Anki (tab-separated)") }
                if !problems.isEmpty { lines.append("Skipped: " + problems.prefix(3).joined(separator: "; ")) }
                task.onUndo = { [self] t in
                    DispatchQueue.global().async {
                        var l = self.ledgerBox
                        let r = FileSafety.undo(&l)
                        DispatchQueue.main.async {
                            t.undone = true
                            t.canUndo = false
                            t.detail = "Undone: removed \(r.restored) note file\(r.restored == 1 ? "" : "s")"
                            t.report = TaskReport(headline: t.detail)
                        }
                    }
                }
                var links = written.prefix(4).map { TaskLink(title: $0.lastPathComponent, url: $0) }
                links.append(TaskLink(title: "Open the Study folder", url: folder))
                task.finish(TaskReport(headline: task.cancelRequested ? "Stopped: \(written.count) files written" : "Study notes ready", lines: lines, links: links), canUndo: !written.isEmpty)
            }
        }
    }
}
