import Foundation
import SwiftUI

// MARK: - Model

/// The little shape beside a sector's colour. The shape varies when hues repeat, so two sectors never look the same.
enum SectorGlyph: String, Codable, CaseIterable {
    case circle, diamond, triangle, square

    var title: String { rawValue.capitalized }
}

/// A section of the library the user can see, name, colour and describe.
struct UserSector: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var order: Int
    /// 0...7 into `Theme.sectorHues`: highlighter, sage, sky, plum, clay, teal, rose, slate.
    var colorIndex: Int
    var glyph: SectorGlyph = .circle
    /// The monochrome glyph that marks this sector. nil = the default for its name (see `GlyphKind.defaultFor`).
    var icon: GlyphKind?
    /// Plain words about what belongs here ("statistics, calculus, anything with formulas"). Sent to Claude when it files a chat.
    var description: String = ""
    /// Rule: words in a chat's title, highlight or questions that file it here.
    var keywords: [String] = []
    /// Rule: apps or sites (a chat made in "Desmos", or mentioning "desmos.com") that file it here.
    var apps: [String] = []

    var hasRules: Bool { !keywords.isEmpty || !apps.isEmpty }
}

extension UserSector {
    /// Tolerates old files that lack `glyph`, `icon`, `description`, `keywords` or `apps`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        glyph = try c.decodeIfPresent(SectorGlyph.self, forKey: .glyph) ?? .circle
        icon = try? c.decodeIfPresent(GlyphKind.self, forKey: .icon)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
    }
}

/// One line of the "Re-file all" preview: this chat would move from one sector to another.
struct RefileMove: Identifiable, Equatable {
    let id: UUID
    let title: String
    let from: String
    let to: String
}

// MARK: - Store

/// The user's own sectors, saved as `sectors.json` next to the library's data (same folder logic as `Library`, so tests that
/// set `Library.overrideDirectory` stay out of the real one). Nothing is written until the first change.
/// Everything happens on the main thread.
final class SectorStore: ObservableObject {
    static let shared = SectorStore()
    static let changed = Notification.Name("MarginSectorsChanged")
    static let maxNameLength = 24

    @Published private(set) var sectors: [UserSector] = []

    let library: Library
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("sectors.json") }
    private var syncing = false
    private var observer: NSObjectProtocol?

    init(directory: URL? = nil, library: Library = .shared) {
        self.library = library
        self.directory = directory ?? library.directory
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([UserSector].self, from: data), !saved.isEmpty {
            sectors = saved.sorted { $0.order < $1.order }
        } else {
            sectors = seeded()
        }
        ensureOther()
        adoptUnknownNames(save: false)
        if library.sectorStore == nil { library.sectorStore = self }
        observer = NotificationCenter.default.addObserver(forName: Library.changed, object: library, queue: .main) { [weak self] _ in
            self?.syncWithLibrary()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    // MARK: Reading

    var names: [String] { sectors.map(\.name) }

    func sector(named name: String) -> UserSector? {
        sectors.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func sector(_ id: UUID) -> UserSector? { sectors.first { $0.id == id } }

    /// Short descriptions for the prompt: only sectors that have one.
    var hints: [String: String] {
        var out: [String: String] = [:]
        for s in sectors {
            let d = s.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { out[s.name] = d }
        }
        return out
    }

    /// The colour and shape of a sector's dot. A name nobody has registered gets a quiet grey circle.
    func style(for name: String) -> (Color, SectorGlyph) {
        guard let s = sector(named: name) else { return (Theme.inkTertiary.color, .circle) }
        return (Theme.sectorHues[s.colorIndex % Theme.sectorHues.count].color, s.glyph)
    }

    /// The glyph for a sector: the user's pick, else the default for its name.
    func icon(for name: String) -> GlyphKind {
        sector(named: name)?.icon ?? GlyphKind.defaultFor(sector: name)
    }

    func count(in name: String) -> Int {
        library.chats.filter { $0.sector == name }.count
    }

    // MARK: Changing

    static func cleanName(_ raw: String) -> String? {
        let t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// A new sector at the end (above Other). Its colour and shape are the first pairing nobody uses yet.
    /// nil when the name is empty or taken.
    @discardableResult
    func create(name: String, colorIndex: Int? = nil, glyph: SectorGlyph? = nil, description: String = "",
                keywords: [String] = [], apps: [String] = []) -> UserSector? {
        guard let clean = Self.cleanName(name), sector(named: clean) == nil else { return nil }
        let free = freeStyle()
        let s = UserSector(name: clean, order: 0, colorIndex: (colorIndex ?? free.0) % Theme.sectorHues.count, glyph: glyph ?? free.1,
                           description: description, keywords: keywords, apps: apps)
        let otherAt = sectors.firstIndex { $0.name == Sector.other } ?? sectors.endIndex
        sectors.insert(s, at: otherAt)
        commit()
        return s
    }

    /// Renames a sector and re-files its chats (and notes and screenshots) under the new name. Other can't be renamed.
    @discardableResult
    func rename(_ id: UUID, to newName: String) -> Bool {
        guard let i = sectors.firstIndex(where: { $0.id == id }), sectors[i].name != Sector.other,
              let clean = Self.cleanName(newName) else { return false }
        let old = sectors[i].name
        if clean == old { return true }
        if let other = sector(named: clean), other.id != id { return false }
        syncing = true
        defer { syncing = false }
        sectors[i].name = clean
        commit()
        library.replaceSector(old, with: clean)
        return true
    }

    /// Everything in `a` goes into `b`, and `a` disappears. Its rules are added to `b`'s.
    @discardableResult
    func merge(_ a: UUID, into b: UUID) -> Bool {
        guard a != b, let from = sector(a), let to = sector(b), from.name != Sector.other else { return false }
        syncing = true
        defer { syncing = false }
        update(b) {
            for k in from.keywords where !$0.keywords.contains(k) { $0.keywords.append(k) }
            for k in from.apps where !$0.apps.contains(k) { $0.apps.append(k) }
        }
        sectors.removeAll { $0.id == a }
        commit()
        library.replaceSector(from.name, with: to.name)
        return true
    }

    /// Removes a sector; whatever was filed in it goes to Other. Other itself stays.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let s = sector(id), s.name != Sector.other else { return false }
        syncing = true
        defer { syncing = false }
        sectors.removeAll { $0.id == id }
        commit()
        library.replaceSector(s.name, with: Sector.other)
        return true
    }

    /// Drag-to-reorder (the shape SwiftUI's `onMove` gives).
    func reorder(from source: IndexSet, to destination: Int) {
        var list = sectors
        list.move(fromOffsets: source, toOffset: destination)
        sectors = list
        commit()
    }

    /// Change a sector's colour, glyph, description or rules. The name only changes through `rename` (which re-files).
    func update(_ id: UUID, _ change: (inout UserSector) -> Void) {
        guard let i = sectors.firstIndex(where: { $0.id == id }) else { return }
        let name = sectors[i].name
        change(&sectors[i])
        sectors[i].name = name
        sectors[i].colorIndex = max(0, sectors[i].colorIndex) % Theme.sectorHues.count
        commit()
    }

    // MARK: Filing by rule

    /// The sector a chat's rules point at, or nil when none match. App matches outweigh keyword matches; ties go to the
    /// sector higher in the list.
    func ruleMatch(for record: ChatRecord) -> String? {
        ruleMatch(title: record.title, quote: record.quote, questions: record.turns.map(\.question), app: record.app)
    }

    func ruleMatch(title: String, quote: String = "", questions: [String] = [], app: String = "") -> String? {
        let hay = ([title, quote] + questions).joined(separator: " ").lowercased()
        let appLower = app.lowercased()
        var best: (name: String, score: Int)?
        for s in sectors where s.hasRules {
            var score = 0
            for a in s.apps.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) where !a.isEmpty {
                if appLower.contains(a) || (a.contains(".") && hay.contains(a)) { score += 3 }
            }
            for k in s.keywords.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) where !k.isEmpty {
                if Self.contains(hay, word: k) { score += 1 }
            }
            if score > (best?.score ?? 0) { best = (s.name, score) }
        }
        return best?.name
    }

    /// Short keywords match whole words only ("ode" must not match "code").
    private static func contains(_ hay: String, word: String) -> Bool {
        guard word.count < 4 else { return hay.contains(word) }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return hay.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Re-file all

    /// What "Re-file all" would do, for the preview: unlocked chats whose rules (or, for chats sitting in Other, the built-in
    /// keyword guess) point somewhere else. Chats you filed yourself are never in it. Nothing is changed.
    func refilePreview() -> [RefileMove] {
        var out: [RefileMove] = []
        for c in library.chats where !c.sectorLocked {
            var target = ruleMatch(for: c)
            if target == nil, c.sector == Sector.other {
                let text = ([c.title, c.quote] + c.turns.map(\.question)).joined(separator: " ")
                if let guess = Sector.guess(from: text), sector(named: guess) != nil { target = sector(named: guess)?.name }
            }
            if let target, target != c.sector { out.append(RefileMove(id: c.id, title: c.title, from: c.sector, to: target)) }
        }
        return out
    }

    /// Applies the ticked moves. Chats keep their lock setting (these are Margin's moves, not yours), and a chat that got
    /// locked since the preview is skipped. Returns what's needed for `Library.undo`.
    @discardableResult
    func applyRefile(_ moves: [RefileMove], only checked: Set<UUID>) -> SectorUndo {
        var changes: [UUID: String] = [:]
        for m in moves where checked.contains(m.id) {
            guard let c = library.chat(m.id), !c.sectorLocked else { continue }
            changes[m.id] = m.to
        }
        return library.applySectors(changes, lock: nil)
    }

    // MARK: Keeping in step with the library

    /// Adds any sector the library uses that isn't listed yet (Claude coins new ones now and then).
    func syncWithLibrary() {
        guard !syncing else { return }
        adoptUnknownNames(save: true)
    }

    private func adoptUnknownNames(save: Bool) {
        let used = library.chats.map(\.sector) + library.notes.map(\.sector) + library.screenshots.map(\.sector)
        var added = false
        for name in used where !name.isEmpty && sector(named: name) == nil {
            let free = freeStyle()
            let otherAt = sectors.firstIndex { $0.name == Sector.other } ?? sectors.endIndex
            sectors.insert(UserSector(name: name, order: 0, colorIndex: free.0, glyph: free.1), at: otherAt)
            added = true
        }
        if added { save ? commit() : renumber() }
    }

    // MARK: Internals

    private func seeded() -> [UserSector] {
        var names = Sector.defaults.filter { $0 != Sector.other }
        for n in library.chats.map(\.sector) + library.notes.map(\.sector) + library.screenshots.map(\.sector)
        where !n.isEmpty && n != Sector.other && !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
            names.append(n)
        }
        let hues = Theme.sectorHues.count, glyphs = SectorGlyph.allCases
        var out = names.enumerated().map { i, n in
            UserSector(name: n, order: i, colorIndex: i % hues, glyph: glyphs[(i / hues) % glyphs.count])
        }
        out.append(UserSector(name: Sector.other, order: out.count, colorIndex: hues - 1, glyph: .square))
        return out
    }

    private func ensureOther() {
        if sector(named: Sector.other) == nil {
            sectors.append(UserSector(name: Sector.other, order: sectors.count, colorIndex: Theme.sectorHues.count - 1, glyph: .square))
        }
        renumber()
    }

    /// The first colour and shape pairing no sector has (shapes vary before hues repeat), or the least-used if all are taken.
    private func freeStyle() -> (Int, SectorGlyph) {
        let taken = Set(sectors.map { "\($0.colorIndex)-\($0.glyph.rawValue)" })
        for g in SectorGlyph.allCases {
            for h in 0..<Theme.sectorHues.count where !taken.contains("\(h)-\(g.rawValue)") { return (h, g) }
        }
        return (sectors.count % Theme.sectorHues.count, .circle)
    }

    private func renumber() {
        for i in sectors.indices { sectors[i].order = i }
    }

    private func commit() {
        renumber()
        let data = try? Self.encoder.encode(sectors)
        let url = fileURL
        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

// MARK: - "Help me describe this sector"

/// One lean Claude call (no tools, no screenshot, Haiku), only when the user clicks the button: given a sector's name and up to
/// 8 titles of chats in it, it suggests a one-sentence description and up to 6 keywords. Same path as `ChatNaming`.
enum SectorDescriber {
    struct Suggestion: Equatable {
        var description: String
        var keywords: [String]
    }

    static let maxTitles = 8
    static let system = """
        You help someone describe a section of their chat history so new chats can be filed into it. \
        Reply with ONLY JSON: {"description": "…", "keywords": ["…"]}. \
        description: one plain sentence (under 20 words) saying what belongs in this section. \
        keywords: at most 6 lowercase words or short phrases that would appear in chats that belong here.
        """

    /// The most recent chat titles in a sector (at most 8).
    static func titles(for sector: String, in library: Library) -> [String] {
        Array(library.chats.filter { $0.sector == sector }.map(\.title).prefix(maxTitles))
    }

    static func prompt(sector: String, titles: [String]) -> String {
        let list = titles.isEmpty ? "(no chats yet)" : titles.prefix(maxTitles).map { "- " + String($0.prefix(80)) }.joined(separator: "\n")
        return "Section name: \(sector)\nChats in it:\n\(list)"
    }

    static func parse(_ reply: String) -> Suggestion? {
        guard let object = ClaudeOneShot.json(from: reply) as? [String: Any] else { return nil }
        var sentence = ((object["description"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.count > 160 { sentence = String(sentence.prefix(160)) }
        var words: [String] = []
        for raw in (object["keywords"] as? [Any]) ?? [] {
            guard let w = (raw as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty, w.count <= 24,
                  !words.contains(w) else { continue }
            words.append(w)
            if words.count == 6 { break }
        }
        guard !sentence.isEmpty || !words.isEmpty else { return nil }
        return Suggestion(description: sentence, keywords: words)
    }

    /// How Claude is reached (replaced in tests).
    static var claudeRun: (_ prompt: String, _ system: String, _ model: ModelChoice, _ done: @escaping (Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) -> Void) -> Void = { prompt, system, model, done in
        ClaudeOneShot.run(prompt, system: system, model: model, timeout: 45, completion: done)
    }

    /// Asks Claude. `done` runs on the main queue. The call is logged in `UsageLog` as Library housekeeping.
    static func describe(sector: String, in library: Library = .shared, model: ModelChoice = .haiku,
                         done: @escaping (Result<Suggestion, ClaudeOneShot.Failure>) -> Void) {
        let text = prompt(sector: sector, titles: titles(for: sector, in: library))
        claudeRun(text, system, model) { result in
            switch result {
            case .failure(let failure):
                done(.failure(failure))
            case .success(let reply):
                UsageLog.recordHousekeeping(.describing, usage: reply.usage)
                if let suggestion = parse(reply.text) {
                    done(.success(suggestion))
                } else {
                    done(.failure(.failed("Claude's answer couldn't be read. Try again.")))
                }
            }
        }
    }
}
