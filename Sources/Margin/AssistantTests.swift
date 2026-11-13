import AppKit
import Foundation

extension FeatureTests {
    /// The Library assistant: what the model's JSON means, what a filter finds, and that deleting waits, spares starred chats and can be undone.
    static func assistantChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("margin-assistant-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let suite = "margin.assistant.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(directory: dir)
        let settings = Settings(defaults: defaults)
        let assistant = LibraryAssistant(library: library, settings: settings, sectors: nil)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        assistant.calendar = cal
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        assistant.now = { today }
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }

        func chat(_ title: String, _ sector: String, daysAgo n: Int, starred: Bool = false) -> ChatRecord {
            var c = ChatRecord(title: title, sector: sector, app: "Safari", quote: "about \(title)", turns: [.init(question: "Why?", answer: "Because \(title).")])
            c.updated = daysAgo(n); c.starred = starred
            return c
        }
        let old1 = chat("Parabola vertex", "Math", daysAgo: 40), old2 = chat("Supply shift", "Economics", daysAgo: 35)
        let week1 = chat("Derivative rules", "Math", daysAgo: 3), week2 = chat("Kinetic energy", "Physics", daysAgo: 5)
        let kept = chat("Elasticity", "Economics", daysAgo: 60, starred: true)
        [old1, old2, week1, week2, kept].forEach { library.save($0, touch: false) }

        // Reading what the model says.
        let fenced = "```json\n{\"say\":\"Looking.\",\"actions\":[{\"type\":\"find\",\"filter\":{\"kinds\":\"note\",\"refs\":2,\"starred\":true}},{\"type\":\"set_setting\",\"key\":\"binAutoEmptyDays\",\"value\":7}]}\n```"
        let plan = LibraryAssistant.parse(fenced)
        check("assistant: reads JSON out of a fenced reply", plan?.say == "Looking." && plan?.actions.count == 2)
        check("assistant: a lone string or number is read as a list or a text", plan?.actions[0].filter?.kinds == ["note"] && plan?.actions[0].filter?.refs == [2]
              && plan?.actions[1].value == "7")
        check("assistant: a reply with no JSON is nothing", LibraryAssistant.parse("Sure, I'll do that!") == nil && LibraryAssistant.parse("{broken") == nil)
        check("assistant: a reply with no actions is just talk", LibraryAssistant.parse("{\"say\":\"Which week?\"}")?.actions.isEmpty == true)

        // Finding.
        let q = assistant.resolve(.init(query: "parabola"))
        check("assistant: finds by words", q.map(\.title) == ["Parabola vertex"])
        check("assistant: finds by sector, newest first", assistant.resolve(.init(sector: "Math")).map(\.title) == ["Derivative rules", "Parabola vertex"])
        check("assistant: finds by date range", assistant.resolve(.init(from: "2026-11-01", to: "2026-11-09")).map(\.title) == ["Derivative rules", "Kinetic energy"])
        check("assistant: 'to' includes the whole day", assistant.resolve(.init(from: "2026-11-06", to: "2026-11-06")).map(\.title) == ["Derivative rules"])
        check("assistant: finds starred", assistant.resolve(.init(starred: true)).map(\.title) == ["Elasticity"])
        check("assistant: finds older than a date", assistant.resolve(.init(to: "2026-10-15")).count == 3)

        // "Those" and "#2" mean the last list.
        _ = assistant.run(.init(say: "", actions: [.init(type: "find", filter: .init(sector: "Economics"))]), apply: true)
        check("assistant: remembers the last results", assistant.last.map(\.title) == ["Supply shift", "Elasticity"])
        check("assistant: #2 is the second of them", assistant.resolve(.init(refs: [2])).map(\.title) == ["Elasticity"])
        check("assistant: scope last is all of them", assistant.resolve(.init(scope: "last")).count == 2)

        // Risk.
        func risk(_ t: String, _ key: String? = nil) -> LibraryAssistant.Risk { LibraryAssistant.risk(of: .init(type: t, key: key)) }
        check("assistant: finding, starring and filing need no OK", risk("find") == .safe && risk("star") == .safe && risk("move") == .safe && risk("set_setting", "learnMode") == .safe)
        check("assistant: deleting waits for an OK", risk("delete") == .confirm)
        check("assistant: deleting for good is the strongest", risk("empty_bin") == .permanent && risk("delete_forever") == .permanent)
        check("assistant: a setting that deletes on its own waits too", risk("set_setting", "binAutoEmptyDays") == .confirm && risk("set_setting", "screenshotRetentionDays") == .confirm)

        // Delete: a preview changes nothing; apply spares starred; undo puts it back.
        let delAll = LibraryAssistant.Plan(say: "", actions: [.init(type: "delete", filter: .init(to: "2026-11-01"))])
        let preview = assistant.run(delAll, apply: false)
        check("assistant: a delete preview changes nothing", library.chats.count == 5 && library.binned.isEmpty)
        check("assistant: ...and says what would happen, with starred staying", preview[0].text.contains("2 chats") && preview[0].text.contains("1 starred stays"))
        let done = assistant.run(delAll, apply: true)
        check("assistant: deleting moves chats to the Bin", library.chats.count == 3 && library.binned.count == 2)
        check("assistant: a starred chat survives the delete", library.chat(kept.id) != nil)
        done.reversed().forEach { $0.undo?() }
        check("assistant: undo brings them back", library.chats.count == 5 && library.binned.isEmpty)
        let onlyStarred = assistant.run(.init(say: "", actions: [.init(type: "delete", filter: .init(starred: true))]), apply: true)
        check("assistant: deleting only starred chats refuses", onlyStarred[0].failed && library.chat(kept.id) != nil)

        // Star, unstar, move, rename.
        let star = assistant.run(.init(say: "", actions: [.init(type: "star", filter: .init(sector: "Physics"))]), apply: true)
        check("assistant: stars", library.chat(week2.id)?.starred == true)
        star.forEach { $0.undo?() }
        check("assistant: unstar undoes it", library.chat(week2.id)?.starred == false)
        let move = assistant.run(.init(say: "", actions: [.init(type: "move", filter: .init(query: "parabola"), sector: "Physics")]), apply: true)
        check("assistant: files under a sector", library.chat(old1.id)?.sector == "Physics" && library.chat(old1.id)?.sectorLocked == true)
        move.forEach { $0.undo?() }
        check("assistant: ...and undoes it", library.chat(old1.id)?.sector == "Math")
        let ren = assistant.run(.init(say: "", actions: [.init(type: "rename", filter: .init(query: "kinetic"), title: "Energy of motion")]), apply: true)
        check("assistant: renames one", library.chat(week2.id)?.title == "Energy of motion" && library.chat(week2.id)?.titleLocked == true)
        ren.forEach { $0.undo?() }
        check("assistant: ...and undoes it too", library.chat(week2.id)?.title == "Kinetic energy")
        let many = assistant.run(.init(say: "", actions: [.init(type: "rename", filter: .init(sector: "Math"), title: "X")]), apply: true)
        check("assistant: won't rename several at once", many[0].failed && library.chat(week1.id)?.title == "Derivative rules")

        // Bin: restore, delete forever, empty.
        _ = assistant.run(.init(say: "", actions: [.init(type: "delete", filter: .init(to: "2026-10-15"))]), apply: true)
        check("assistant: two are in the Bin", library.binned.count == 2)
        _ = assistant.run(.init(say: "", actions: [.init(type: "restore", filter: .init(query: "parabola"))]), apply: true)
        check("assistant: restores by words", library.chat(old1.id) != nil && library.binned.count == 1)
        let forever = assistant.run(.init(say: "", actions: [.init(type: "delete_forever", filter: .init(scope: "bin"))]), apply: false)
        check("assistant: a delete-forever preview deletes nothing", library.binned.count == 1 && forever[0].text.contains("can't be undone"))
        _ = assistant.run(.init(say: "", actions: [.init(type: "empty_bin")]), apply: true)
        check("assistant: empties the Bin", library.binned.isEmpty)

        // Settings.
        let off = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "saveScreenshots", value: "off")]), apply: true)
        check("assistant: changes a setting", settings.saveScreenshots == false)
        off.forEach { $0.undo?() }
        check("assistant: ...and undoes it", settings.saveScreenshots == true)
        _ = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "libraryRowDensity", value: "compact")]), apply: true)
        check("assistant: sets a choice setting", settings.libraryRowDensity == .compact)
        let bad = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "libraryRowDensity", value: "enormous")]), apply: true)
        check("assistant: refuses a value that isn't one", bad[0].failed && settings.libraryRowDensity == .compact)
        let unknown = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "personalRules", value: "x")]), apply: true)
        check("assistant: refuses a setting it isn't allowed to touch", unknown[0].failed)
        check("assistant: a setting preview leaves nothing changed", {
            _ = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "binAutoEmptyDays", value: "3")]), apply: false)
            return settings.binAutoEmptyDays == 30
        }())
        let unk = assistant.run(.init(say: "", actions: [.init(type: "launch_missiles")]), apply: true)
        check("assistant: an action it doesn't know is refused", unk[0].failed)

        // What the model is shown.
        let prompt = assistant.userPrompt("delete old ones", history: [("You", "hi")])
        check("assistant: the prompt carries today's date and the counts", prompt.contains("2026-11-09") && prompt.contains("4 chats (1 starred)"))
        check("assistant: ...the settings and the request, but no chat contents", prompt.contains("binAutoEmptyDays=30") && prompt.contains("REQUEST: delete old ones")
              && !prompt.contains("Because Parabola vertex"))
    }
}
