import AppKit
import Foundation

extension FeatureTests {
    /// The Bin: deleting moves things there, restoring puts them back, and it empties itself after 30 days.
    static func binChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("margin-bintest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let library = Library(directory: dir)

        func chat(_ title: String, _ sector: String = "Math") -> ChatRecord {
            ChatRecord(title: title, sector: sector, app: "Safari", quote: "about \(title)", turns: [.init(question: "Why?", answer: "Because \(title).")])
        }
        let a = chat("Parabola"), b = chat("Supply shift", "Economics")
        library.save(a)
        library.save(b)
        library.flush()
        let stored = library.chat(a.id) ?? a // as the library holds it (saving stamps the time)
        let aFile = dir.appendingPathComponent("chats/\(a.id.uuidString).json")
        check("bin: starts empty", library.binned.isEmpty)

        // A chat: delete → Bin → restore.
        library.delete(chat: a.id)
        library.flush()
        check("bin: deleting a chat takes it out of the list", library.chat(a.id) == nil && library.chats.map(\.id) == [b.id])
        check("bin: ...and puts it in the Bin with everything in it", library.binItem(a.id)?.chat == stored && library.binned.count == 1)
        check("bin: ...its file moved (not copied)", !fm.fileExists(atPath: aFile.path)
              && fm.fileExists(atPath: dir.appendingPathComponent("bin/chat-\(a.id.uuidString).json").path))
        check("bin: a deleted chat isn't searched, counted or filed under a sector", library.search(chats: "parabola").isEmpty
              && !library.usedSectors.contains { $0.name == "Math" })
        check("bin: ...but the Bin's search finds it", library.search(bin: "parabola").count == 1 && library.search(bin: "parabola", kind: .note).isEmpty
              && library.search(bin: "zzz").isEmpty)
        check("bin: a new item has about 30 days", library.daysLeft(library.binned[0]) == 30)
        check("bin: restoring puts it back", library.restore(a.id) && library.chat(a.id) == stored && library.binned.isEmpty)
        library.flush()
        check("bin: ...its file is back and the Bin's is gone", fm.fileExists(atPath: aFile.path)
              && !fm.fileExists(atPath: dir.appendingPathComponent("bin/chat-\(a.id.uuidString).json").path))
        check("bin: a chat comes back to its old place in the list", library.chats.map(\.id).contains(a.id))
        check("bin: restoring something that isn't there does nothing", !library.restore(UUID()))

        // It survives a restart.
        library.delete(chat: b.id)
        library.flush()
        let reopened = Library(directory: dir)
        check("bin: the Bin survives a restart", reopened.binned.map(\.id) == [b.id] && reopened.binItem(b.id)?.chat?.title == "Supply shift")
        check("bin: ...and the chat stays out of the list", reopened.chats.map(\.id) == [a.id])

        // A note and a screenshot (the picture stays until it's deleted for good).
        let note = Note(title: "T", sector: "Math", app: "Safari", quote: "q", question: "Why up?", body: "Because a > 0.")
        library.add(note)
        var shot = ScreenshotRecord(title: "BIDV history")
        shot.text = "Transaction history"
        let jpeg = Snipper.downscaledJPEG(wordsPNG("Hello", width: 400, height: 200)) ?? Data()
        _ = library.writeScreenshotImage(jpeg, for: shot)
        library.add(shot)
        let picture = library.imageURL(for: shot).path
        library.delete(note: note.id)
        library.delete(screenshot: shot.id)
        library.flush()
        check("bin: a note and a screenshot go to the Bin too", library.notes.isEmpty && library.screenshots.isEmpty
              && library.binItem(note.id)?.kind == .note && library.binItem(shot.id)?.kind == .screenshot)
        check("bin: a screenshot's picture waits in the Bin with it", fm.fileExists(atPath: picture))
        check("bin: the Bin searches pictures by the words in them", library.search(bin: "transaction").map(\.id) == [shot.id])
        check("bin: restoring a screenshot brings its picture back to the dashboard", library.restore(shot.id)
              && library.screenshot(shot.id) == shot && fm.fileExists(atPath: picture))
        check("bin: restoring a note", library.restore(note.id) && library.notes.map(\.id) == [note.id])

        // Delete forever.
        library.delete(screenshot: shot.id)
        library.deleteForever(shot.id)
        library.flush()
        check("bin: deleting a screenshot for good removes its picture", library.binItem(shot.id) == nil && !fm.fileExists(atPath: picture))
        check("bin: ...and it can't come back", !library.restore(shot.id) && library.screenshot(shot.id) == nil)

        // Delete all gives back the ids (for Undo), and a restore brings them all back.
        let ids = library.deleteAllChats()
        library.flush()
        check("bin: clear-all chats returns their ids and fills the Bin", Set(ids) == Set([a.id]) && library.chats.isEmpty && library.binItem(a.id) != nil)
        check("bin: Undo of a clear-all", ids.allSatisfy { library.restore($0) } && library.chats.map(\.id) == [a.id])

        // A chat that carried on after it was deleted: restoring doesn't overwrite it, it comes back beside it.
        library.delete(chat: a.id)
        library.save(a)
        check("bin: a chat that carried on is back already", library.chats.map(\.id) == [a.id])
        check("bin: restoring the old copy keeps both", library.restore(a.id) && library.chats.count == 2 && Set(library.chats.map(\.title)) == ["Parabola"])

        // 30 days.
        let old = BinItem(chat: chat("Ancient"), deleted: Date().addingTimeInterval(-31 * 86_400))
        let young = BinItem(chat: chat("Recent"), deleted: Date().addingTimeInterval(-29 * 86_400))
        library.keepInBin(old)
        library.keepInBin(young)
        check("bin: 29 days in, it has 1 day left", library.daysLeft(young) == 1)
        check("bin: the Bin drops what's older than 30 days, and only that", library.purgeBin() == 1
              && library.binItem(old.id) == nil && library.binItem(young.id) != nil)
        library.flush()
        check("bin: ...their files go too", !fm.fileExists(atPath: dir.appendingPathComponent("bin/chat-\(old.id.uuidString).json").path)
              && fm.fileExists(atPath: dir.appendingPathComponent("bin/chat-\(young.id.uuidString).json").path))
        library.keepInBin(old)
        library.flush()
        check("bin: opening the library drops what's old", Library(directory: dir).binItem(old.id) == nil)

        // Empty Bin.
        library.delete(note: note.id)
        let gone = library.emptyBin()
        library.flush()
        check("bin: Empty Bin deletes everything in it", library.binned.isEmpty && gone.contains(note.id) && gone.contains(young.id)
              && ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("bin").path)) ?? []).isEmpty)

        dashboardChecks(check)
    }
}

extension FeatureTests {
    /// What the dashboard shows and does, without a window: day groups, labels, the clear / undo / restore flow, and which view shows what.
    static func dashboardChecks(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_000_000) // a fixed afternoon
        func ago(days: Double, hours: Double = 0) -> Date { now.addingTimeInterval(-(days * 86_400 + hours * 3600)) }

        check("dashboard: this morning is TODAY", Feed.dayLabel(ago(days: 0, hours: 3), now: now, calendar: cal) == "Today")
        check("dashboard: the day before is YESTERDAY", Feed.dayLabel(ago(days: 1), now: now, calendar: cal) == "Yesterday")
        check("dashboard: 3 days ago is in the last 7 days", Feed.dayLabel(ago(days: 3), now: now, calendar: cal) == "Previous 7 days")
        check("dashboard: 15 days ago is in the last 30 days", Feed.dayLabel(ago(days: 15), now: now, calendar: cal) == "Previous 30 days")
        let older = Feed.dayLabel(ago(days: 90), now: now, calendar: cal)
        check("dashboard: older ones are filed by month (\(older))", older.hasSuffix("2026") && older.contains(" "))

        func item(_ title: String, _ date: Date) -> FeedItem {
            var c = ChatRecord(title: title, sector: "Math", app: "x", quote: "", turns: [.init(question: "q", answer: "a")])
            c.updated = date
            return FeedItem(chat: c)
        }
        let groups = Feed.groups([item("a", ago(days: 0, hours: 1)), item("b", ago(days: 0, hours: 2)), item("c", ago(days: 1)), item("d", ago(days: 40))],
                                 now: now, calendar: cal)
        check("dashboard: items are grouped under their day, in order", groups.map(\.label).first == "Today" && groups.count == 3
              && groups[0].items.map(\.title) == ["a", "b"] && groups[1].label == "Yesterday" && groups[1].items.count == 1)

        check("dashboard: times read like 19m, 3h, Yesterday", Feed.ago(now, now: now, calendar: cal) == "now" && Feed.ago(ago(days: 0, hours: 0.32), now: now, calendar: cal) == "19m"
              && Feed.ago(ago(days: 0, hours: 3), now: now, calendar: cal) == "3h" && Feed.ago(ago(days: 1), now: now, calendar: cal) == "Yesterday")
        check("dashboard: a week or more shows the date", Feed.ago(ago(days: 20), now: now, calendar: cal).split(separator: " ").count == 2)
        check("dashboard: slug of a title", Feed.slug("Avoiding the vibe-coded look!") == "avoiding-the-vibe-coded-look"
              && Feed.slug("Computer Science", separator: "_") == "computer_science" && Feed.slug("  ?? ") == "")
        check("dashboard: slug keeps other scripts and clips long titles", Feed.slug("Stress in замок") == "stress-in-замок"
              && Feed.slug(String(repeating: "word ", count: 30)).count <= 40)
        check("dashboard: reading time", Feed.readingTime(String(repeating: "word ", count: 840)) == "4 min read · 840 words"
              && Feed.readingTime("one") == "1 min read · 1 word")

        // Which view shows which kinds.
        check("dashboard: All and the Bin show everything", BinItem.Kind.allCases.allSatisfy { LibraryState.shows($0, in: .all) && LibraryState.shows($0, in: .bin) })
        check("dashboard: Chats, Notebook and Screenshots each show only their own",
              LibraryState.shows(.chat, in: .chats) && !LibraryState.shows(.note, in: .chats) && LibraryState.shows(.note, in: .notebook)
                && !LibraryState.shows(.screenshot, in: .notebook) && LibraryState.shows(.screenshot, in: .screenshots) && !LibraryState.shows(.chat, in: .screenshots))

        // The clear / undo / restore flow, on a throwaway library.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("margin-dashtest-\(UUID().uuidString)", isDirectory: true)
        let real = Library.shared.directory
        Library.shared.directory = dir
        defer { Library.shared.directory = real; try? fm.removeItem(at: dir) }
        let lib = Library.shared
        var chats: [ChatRecord] = []
        for t in ["One", "Two", "Three"] {
            let c = ChatRecord(title: t, sector: "Math", app: "x", quote: "", turns: [.init(question: "q", answer: "a \(t)")])
            lib.save(c)
            chats.append(lib.chat(c.id)!)
        }
        let note = Note(title: "N", sector: "Math", app: "x", quote: "", question: "Why?", body: "Because.")
        lib.add(note)
        let state = LibraryState()
        let ref = { (c: ChatRecord) in ItemRef(kind: .chat, id: c.id) }

        state.selection = ref(chats[0])
        state.clear(ref(chats[0]), next: ref(chats[1]))
        check("dashboard: clearing the selected row shows the next one", state.selection == ref(chats[1]) && lib.chat(chats[0].id) == nil && lib.binItem(chats[0].id) != nil)
        check("dashboard: clearing offers Undo for just that", state.toast?.text == "Chat moved to the Bin" && state.toast?.undo == [chats[0].id])
        state.clear(ref(chats[2]), next: nil)
        check("dashboard: clearing a row that isn't selected leaves the selection alone", state.selection == ref(chats[1]) && lib.binItem(chats[2].id) != nil)
        let toast = state.toast!
        state.undo(toast)
        check("dashboard: Undo puts it back and dismisses the message", lib.chat(chats[2].id) != nil && lib.binItem(chats[2].id) == nil && state.toast == nil)
        state.clear(ItemRef(kind: .note, id: note.id))
        check("dashboard: a note is cleared the same way", lib.notes.isEmpty && lib.binItem(note.id)?.kind == .note && state.toast?.text == "Note moved to the Bin")
        state.clear(ItemRef(kind: .chat, id: UUID()))
        check("dashboard: clearing something that isn't there does nothing", state.toast?.text == "Note moved to the Bin")

        state.restore(ItemRef(kind: .note, id: note.id))
        check("dashboard: Restore from the Bin puts it back", lib.notes.map(\.id) == [note.id] && lib.binItem(note.id) == nil && state.toast?.text == "Put back")
        state.deleteForever(ref(chats[0]), next: nil)
        check("dashboard: Delete forever empties its place in the Bin", lib.binItem(chats[0].id) == nil && lib.chat(chats[0].id) == nil)

        // Switching views.
        state.sector = "Math"
        state.kind = .chat
        state.selection = ref(chats[1])
        state.mode = .all
        check("dashboard: another view starts without the old sector or filter", state.sector == nil && state.kind == nil)
        check("dashboard: ...and a chat stays selected where chats are shown", state.selection == ref(chats[1]))
        state.mode = .notebook
        check("dashboard: ...but not in the Notebook, which has no chats", state.selection == nil)
        state.selectedScreenshot = UUID()
        check("dashboard: selectedChat / selectedNote / selectedScreenshot are views of the one selection", state.selectedChat == nil && state.selection?.kind == .screenshot)
        state.selectedChat = chats[1].id
        check("dashboard: ...and setting one replaces it", state.selection == ref(chats[1]) && state.selectedScreenshot == nil)

        // What the lists are made from.
        let shot = ScreenshotRecord(title: "Pic")
        lib.add(shot)
        lib.delete(chat: chats[1].id)
        let binned = FeedItem(binned: lib.binItem(chats[1].id)!, library: lib)
        check("dashboard: a Bin row knows how long it has left", binned.daysLeft == 30 && binned.kindName == "Chat" && binned.title == "Two")
        check("dashboard: a screenshot row carries its picture", FeedItem(shot: shot, library: lib).thumb == lib.imageURL(for: shot))
        check("dashboard: each kind has its own icon", !FeedItem(chat: chats[1]).symbol.isEmpty
              && FeedItem(note: note).symbol != FeedItem(chat: chats[1]).symbol && FeedItem(shot: shot, library: lib).symbol != FeedItem(note: note).symbol)
        check("dashboard: sector colors are steady (the same name, the same color)", sectorColor("Basket weaving") == sectorColor("Basket weaving"))
        // (Instrument: sectors are told apart by glyph, not colour, so Math vs Economics no longer differ here.)
    }
}
