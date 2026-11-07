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

extension ScreenshotRecord {
    private enum CodingKeys: String, CodingKey {
        case id, created, title, titleLocked, sector, sectorLocked, app, windowTitle, source, text, width, height, originalPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Screenshot"
        titleLocked = try c.decodeIfPresent(Bool.self, forKey: .titleLocked) ?? false
        sector = try c.decodeIfPresent(String.self, forKey: .sector) ?? Sector.other
        sectorLocked = try c.decodeIfPresent(Bool.self, forKey: .sectorLocked) ?? false
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .system
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
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

/// A screenshot kept in the dashboard: the picture (a JPEG in the library's folder), where it was taken, what's written in
/// it, and a label saying what it shows.
struct ScreenshotRecord: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Margin's own snip (hold Tab, press \).
        case snip
        /// macOS's: ⌘⇧3, ⌘⇧4 or ⌘⇧5 (found in the screenshots folder).
        case system
    }

    var id = UUID()
    /// When it was taken.
    var created = Date()
    var title: String
    /// You renamed it, so Margin stops labeling it.
    var titleLocked = false
    var sector: String = Sector.other
    var sectorLocked = false
    /// The app it was taken in, and that window's title (the page, document or chat it showed).
    var app: String = ""
    var windowTitle: String = ""
    var source: Source = .system
    /// The words found in the picture (clipped), for search.
    var text: String = ""
    var width = 0
    var height = 0
    /// The file macOS saved, left exactly where it was (nothing is moved or deleted there).
    var originalPath: String?

    var imageFile: String { "\(id.uuidString).jpg" }

    /// The first words found in it, for the list.
    var snippet: String {
        let words = text.replacingOccurrences(of: "\n", with: " ").split(separator: " ").prefix(24).joined(separator: " ")
        return words.isEmpty ? [app, windowTitle].filter { !$0.isEmpty }.joined(separator: " · ") : words
    }

    var sourceLabel: String { source == .snip ? "Snip (Tab+\\)" : "Screenshot" }
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

extension ChatRecord {
    /// When this chat's newest quiz was taken, if that quiz left questions missed. A chat leaves "To review" once its newest quiz is
    /// all right (the older misses stay in its history). Nil: nothing to review.
    var reviewDate: Date? {
        guard let latest = quizzes.enumerated().max(by: { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) })?.element,
              !latest.missed.isEmpty else { return nil }
        return latest.date
    }
}

enum Review {
    /// The chats to look at again, newest miss first. Uses the quiz results already stored on each chat; nothing else is saved.
    static func chats(_ chats: [ChatRecord]) -> [(chat: ChatRecord, missed: Date)] {
        chats.compactMap { c in c.reviewDate.map { (c, $0) } }.sorted { $0.1 > $1.1 }
    }
}

// MARK: - The Bin

/// What a dismissed agent leaves in the Bin: enough to show what it did, and to start it again.
struct BinnedTask: Codable, Equatable {
    enum Outcome: String, Codable { case done, failed, cancelled, unfinished }
    struct Link: Codable, Equatable {
        var title: String
        var url: String
    }

    /// `BackgroundTask.Kind`'s raw value ("tidy", "study", "connected"…).
    var kind: String
    var title: String
    var outcome: Outcome
    /// The headline of its report, or why it failed.
    var headline: String
    var lines: [String] = []
    var links: [Link] = []
    var tokens = 0
    /// What it was asked to do, so it can run again.
    var spec: TaskSpec?
    /// False for a job on your online accounts: what it read isn't written to disk, only that it ran.
    var reportKept = true
}

/// Something you deleted, kept in the Bin for `Library.binDays` days so you can get it back.
struct BinItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case chat, note, screenshot, agent }

    /// The deleted thing's own id.
    var id: UUID
    var kind: Kind
    var deleted = Date()
    var chat: ChatRecord?
    var note: Note?
    var screenshot: ScreenshotRecord?
    var agent: BinnedTask?

    init(chat: ChatRecord, deleted: Date = Date()) { id = chat.id; kind = .chat; self.deleted = deleted; self.chat = chat }
    init(note: Note, deleted: Date = Date()) { id = note.id; kind = .note; self.deleted = deleted; self.note = note }
    init(screenshot: ScreenshotRecord, deleted: Date = Date()) { id = screenshot.id; kind = .screenshot; self.deleted = deleted; self.screenshot = screenshot }
    init(agent: BinnedTask, id: UUID, deleted: Date = Date()) { self.id = id; kind = .agent; self.deleted = deleted; self.agent = agent }

    var title: String {
        switch kind {
        case .chat: return chat?.title ?? "Chat"
        case .note: return note?.question ?? "Note"
        case .screenshot: return screenshot?.title ?? "Screenshot"
        case .agent: return agent?.title ?? "Agent"
        }
    }

    var sector: String {
        switch kind {
        case .chat: return chat?.sector ?? Sector.other
        case .note: return note?.sector ?? Sector.other
        case .screenshot: return screenshot?.sector ?? Sector.other
        case .agent: return BackgroundTask.Kind(rawValue: agent?.kind ?? "")?.title ?? "Agent"
        }
    }

    /// A line or two of what it holds, for the list.
    var snippet: String {
        switch kind {
        case .chat: return chat?.snippet ?? ""
        case .note: return note?.body.replacingOccurrences(of: "\n", with: " ") ?? ""
        case .screenshot: return screenshot?.snippet ?? ""
        case .agent: return agent?.headline ?? ""
        }
    }

    /// When the thing itself was made or last changed (the Bin lists by when you deleted it).
    var made: Date {
        switch kind {
        case .chat: return chat?.updated ?? deleted
        case .note: return note?.created ?? deleted
        case .screenshot: return screenshot?.created ?? deleted
        case .agent: return deleted
        }
    }

    /// Everything a search can match.
    var searchText: String {
        switch kind {
        case .chat: return [chat?.title, chat?.sector, chat?.quote, chat?.transcript].compactMap { $0 }.joined(separator: " ")
        case .note: return [note?.title, note?.sector, note?.quote, note?.question, note?.body].compactMap { $0 }.joined(separator: " ")
        case .screenshot:
            return [screenshot?.title, screenshot?.sector, screenshot?.app, screenshot?.windowTitle, screenshot?.text].compactMap { $0 }.joined(separator: " ")
        case .agent: return [agent?.title, agent?.headline, agent?.lines.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// What it takes to put sectors back after a multi-move, a re-file or a rename/merge/delete.
struct SectorUndo {
    var chats: [UUID: (sector: String, locked: Bool)] = [:]
    var notes: [UUID: String] = [:]
    var screenshots: [UUID: (sector: String, locked: Bool)] = [:]
    var isEmpty: Bool { chats.isEmpty && notes.isEmpty && screenshots.isEmpty }
    var count: Int { chats.count + notes.count + screenshots.count }
}

// MARK: - Store

/// Chats and notes, kept on this Mac as small JSON files under Application Support/Margin/Library. Everything
/// happens on the main thread; the files are written in the background.
final class Library {
    static let shared = Library()
    static let changed = Notification.Name("MarginLibraryChanged")
    /// How long a deleted thing waits in the Bin before it's deleted for good (the Library settings page sets it; 0 = until you empty it).
    /// Where the Bin and retention settings come from; tests swap in a throwaway Settings.
    static var settings: Settings = .shared
    static var binDays: Int { max(0, settings.binAutoEmptyDays) }
    /// "30 days", or "until you empty it" when auto-empty is off. For sentences like "waits here ...".
    static var binWaitPhrase: String { binDays > 0 ? "\(binDays) days" : "until you empty it" }

    /// Where the files live (tests point this somewhere temporary).
    var directory: URL {
        didSet { load() }
    }
    private let writeQueue = DispatchQueue(label: "margin.library")

    private(set) var chats: [ChatRecord] = []
    private(set) var notes: [Note] = []
    private(set) var screenshots: [ScreenshotRecord] = []
    /// Everything you deleted that is still waiting in the Bin, newest first.
    private(set) var binned: [BinItem] = []

    /// The user's own sectors (names, colours, descriptions, rules). Tests give a Library its own; the shared one uses `SectorStore.shared`.
    var sectorStore: SectorStore?
    var activeSectorStore: SectorStore? { sectorStore ?? (self === Library.shared ? SectorStore.shared : nil) }

    /// Set (before the first use of `Library.shared`) by `--uishots`, so the headless pictures never open the real library.
    nonisolated(unsafe) static var overrideDirectory: URL?

    init(directory: URL? = nil) {
        self.directory = directory ?? Library.overrideDirectory ?? ClaudeSession.workingDirectory.appendingPathComponent("Library", isDirectory: true)
        load()
    }

    private var chatsDirectory: URL { directory.appendingPathComponent("chats", isDirectory: true) }
    private var notesDirectory: URL { directory.appendingPathComponent("notes", isDirectory: true) }
    private var screenshotsDirectory: URL { directory.appendingPathComponent("screenshots", isDirectory: true) }
    private var binDirectory: URL { directory.appendingPathComponent("bin", isDirectory: true) }
    /// The pictures themselves (one JPEG per screenshot).
    var screenshotImagesDirectory: URL { directory.appendingPathComponent("screenshot-images", isDirectory: true) }

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
        screenshots = read(screenshotsDirectory, ScreenshotRecord.self).sorted { $0.created > $1.created }
        binned = read(binDirectory, BinItem.self).sorted { $0.deleted > $1.deleted }
        purgeBin()
    }

    // MARK: Chats

    func chat(_ id: UUID) -> ChatRecord? { chats.first { $0.id == id } }

    /// Saves (or updates) a chat. A chat with nothing answered yet isn't kept.
    func save(_ record: ChatRecord, touch: Bool = true) {
        guard record.turns.contains(where: { !$0.answer.isEmpty }) else { return }
        var record = record
        if touch { record.updated = Date() }
        // A rule you wrote beats Claude's guess; a chat you filed yourself is never re-filed.
        if !record.sectorLocked, let ruled = activeSectorStore?.ruleMatch(for: record), ruled != record.sector { record.sector = ruled }
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

    /// Files several chats at once (multi-select). Locked, like a single move. Returns what's needed to undo it.
    @discardableResult
    func move(ids: [UUID], toSector sector: String) -> SectorUndo {
        let name = Sector.normalize(sector, known: allSectors)
        return applySectors(Dictionary(ids.map { ($0, name) }, uniquingKeysWith: { a, _ in a }), lock: true)
    }

    /// Puts chats in sectors. `lock: true` marks them as filed by you; `nil` leaves each chat's lock as it was.
    @discardableResult
    func applySectors(_ changes: [UUID: String], lock: Bool?) -> SectorUndo {
        var undo = SectorUndo()
        for (id, name) in changes {
            guard var c = chat(id) else { continue }
            let target = Sector.normalize(name, known: allSectors)
            let newLock = lock ?? c.sectorLocked
            guard target != c.sector || newLock != c.sectorLocked else { continue }
            undo.chats[id] = (c.sector, c.sectorLocked)
            c.sector = target
            c.sectorLocked = newLock
            storeChat(c)
        }
        if !undo.isEmpty { announce() }
        return undo
    }

    /// Renames a sector everywhere (chats, notes, screenshots) without touching any lock. Used by rename, merge and delete.
    @discardableResult
    func replaceSector(_ old: String, with new: String) -> SectorUndo {
        var undo = SectorUndo()
        guard old != new else { return undo }
        for var c in chats where c.sector == old {
            undo.chats[c.id] = (c.sector, c.sectorLocked)
            c.sector = new
            storeChat(c)
        }
        for i in notes.indices where notes[i].sector == old {
            undo.notes[notes[i].id] = old
            notes[i].sector = new
            write(notes[i], to: notesDirectory.appendingPathComponent("\(notes[i].id.uuidString).json"))
        }
        for i in screenshots.indices where screenshots[i].sector == old {
            undo.screenshots[screenshots[i].id] = (old, screenshots[i].sectorLocked)
            screenshots[i].sector = new
            write(screenshots[i], to: screenshotsDirectory.appendingPathComponent("\(screenshots[i].id.uuidString).json"))
        }
        if !undo.isEmpty { announce() }
        return undo
    }

    /// Takes back a `move(ids:)`, a re-file or a `replaceSector`.
    func undo(_ undo: SectorUndo) {
        for (id, old) in undo.chats {
            guard var c = chat(id) else { continue }
            c.sector = old.sector
            c.sectorLocked = old.locked
            storeChat(c)
        }
        for (id, sector) in undo.notes {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            notes[i].sector = sector
            write(notes[i], to: notesDirectory.appendingPathComponent("\(id.uuidString).json"))
        }
        for (id, old) in undo.screenshots {
            guard let i = screenshots.firstIndex(where: { $0.id == id }) else { continue }
            screenshots[i].sector = old.sector
            screenshots[i].sectorLocked = old.locked
            write(screenshots[i], to: screenshotsDirectory.appendingPathComponent("\(id.uuidString).json"))
        }
        if !undo.isEmpty { announce() }
    }

    /// Replaces a chat in place and writes it (no re-sorting, no timestamp change, no announcement).
    private func storeChat(_ c: ChatRecord) {
        guard let i = chats.firstIndex(where: { $0.id == c.id }) else { return }
        chats[i] = c
        write(c, to: chatsDirectory.appendingPathComponent("\(c.id.uuidString).json"))
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
            let normalized = activeSectorStore?.ruleMatch(for: c) ?? Sector.normalize(s, known: allSectors)
            if normalized != c.sector { c.sector = normalized; changed = true }
        }
        if changed { save(c, touch: false) } // renaming isn't new activity: it keeps its place in the list
        return changed
    }

    /// Moves a chat to the Bin (it can be put back for `binDays` days).
    func delete(chat id: UUID) {
        guard let c = chat(id) else { return }
        keepInBin(BinItem(chat: c))
        chats.removeAll { $0.id == id }
        remove(chatsDirectory.appendingPathComponent("\(id.uuidString).json"))
        announce()
    }

    /// Moves every chat to the Bin. Returns their ids (so the dashboard can offer Undo).
    @discardableResult
    func deleteAllChats() -> [UUID] {
        let all = chats
        chats.removeAll()
        for c in all {
            keepInBin(BinItem(chat: c))
            remove(chatsDirectory.appendingPathComponent("\(c.id.uuidString).json"))
        }
        announce()
        return all.map(\.id)
    }

    // MARK: Notes

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        write(note, to: notesDirectory.appendingPathComponent("\(note.id.uuidString).json"))
        announce()
    }

    /// Moves a note to the Bin.
    func delete(note id: UUID) {
        guard let n = notes.first(where: { $0.id == id }) else { return }
        keepInBin(BinItem(note: n))
        notes.removeAll { $0.id == id }
        remove(notesDirectory.appendingPathComponent("\(id.uuidString).json"))
        announce()
    }

    /// The note for this chat's answer if it was already kept (so Keep doesn't double up).
    func note(forChat id: UUID, question: String) -> Note? {
        notes.first { $0.chatID == id && $0.question == question && $0.kind == .answer }
    }

    // MARK: Screenshots

    func screenshot(_ id: UUID) -> ScreenshotRecord? { screenshots.first { $0.id == id } }

    func imageURL(for record: ScreenshotRecord) -> URL { screenshotImagesDirectory.appendingPathComponent(record.imageFile) }

    /// Keeps a screenshot. Its picture must already be in `screenshotImagesDirectory` (see `writeScreenshotImage`).
    func add(_ record: ScreenshotRecord) {
        screenshots.removeAll { $0.id == record.id }
        screenshots.append(record)
        screenshots.sort { $0.created > $1.created }
        write(record, to: screenshotsDirectory.appendingPathComponent("\(record.id.uuidString).json"))
        announce()
    }

    /// Writes a screenshot's picture now (so it's there the moment the record is). Safe from any thread.
    func writeScreenshotImage(_ jpeg: Data, for record: ScreenshotRecord) -> Bool {
        let dir = screenshotImagesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpeg.write(to: dir.appendingPathComponent(record.imageFile), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func rename(screenshot id: UUID, to title: String) {
        guard var s = screenshot(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        s.title = t
        s.titleLocked = true
        add(s)
    }

    func unlockTitle(screenshot id: UUID) {
        guard var s = screenshot(id), s.titleLocked else { return }
        s.titleLocked = false
        add(s)
    }

    func move(screenshot id: UUID, toSector sector: String) {
        guard var s = screenshot(id) else { return }
        s.sector = Sector.normalize(sector, known: allSectors)
        s.sectorLocked = true
        add(s)
    }

    /// A better label for a screenshot (from the model on this Mac, or Claude when asked). Whatever you've set yourself is left alone.
    @discardableResult
    func applyScreenshotLabel(_ id: UUID, title: String?, sector: String?, force: Bool = false) -> Bool {
        guard var s = screenshot(id) else { return false }
        var changed = false
        if (force || !s.titleLocked), let t = ChatNaming.cleanTitle(title), t != s.title { s.title = t; changed = true }
        if !s.sectorLocked, let sec = sector, !sec.isEmpty {
            let normalized = Sector.normalize(sec, known: allSectors)
            if normalized != s.sector { s.sector = normalized; changed = true }
        }
        if changed { add(s) }
        return changed
    }

    /// Moves a screenshot to the Bin. Its picture stays where it is until the Bin is emptied (or the item is deleted for good).
    func delete(screenshot id: UUID) {
        guard let s = screenshot(id) else { return }
        keepInBin(BinItem(screenshot: s))
        screenshots.removeAll { $0.id == id }
        remove(screenshotsDirectory.appendingPathComponent("\(id.uuidString).json"))
        announce()
    }

    /// Moves every screenshot to the Bin. Returns their ids (so the dashboard can offer Undo).
    @discardableResult
    func deleteAllScreenshots() -> [UUID] {
        let all = screenshots
        screenshots.removeAll()
        for s in all {
            keepInBin(BinItem(screenshot: s))
            remove(screenshotsDirectory.appendingPathComponent("\(s.id.uuidString).json"))
        }
        announce()
        return all.map(\.id)
    }

    func search(screenshots query: String, sector: String? = nil) -> [ScreenshotRecord] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return screenshots.filter { s in
            if let sector, s.sector != sector { return false }
            guard !terms.isEmpty else { return true }
            let haystack = (s.title + " " + s.sector + " " + s.app + " " + s.windowTitle + " " + s.text).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Sectors that have screenshots in them, with how many.
    var usedScreenshotSectors: [(name: String, count: Int)] {
        allSectors.compactMap { name in
            let n = screenshots.filter { $0.sector == name }.count
            return n > 0 ? (name, n) : nil
        }
    }

    // MARK: Bin

    func binItem(_ id: UUID) -> BinItem? { binned.first { $0.id == id } }

    private func binFile(_ item: BinItem) -> URL {
        binDirectory.appendingPathComponent("\(item.kind.rawValue)-\(item.id.uuidString).json")
    }

    /// Puts something in the Bin (a chat, note or screenshot you delete goes here by itself; the agent bar adds a dismissed agent).
    func keepInBin(_ item: BinItem) {
        binned.removeAll { $0.id == item.id }
        binned.append(item)
        binned.sort { $0.deleted > $1.deleted }
        write(item, to: binFile(item))
    }

    /// Same as `keepInBin`, for callers outside the library that need the dashboard to refresh.
    func addToBin(_ item: BinItem) {
        keepInBin(item)
        announce()
    }

    /// Takes a chat, note or screenshot out of the Bin and puts it back where it was. (An agent goes back on the agent bar:
    /// see `TaskEngine.restore`, which then calls `forget`.) False if it isn't in the Bin.
    @discardableResult
    func restore(_ id: UUID) -> Bool {
        guard let item = binItem(id) else { return false }
        switch item.kind {
        case .chat:
            guard var c = item.chat else { return false }
            // If the chat carried on after you deleted it, that newer one is already back; this copy comes back beside it.
            if chats.contains(where: { $0.id == c.id }) { c.id = UUID() }
            chats.append(c)
            chats.sort { $0.updated > $1.updated }
            write(c, to: chatsDirectory.appendingPathComponent("\(c.id.uuidString).json"))
        case .note:
            guard var n = item.note else { return false }
            if notes.contains(where: { $0.id == n.id }) { n.id = UUID() }
            notes.append(n)
            notes.sort { $0.created > $1.created }
            write(n, to: notesDirectory.appendingPathComponent("\(n.id.uuidString).json"))
        case .screenshot:
            guard let s = item.screenshot else { return false }
            screenshots.removeAll { $0.id == s.id }
            screenshots.append(s)
            screenshots.sort { $0.created > $1.created }
            write(s, to: screenshotsDirectory.appendingPathComponent("\(s.id.uuidString).json"))
        case .agent:
            return false
        }
        forget(item)
        announce()
        return true
    }

    /// Takes it out of the Bin without putting anything back (the caller has done that, or means to delete it).
    private func forget(_ item: BinItem) {
        binned.removeAll { $0.id == item.id }
        remove(binFile(item))
    }

    /// Takes an agent out of the Bin after the agent bar has put it back.
    func forget(agent id: UUID) {
        guard let item = binItem(id), item.kind == .agent else { return }
        forget(item)
        announce()
    }

    /// Deletes one thing for good (a screenshot's picture goes too).
    func deleteForever(_ id: UUID) {
        guard let item = binItem(id) else { return }
        if let s = item.screenshot { remove(screenshotImagesDirectory.appendingPathComponent(s.imageFile)) }
        forget(item)
        announce()
    }

    /// Deletes everything in the Bin for good. Returns the ids that went.
    @discardableResult
    func emptyBin() -> [UUID] {
        let all = binned
        for item in all {
            if let s = item.screenshot { remove(screenshotImagesDirectory.appendingPathComponent(s.imageFile)) }
            forget(item)
        }
        if !all.isEmpty { announce() }
        return all.map(\.id)
    }

    /// Deletes what has been in the Bin longer than `binDays`. Returns how many went.
    @discardableResult
    func purgeBin(now: Date = Date(), days: Int = Library.binDays) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let old = binned.filter { $0.deleted < cutoff }
        for item in old {
            if let s = item.screenshot { remove(screenshotImagesDirectory.appendingPathComponent(s.imageFile)) }
            forget(item)
        }
        return old.count
    }

    /// Whole days before it's deleted for good (at least 1 while it's still here).
    func daysLeft(_ item: BinItem, now: Date = Date()) -> Int {
        guard Self.binDays > 0 else { return Int.max }
        let gone = item.deleted.addingTimeInterval(Double(Self.binDays) * 86_400)
        return max(1, Int((gone.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// Applies the two retention settings: the Bin's auto-empty days (see `binDays`) and "Keep screenshots for" (a screenshot
    /// older than that is deleted for good, picture included; 0 = keep). Cheap; called at launch and when the Library opens.
    @discardableResult
    func applyRetention(now: Date = Date(), settings: Settings = Library.settings) -> (bin: Int, screenshots: Int) {
        let binGone = purgeBin(now: now, days: max(0, settings.binAutoEmptyDays))
        var shotsGone = 0
        let days = settings.screenshotRetentionDays
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for s in screenshots where s.created < cutoff {
                delete(screenshot: s.id)
                deleteForever(s.id)
                shotsGone += 1
            }
        }
        return (binGone, shotsGone)
    }

    /// Names of the picture files that belong to screenshots sitting in the Bin.
    var binnedImageFiles: [String] { binned.compactMap { $0.screenshot?.imageFile } }

    func search(bin query: String, kind: BinItem.Kind? = nil) -> [BinItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return binned.filter { item in
            if let kind, item.kind != kind { return false }
            guard !terms.isEmpty else { return true }
            let haystack = item.searchText.lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Sectors and search

    /// Every sector in use plus the defaults, defaults first.
    var allSectors: [String] {
        var out = activeSectorStore?.names ?? Sector.defaults
        for name in (chats.map(\.sector) + notes.map(\.sector) + screenshots.map(\.sector)) where !out.contains(name) { out.append(name) }
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
        let base = activeSectorStore?.names ?? Sector.defaults
        return used + base.filter { !used.contains($0) && $0 != Sector.other } + [Sector.other]
    }

    /// One short description per sector that has one (empty ones are left out), for the prompt.
    var sectorHintsForPrompt: [String: String] { activeSectorStore?.hints ?? [:] }

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
