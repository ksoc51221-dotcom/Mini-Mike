import Foundation

/// Pure aggregation behind the Library settings page: usage from `UsageLog` entries, and sizes of the Library's folders.
/// Everything takes its inputs (entries, a `now`, a calendar, a folder) so it can be tested without touching real data.
enum LibraryUsage {
    // MARK: - Housekeeping labels

    /// `UsageLog.Entry.why` for calls Margin makes for the Library itself (not for an answer you asked for).
    static let housekeepingPrefix = "housekeeping"

    enum Housekeeping: String, CaseIterable {
        case naming, filing, describing

        /// The label written to the usage log.
        var label: String { "\(LibraryUsage.housekeepingPrefix): \(rawValue)" }
    }

    static func isHousekeeping(_ why: String) -> Bool { why.hasPrefix(housekeepingPrefix) }

    // MARK: - Usage

    struct Totals: Equatable {
        var input = 0
        var output = 0
        var cached = 0
        var cost = 0.0
        var calls = 0

        var tokens: Int { input + output + cached }

        mutating func add(_ e: UsageLog.Entry) {
            input += e.input
            output += e.output
            cached += e.cached
            cost += e.costUSD
            calls += 1
        }
    }

    /// Entries that spent Claude tokens (local answers and "reask" markers don't).
    static func claudeEntries(_ entries: [UsageLog.Entry]) -> [UsageLog.Entry] { entries.filter { $0.engine == "claude" } }

    static func totals(_ entries: [UsageLog.Entry], from start: Date, to end: Date = .distantFuture) -> Totals {
        var t = Totals()
        for e in claudeEntries(entries) where e.time >= start && e.time < end { t.add(e) }
        return t
    }

    /// Start of the calendar week and month that contain `now`.
    static func weekStart(_ now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    static func monthStart(_ now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    struct Periods: Equatable {
        var week: Totals
        var month: Totals
    }

    static func periods(_ entries: [UsageLog.Entry], now: Date = Date(), calendar: Calendar = .current) -> Periods {
        Periods(week: totals(entries, from: weekStart(now, calendar: calendar)),
                month: totals(entries, from: monthStart(now, calendar: calendar)))
    }

    struct Day: Equatable, Identifiable {
        var start: Date
        var tokens: Int
        var id: Date { start }
    }

    /// Claude tokens per day for the last `days` days, oldest first, today last. Days with nothing are 0.
    static func daily(_ entries: [UsageLog.Entry], days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var out: [Day] = (0..<days).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Day(start: $0, tokens: 0) }
        }
        guard let first = out.first?.start else { return [] }
        for e in claudeEntries(entries) where e.time >= first {
            let d = calendar.startOfDay(for: e.time)
            if let i = out.firstIndex(where: { $0.start == d }) { out[i].tokens += e.input + e.output + e.cached }
        }
        return out
    }

    struct Split: Equatable {
        var answers = Totals()
        var housekeeping = Totals()
        /// Housekeeping's share of all Margin tokens, 0 to 100.
        var housekeepingPercent: Int {
            let all = answers.tokens + housekeeping.tokens
            return all > 0 ? Int((Double(housekeeping.tokens) / Double(all) * 100).rounded()) : 0
        }
    }

    /// Answers you asked for versus the Library's own upkeep (chat naming, sector filing, sector descriptions).
    static func split(_ entries: [UsageLog.Entry], from start: Date = .distantPast) -> Split {
        var s = Split()
        for e in claudeEntries(entries) where e.time >= start {
            if isHousekeeping(e.why) { s.housekeeping.add(e) } else { s.answers.add(e) }
        }
        return s
    }

    struct LocalSavings: Equatable {
        var answers = 0
        var saved = 0
        var percent = 0
    }

    static func localSavings(_ entries: [UsageLog.Entry], from start: Date = .distantPast) -> LocalSavings {
        let s = UsageLog.summarize(entries.filter { $0.time >= start })
        return LocalSavings(answers: s.localAnswers, saved: s.saved, percent: s.savedPercent)
    }

    // MARK: - Formatting

    /// 950 -> "950", 1,240 -> "1.2k", 3,400,000 -> "3.4M".
    static func compact(_ n: Int) -> String {
        let v = Double(abs(n)), sign = n < 0 ? "-" : ""
        switch v {
        case ..<1_000: return "\(n)"
        case ..<10_000: return sign + trim(v / 1_000) + "k"
        case ..<1_000_000: return sign + String(Int((v / 1_000).rounded())) + "k"
        default: return sign + trim(v / 1_000_000) + "M"
        }
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    static func dollars(_ v: Double) -> String { v < 0.005 && v > 0 ? "<$0.01" : String(format: "$%.2f", v) }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    // MARK: - Storage

    /// What the Library keeps on disk, grouped the way the Library thinks of it. Chats, notes and the Bin are folders of JSON;
    /// a screenshot is a JSON record (`screenshots`) plus a JPEG (`screenshot-images`). A screenshot in the Bin still has its
    /// JPEG until the Bin is emptied, so that picture counts under Bin, not Screenshots.
    enum Kind: String, CaseIterable, Identifiable {
        case chats, notes, screenshots, bin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chats: return "Chats"
            case .notes: return "Notes"
            case .screenshots: return "Screenshots"
            case .bin: return "Bin"
            }
        }
    }

    struct Size: Equatable {
        var bytes: Int64 = 0
        var files = 0
        static func + (a: Size, b: Size) -> Size { Size(bytes: a.bytes + b.bytes, files: a.files + b.files) }
    }

    struct StorageReport: Equatable {
        var sizes: [Kind: Size] = [:]
        /// Things in the Bin (a screenshot is one thing, though it is two files).
        var binItems = 0
        subscript(kind: Kind) -> Size { sizes[kind] ?? Size() }
        var total: Int64 { sizes.values.reduce(0) { $0 + $1.bytes } }
    }

    /// Size and file count of everything under `url` (0 if it doesn't exist). `skipping` leaves out files by name.
    static func size(of url: URL, skipping: Set<String> = [], only: Set<String>? = nil) -> Size {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return Size() }
        var s = Size()
        for case let file as URL in walker {
            let name = file.lastPathComponent
            if skipping.contains(name) || (only.map { !$0.contains(name) } ?? false) { continue }
            guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            s.bytes += Int64(v.fileSize ?? 0)
            s.files += 1
        }
        return s
    }

    /// Sizes from the real Library's folders (`Library.directory`), with the Bin's screenshot pictures counted under Bin.
    static func storage(of library: Library) -> StorageReport {
        let dir = library.directory
        let binImages = Set(library.binnedImageFiles)
        func sub(_ name: String) -> URL { dir.appendingPathComponent(name, isDirectory: true) }
        var r = StorageReport()
        r.sizes[.chats] = size(of: sub("chats"))
        r.sizes[.notes] = size(of: sub("notes"))
        r.sizes[.screenshots] = size(of: sub("screenshots")) + size(of: library.screenshotImagesDirectory, skipping: binImages)
        r.sizes[.bin] = size(of: sub("bin")) + size(of: library.screenshotImagesDirectory, only: binImages)
        r.binItems = library.binned.count
        return r
    }

    // MARK: - Export

    struct Export: Codable {
        var exported: Date
        var chats: [ChatRecord]
        var notes: [Note]
    }

    /// The whole library as one JSON file (dates in ISO 8601).
    static func exportJSON(chats: [ChatRecord], notes: [Note], now: Date = Date()) -> Data? {
        let e = JSONEncoder.iso8601(.prettyPrinted, .sortedKeys)
        return try? e.encode(Export(exported: now, chats: chats, notes: notes))
    }

    /// A suggested file name like "Margin Library 2026-10-29.json".
    static func exportName(ext: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "Margin Library %04d-%02d-%02d.%@", c.year ?? 0, c.month ?? 0, c.day ?? 0, ext)
    }
}

extension UsageLog {
    /// Records a Claude call the Library made for itself, so the settings page can tell it apart from your answers.
    static func recordHousekeeping(_ kind: LibraryUsage.Housekeeping, usage: ClaudeSession.Usage) {
        record(Entry(engine: "claude", lean: true, why: kind.label, first: false, usage: usage, saved: 0))
    }
}
