import Foundation

/// Unit checks for the Library settings aggregation (pure functions and temporary folders; no panels, no windows).
extension FeatureTests {
    static func librarySettings(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        // Thursday 29 October 2026, noon UTC.
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
        func at(_ daysAgo: Int, hour: Int = 9) -> Date {
            cal.date(byAdding: .hour, value: hour - 12, to: cal.date(byAdding: .day, value: -daysAgo, to: now)!)!
        }
        func entry(_ daysAgo: Int, in i: Int, out o: Int, cached c: Int = 0, why: String = "snip", cost: Double = 0.01,
                   engine: String = "claude") -> UsageLog.Entry {
            var e = UsageLog.Entry(engine: engine)
            e.time = at(daysAgo)
            e.input = i; e.output = o; e.cached = c; e.costUSD = cost; e.why = why
            return e
        }
        let hk = LibraryUsage.Housekeeping.naming.label
        let entries = [
            entry(0, in: 100, out: 50, cached: 850),             // today: 1000
            entry(1, in: 200, out: 100, cached: 700, cost: 0.02), // Wed: 1000
            entry(3, in: 10, out: 5, cached: 5, why: hk),          // Mon: 20 (housekeeping)
            entry(4, in: 1000, out: 0, cached: 0),                 // Sun, last week, same month
            entry(30, in: 5000, out: 0, cached: 0),                // September
            entry(20, in: 0, out: 0, engine: "local"),
        ]
        var local = UsageLog.Entry(engine: "local", saved: 4200); local.time = at(1)
        var reask = UsageLog.Entry.reask(saving: 1000); reask.time = at(1)

        check("settings: housekeeping labels", LibraryUsage.isHousekeeping(hk) && !LibraryUsage.isHousekeeping("snip")
              && LibraryUsage.Housekeeping.allCases.allSatisfy { LibraryUsage.isHousekeeping($0.label) })
        check("settings: week starts Monday", LibraryUsage.weekStart(now, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        check("settings: month starts on the 1st", LibraryUsage.monthStart(now, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 1)))

        let p = LibraryUsage.periods(entries, now: now, calendar: cal)
        check("settings: week tokens (Mon to now)", p.week.tokens == 1000 + 1000 + 20)
        check("settings: week split into input/output/cached", p.week.input == 310 && p.week.output == 155 && p.week.cached == 1555)
        check("settings: week cost sums", abs(p.week.cost - 0.04) < 1e-9)
        check("settings: month tokens skip September", p.month.tokens == 1000 + 1000 + 20 + 1000)
        check("settings: local entries cost no Claude tokens", LibraryUsage.totals(entries, from: .distantPast).calls == 5)

        let days = LibraryUsage.daily(entries, days: 14, now: now, calendar: cal)
        check("settings: 14 days, oldest first", days.count == 14 && days.last?.start == cal.startOfDay(for: now)
              && days.first?.start == cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now)))
        check("settings: today and yesterday bars", days[13].tokens == 1000 && days[12].tokens == 1000)
        check("settings: empty days are 0, old entries left out", days[11].tokens == 0 && days.map(\.tokens).reduce(0, +) == 3020)
        check("settings: no entries gives flat zeros", LibraryUsage.daily([], days: 14, now: now, calendar: cal).allSatisfy { $0.tokens == 0 })

        let s = LibraryUsage.split(entries)
        check("settings: split separates upkeep", s.housekeeping.tokens == 20 && s.housekeeping.calls == 1 && s.answers.calls == 4)
        check("settings: upkeep percent", LibraryUsage.split(entries, from: at(4)).housekeepingPercent == 1)
        check("settings: split of nothing", LibraryUsage.split([]).housekeepingPercent == 0)

        let saved = LibraryUsage.localSavings([local, reask] + entries)
        check("settings: local savings count answers and net out re-asks", saved.answers == 2 && saved.saved == 3200)
        check("settings: savings percent", saved.percent == UsageLog.summarize([local, reask] + entries).savedPercent)

        check("settings: compact numbers", LibraryUsage.compact(0) == "0" && LibraryUsage.compact(950) == "950"
              && LibraryUsage.compact(1240) == "1.2k" && LibraryUsage.compact(12_400) == "12k"
              && LibraryUsage.compact(3_400_000) == "3.4M" && LibraryUsage.compact(2000) == "2k")
        check("settings: dollars", LibraryUsage.dollars(0) == "$0.00" && LibraryUsage.dollars(0.001) == "<$0.01" && LibraryUsage.dollars(1.5) == "$1.50")
        check("settings: export name", LibraryUsage.exportName(ext: "json", now: now, calendar: cal) == "Margin Library 2026-10-29.json")

        // Storage and retention, on a throwaway Library (the real one is never touched).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("margin-settings-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let lib = Library(directory: root)
        lib.save(ChatRecord(title: "A", sector: "Math", app: "Safari", quote: "q", turns: [.init(question: "Q", answer: "A")]))
        lib.save(ChatRecord(title: "B", sector: "Math", app: "Safari", quote: "q", turns: [.init(question: "Q", answer: "A")]))
        lib.add(Note(title: "N", sector: "Math", app: "Safari", quote: "q", question: "Q", body: "B"))
        func shot(_ name: String, age days: Int) -> ScreenshotRecord {
            var r = ScreenshotRecord(title: name)
            r.created = Date().addingTimeInterval(-Double(days) * 86_400)
            _ = lib.writeScreenshotImage(Data(count: 4000), for: r)
            lib.add(r)
            return r
        }
        let old = shot("old", age: 100), young = shot("young", age: 1), binShot = shot("binned", age: 2)
        lib.delete(screenshot: binShot.id)
        lib.flush()
        let report = LibraryUsage.storage(of: lib)
        check("storage: chats counted", report[.chats].files == 2 && report[.chats].bytes > 0)
        check("storage: notes counted", report[.notes].files == 1)
        check("storage: screenshots are record plus picture, minus the binned one", report[.screenshots].files == 4 && report[.screenshots].bytes >= 8000)
        check("storage: the binned screenshot's picture counts under Bin", report[.bin].files == 2 && report[.bin].bytes >= 4000 && report.binItems == 1)
        check("storage: total adds up", report.total == LibraryUsage.Kind.allCases.map { report[$0].bytes }.reduce(0, +))
        check("storage: a missing folder is empty", LibraryUsage.size(of: root.appendingPathComponent("nope")).files == 0)

        // Retention uses Settings; the Bin days come from the real setting, 0 = never.
        let suite = "margin-test-\(UUID().uuidString)"
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        let realSettings = Library.settings
        Library.settings = settings
        defer { Library.settings = realSettings; UserDefaults().removePersistentDomain(forName: suite) }
        settings.binAutoEmptyDays = 30; settings.screenshotRetentionDays = 0
        check("retention: forever keeps old screenshots", lib.applyRetention().screenshots == 0 && lib.screenshot(old.id) != nil)
        settings.screenshotRetentionDays = 30
        let gone = lib.applyRetention()
        lib.flush()
        check("retention: screenshots older than N days go for good, picture too", gone.screenshots == 1 && lib.screenshot(old.id) == nil
              && !fm.fileExists(atPath: lib.imageURL(for: old).path) && lib.screenshot(young.id) != nil)
        settings.binAutoEmptyDays = 0
        check("bin days: 0 means never auto-empty", Library.binDays == 0 && lib.purgeBin(now: Date().addingTimeInterval(400 * 86_400)) == 0 && lib.binned.count == 1)
        settings.binAutoEmptyDays = 7
        let purged = lib.purgeBin(now: Date().addingTimeInterval(8 * 86_400))
        lib.flush()
        check("bin days: the setting is what Library reads", Library.binDays == 7 && purged == 1 && lib.binned.isEmpty
              && !fm.fileExists(atPath: lib.imageURL(for: binShot).path))
        lib.delete(screenshot: young.id)
        let emptied = lib.emptyBin().count
        lib.flush()
        check("bin: Empty Bin now deletes everything and its pictures", emptied == 1 && lib.binned.isEmpty && LibraryUsage.storage(of: lib)[.bin].files == 0)

        // Export
        let chat = ChatRecord(title: "T", sector: "Math", app: "Safari", quote: "q", turns: [.init(question: "Q", answer: "A")])
        let json = LibraryUsage.exportJSON(chats: [chat], notes: [], now: now)
        let back = json.flatMap { data -> LibraryUsage.Export? in
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try? d.decode(LibraryUsage.Export.self, from: data)
        }
        check("export: JSON round-trips", back?.chats.map(\.id) == [chat.id] && back?.chats.first?.turns == chat.turns && back?.notes.isEmpty == true)

        // The new keys are read through Settings with defaults equal to the old behaviour.
        check("settings: enums parse", LibraryDefaultView(rawValue: "last") == .last && LibraryRowDensity(rawValue: "compact") == .compact)
    }
}
