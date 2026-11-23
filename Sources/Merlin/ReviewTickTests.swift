import AppKit
import Foundation

extension FeatureTests {
    /// Old review fields still load, the Assistant's abilities (shortcuts, colour, mode), and the done mark.
    static func reviewChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merlin-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let suite = "merlin.review.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(directory: dir)
        let assistant = LibraryAssistant(library: library, settings: Settings(defaults: defaults), sectors: nil)

        var plain = ChatRecord(title: "Bayes rule", sector: "Math", app: "Safari", quote: "about Bayes", turns: [.init(question: "Why?", answer: "Because.")])
        plain.updated = Date().addingTimeInterval(-3600)
        var missed = ChatRecord(title: "Torque", sector: "Physics", app: "Safari", quote: "about torque", turns: [.init(question: "Why?", answer: "Because.")])
        missed.quizzes = [QuizResult(title: "q", correct: 1, total: 2, date: Date().addingTimeInterval(-7200), missed: [.init(question: "a", answer: "b", why: "c")])]
        library.save(plain, touch: false); library.save(missed, touch: false)

        // The manual bookmark and "To review" are gone. Chats saved by older versions still load and keep the old fields when saved again.
        let marked = Date().addingTimeInterval(-600).timeIntervalSinceReferenceDate
        let oldJSON = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964AA","created":0,"updated":0,"title":"Bookmarked once","sector":"Math","app":"","quote":"","turns":[{"question":"Why?","answer":"Because."}],"reviewMarked":"#
            + "\(marked),\"reviewCleared\":\(marked)}"
        let old = try? JSONDecoder().decode(ChatRecord.self, from: Data(oldJSON.utf8))
        check("review: an old bookmarked chat still loads", old?.title == "Bookmarked once" && old?.reviewMarked != nil && old?.reviewCleared != nil)
        if let old { library.save(old, touch: false) }
        library.flush()
        let reread = Library(directory: dir).chat(old?.id ?? UUID())
        check("review: the old review fields survive a re-save (the file isn't stripped)", reread?.reviewMarked != nil && reread?.reviewCleared != nil)

        // The Assistant can't bookmark any more: the old actions are refused and change nothing; its quick commands offer the star.
        for type in ["review", "unreview"] {
            let plan = LibraryAssistant.Plan(say: "", actions: [.init(type: type, filter: .init(query: type == "review" ? "bayes" : "torque"))])
            let steps = assistant.run(plan, apply: true)
            check("assistant: “\(type)” is no longer an action", steps.first?.failed == true
                  && library.chat(plain.id) != nil && library.chat(missed.id) != nil)
        }
        check("assistant: its instructions don't offer a To review action", !LibraryAssistant.systemPrompt.contains("\"review\"")
              && !LibraryAssistant.systemPrompt.contains("unreview"))
        check("assistant: no quick command bookmarks; one stars", !AssistantCommands.all.contains { $0.symbol.hasPrefix("bookmark") || $0.prompt.contains("To review") }
              && AssistantCommands.all.contains { $0.symbol == "star" && $0.fill })

        // Shortcuts by words.
        func chord(_ s: String) -> Chord? { Chord.parse(s) }
        check("shortcuts: words and symbols read as chords",
              chord("option+cmd+j") == Chord(keyCode: 38, command: true, option: true)
              && chord("⌘⇧H") == Chord(keyCode: 4, command: true, shift: true)
              && chord("Control + Shift + L") == Chord(keyCode: 37, shift: true, control: true)
              && chord("tab+\\") == Chord(keyCode: 42, holdTab: true))
        check("shortcuts: nonsense isn't a chord", chord("nonsense") == nil && chord("cmd+") == nil && chord("") == nil && chord("cmd+banana") == nil)
        let store = KeybindStore.shared
        let before = store.current
        let set = LibraryAssistant.Plan(say: "", actions: [.init(type: "set_keybind", key: "history", value: "option+cmd+j")])
        let steps = assistant.run(set, apply: false)
        check("assistant shortcut: a preview changes nothing", store.current == before && steps.first?.failed == false)
        let applied = assistant.run(set, apply: true)
        check("assistant shortcut: sets it", store.current.chord(.history) == Chord(keyCode: 38, command: true, option: true))
        applied.reversed().forEach { $0.undo?() }
        check("assistant shortcut: undo restores it", store.current == before)
        let clash = assistant.run(.init(say: "", actions: [.init(type: "set_keybind", key: "engine", value: "cmd+shift+l")]), apply: true)
        check("assistant shortcut: a chord already in use is refused", clash.first?.failed == true && store.current == before)
        let plainKey = assistant.run(.init(say: "", actions: [.init(type: "set_keybind", key: "engine", value: "j")]), apply: true)
        check("assistant shortcut: a bare key is refused", plainKey.first?.failed == true && store.current == before)
        check("assistant shortcut: an unknown shortcut is refused",
              assistant.run(.init(say: "", actions: [.init(type: "set_keybind", key: "launch", value: "cmd+j")]), apply: true).first?.failed == true)

        // Colour and mode by words.
        let theme = ThemeStore.shared
        let (oldAccent, oldMode) = (theme.accent, theme.mode)
        _ = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "accentColor", value: "violet")]), apply: false)
        check("assistant colour: a preview changes nothing", theme.accent == oldAccent)
        let paint = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "accentColor", value: "Violet")]), apply: true)
        check("assistant colour: sets a named colour", theme.accent == AccentTheme(hue: 0.75))
        paint.reversed().forEach { $0.undo?() }
        check("assistant colour: undo restores it", theme.accent == oldAccent)
        _ = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "accentColor", value: "200")]), apply: true)
        check("assistant colour: a hue in degrees works", abs((theme.accent.hue ?? 0) - 200.0 / 360) < 0.001)
        check("assistant colour: nonsense is refused",
              assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "accentColor", value: "chartreuse-ish")]), apply: true).first?.failed == true
              && assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "accentColor", value: "999")]), apply: false).first?.failed == true)
        theme.setAccent(oldAccent)
        _ = assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "appearanceMode", value: "dark")]), apply: true)
        check("assistant mode: dark", theme.mode == .dark)
        theme.setMode(oldMode)
        check("assistant mode: a bad word is refused",
              assistant.run(.init(say: "", actions: [.init(type: "set_setting", key: "appearanceMode", value: "purple")]), apply: false).first?.failed == true)

        // The commands box.
        let titles = AssistantCommands.all.map(\.title)
        check("commands: every command is unique and has a prompt", Set(titles).count == titles.count && AssistantCommands.all.allSatisfy { !$0.prompt.isEmpty })
        check("commands: covers finding, starring, settings and shortcuts",
              ["Find chats…", "Star chats about…", "Change a shortcut…", "Dark mode", "Accent colour…", "About Merlin"].allSatisfy(titles.contains))

        // The done mark.
        let spark = SparkShape().path(in: CGRect(x: 0, y: 0, width: 20, height: 20)).boundingRect
        check("done: the mark is Merlin's spark, centred", spark.width > 12 && abs(spark.midX - 10) < 1 && abs(spark.midY - 10) < 1)
    }
}
