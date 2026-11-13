import AppKit
import Foundation

extension FeatureTests {
    /// Starred chats: they sort first, can't be deleted, survive "delete all" and a restart; select mode ticks only what can go.
    static func starChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("margin-startest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let library = Library(directory: dir)

        func chat(_ title: String, _ sector: String = "Math") -> ChatRecord {
            ChatRecord(title: title, sector: sector, app: "Safari", quote: "about \(title)", turns: [.init(question: "Why?", answer: "Because \(title).")])
        }
        let a = chat("Alpha"), b = chat("Beta"), c = chat("Gamma")
        [a, b, c].forEach { library.save($0) }
        check("star: a new chat isn't starred", library.chats.allSatisfy { !$0.starred })

        // Starring.
        check("star: starring a chat works", library.setStarred(a.id, true) && library.chat(a.id)?.starred == true)
        check("star: starring something that isn't there says no", !library.setStarred(UUID(), true))
        let beforeUpdated = library.chat(a.id)?.updated
        library.setStarred(a.id, true)
        check("star: starring doesn't count as new activity", library.chat(a.id)?.updated == beforeUpdated)

        // Sorting: the feed puts starred first and the groups open with "Starred".
        let items = library.chats.map(FeedItem.init(chat:))
        let ordered = Feed.starredFirst(items.reversed())
        check("star: starred rows lead the list", ordered.first?.ref.id == a.id && ordered.count == 3)
        check("star: the rest keep their order", ordered.dropFirst().map(\.ref.id) == items.reversed().filter { !$0.starred }.map(\.ref.id))
        let groups = Feed.groups(Feed.starredFirst(items))
        check("star: the first group is Starred", groups.first?.label == "Starred" && groups.first?.items.map(\.ref.id) == [a.id])
        check("star: no Starred group when nothing is starred", Feed.groups(items.map { var i = $0; i.starred = false; return i }).allSatisfy { $0.label != "Starred" })

        // Protection.
        check("star: a starred chat can't be deleted", !library.delete(chat: a.id) && library.chat(a.id) != nil && library.binned.isEmpty)
        check("star: an unstarred chat still can", library.delete(chat: b.id) && library.chat(b.id) == nil && library.binned.count == 1)
        _ = library.restore(b.id)
        let gone = library.deleteAllChats()
        check("star: delete-all leaves starred chats and reports only what moved", gone.sorted { $0.uuidString < $1.uuidString } == [b.id, c.id].sorted { $0.uuidString < $1.uuidString }
              && library.chats.map(\.id) == [a.id])
        check("star: ...and its file is still on disk", { library.flush(); return fm.fileExists(atPath: dir.appendingPathComponent("chats/\(a.id.uuidString).json").path) }())

        // Survives a restart (decoded from disk), and an old file with no `starred` key still opens.
        let reopened = Library(directory: dir)
        check("star: the star survives a restart", reopened.chat(a.id)?.starred == true)
        let oldJSON = """
        {"id":"\(UUID().uuidString)","title":"Old","sector":"Math","app":"","quote":"","turns":[{"question":"q","answer":"a"}]}
        """
        let old = try? JSONDecoder().decode(ChatRecord.self, from: Data(oldJSON.utf8))
        check("star: an old chat without the key opens unstarred", old?.starred == false)

        // Unstar → can delete again.
        reopened.setStarred(a.id, false)
        check("star: after unstarring it can be deleted", reopened.delete(chat: a.id) && reopened.chat(a.id) == nil)

        // Select mode (mass delete).
        let lib2 = Library(directory: fm.temporaryDirectory.appendingPathComponent("margin-startest2-\(UUID().uuidString)", isDirectory: true))
        defer { try? fm.removeItem(at: lib2.directory) }
        let recs = (1...5).map { chat("Chat \($0)") }
        recs.forEach { lib2.save($0) }
        lib2.setStarred(recs[0].id, true)
        let feed = Feed.starredFirst(lib2.chats.map(FeedItem.init(chat:)))
        let state = LibraryState()
        state.selecting = true
        state.toggleAll(in: feed)
        check("select: All ticks everything except starred chats", state.picked.count == 4 && !state.picked.contains(ItemRef(kind: .chat, id: recs[0].id)))
        state.toggle(feed[0]) // the starred one
        check("select: a starred chat can't be ticked", state.picked.count == 4)
        state.toggleAll(in: feed)
        check("select: All again unticks everything", state.picked.isEmpty)
        state.toggle(feed[1]); state.toggle(feed[2])
        check("select: clicking ticks and unticks one row", state.picked.count == 2)
        state.toggle(feed[2])
        check("select: ...unticking works", state.picked.count == 1)
        state.selecting = false
        check("select: leaving select mode clears the ticks", state.picked.isEmpty)
    }
}
