import Foundation

// MARK: - Sectors

/// The subjects chats are filed under ("Math", "Language", "Physics"…). Claude names the sector of each chat in
/// the same answer it gives (a few extra words, no extra call); when it doesn't, a keyword guess on this Mac does.
enum Sector {
    static let other = "Other"
    static let defaults = ["Math", "Physics", "Chemistry", "Biology", "Computer Science", "Economics",
                           "Language", "History", "Writing", "Health", "Business", "Other"]

    /// Other names Claude (or a person) tends to use, mapped to the sector they belong in.
    private static let aliases: [String: String] = [
        "maths": "Math", "mathematics": "Math", "calculus": "Math", "algebra": "Math", "geometry": "Math",
        "statistics": "Math", "stats": "Math", "probability": "Math",
        "languages": "Language", "linguistics": "Language", "russian": "Language", "english": "Language",
        "spanish": "Language", "french": "Language", "grammar": "Language", "vocabulary": "Language",
        "cs": "Computer Science", "computing": "Computer Science", "programming": "Computer Science",
        "coding": "Computer Science", "software": "Computer Science", "tech": "Computer Science",
        "technology": "Computer Science", "code": "Computer Science",
        "economy": "Economics", "econ": "Economics", "finance": "Business", "marketing": "Business",
        "management": "Business", "accounting": "Business",
        "physical science": "Physics", "mechanics": "Physics",
        "chem": "Chemistry", "bio": "Biology", "medicine": "Health", "psychology": "Health",
        "history": "History", "geography": "History", "politics": "History", "law": "History",
        "literature": "Writing", "essay": "Writing", "essays": "Writing",
        "general": "Other", "misc": "Other", "miscellaneous": "Other", "none": "Other", "unknown": "Other",
    ]

    /// A clean sector name: known ones keep their spelling, aliases fold into them, and a genuinely new
    /// sector comes out in Title Case, at most 24 characters.
    static func normalize(_ raw: String, known: [String] = defaults) -> String {
        let cleaned = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !cleaned.isEmpty else { return other }
        let lower = cleaned.lowercased()
        if let hit = known.first(where: { $0.lowercased() == lower }) { return hit }
        if let alias = aliases[lower] { return alias }
        let words = cleaned.split(separator: " ").prefix(3).map { w -> String in
            w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }
        return String(words.joined(separator: " ").prefix(24))
    }

    private static let keywords: [String: [String]] = [
        "Math": ["equation", "derivative", "integral", "quadratic", "polynomial", "theorem", "proof", "algebra", "calculus",
                 "matrix", "vector", "probability", "variance", "logarithm", "trigonometry", "sine", "cosine", "slope",
                 "parabola", "factor", "fraction", "limit", "sequence", "geometry", "angle", "triangle"],
        "Physics": ["velocity", "acceleration", "force", "momentum", "energy", "newton", "quantum", "relativity", "gravity",
                    "photon", "electric", "magnetic", "wave", "friction", "torque", "thermodynamic", "entropy", "voltage"],
        "Chemistry": ["molecule", "atom", "reaction", "compound", "electron", "periodic table", "acid", "base", "ion",
                      "bond", "oxidation", "solvent", "mole", "catalyst", "organic"],
        "Biology": ["cell", "dna", "gene", "protein", "evolution", "organism", "enzyme", "photosynthesis", "mitosis",
                    "species", "ecosystem", "bacteria", "neuron", "chromosome"],
        "Computer Science": ["algorithm", "function", "variable", "closure", "compiler", "database", "api", "python",
                             "javascript", "swift", "recursion", "array", "pointer", "thread", "git", "runtime", "class",
                             "framework", "server", "bug", "code"],
        "Economics": ["supply", "demand", "elasticity", "inflation", "gdp", "opportunity cost", "equilibrium", "monopoly",
                      "marginal", "surplus", "recession", "interest rate", "fiscal", "monetary", "market", "tariff"],
        "Language": ["grammar", "verb", "noun", "tense", "conjugat", "pronounc", "translation", "translate", "vocabulary",
                     "adjective", "preposition", "accent", "idiom", "declension", "phrase", "dialect"],
        "History": ["war", "empire", "revolution", "century", "dynasty", "treaty", "colonial", "ancient", "medieval",
                    "republic", "monarch", "civilization"],
        "Writing": ["essay", "thesis", "paragraph", "argument", "tone", "draft", "rewrite", "metaphor", "narrative",
                    "citation", "outline"],
        "Health": ["symptom", "diagnosis", "vitamin", "disease", "therapy", "anxiety", "nutrition", "sleep", "dose",
                   "medication", "exercise"],
        "Business": ["revenue", "profit", "startup", "customer", "invoice", "budget", "roi", "stakeholder", "pitch",
                     "valuation"],
    ]

    /// A quick guess from the words in what you highlighted and asked (nothing leaves this Mac). nil when it's unclear.
    static func guess(from text: String) -> String? {
        let lower = text.lowercased()
        // A different script is the strongest hint of all.
        let foreign = Router.nonLatinLetterCount(text)
        if foreign >= 3 { return "Language" }
        var best: (sector: String, score: Int)?
        for (sector, words) in keywords {
            var score = 0
            for w in words where lower.contains(w) { score += w.count >= 6 ? 2 : 1 }
            if score > (best?.score ?? 0) { best = (sector, score) }
        }
        guard let best, best.score >= 2 else { return nil }
        return best.sector
    }
}

// MARK: - Records

/// One saved chat.
struct ChatRecord: Codable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, created, updated, title, sector, titleLocked, sectorLocked, app, quote, turns, quizzes
    }

    struct Turn: Codable, Equatable {
        var question: String
        /// Claude's answer as shown, voice-clip and graph tags included (so a saved graph still draws).
        var answer: String
    }

    var id = UUID()
    var created = Date()
    var updated = Date()
    var title: String
    var sector: String
    /// You renamed it, so Margin stops renaming it.
    var titleLocked = false
    /// You moved it to a sector yourself, so Margin stops filing it.
    var sectorLocked = false
    var app: String
    /// What you highlighted (clipped), or a note for a snip or video.
    var quote: String
    var turns: [Turn]
    var quizzes: [QuizResult] = []

    /// The first few words of the latest answer, for the list.
    var snippet: String {
        guard let last = turns.last(where: { !$0.answer.isEmpty }) else { return quote }
        var plain = Answer.plainText(last.answer).replacingOccurrences(of: "\n", with: " ")
        for mark in ["**", "__", "`", "• "] { plain = plain.replacingOccurrences(of: mark, with: "") }
        return String(plain.prefix(140))
    }

    /// Everything said, as plain text (for search and for copying out).
    var transcript: String {
        var parts: [String] = []
        if !quote.isEmpty { parts.append("> " + quote) }
        for t in turns { parts.append("**\(t.question)**\n\n" + Answer.plainText(t.answer)) }
        return parts.joined(separator: "\n\n")
    }
}

extension ChatRecord {
    /// Older saved chats don't have every key (like `sectorLocked`); they still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
        title = try c.decode(String.self, forKey: .title)
        sector = try c.decodeIfPresent(String.self, forKey: .sector) ?? Sector.other
        titleLocked = try c.decodeIfPresent(Bool.self, forKey: .titleLocked) ?? false
        sectorLocked = try c.decodeIfPresent(Bool.self, forKey: .sectorLocked) ?? false
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        quizzes = try c.decodeIfPresent([QuizResult].self, forKey: .quizzes) ?? []
    }
}

/// A saved answer in the notebook ("Keep it"), or a quiz question you missed.
struct Note: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case answer, missed }

    var id = UUID()
    var created = Date()
    var kind: Kind = .answer
    var title: String
    var sector: String
    var app: String
    var quote: String
    var question: String
    /// The answer as plain text (voice clips become their words).
    var body: String
    var chatID: UUID?
}

/// The outcome of one quiz.
struct QuizResult: Codable, Equatable {
    var title: String
    var correct: Int
    var total: Int
    var date = Date()
    var missed: [Missed] = []

    struct Missed: Codable, Equatable {
        var question: String
        var answer: String
        var why: String
    }
}

// MARK: - Store

/// Chats and notes, kept on this Mac as small JSON files under Application Support/Margin/Library. Everything
/// happens on the main thread; the files are written in the background.
final class Library {
    static let shared = Library()
    static let changed = Notification.Name("MarginLibraryChanged")

    /// Where the files live (tests point this somewhere temporary).
    var directory: URL {
        didSet { load() }
    }
    private let writeQueue = DispatchQueue(label: "margin.library")

    private(set) var chats: [ChatRecord] = []
    private(set) var notes: [Note] = []

    init(directory: URL? = nil) {
        self.directory = directory ?? ClaudeSession.workingDirectory.appendingPathComponent("Library", isDirectory: true)
        load()
    }

    private var chatsDirectory: URL { directory.appendingPathComponent("chats", isDirectory: true) }
    private var notesDirectory: URL { directory.appendingPathComponent("notes", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        func read<T: Decodable>(_ dir: URL, _ type: T.Type) -> [T] {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(T.self, from: $0) }
            }
        }
        chats = read(chatsDirectory, ChatRecord.self).sorted { $0.updated > $1.updated }
        notes = read(notesDirectory, Note.self).sorted { $0.created > $1.created }
    }

    // MARK: Chats

    func chat(_ id: UUID) -> ChatRecord? { chats.first { $0.id == id } }

    /// Saves (or updates) a chat. A chat with nothing answered yet isn't kept.
    func save(_ record: ChatRecord, touch: Bool = true) {
        guard record.turns.contains(where: { !$0.answer.isEmpty }) else { return }
        var record = record
        if touch { record.updated = Date() }
        if let i = chats.firstIndex(where: { $0.id == record.id }) {
            chats[i] = record
        } else {
            chats.append(record)
        }
        chats.sort { $0.updated > $1.updated }
        write(record, to: chatsDirectory.appendingPathComponent("\(record.id.uuidString).json"))
        announce()
    }

    func rename(_ id: UUID, to title: String) {
        guard var c = chat(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        c.title = t
        c.titleLocked = true
        save(c)
    }

    func move(_ id: UUID, toSector sector: String) {
        guard var c = chat(id) else { return }
        c.sector = Sector.normalize(sector, known: allSectors)
        c.sectorLocked = true // you filed it, so Margin leaves it there
        save(c)
    }

    /// "Let Margin name this one again."
    func unlockTitle(_ id: UUID) {
        guard var c = chat(id), c.titleLocked else { return }
        c.titleLocked = false
        save(c, touch: false)
    }

    /// Claude's name and sector for a chat that has just been closed. Whatever you've set yourself is left alone, and
    /// it's checked again here (not only before asking), since you may have renamed the chat while Claude was thinking.
    @discardableResult
    func applyAutoName(_ id: UUID, title: String?, sector: String?) -> Bool {
        guard var c = chat(id) else { return false }
        var changed = false
        if !c.titleLocked, let t = ChatNaming.cleanTitle(title), t != c.title { c.title = t; changed = true }
        if !c.sectorLocked, let s = sector, !s.isEmpty {
            let normalized = Sector.normalize(s, known: allSectors)
            if normalized != c.sector { c.sector = normalized; changed = true }
        }
        if changed { save(c, touch: false) } // renaming isn't new activity: it keeps its place in the list
        return changed
    }

    func delete(chat id: UUID) {
        chats.removeAll { $0.id == id }
        remove(chatsDirectory.appendingPathComponent("\(id.uuidString).json"))
        announce()
    }

    func deleteAllChats() {
        let ids = chats.map(\.id)
        chats.removeAll()
        for id in ids { remove(chatsDirectory.appendingPathComponent("\(id.uuidString).json")) }
        announce()
    }

    // MARK: Notes

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        write(note, to: notesDirectory.appendingPathComponent("\(note.id.uuidString).json"))
        announce()
    }

    func delete(note id: UUID) {
        notes.removeAll { $0.id == id }
        remove(notesDirectory.appendingPathComponent("\(id.uuidString).json"))
        announce()
    }

    /// The note for this chat's answer if it was already kept (so Keep doesn't double up).
    func note(forChat id: UUID, question: String) -> Note? {
        notes.first { $0.chatID == id && $0.question == question && $0.kind == .answer }
    }

    // MARK: Sectors and search

    /// Every sector in use plus the defaults, defaults first.
    var allSectors: [String] {
        var out = Sector.defaults
        for name in (chats.map(\.sector) + notes.map(\.sector)) where !out.contains(name) { out.append(name) }
        return out
    }

    /// Sectors that have something in them, with how many chats and notes.
    var usedSectors: [(name: String, chats: Int, notes: Int)] {
        allSectors.compactMap { name in
            let c = chats.filter { $0.sector == name }.count, n = notes.filter { $0.sector == name }.count
            return c + n > 0 ? (name, c, n) : nil
        }
    }

    /// Sectors to offer Claude when it files a new chat: the ones in use, then the rest of the defaults.
    var sectorsForPrompt: [String] {
        let used = usedSectors.map(\.name)
        return used + Sector.defaults.filter { !used.contains($0) && $0 != Sector.other } + [Sector.other]
    }

    func search(chats query: String, sector: String? = nil) -> [ChatRecord] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return chats.filter { c in
            if let sector, c.sector != sector { return false }
            guard !terms.isEmpty else { return true }
            let haystack = (c.title + " " + c.sector + " " + c.quote + " " + c.transcript).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    func search(notes query: String, sector: String? = nil) -> [Note] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return notes.filter { n in
            if let sector, n.sector != sector { return false }
            guard !terms.isEmpty else { return true }
            let haystack = (n.title + " " + n.sector + " " + n.quote + " " + n.question + " " + n.body).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Files

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        writeQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func remove(_ url: URL) {
        writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for pending writes (for tests).
    func flush() { writeQueue.sync {} }

    private func announce() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

// MARK: - Markdown notebook

/// Notes mirrored to plain Markdown files (one per sector) so they open anywhere.
enum Notebook {
    /// ~/Documents/Margin Notes by default.
    static var folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Margin Notes", isDirectory: true)

    static func markdown(_ note: Note) -> String {
        var lines = ["## \(note.title)", ""]
        let date = note.created.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        lines.append("*\(note.kind == .missed ? "Missed in a quiz" : "Kept") · \(date) · \(note.app)*")
        if !note.quote.isEmpty { lines += ["", "> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ")] }
        lines += ["", "**\(note.question)**", "", note.body, "", "---", ""]
        return lines.joined(separator: "\n")
    }

    /// Adds the note to its sector's file. Returns false if the folder couldn't be written (e.g. permission).
    @discardableResult
    static func export(_ note: Note) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(note.sector.replacingOccurrences(of: "/", with: "-") + ".md")
            let entry = markdown(note)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(("# \(note.sector)\n\n" + entry).utf8).write(to: file)
            }
            return true
        } catch {
            return false
        }
    }
}
