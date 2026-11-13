import AppKit
import AVFoundation
import PDFKit
import Speech
import SwiftUI

/// Unit checks for the library, notebook, quiz and (later) the other newer features. Run by `Margin --unittest`.
enum FeatureTests {
    static func run(_ check: (String, Bool) -> Void) {
        library(check)
        answers(check)
        quiz(check)
        calendar(check)
        voiceUnitChecks(check)
        documents(check)
        oneShotChecks(check)
        voiceRouting(check)
        savingChecks(check)
        uiFixChecks(check)
        binChecks(check)
        starChecks(check)
        mathChecks(check)
        assistantChecks(check)
        keybindChecks(check)
        themeChecks(check)
        reviewChecks(check)
        sectorChecks(check)
        librarySettings(check)
        reviewList(check)
        personalAndLearn(check)
        MCPServer.selfTest(check)
    }

    // MARK: - Context, Rules and Learn mode

    private static func personalAndLearn(_ check: (String, Bool) -> Void) {
        // A fixed name, so repeat runs can't pile up settings files. Cleared first in case a crash left anything in it.
        let suite = "com.kien.margin.tests.personal"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let realSource = Prompts.personalSource
        defer {
            Prompts.personalSource = realSource
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = Settings(defaults: defaults)
        Prompts.personalSource = settings
        func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

        // Empty boxes add nothing, on every kind of chat.
        check("personal: Context, Rules and Learn mode start empty and off",
              settings.personalContext.isEmpty && settings.personalRules.isEmpty && !settings.learnMode)
        let claudeBase = Prompts.system(webSearch: true, sectors: ["Math"], features: [])
        check("personal: empty boxes leave Claude's prompt untouched", Prompts.personalized(claudeBase) == claudeBase)
        check("personal: empty boxes leave the local prompt untouched", LocalSession(model: "qwen3:8b").startingSystemPrompt == Prompts.localSystem)
        settings.personalContext = "  \n "
        settings.personalRules = "\n\n"
        check("personal: boxes holding only spaces count as empty", Prompts.personalized(claudeBase) == claudeBase)

        // Filled boxes reach the prompt of every chat that talks to a model.
        settings.personalContext = "I study economics"
        settings.personalRules = "Straight forward answer"
        check("personal: the boxes are remembered", Settings(defaults: defaults).personalContext == "I study economics"
              && Settings(defaults: defaults).personalRules == "Straight forward answer")
        func reaches(_ prompt: String) -> Bool {
            occurrences("I study economics", in: prompt) == 1 && occurrences("Straight forward answer", in: prompt) == 1
        }
        check("personal: both reach a Claude chat, once", reaches(ClaudeSession(model: .sonnet, webSearch: true, features: []).startingSystemPrompt))
        check("personal: both reach a lean Claude chat, once", reaches(ClaudeSession(model: .sonnet, webSearch: false, features: []).startingSystemPrompt))
        check("personal: both reach a local chat through Ollama, once", reaches(LocalSession(model: "qwen3:8b").startingSystemPrompt))
        check("personal: both reach a quick-model chat, once", reaches(LocalSession(model: Settings.haikuID).startingSystemPrompt))
        check("personal: both reach a local video chat", reaches(LocalSession(model: "qwen3:8b", system: Prompts.localVideoSystem).startingSystemPrompt))
        let firstMessage = Prompts.first(app: "Safari", selection: "x", context: nil, question: "why?")
        check("personal: they stay out of the messages, so follow-ups don't resend them",
              !firstMessage.contains("I study economics") && !firstMessage.contains("Straight forward answer"))
        settings.personalRules = ""
        let contextOnly = Prompts.personalized(claudeBase)
        check("personal: one empty box adds nothing of its own", contextOnly.contains("I study economics") && !contextOnly.contains("The user's rules"))
        settings.personalContext = String(repeating: "x", count: Prompts.maxPersonal + 500)
        check("personal: a huge paste is cut to the limit",
              Prompts.personalized(claudeBase).count <= claudeBase.count + Prompts.maxPersonal + 200)

        // Hint levels.
        let hints = Prompts.hintLevels.map { Prompts.hint($0) }
        check("learn: each level asks for something different", Set(hints).count == 4 && Set(hints.map { $0.replacingOccurrences(of: #"Hint level \d of 4"#, with: "", options: .regularExpression) }).count == 4)
        check("learn: each prompt names its level", Prompts.hintLevels.allSatisfy { Prompts.hint($0).contains("Hint level \($0) of 4") })
        check("learn: levels below 4 hold back the answer, level 4 gives it",
              (1...3).allSatisfy { Prompts.hint($0).contains("Don't") && Prompts.hint($0).contains("give the") } && !Prompts.hint(4).contains("Don't") && Prompts.hint(4).contains("final answer"))
        let wrapped = Prompts.hintLevels.flatMap { [Prompts.hint($0), Prompts.hint($0, movingUp: true)] }
        check("learn: the instruction doesn't push a chat to Claude or switch on extras",
              wrapped.allSatisfy { !Router.needsClaude($0) && Prompts.features(question: $0, selection: "").isEmpty })
        check("learn: the instruction isn't mistaken for a calendar or video request",
              wrapped.allSatisfy { CalendarIntent.parse($0) == nil && VideoIntent.parse($0) == nil })

        // The popup, Learn mode off and on.
        func chat(text: String = "Why is 2 + 2 four?", learn: Bool) -> (AskModel, () -> [String]) {
            let selection = Selection(text: text, appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
            let model = AskModel(selection: selection, footnote: "")
            model.learnMode = learn
            let box = SentBox()
            model.onAsk = { box.prompts.append($0) }
            return (model, { box.prompts })
        }
        func finish(_ model: AskModel) {
            model.turns[model.turns.count - 1].answer = "An answer."
            model.turns[model.turns.count - 1].done = true
            model.isStreaming = false
        }
        let (off, offSent) = chat(learn: false)
        check("learn off: no picker", !off.hintPicking)
        off.draft = "why?"
        off.submit()
        check("learn off: a typed question goes straight out, unchanged", offSent() == ["why?"] && off.turns.first?.question == "why?")
        finish(off)
        check("learn off: Go deeper is there, the hint button isn't", off.canGoDeeper && !off.canHintUp)
        let (offEmpty, offEmptySent) = chat(learn: false)
        offEmpty.submit()
        check("learn off: pressing Return with nothing typed still explains simply", offEmptySent() == [Prompts.emptySubmit])

        let (on, onSent) = chat(learn: true)
        check("learn on: a highlight shows the picker and sends nothing", on.hintPicking && onSent().isEmpty && on.turns.isEmpty)
        on.pickHint(1)
        check("learn on: picking a level asks at that level", onSent() == [Prompts.hint(1)] && !on.hintPicking && on.hintLevel == 1)
        check("learn on: no moving up while it answers", !on.canHintUp)
        finish(on)
        check("learn on: an answer offers the next level, not Go deeper", on.canHintUp && !on.canGoDeeper)
        on.hintUp()
        check("learn on: moving up asks about the same problem at the next level", onSent().last == Prompts.hint(2, movingUp: true) && on.hintLevel == 2)
        finish(on); on.hintUp(); finish(on); on.hintUp(); finish(on)
        check("learn on: level 4 is the top, and Go deeper comes back", on.hintLevel == 4 && !on.canHintUp && on.canGoDeeper && onSent().count == 4)

        let (typed, typedSent) = chat(learn: true)
        typed.draft = "what about 3 + 3?"
        typed.submit()
        check("learn on: a typed question waits for a level", typedSent().isEmpty && typed.hintQuestion == "what about 3 + 3?" && typed.draft.isEmpty && typed.hintPicking)
        typed.pickHint(3)
        check("learn on: the typed question goes out with its level", typedSent().first == Prompts.hint(3, question: "what about 3 + 3?") && typedSent().first?.contains("what about 3 + 3?") == true && typed.hintQuestion == nil)

        let (blank, blankSent) = chat(text: "", learn: true)
        check("learn on: with nothing highlighted, no picker until there's a question", !blank.hintPicking)
        blank.draft = "explain derivatives"
        blank.submit()
        check("learn on: a typed question in a blank chat gets the picker", blank.hintPicking && blankSent().isEmpty)

        let (event, eventSent) = chat(learn: true)
        event.draft = "add dinner with Anna to my calendar tomorrow at seven"
        event.submit()
        check("learn on: a calendar request isn't held back for a hint", eventSent().count == 1 && event.hintQuestion == nil)

        let (skip, skipSent) = chat(learn: true)
        skip.draft = "just tell me"
        skip.submit()
        skip.skipHints()
        check("learn on: Skip hints sends a waiting question as it is", skipSent() == ["just tell me"] && !skip.hintPicking && skip.hintLevel == nil)

        // The toggle on the new-chat screen.
        let (toggled, toggledSent) = chat(learn: false)
        let memory = LearnMemory()
        toggled.onLearnChange = { memory.values.append($0); settings.learnMode = $0 }
        check("learn toggle: offered on a new chat", toggled.canToggleLearn)
        toggled.toggleLearn()
        check("learn toggle: on shows the picker and is remembered", toggled.hintPicking && memory.values == [true] && Settings(defaults: defaults).learnMode)
        toggled.toggleLearn()
        check("learn toggle: off hides the picker and is remembered", !toggled.hintPicking && memory.values == [true, false] && !Settings(defaults: defaults).learnMode)
        toggled.toggleLearn()
        toggled.draft = "my question"
        toggled.submit()
        toggled.toggleLearn()
        check("learn toggle: turning off puts a waiting question back in the field, unsent",
              toggled.draft == "my question" && toggled.hintQuestion == nil && toggledSent().isEmpty)
        toggled.toggleLearn()
        toggled.pickHint(2)
        let levelBefore = toggled.hintLevel
        let countBefore = memory.values.count
        check("learn toggle: gone once a chat has started", !toggled.canToggleLearn)
        toggled.toggleLearn()
        check("learn toggle: can't change a chat under way", toggled.learnMode && toggled.hintLevel == levelBefore && memory.values.count == countBefore)
        let (other, _) = chat(learn: true)
        let (second, _) = chat(learn: true)
        other.onLearnChange = { settings.learnMode = $0 }
        other.toggleLearn()
        check("learn toggle: another open chat keeps the mode it started in", second.learnMode && second.hintPicking)

        let (read, _) = chat(learn: true)
        read.doc = .ready(name: "Book", detail: "")
        check("learn on: a chat reading a whole document keeps its usual flow", !read.hintPicking)
    }

    private final class SentBox { var prompts: [String] = [] }
    private final class LearnMemory { var values: [Bool] = [] }

    // MARK: - To review

    private static func reviewList(_ check: (String, Bool) -> Void) {
        let now = Date()
        func miss(_ ago: Double) -> QuizResult {
            QuizResult(title: "q", correct: 1, total: 2, date: now.addingTimeInterval(-ago), missed: [.init(question: "q", answer: "a", why: "w")])
        }
        func clean(_ ago: Double) -> QuizResult { QuizResult(title: "q", correct: 2, total: 2, date: now.addingTimeInterval(-ago)) }
        func chat(_ title: String, _ quizzes: [QuizResult]) -> ChatRecord {
            var c = ChatRecord(title: title, sector: "Math", app: "Safari", quote: "", turns: [.init(question: "q", answer: "a")])
            c.quizzes = quizzes
            return c
        }
        let never = chat("never quizzed", [])
        let old = chat("old miss", [miss(3000)])
        let recent = chat("recent miss", [miss(100)])
        let fixed = chat("fixed on retake", [miss(500), clean(50)])
        let relapsed = chat("missed again", [clean(900), miss(200)])
        let perfect = chat("all right", [clean(10)])
        let list = Review.chats([never, old, recent, fixed, relapsed, perfect])
        check("review: only chats whose newest quiz missed something", Set(list.map(\.chat.title)) == ["old miss", "recent miss", "missed again"])
        check("review: newest miss first", list.map(\.chat.title) == ["recent miss", "missed again", "old miss"])
        check("review: a perfect retake takes it off the list", !list.contains { $0.chat.title == "fixed on retake" })
        check("review: the list's date is the miss, not the chat", abs(list[0].missed.timeIntervalSince(now.addingTimeInterval(-100))) < 1)
        check("review: order doesn't depend on how results were stored", chat("x", [miss(100), clean(500)]).reviewDate != nil
              && chat("x", [clean(500), miss(100)]).reviewDate != nil && chat("x", [clean(10), miss(100)]).reviewDate == nil)
        check("review: empty library is empty", Review.chats([]).isEmpty)
        let oldJSON = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","created":0,"updated":0,"title":"t","sector":"Math","app":"","quote":"","turns":[]}"#
        check("review: older chats without quiz data decode and stay off the list",
              (try? JSONDecoder().decode(ChatRecord.self, from: Data(oldJSON.utf8)))?.reviewDate == nil)
    }

    // MARK: - Meta tag, sectors, library

    private static func answers(_ check: (String, Bool) -> Void) {
        let raw = "Parabolas open up when a is positive.\n\n<meta title=\"Parabola direction\" sector=\"Maths\"/>"
        let meta = Answer.meta(in: raw)
        check("meta: title read", meta?.title == "Parabola direction")
        check("meta: sector read", meta?.sector == "Maths")
        check("meta: stripped from the answer", Answer.withoutMeta(raw) == "Parabolas open up when a is positive.")
        check("meta: never shown as text",
              Answer.pieces(raw) == [.text("Parabolas open up when a is positive.")])
        check("meta: half-written tag hidden while streaming",
              Answer.pieces("Short answer.\n\n<meta title=\"Par", hidePartial: true) == [.text("Short answer.\n\n")])
        check("meta: a lone < hidden while streaming", Answer.pieces("a <", hidePartial: true) == [.text("a ")])
        check("meta: absent is nil", Answer.meta(in: "no tag here") == nil)
        check("meta: long title is cut", (Answer.meta(in: "<meta title=\"\(String(repeating: "word ", count: 30))\" sector=\"x\"/>")?.title.count ?? 99) <= 61)
        check("meta: plain text for prompts ignores it", Answer.plainText(raw) == "Parabolas open up when a is positive.")

        check("sector: alias folds in", Sector.normalize("Maths") == "Math" && Sector.normalize("programming") == "Computer Science")
        check("sector: known name keeps its spelling", Sector.normalize("physics") == "Physics")
        check("sector: new sector is title-cased", Sector.normalize("art history of rome") == "Art History Of")
        check("sector: empty is Other", Sector.normalize("  ") == "Other")
        check("sector: guess math", Sector.guess(from: "How do I factor this quadratic equation and find its derivative?") == "Math")
        check("sector: guess economics", Sector.guess(from: "supply and demand shift raises equilibrium price, elasticity") == "Economics")
        check("sector: Russian text is Language", Sector.guess(from: "Я закрыл дверь на замок") == "Language")
        check("sector: unclear is nil", Sector.guess(from: "what does this mean") == nil)
        check("prompt: the meta rule lists the sectors", Prompts.metaRule(["Math", "Language"]).contains("Math, Language"))
        check("prompt: the system prompt carries the meta rule", Prompts.system(webSearch: false).contains("<meta title="))
    }

    private static func library(_ check: (String, Bool) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-library-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = Library(directory: dir)
        func chat(_ title: String, _ sector: String, _ q: String, _ a: String) -> ChatRecord {
            ChatRecord(title: title, sector: sector, app: "Safari", quote: "quote about \(title)", turns: [.init(question: q, answer: a)])
        }
        let math = chat("Parabola direction", "Math", "Why does it open up?", "Because **a** is positive.")
        let lang = chat("Russian lock vs castle", "Language", "Which замок?", "Stress decides it.")
        lib.save(math)
        lib.save(lang)
        lib.save(ChatRecord(title: "Empty", sector: "Other", app: "x", quote: "", turns: [.init(question: "q", answer: "")]))
        check("library: saves chats, not empty ones", lib.chats.count == 2)
        check("library: sectors in use", lib.usedSectors.map(\.name).sorted() == ["Language", "Math"])
        check("library: search by word in the answer", lib.search(chats: "positive").map(\.title) == ["Parabola direction"])
        check("library: search by title and sector filter", lib.search(chats: "russian", sector: "Language").count == 1
              && lib.search(chats: "russian", sector: "Math").isEmpty)
        check("library: search needs every word", lib.search(chats: "positive castle").isEmpty)
        lib.rename(math.id, to: "My parabola note")
        check("library: rename locks the title", lib.chat(math.id)?.title == "My parabola note" && lib.chat(math.id)?.titleLocked == true)
        lib.move(math.id, toSector: "physics")
        check("library: move to a sector", lib.chat(math.id)?.sector == "Physics")
        lib.move(math.id, toSector: "Optics Lab")
        check("library: a new sector appears in the list", lib.allSectors.contains("Optics Lab"))
        check("library: prompt lists used sectors first", Array(lib.sectorsForPrompt.prefix(3)).contains("Optics Lab"))

        let note = Note(title: "Parabola", sector: "Math", app: "Safari", quote: "q", question: "Why up?", body: "Because a > 0.", chatID: math.id)
        lib.add(note)
        check("library: notes are kept", lib.notes.count == 1 && lib.note(forChat: math.id, question: "Why up?") != nil)
        check("library: search notes", lib.search(notes: "because").count == 1 && lib.search(notes: "zzz").isEmpty)

        lib.flush()
        let reopened = Library(directory: dir)
        check("library: survives a restart", reopened.chats.count == 2 && reopened.notes.count == 1
              && reopened.chat(math.id)?.title == "My parabola note")
        reopened.delete(chat: lang.id)
        reopened.delete(note: note.id)
        reopened.flush()
        let again = Library(directory: dir)
        check("library: deletes stay deleted", again.chats.count == 1 && again.notes.isEmpty)
        check("library: ...in the Bin, not gone", again.binned.count == 2 && again.binItem(lang.id)?.kind == .chat && again.binItem(note.id)?.kind == .note)
        again.deleteAllChats()
        again.flush()
        check("library: clear all", Library(directory: dir).chats.isEmpty)

        // The Markdown notebook, in a temporary folder (never the real Documents).
        let saved = Notebook.folder
        Notebook.folder = dir.appendingPathComponent("notes-md")
        let md = Notebook.markdown(note)
        check("notebook: markdown has title, quote and body", md.contains("## Parabola") && md.contains("> q") && md.contains("Because a > 0."))
        check("notebook: export writes the sector file", Notebook.export(note)
              && FileManager.default.fileExists(atPath: Notebook.folder.appendingPathComponent("Math.md").path))
        _ = Notebook.export(note)
        let file = (try? String(contentsOf: Notebook.folder.appendingPathComponent("Math.md"), encoding: .utf8)) ?? ""
        check("notebook: a second note is appended", file.components(separatedBy: "## Parabola").count == 3 && file.hasPrefix("# Math"))
        Notebook.folder = saved
    }

    // MARK: - Calendar requests

    private static func calendar(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        cal.firstWeekday = 1
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let now = date(2026, 10, 13, 10, 0) // a Tuesday morning
        func parse(_ s: String) -> CalendarIntent.Draft? { CalendarIntent.parse(s, now: now, calendar: cal) }

        let user = parse(#"Hey add "doing this and this" to my calender at 8-9 on 8th of Jan 2027"#)
        check("calendar: the example, title", user?.title == "Doing this and this")
        check("calendar: the example, date and time", user?.start == date(2027, 1, 8, 8) && user?.end == date(2027, 1, 8, 9))
        check("calendar: the example, am/pm was a guess, date wasn't", user?.guessedMeridiem == true && user?.missingDate == false && user?.allDay == false)

        let dentist = parse("add dentist appointment to my calendar tomorrow at 3pm")
        check("calendar: tomorrow at 3pm", dentist?.title == "Dentist appointment" && dentist?.start == date(2026, 10, 14, 15)
              && dentist?.end == date(2026, 10, 14, 16) && dentist?.guessedMeridiem == false)
        let meeting = parse("schedule a meeting with Anna next Tuesday 2-3pm")
        check("calendar: 'next Tuesday' on a Tuesday is a week away", meeting?.start == date(2026, 10, 20, 14) && meeting?.end == date(2026, 10, 20, 15))
        check("calendar: no 'calendar' word needed after 'schedule'", meeting?.title == "Meeting with Anna")
        let study = parse("add study session to calendar Friday 6pm for 2 hours")
        check("calendar: weekday and duration", study?.start == date(2026, 10, 16, 18) && study?.end == date(2026, 10, 16, 20) && study?.title == "Study session")
        check("calendar: next Friday is next week's", parse("put lunch on my calendar next Friday at noon")?.start == date(2026, 10, 23, 12))
        let march = parse(#"put "Lunch with Sam" on my calendar on 3/15"#)
        check("calendar: M/D with no year is the next one, all day", march?.start == date(2027, 3, 15) && march?.allDay == true && march?.missingTime == true)
        let party = parse("add birthday party to my calendar on January 8")
        check("calendar: month and day, no year", party?.start == date(2027, 1, 8) && party?.allDay == true && party?.title == "Birthday party")
        let gym = parse("add gym to my calendar at 7")
        check("calendar: no date, time passed or not: tomorrow 7 AM guess", gym?.start == date(2026, 10, 14, 7) && gym?.guessedMeridiem == true && gym?.missingDate == true)
        check("calendar: an evening time today stays today", parse("add dinner to my calendar at 7pm")?.start == date(2026, 10, 13, 19))
        let block = parse("block 9 to 11 tomorrow for studying")
        check("calendar: 'block' with a range", block?.start == date(2026, 10, 14, 9) && block?.end == date(2026, 10, 14, 11) && block?.title == "Studying")
        let exam = parse(#"add "Exam" to my google calendar on 2027-02-03 at 14:00"#)
        check("calendar: ISO date and 24-hour time", exam?.start == date(2027, 2, 3, 14) && exam?.end == date(2027, 2, 3, 15) && exam?.guessedMeridiem == false)
        check("calendar: 11-1pm starts in the morning", parse("add class to my calendar tomorrow 11-1pm")?.start == date(2026, 10, 14, 11)
              && parse("add class to my calendar tomorrow 11-1pm")?.end == date(2026, 10, 14, 13))
        check("calendar: 8am to 9", parse("add run to my calendar tomorrow from 8am to 9")?.end == date(2026, 10, 14, 9))
        check("calendar: past midnight runs into the next day", parse("add party to my calendar tomorrow 9pm-1")?.end == date(2026, 10, 15, 1))
        check("calendar: the day after tomorrow", parse("add haircut to my calendar the day after tomorrow at 4pm")?.start == date(2026, 10, 15, 16))
        check("calendar: in two weeks", parse("add checkup to my calendar in two weeks at 9am")?.start == date(2026, 10, 27, 9))
        check("calendar: 'tonight' means this evening", parse("add movie to my calendar tonight at 8")?.start == date(2026, 10, 13, 20))
        let spoken = parse("add doing this and this to my calendar at 8 to 9 on the 8th of January 2027.")
        check("calendar: as the recognizer writes it (numerals, full stop), the title is clean",
              spoken?.title == "Doing this and this" && spoken?.start == date(2027, 1, 8, 8))
        let none = parse("add call mom to my calendar")
        check("calendar: no date or time at all is flagged, not refused", none?.missingDate == true && none?.missingTime == true && none?.title == "Call mom")
        check("calendar: questions aren't requests", parse("What's on my calendar tomorrow?") == nil
              && parse("how do I schedule tasks in cron") == nil && parse("explain the Gregorian calendar") == nil
              && parse("what does add to cart mean") == nil)
        check("calendar: speech slips ('calender') still count", CalendarIntent.looksLikeRequest("add lunch to my calender tomorrow at 1", now: now))
        let url = CalendarStore.googleURL(user!, calendar: cal)
        check("calendar: Google link has the title and local times", url.absoluteString.contains("text=Doing%20this%20and%20this")
              && url.absoluteString.contains("dates=20270108T080000/20270108T090000"))
        check("calendar: all-day Google link ends the next day",
              CalendarStore.googleURL(party!, calendar: cal).absoluteString.contains("dates=20270108/20270109"))
    }

    // MARK: - Quiz

    private static func quiz(_ check: (String, Bool) -> Void) {
        let json = """
        {"title":"Parabolas","questions":[
         {"q":"Which way does y = 2x² open?","options":["Up","Down","Left","Right"],"answer":0,"why":"a is positive."},
         {"q":"Vertex of (x-1)²+3?","options":["(1,3)","(−1,3)","(1,−3)","(3,1)"],"answer":"(1,3)","why":"h=1, k=3."},
         {"q":"Pick","options":["a","b","c","d"],"answer":"C"},
         {"q":"Why does a flip it?","answer":"A negative a reflects it over the x-axis.","why":"Sign of a."},
         {"q":"No answer given"}
        ]}
        """
        let spec = QuizSpec.parse(json)
        check("quiz: parses questions, drops the broken one", spec?.questions.count == 4)
        check("quiz: numeric answer", spec?.questions[0].correct == 0 && spec?.questions[0].isChoice == true)
        check("quiz: answer given as the option's text", spec?.questions[1].correct == 0)
        check("quiz: answer given as a letter", spec?.questions[2].correct == 2 && spec?.questions[2].answer == "c")
        check("quiz: short answer has no options", spec?.questions[3].isChoice == false && spec?.questions[3].answer.hasPrefix("A negative") == true)
        check("quiz: garbage is nil", QuizSpec.parse("not json") == nil && QuizSpec.parse(#"{"questions":[]}"#) == nil)
        check("quiz: boolean answers are ignored", QuizSpec.parse(#"{"questions":[{"q":"x","options":["a","b"],"answer":true}]}"#) == nil)

        let answer = "Here you go.\n<quiz>\(json)</quiz>"
        let pieces = Answer.pieces(answer)
        check("quiz: becomes a quiz piece between text", pieces.count == 2 && {
            if case .quiz = pieces[1] { return true } else { return false }
        }())
        check("quiz: unfinished shows 'writing a quiz'", Answer.pieces("Ok.\n<quiz>{\"title\":\"x", hidePartial: true).last == .writingQuiz)
        check("quiz: plain text note", Answer.plainText(answer).contains("[a quiz was shown here]"))
        check("quiz: asked as a lean Claude call", Router.plan(.init(prompt: Prompts.quiz, selection: "text", localMode: true)).lean
              && Router.plan(.init(prompt: Prompts.quiz, selection: "text", localMode: true)).engine == .claude)
        check("quiz: a local chat hands it to Claude", Router.needsEscalation(Prompts.quiz, from: .init(engine: .local, lean: false, why: "")))
        check("quiz: a lean chat keeps it", !Router.needsEscalation(Prompts.quiz, from: .init(engine: .claude, lean: true, why: "")))
        tokenChecks(check)
        namingChecks(check)
        videoIntentChecks(check)
    }

    /// "Summarize this video", typed or spoken, goes to the video summarizer and nothing else does.
    static func videoIntentChecks(_ check: (String, Bool) -> Void) {
        let yes: [String] = ["summarize this video", "Summarize the video", "can you summarize this youtube video for me",
                             "give me a summary of this video", "tl;dr of this video", "recap the video", "what's this video about",
                             "what is this youtube video about", "summarise the lecture", "summarize this tutorial",
                             "key points of this video", "sum up this video please", "summarize the youtube tab"]
        for t in yes { check("video: “\(t)” is a video request", VideoIntent.parse(t) == .youtube(id: nil)) }
        check("video: a pasted link with a request names the video",
              VideoIntent.parse("summarize https://www.youtube.com/watch?v=arj7oStGLkU") == .youtube(id: "arj7oStGLkU"))
        check("video: a link on its own is a request too", VideoIntent.parse("https://youtu.be/arj7oStGLkU") == .youtube(id: "arj7oStGLkU"))
        check("video: a link with an unrelated question isn't", VideoIntent.parse("is https://youtu.be/arj7oStGLkU safe for kids?") == nil)
        check("video: “listen along” listens", VideoIntent.parse("listen along") == .listenAlong)
        check("video: summarize what's playing listens", VideoIntent.parse("summarize what's playing") == .listenAlong
              && VideoIntent.parse("summarize this podcast") == .listenAlong && VideoIntent.parse("recap this meeting") == .listenAlong)
        let no: [String] = ["summarize this paragraph", "summarize chapter 4 of my econ textbook", "what does this word mean",
                            "summarize this page", "tidy my desktop", "explain this", "why does ice float",
                            "I watched a video yesterday and liked it", "what's the capital of France", "summarize"]
        for t in no { check("video: “\(t)” isn't", VideoIntent.parse(t) == nil) }
        check("video: voice sends it to the video summarizer", CommandCenter.route("summarize this video") == .video(.youtube(id: nil)))
        check("video: …wake words and all", { if case .video = CommandCenter.route("Hey Margin summarize this video") { return true } else { return false } }()
              || CommandCenter.route(CommandCenter.cleaned("Hey Margin summarize this video")) == .video(.youtube(id: nil)))
        check("video: a textbook summary is a question", CommandCenter.route("summarize chapter 4 of my econ textbook") == .ask)
        check("video: a plain question is still a question", CommandCenter.route("why does ice float") == .ask)
        check("video: the explanations are plain words", VideoIntent.explain(.noBrowser).contains("listen along")
              && VideoIntent.explain(.notAVideo).contains("front tab") && VideoIntent.explain(.needsPermission("Safari")).contains("Automation"))
    }

    /// Closing a chat names it, and what you named or filed yourself is never touched.
    static func namingChecks(_ check: (String, Bool) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        func chat(_ title: String, turns: Int = 3) -> ChatRecord {
            ChatRecord(title: title, sector: "Other", app: "Safari", quote: "The quadratic formula gives both roots.",
                       turns: (0..<turns).map { .init(question: "Question \($0)", answer: "Answer \($0) about parabolas.") })
        }
        var a = chat("Chat from Safari")
        library.save(a)
        check("naming: Claude's name and sector are applied to an unlocked chat",
              library.applyAutoName(a.id, title: "Solving quadratic equations", sector: "math")
              && library.chat(a.id)?.title == "Solving quadratic equations" && library.chat(a.id)?.sector == "Math")
        let before = library.chat(a.id)?.updated
        _ = library.applyAutoName(a.id, title: "Parabola roots", sector: nil)
        check("naming: renaming isn't new activity (it keeps its place in the list)", library.chat(a.id)?.updated == before)

        library.rename(a.id, to: "My own title")
        check("naming: a name you typed locks the title", library.chat(a.id)?.titleLocked == true)
        _ = library.applyAutoName(a.id, title: "Something Claude likes", sector: "Physics")
        check("naming: Claude doesn't rename a chat you named", library.chat(a.id)?.title == "My own title")
        check("naming: …but still files it (you didn't pick a sector)", library.chat(a.id)?.sector == "Physics")
        library.move(a.id, toSector: "Economics")
        _ = library.applyAutoName(a.id, title: "x", sector: "Math")
        check("naming: a sector you chose locks too", library.chat(a.id)?.sector == "Economics" && library.chat(a.id)?.sectorLocked == true)
        check("naming: nothing left for Claude to do on a fully-named chat", !ChatNaming.shouldRename(library.chat(a.id), hadClaudeTitle: true))
        library.unlockTitle(a.id)
        _ = library.applyAutoName(a.id, title: "Back to Claude's name", sector: nil)
        check("naming: unlocking lets Margin name it again", library.chat(a.id)?.title == "Back to Claude's name")

        a = chat("One question", turns: 1)
        check("naming: a one-question chat that Claude already titled isn't renamed again", !ChatNaming.shouldRename(a, hadClaudeTitle: true))
        check("naming: …unless it never got a title", ChatNaming.shouldRename(a, hadClaudeTitle: false))
        check("naming: a longer chat is renamed", ChatNaming.shouldRename(chat("Long", turns: 3), hadClaudeTitle: true))
        check("naming: an unsaved chat isn't", !ChatNaming.shouldRename(nil, hadClaudeTitle: false))

        check("naming: titles lose quotes and full stops", ChatNaming.cleanTitle("  “Russian verb stress.”  ") == "Russian verb stress")
        check("naming: empty or one-letter titles are rejected", ChatNaming.cleanTitle("  ") == nil && ChatNaming.cleanTitle("x") == nil && ChatNaming.cleanTitle(nil) == nil)
        let long = ChatNaming.cleanTitle(String(repeating: "word ", count: 30))
        check("naming: long titles are cut at a word (\(long?.count ?? 0) characters)", (long?.count ?? 99) <= 60 && long?.hasSuffix("word") == true)
        check("naming: Claude's JSON is read, even in a code fence",
              ChatNaming.parse("```json\n{\"title\": \"Opportunity cost basics\", \"sector\": \"Economics\"}\n```")?.title == "Opportunity cost basics")
        check("naming: junk isn't", ChatNaming.parse("I think this chat is about math.") == nil)
        let digest = ChatNaming.digest(chat("Big", turns: 8))
        check("naming: what Claude reads is small (\(digest.count) characters)", digest.count <= 1800 && digest.contains("Question 0"))

        // Chats saved before sectors could be locked still open.
        let old = """
        {"id":"\(UUID().uuidString)","created":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z","title":"Old chat","sector":"Math",
         "titleLocked":true,"app":"Safari","quote":"","turns":[{"question":"q","answer":"a"}]}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let decoded = try? d.decode(ChatRecord.self, from: Data(old.utf8))
        check("naming: a chat saved by an older Margin still opens", decoded?.title == "Old chat" && decoded?.titleLocked == true && decoded?.sectorLocked == false)

        check("hotkey: ⌘⇧L opens the history", Hotkeys.action(keyCode: 37, flags: [.maskCommand, .maskShift], tabHeld: false) == .history
              && Hotkeys.action(keyCode: 37, flags: .maskCommand, tabHeld: false) == nil
              && Hotkeys.action(keyCode: 37, flags: [], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 37, flags: [.maskCommand, .maskShift, .maskAlternate], tabHeld: false) == nil)
    }

    /// Margin --tokenbench: what the slimmer prompts save, measured on real Haiku calls (3 small ones).
    static func tokenBench() -> Never {
        let question = "What does \"adjourned\" mean here?\n\nThe committee adjourned until further notice."
        let configs: [(String, String)] = [
            ("before: every rule in every chat", Prompts.system(webSearch: false, features: .all)),
            ("now: plain question (no voice/graph rules)", Prompts.system(webSearch: false, features: [])),
            ("now: with graph rules (Visualize)", Prompts.system(webSearch: false, features: .graphs)),
        ]
        DispatchQueue.global().async {
            var base = 0
            for (i, (name, system)) in configs.enumerated() {
                let r = ClaudeOneShot.runSync(question, system: system, model: .haiku)
                switch r {
                case .success(let reply):
                    let input = reply.usage.inputTokens + reply.usage.cacheCreationTokens + reply.usage.cacheReadTokens
                    if i == 0 { base = input }
                    let delta = i == 0 || base == 0 ? "" : "  (\(base - input) fewer, \((base - input) * 100 / base)% less)"
                    print("\(name): \(system.count) characters of rules, \(input) input tokens\(delta)")
                case .failure(let f):
                    print("\(name): failed \(f.localizedDescription)")
                }
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Tokens: instructions are only sent when a question can use them, and Smart mode keeps the screenshot out unless it's needed.
    static func tokenChecks(_ check: (String, Bool) -> Void) {
        let plain = Prompts.features(question: "What does this mean?", selection: "The committee adjourned until further notice.")
        check("tokens: a plain question needs neither voice nor graph rules", plain.isEmpty)
        check("tokens: Pronounce brings the voice rule", Prompts.features(question: Prompts.pronounce, selection: "kitten").contains(.voice))
        check("tokens: Visualize brings the graph rule", Prompts.features(question: Prompts.visualize, selection: "y = x^2").contains(.graphs))
        check("tokens: Russian text brings the voice rule", Prompts.features(question: "Что это значит?", selection: "привет").contains(.voice))
        check("tokens: 'plot' brings the graph rule", Prompts.features(question: "plot this for me", selection: "x").contains(.graphs))
        let lean = Prompts.system(webSearch: false, features: [])
        let full = Prompts.system(webSearch: false, features: .all)
        check("tokens: the slim system prompt is clearly shorter (\(lean.count) vs \(full.count) characters)", lean.count < full.count * 6 / 10)
        check("tokens: the slim prompt has no graph or say instructions", !lean.contains("<graph>") && !lean.contains("<say>"))
        check("tokens: the full prompt has both", full.contains("<graph>") && full.contains("<say>"))
        check("tokens: every prompt still asks for the title/sector line", lean.contains("<meta"))
        let extra = Prompts.extraInstructions(for: Prompts.visualize, have: [])
        check("tokens: a later graph question carries the graph rule with it", extra?.text.contains("<graph>") == true && extra?.added == .graphs)
        check("tokens: nothing extra when the chat already has it", Prompts.extraInstructions(for: Prompts.visualize, have: .all) == nil)
        check("tokens: nothing extra for a plain follow-up", Prompts.extraInstructions(for: "why?", have: []) == nil)
        let smart = Router.Input(prompt: "Why does this happen?", selection: "Demand curves slope down.", smart: true)
        check("smart: a highlighted question needs no screenshot or web", Router.plan(smart).lean && Router.plan(smart).engine == .claude)
        var off = smart; off.smart = false
        check("smart: off keeps the old full call", !Router.plan(off).lean)
        var onScreen = smart; onScreen.prompt = "What is this chart on my screen showing?"
        check("smart: asking about the screen keeps the screenshot", !Router.plan(onScreen).lean)
        var web = smart; web.prompt = "What's the latest version?"
        check("smart: asking for current facts keeps web search", !Router.plan(web).lean)
        var blank = smart; blank.selection = ""; blank.isBlank = true
        check("smart: nothing highlighted still gets the screenshot", !Router.plan(blank).lean)
        check("smart: a lean chat moves to a full one for a screen question", Router.needsEscalation("what's on my screen?", from: Router.plan(smart)))
    }
}

// MARK: - Live checks and pictures

extension FeatureTests {
    private static var liveSession: ClaudeSession?

    /// Margin --libtest: a real Claude round trip. The first answer must carry a title and sector (no extra call),
    /// and "Quiz me" must come back as a quiz Margin can parse and grade.
    static func liveLibraryTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let session = ClaudeSession(model: Settings.shared.model, webSearch: false)
        liveSession = session
        var answer = ""
        var turn = 0
        var usage = ClaudeSession.Usage()
        session.onUsage = { usage = $0 }
        session.onEvent = { event in
            switch event {
            case .delta(let t): answer += t
            case .activity: answer = ""
            case .error(let m):
                print("LIBTEST FAIL: \(m)")
                exit(1)
            case .unavailable: break
            case .turnDone:
                if turn == 0 {
                    print("--- first answer (\(usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens) in, \(usage.outputTokens) out)\n\(answer)")
                    let meta = Answer.meta(in: answer)
                    check("the first answer carries a title", !(meta?.title.isEmpty ?? true))
                    check("…and a sector that is Math (got \(meta.map { Sector.normalize($0.sector, known: Library.shared.allSectors) } ?? "none"))",
                          meta.map { Sector.normalize($0.sector, known: Library.shared.allSectors) } == "Math")
                    check("…and nothing of it shows in the chat", !Answer.pieces(answer).contains {
                        if case .text(let t) = $0 { return t.contains("<meta") } else { return false }
                    })
                    turn = 1
                    answer = ""
                    session.send(Prompts.quiz)
                } else {
                    print("--- quiz (\(usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens) in, \(usage.outputTokens) out)\n\(answer)")
                    let pieces = Answer.pieces(answer)
                    let json = pieces.compactMap { p -> String? in if case .quiz(let j) = p { return j } else { return nil } }.first
                    let spec = json.flatMap(QuizSpec.parse)
                    check("the quiz parses", spec != nil)
                    check("…with 4 questions", spec?.questions.count == 4)
                    check("…3 or more are multiple choice", (spec?.questions.filter(\.isChoice).count ?? 0) >= 3)
                    check("…and no text outside the quiz", !pieces.contains { if case .text = $0 { return true } else { return false } })
                    session.stop()
                    print(failures == 0 ? "LIBTEST PASS" : "LIBTEST FAIL (\(failures))")
                    exit(failures == 0 ? 0 : 1)
                }
            }
        }
        do { try session.start() } catch { print("LIBTEST FAIL: \(error.localizedDescription)"); exit(1) }
        session.send(Prompts.first(app: "Safari",
                                   selection: "y = a(x − h)² + k: the vertex is at (h, k), and a controls how wide it is and which way it opens.",
                                   context: nil, question: "Explain this more simply."))
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { print("LIBTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }

    /// Margin --libdemo <dir>: pictures of the quiz in four states and the History, Screenshots & Notebook window, filled with
    /// sample chats in a temporary library (nothing of yours is touched or shown).
    @MainActor
    static func libraryDemo(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let quizJSON = """
        {"title":"Parabolas","questions":[
         {"q":"Which way does y = 2x² open?","options":["Up","Down","Left","Right"],"answer":0,"why":"a = 2 is positive, so it opens up."},
         {"q":"What is the vertex of y = (x − 1)² + 3?","options":["(1, 3)","(−1, 3)","(1, −3)","(3, 1)"],"answer":0,"why":"Vertex form shows (h, k) directly."},
         {"q":"Why does a negative a flip the parabola?","answer":"It reflects it across the x-axis, so it opens downward.","why":"The sign of a sets the direction."}]}
        """
        func render(_ name: String, _ view: some View, width: CGFloat = 340, height: CGFloat? = nil) {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height).padding(16)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            guard let image = renderer.cgImage else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            print("  saved \(name)")
        }
        render("quiz-1-question.png", QuizView(source: quizJSON))
        render("quiz-2-picked-wrong.png", QuizView(source: quizJSON, index: 0, picked: 1, marks: [0: false]))
        render("quiz-3-short-answer.png", QuizView(source: quizJSON, index: 2, revealed: true))
        render("quiz-4-score.png", QuizView(source: quizJSON, index: 3, marks: [0: false, 1: true, 2: false]))

        // A temporary library, so the window shows sample chats and never yours.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-libdemo-\(UUID().uuidString)")
        let real = Library.shared.directory
        Library.shared.directory = tmp
        defer { Library.shared.directory = real; try? FileManager.default.removeItem(at: tmp) }
        let samples: [(String, String, String, String, String)] = [
            ("Parabola direction and width", "Math", "Why does a negative a flip it?", "Because **a** sets the direction: negative values reflect it over the x-axis.", "y = a(x − h)² + k"),
            ("Supply shift effects", "Economics", "What happens when supply shifts right?", "The equilibrium price falls and the quantity rises.", "supply shifts right"),
            ("Stress in замок", "Language", "How do I pronounce this?", "замо́к (lock) is stressed on the second syllable; за́мок (castle) on the first.", "замок"),
            ("Newton's third law", "Physics", "Simpler?", "Every force has an equal and opposite partner force.", "action and reaction"),
            ("Closures capture by reference", "Computer Science", "Example?", "The closure sees later changes to the variable.", "closures capture variables"),
            ("Opportunity cost", "Economics", "Define terms", "The value of the next best thing you give up.", "opportunity cost"),
        ]
        for (i, s) in samples.enumerated() {
            var c = ChatRecord(title: s.0, sector: s.1, app: i % 2 == 0 ? "Safari" : "Preview", quote: s.4,
                               turns: [.init(question: s.2, answer: s.3)])
            c.updated = Date().addingTimeInterval(-Double(i) * 5400)
            if i == 0 { c.quizzes = [QuizResult(title: "Parabolas", correct: 2, total: 3)] }
            Library.shared.save(c)
        }
        Library.shared.add(Note(title: "Parabola direction", sector: "Math", app: "Safari", quote: "y = a(x − h)² + k",
                                question: "Why does a negative a flip it?", body: "Negative a reflects it over the x-axis."))
        Library.shared.add(Note(kind: .missed, title: "Parabolas", sector: "Math", app: "Safari", quote: "",
                                question: "Which way does y = 2x² open?", body: "Up, because a = 2 is positive."))

        // A few screenshots, as the inbox would have kept them.
        let shots: [(title: String, sector: String, app: String, window: String, words: String, source: ScreenshotRecord.Source)] = [
            ("BIDV transaction history", "Business", "Safari", "BIDV SmartBanking", "Transaction History October", .system),
            ("AL1 ESL 03 cover work", "Language", "Microsoft Teams", "AL1 ESL 03 | Files", "Cover Work Week Six", .system),
            ("Parabola homework, question 4", "Math", "Preview", "Algebra worksheet.pdf", "Find the vertex of y = x squared", .snip),
            ("Swift error: cannot find type", "Computer Science", "Xcode", "Connected.swift", "error: cannot find type in scope", .system),
        ]
        for (i, s) in shots.enumerated() {
            var r = ScreenshotRecord(created: Date().addingTimeInterval(-Double(i) * 7200 - 600), title: s.title)
            r.sector = s.sector
            r.app = s.app
            r.windowTitle = s.window
            r.source = s.source
            r.text = s.words
            if let jpeg = Snipper.downscaledJPEG(wordsPNG(s.words, width: 1000, height: 560)), let rep = NSBitmapImageRep(data: jpeg) {
                r.width = rep.pixelsWide
                r.height = rep.pixelsHigh
                _ = Library.shared.writeScreenshotImage(jpeg, for: r)
            }
            Library.shared.add(r)
        }

        // Things you deleted, so the Bin has something in it: a chat, a note and a screenshot.
        var old = ChatRecord(title: "Draft of the ESL cover plan", sector: "Language", app: "Microsoft Teams", quote: "Cover work, week six",
                             turns: [.init(question: "Summarize this plan", answer: "Three activities: warm-up, reading, discussion.")])
        old.updated = Date().addingTimeInterval(-3 * 86_400)
        Library.shared.save(old, touch: false)
        Library.shared.delete(chat: old.id)
        let oldNote = Note(title: "Elasticity", sector: "Economics", app: "Safari", quote: "price elasticity", question: "What is elasticity?",
                           body: "How much the quantity demanded moves when the price moves.")
        Library.shared.add(oldNote)
        Library.shared.delete(note: oldNote.id)
        if let first = Library.shared.screenshots.last { Library.shared.delete(screenshot: first.id) }

        // The real window as ⌘⇧L shows it (a floating panel, sample library), photographed off the screen, in each of its views.
        let live = LibraryWindow.shared
        let state = live.debugState
        live.show(mode: .chats, takeKeyboard: false) // never takes your typing
        live.debugClickThrough(true) // ...or your clicks
        if let w = live.debugWindow, let vf = NSScreen.main?.visibleFrame { // bottom-right, out of the way
            w.setFrameOrigin(NSPoint(x: max(vf.minX, vf.maxX - w.frame.width - 20), y: vf.minY + 20))
        }
        func snap(_ name: String) {
            guard let id = live.debugWindow?.windowNumber else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-l", String(id), "-o", "-x", out.appendingPathComponent(name).path]
            try? p.run()
            p.waitUntilExit()
            print("  saved \(name)")
        }
        let steps: [(String, () -> Void)] = [
            ("dashboard-chats.png", { state.selectedChat = Library.shared.chats.first?.id }),
            ("dashboard-notebook.png", { state.mode = .notebook; state.selectedNote = Library.shared.notes.first?.id }),
            ("dashboard-screenshots.png", { state.mode = .screenshots; state.selectedScreenshot = Library.shared.screenshots.first?.id }),
            ("dashboard-all.png", { state.mode = .all; state.selection = nil }),
            ("dashboard-bin.png", { state.mode = .bin; state.selection = Library.shared.binned.first.map { ItemRef(kind: $0.kind, id: $0.id) } }),
            ("dashboard-cleared.png", {
                state.mode = .notebook
                if state.toast == nil, let n = Library.shared.notes.first { state.clear(ItemRef(kind: .note, id: n.id)) }
            }),
        ]
        func run(_ i: Int) {
            guard i < steps.count else {
                live.toggle()
                print("LIBDEMO DONE")
                exit(0)
            }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                steps[i].1() // again, in case a click on the demo window moved it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    snap(steps[i].0)
                    run(i + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { run(0) }
        app.run()
        exit(0)
    }
}



extension FeatureTests {
    /// Margin --calendardemo <dir>: asks a chat (in a click-through test window) to add an event, and saves a picture of
    /// the card. Nothing is added to any calendar and Margin doesn't ask for calendar access.
    @MainActor
    static func calendarDemo(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("calendar access: \(CalendarStore.status.rawValue) (0 = not asked yet)")
        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = TestSpot.mouse(on: screen)
        dock.chatShortcut { Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: point) }
        guard let agent = dock.debugAgents.last else { print("CALENDARDEMO FAIL"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            agent.debugAsk(#"Hey add "doing this and this" to my calender at 8-9 on 8th of Jan 2027"#)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if let image = agent.debugSnapshot() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: out.appendingPathComponent("calendar-card.png"))
                    print("  saved calendar-card.png")
                }
                print("phase: \(agent.phase), title: \(agent.title)")
                agent.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("CALENDARDEMO DONE"); exit(0) }
            }
        }
        app.run()
        exit(0)
    }
}

extension FeatureTests {
    /// ⌘⇧V talks to a chat (on key-down, until key-up).
    static func talkChordChecks(_ check: (String, Bool) -> Void) {
        let keys = Hotkeys()
        var log: [String] = []
        keys.onTalkStart = { log.append("talk") }
        keys.onTalkEnd = { log.append("end") }
        func key(_ code: CGKeyCode, down: Bool, _ flags: CGEventFlags = [.maskCommand, .maskShift]) -> Bool {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
            e.flags = flags
            let swallowed = keys.handle(down ? .keyDown : .keyUp, e) == nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            return swallowed
        }
        let v: CGKeyCode = 9, a: CGKeyCode = 0
        log = []
        let s1 = [key(v, down: true), key(v, down: false)]
        check("chord: ⌘⇧V alone talks to a chat", log == ["talk", "end"] && s1.allSatisfy { $0 })
        log = []
        check("chord: a plain A types normally", !key(a, down: true, []) && !key(a, down: false, []) && log.isEmpty)
        check("chord: ⌘⇧A is left to the app you're in", !key(a, down: true) && !key(a, down: false) && log.isEmpty)
        log = []
        _ = key(v, down: true) // ⌘⇧V pressed, its release is lost
        _ = key(v, down: true) // pressed again
        check("chord: after a lost ⌘⇧V release, pressing it again starts a new talk (\(log))", log == ["talk", "end", "talk"])
        _ = key(v, down: false)
    }

    static func voiceUnitChecks(_ check: (String, Bool) -> Void) {
        let flags: CGEventFlags = [.maskAlternate, .maskShift]
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        check("voice: Cmd+Shift+V is the talk chord", Hotkeys.action(keyCode: 9, flags: cmdShift, tabHeld: false) == .talk)
        check("voice: plain V and Cmd+V (paste) are left alone", Hotkeys.action(keyCode: 9, flags: [], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 9, flags: .maskCommand, tabHeld: false) == nil)
        check("voice: Cmd+Option+Shift+V isn't ours", Hotkeys.action(keyCode: 9, flags: [.maskAlternate, .maskShift, .maskCommand], tabHeld: false) == nil)
        check("voice: Option+Shift+Space is free again", Hotkeys.action(keyCode: 49, flags: [.maskAlternate, .maskShift], tabHeld: false) == nil)
        check("voice: Cmd+Shift+A and Cmd+Shift+C aren't Margin's", Hotkeys.action(keyCode: 0, flags: cmdShift, tabHeld: false) == nil
              && Hotkeys.action(keyCode: 8, flags: cmdShift, tabHeld: false) == nil)
        talkChordChecks(check)
        check("voice: a question that mentions agents is still a question", CommandCenter.route("what is a principal agent problem") == .ask
              && CommandCenter.route("show me pictures of cats") == .ask && CommandCenter.route("what do real estate agents do") == .ask)
        check("voice: the chat chord still works", Hotkeys.action(keyCode: 48, flags: flags, tabHeld: false) == .chat)
        check("voice: wake words come off", CommandCenter.cleaned("Hey Margin, add lunch to my calendar") == "add lunch to my calendar"
              && CommandCenter.cleaned("okay margin what is entropy") == "what is entropy"
              && CommandCenter.cleaned("hey add lunch") == "add lunch"
              && CommandCenter.cleaned("margin") == "")
        check("voice: a question that merely contains 'margin' keeps it", CommandCenter.cleaned("what is profit margin") == "what is profit margin")
        check("voice: calendar request routes to the calendar", CommandCenter.route("add lunch to my calendar tomorrow at noon") == .calendar)
        check("voice: a question routes to Claude", CommandCenter.route("why is the sky blue") == .ask)
    }

    /// Margin --voicelag: how long each step of starting to listen takes on this Mac (no microphone, nothing recorded).
    static func voiceLag() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            func ms(_ since: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(since) * 1000) }
            var t = Date()
            let installed = await Transcription.isInstalled(.english)
            print("is the English model installed? \(installed): \(ms(t))")
            // The steps inside prepare, one by one.
            do {
                let locale = Locale(identifier: "en-US")
                t = Date()
                let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
                print("  supportedLocale: \(ms(t))")
                t = Date()
                let transcriber = SpeechTranscriber(locale: supported ?? locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
                print("  make transcriber: \(ms(t))")
                t = Date()
                let status = await AssetInventory.status(forModules: [transcriber])
                print("  AssetInventory.status: \(status) (\(ms(t)))")
                print("  installedLocales: \(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })")
                t = Date()
                let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                print("  assetInstallationRequest (\(request == nil ? "nothing to install" : "needs install")): \(ms(t))")
                t = Date()
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                print("  bestAvailableAudioFormat (\(format.map { "\($0.sampleRate) Hz" } ?? "nil")): \(ms(t))")
                t = Date()
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try? await analyzer.prepareToAnalyze(in: format)
                print("  prepareToAnalyze (first, cold): \(ms(t))")
                await analyzer.cancelAndFinishNow()
                for n in 2...3 {
                    // A fresh transcriber and analyzer each time (a module can only belong to one analyzer).
                    t = Date()
                    let tr = SpeechTranscriber(locale: supported ?? locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
                    let an = SpeechAnalyzer(modules: [tr])
                    try? await an.prepareToAnalyze(in: format)
                    print("  fresh transcriber + prepareToAnalyze #\(n): \(ms(t))")
                    t = Date()
                    let (seq, cont) = AsyncStream<AnalyzerInput>.makeStream()
                    try? await an.start(inputSequence: seq)
                    print("    analyzer.start: \(ms(t))")
                    cont.finish()
                    await an.cancelAndFinishNow()
                }
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// Margin --voicecheck: what voice has to work with on this Mac, without recording or downloading anything.
    static func voiceCheck() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        print("microphone permission: \(["not asked yet", "restricted", "denied", "allowed"][mic.rawValue])")
        print("calendar permission: \(CalendarStore.status.rawValue) (3 = allowed, 0 = not asked yet)")
        Task {
            for lang in SpokenLanguage.allCases {
                print("speech model for \(lang.title): \(await Transcription.isInstalled(lang) ? "installed" : "NOT installed (Margin asks before downloading)")")
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// Margin --pilldemo <dir>: pictures of the voice pill in each state (no audio, nothing recorded).
    @MainActor
    static func pillDemo(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let voice = VoiceController()
        let states: [(String, VoiceController.Phase, String, Float)] = [
            ("pill-listening", .listening, "add dinner with Anna to my calendar tomorrow at seven", 0.6),
            ("pill-needs-model", .needsModel("English"), "", 0),
            ("pill-denied", .micDenied, "", 0),
            ("pill-ready", .message("Ready. Hold ⌘⇧V to talk, let go to send."), "", 0),
        ]
        var i = 0
        func next() {
            guard i < states.count else { print("PILLDEMO DONE"); exit(0) }
            let s = states[i]
            voice.debugSet(s.1, text: s.2, level: s.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let image = voice.debugPill.debugImage {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(s.0 + ".png"))
                    print("  saved \(s.0).png")
                }
                i += 1
                next()
            }
        }
        next()
        app.run()
        exit(0)
    }
}

extension FeatureTests {
    private static var liveTranscription: Transcription?

    /// Margin --voicetest: the speech-to-text and calendar chain with a synthesized voice standing in for the microphone
    /// (the same recognizer and the same words-to-event steps a real command uses). Needs the English speech model
    /// to be installed already; it never downloads anything and never touches your calendar.
    static func voiceTest(phrase: String? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let sentence = phrase ?? "Hey Margin, add doing this and this to my calendar at eight to nine on the eighth of January twenty twenty seven."
        Task {
            guard await Transcription.isInstalled(.english) else {
                print("VOICETEST SKIPPED: the English speech model isn't installed (Margin never downloads it without asking)")
                exit(0)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-voicetest-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            let spoken: Speech.Rendered? = await withCheckedContinuation { cont in
                Speech.render(SayRequest(text: sentence, lang: "en-US", ipa: nil), slow: false, to: url) { cont.resume(returning: try? $0.get()) }
            }
            check("a spoken sentence was synthesized", spoken != nil)
            let t = Transcription(language: .english)
            liveTranscription = t
            do {
                try await t.prepare { _ in }
                try await t.transcribeFile(url) { _ in }
            } catch {
                print("VOICETEST FAIL: \(error.localizedDescription)")
                exit(1)
            }
            let heard = t.lines.map(\.text).joined(separator: " ")
            print("heard: \(heard)")
            check("the recognizer heard something", !heard.isEmpty)
            let cleaned = CommandCenter.cleaned(heard)
            print("cleaned: \(cleaned)")
            check("it routes to the calendar", CommandCenter.route(cleaned) == .calendar)
            let draft = CalendarIntent.parse(cleaned)
            print("event: \(String(describing: draft))")
            var cal = Calendar.current
            cal.timeZone = .current
            check("the title survives", draft?.title.lowercased().contains("doing this and this") == true)
            check("the date is 8 January 2027", draft.map { cal.dateComponents([.year, .month, .day], from: $0.start) } == DateComponents(year: 2027, month: 1, day: 8))
            check("the time is 8 to 9", draft.map { cal.component(.hour, from: $0.start) == 8 && cal.component(.hour, from: $0.end) == 9 } ?? false)
            print(failures == 0 ? "VOICETEST PASS" : "VOICETEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }
}

// MARK: - Video requests typed in a chat

extension FeatureTests {
    /// Margin --videochattest: typing a YouTube link with "summarize" into a chat turns it into a video agent for that video,
    /// and a normal question is left alone. (No Claude call, no browser touched.)
    static func videoChatTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let mouse = TestSpot.mouse(on: screen)
        let icon = NSRect(x: mouse.x, y: mouse.y, width: 26, height: 26)
        let selection = Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: mouse)
        let chat = AskPanelController(selection: selection, iconFrame: icon)
        var opened: [VideoSource] = []
        chat.onOpenVideo = { opened.append($0) }
        chat.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            chat.debugAsk("please summarize https://www.youtube.com/watch?v=arj7oStGLkU")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check("a pasted link with “summarize” opens the video summarizer for that video", opened == [.youtube(id: "arj7oStGLkU")])
                check("it didn't start a Claude question", chat.debugEngine == "none")
                chat.close()
                print(failures == 0 ? "VIDEOCHATTEST PASS" : "VIDEOCHATTEST FAIL (\(failures))")
                exit(failures == 0 ? 0 : 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("VIDEOCHATTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}

// MARK: - Naming a closed chat (live)

extension FeatureTests {
    /// Margin --namingtest: real Claude names a made-up chat (in a temporary library, never yours) when it's "closed", and
    /// a chat you rename while Claude is still thinking keeps your name.
    static func liveNamingTest() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-namingtest-\(UUID().uuidString)")
        let library = Library(directory: dir)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func chat(_ turns: [(String, String)], quote: String) -> ChatRecord {
            ChatRecord(title: "Chat from Preview", sector: "Other", app: "Preview", quote: quote,
                       turns: turns.map { .init(question: $0.0, answer: $0.1) })
        }
        let econ = chat([("What is opportunity cost?", "It's the value of the best alternative you give up when you choose something."),
                         ("Give an example", "Spending Saturday studying costs you the money you'd have earned working a shift."),
                         ("How does it relate to a production possibility frontier?", "Moving along the curve shows the trade-off: more of one good means less of the other.")],
                        quote: "Opportunity cost is the value of the next best alternative.")
        let russian = chat([("how do i stress this word", "Stress falls on the second syllable: замо́к (lock) vs за́мок (castle)."),
                            ("what about the plural", "Замки́ has end stress in the plural, for both meanings.")], quote: "замок")
        library.save(econ)
        library.save(russian)
        let t0 = Date()
        var tokens = 0
        var finished = 0
        func oneDone(_ used: Int) {
            tokens += used
            finished += 1
            guard finished == 2 else { return }
            let e = library.chat(econ.id), r = library.chat(russian.id)
            print("   \(Int(Date().timeIntervalSince(t0) * 1000)) ms, about \(tokens) tokens for two chats")
            print("   econ chat -> “\(e?.title ?? "")” in \(e?.sector ?? "")")
            print("   russian chat -> “\(r?.title ?? "")” in \(r?.sector ?? "")")
            check("a closed chat got a real name instead of 'Chat from Preview'", e?.title != "Chat from Preview" && (e?.title.count ?? 0) >= 6)
            check("economics was filed under Economics", e?.sector == "Economics")
            check("the Russian chat was filed under Language", r?.sector == "Language")
            check("the Russian chat kept the name you gave it while Claude was thinking", r?.title == "My Russian notes")
            check("…and it was marked as yours", r?.titleLocked == true)
            check("it cost under 2,000 tokens each", tokens < 4000)
            try? FileManager.default.removeItem(at: dir)
            print(failures == 0 ? "NAMINGTEST PASS" : "NAMINGTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("local") { ChatNaming.useLocal = { true }; print("   (naming on the Mac with Ollama; Claude only if that fails)") }
        ChatNaming.rename(econ.id, in: library, done: oneDone)
        ChatNaming.rename(russian.id, in: library, done: oneDone)
        library.rename(russian.id, to: "My Russian notes") // you rename it right after closing, before Claude answers
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("NAMINGTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}

// MARK: - Dictation

extension FeatureTests {
    /// Margin --voicedictation: the hold-to-talk recorder, fed synthesized speech in place of the microphone. Checks that
    /// words said before the recognizer is ready aren't lost, that the text is ready quickly after you let go, and how
    /// long it all takes. (The real microphone isn't touched: nothing is recorded.)
    static func dictationTest() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
        let sentence = "Please organize my downloads folder and then find the elasticity PDF."
        Task {
            guard await Dictation.isInstalled() else {
                print("DICTATIONTEST SKIPPED: the English speech model isn't installed (Margin never downloads it without asking)")
                exit(0)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-dictation-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            let rendered: Speech.Rendered? = await withCheckedContinuation { cont in
                Speech.render(SayRequest(text: sentence, lang: "en-US", ipa: nil), slow: false, to: url) { cont.resume(returning: try? $0.get()) }
            }
            check("a spoken sentence was synthesized", rendered != nil)
            guard let file = try? AVAudioFile(forReading: url) else { print("DICTATIONTEST FAIL: no audio"); exit(1) }
            let format = file.processingFormat
            var chunks: [AVAudioPCMBuffer] = []
            while file.framePosition < file.length {
                guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { break }
                try? file.read(into: b, frameCount: 2048)
                if b.frameLength == 0 { break }
                chunks.append(b)
            }
            print("  \(chunks.count) chunks of sound, \(Int(format.sampleRate)) Hz")

            let t0 = Date()
            await Dictation.warmUp()
            print("  warm-up (once, at launch): \(ms(t0)) ms")

            // 1. A press: everything is fed in at once, before the recognizer can possibly be ready.
            var shown: [String] = []
            var d = Dictation()
            d.onText = { shown.append($0) }
            d.debugStart(format: format)
            for c in chunks { d.debugFeed(c) }
            var t = Date()
            let first = await d.finish()
            print("  heard (words said while it was waking up): “\(first)”  — ready \(ms(t)) ms after letting go")
            let lower = first.lowercased()
            check("nothing said at the start was lost", lower.contains("organize") && lower.contains("downloads"))
            check("the end was heard too", lower.contains("elasticity"))
            check("the text was ready within 3 s of letting go", ms(t) < 3000)
            check("words were shown while it went", !shown.isEmpty)

            // 2. Another press straight after (the recognizer is warm now), fed at about twice real time.
            d = Dictation()
            d.debugStart(format: format)
            try? await Task.sleep(nanoseconds: 300_000_000)
            for c in chunks {
                d.debugFeed(c)
                try? await Task.sleep(nanoseconds: UInt64(Double(c.frameLength) / format.sampleRate * 0.5 * 1e9))
            }
            t = Date()
            let second = await d.finish()
            print("  second press: “\(second)”  — ready \(ms(t)) ms after letting go")
            check("a second press works as well", second.lowercased().contains("organize") && second.lowercased().contains("elasticity"))
            check("  and is quick (under 2 s after letting go)", ms(t) < 2000)

            // 3. A tap with no speech.
            d = Dictation()
            d.debugStart(format: format)
            t = Date()
            let nothing = await d.finish()
            check("silence gives an empty result, quickly (\(ms(t)) ms)", nothing.isEmpty && ms(t) < 3000)

            // 4. Held the keys but said nothing: a second of silence from the microphone.
            d = Dictation()
            d.debugStart(format: format)
            var quiet = 0
            while quiet < Int(format.sampleRate) {
                if let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) {
                    b.frameLength = 2048 // zeros
                    for ch in 0..<Int(format.channelCount) { memset(b.floatChannelData![ch], 0, 2048 * MemoryLayout<Float>.size) }
                    d.debugFeed(b)
                }
                quiet += 2048
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            t = Date()
            let hush = await d.finish()
            check("a second of silence gives an empty result, quickly (\(ms(t)) ms)", hush.isEmpty && ms(t) < 4000)

            print(failures == 0 ? "DICTATIONTEST PASS" : "DICTATIONTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }
}

// MARK: - Documents

extension FeatureTests {
    /// A PDF whose pages carry `texts`, either as real text or (to imitate a scan) as a picture of the text.
    private static func makePDF(_ texts: [String], asPicture: Bool) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-doc-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: asPicture ? 22 : 12), .foregroundColor: NSColor.black, .paragraphStyle: style]
        for text in texts {
            ctx.beginPDFPage(nil)
            let area = box.insetBy(dx: 50, dy: 60)
            if asPicture {
                // Draw the text into a bitmap, then the bitmap onto the page: no text layer, like a scan.
                let scale: CGFloat = 2
                let w = Int(area.width * scale), h = Int(area.height * scale)
                if let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    bmp.setFillColor(NSColor.white.cgColor)
                    bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    bmp.scaleBy(x: scale, y: scale)
                    let g = NSGraphicsContext(cgContext: bmp, flipped: false)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = g
                    (text as NSString).draw(in: CGRect(x: 0, y: 0, width: area.width, height: area.height), withAttributes: attrs)
                    NSGraphicsContext.restoreGraphicsState()
                    if let image = bmp.makeImage() { ctx.draw(image, in: area) }
                }
            } else {
                let g = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = g
                (text as NSString).draw(in: area, withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private static func documents(_ check: (String, Bool) -> Void) {
        // Cutting text up
        let essay = (1...30).map { "Paragraph \($0) is about topic number \($0) and says something specific about it." }.joined(separator: "\n\n")
        let cut = DocIndex.passages(from: essay, size: 400)
        check("doc: text is cut into passages near the target size", cut.count > 3 && cut.allSatisfy { $0.text.count <= 800 })
        let long = String(repeating: "A sentence that goes on. ", count: 200)
        check("doc: one huge paragraph is cut at sentence ends", DocIndex.passages(from: long, size: 500).count >= 5)
        check("doc: tiny scraps are dropped", DocIndex.passages(from: "ok\n\nhi").isEmpty)

        // Finding the right parts (BM25)
        let book = DocIndex(title: "Econ", kind: "PDF", pageCount: 4, passages: [
            Passage(text: "Opportunity cost is the value of the next best alternative that you give up when you make a choice.", page: 1),
            Passage(text: "Elasticity measures how much quantity demanded responds to a change in price. Elastic demand is sensitive to price.", page: 2),
            Passage(text: "A monopoly is a market with a single seller who can set prices above marginal cost.", page: 3),
            Passage(text: "Gross domestic product adds up the value of final goods and services produced in a country.", page: 4),
        ])
        check("doc: finds the page about elasticity", book.relevant(to: "What does price elasticity of demand mean?", limit: 1).first?.page == 2)
        check("doc: finds opportunity cost", book.relevant(to: "explain opportunity cost", limit: 1).first?.page == 1)
        check("doc: results come back in page order", book.relevant(to: "price demand monopoly", limit: 3).map(\.page) == [2, 3])
        check("doc: nothing matches means nothing found", book.relevant(to: "photosynthesis chlorophyll").isEmpty)
        check("doc: overview spreads over the document", book.overview(budget: 1800).count == 4 && DocIndex(title: "", kind: "", pageCount: nil, passages: []).overview().isEmpty)
        check("doc: passages carry page numbers to Claude", DocIndex.render([Passage(text: "Hello", page: 12)]) == "[p. 12] Hello")
        let prompt = Prompts.firstWithDocument(app: "Preview", doc: book, selection: "", passages: book.relevant(to: "elasticity", limit: 1),
                                               question: "What is it?", overview: false)
        check("doc: the prompt names the document and its size, and asks for page citations", prompt.contains("«Econ»") && prompt.contains("4 pages") && prompt.contains("cite pages"))
        check("doc: the prompt holds the passage, not the whole book", prompt.contains("Elasticity") && !prompt.contains("monopoly"))
        check("doc: a follow-up without matches is just the question", Prompts.withPassages("Why?", [], overview: false) == "Why?")
        check("doc: a document chat is a lean Claude call", Router.plan(.init(prompt: "x", selection: "", isBlank: true, hasDocument: true)).lean)

        // Web pages
        let html = "<html><head><title>Entropy &amp; Heat</title><style>p{color:red}</style><script>var x=1;</script></head><body><nav>Menu Home</nav><h1>Entropy</h1><p>Entropy measures disorder.&nbsp;It rises.</p><p>Second law &#8212; always.</p><footer>Copyright</footer></body></html>"
        let (title, text) = HTMLText.extract(html)
        check("doc: web title", title == "Entropy & Heat")
        check("doc: web text has the content", text.contains("Entropy measures disorder. It rises.") && text.contains("Second law — always."))
        check("doc: scripts, styles, menus and footers are dropped", !text.contains("var x") && !text.contains("color:red") && !text.contains("Menu Home") && !text.contains("Copyright"))
        check("doc: names for chips", PageReader.displayName(URL(string: "https://www.example.com/a")!) == "example.com"
              && PageReader.displayName(URL(fileURLWithPath: "/tmp/Textbook.pdf")) == "Textbook.pdf")
        check("doc: what can be read", PageReader.isReadable(URL(fileURLWithPath: "/a/b.pdf")) && PageReader.isReadable(URL(string: "https://x.com")!)
              && !PageReader.isReadable(URL(fileURLWithPath: "/a/b.zip")) && !PageReader.isReadable(URL(string: "ftp://x.com")!))

        // A real PDF with a text layer: 12 pages, one topic each
        let topics = ["photosynthesis in green plants", "the French revolution of 1789", "quadratic equations and parabolas", "supply and demand curves",
                      "newtonian gravity and orbits", "the Roman Republic", "cell division and mitosis", "plate tectonics", "the water cycle",
                      "compound interest", "the periodic table", "Shakespeare's sonnets"]
        let pdfURL = makePDF(topics.enumerated().map { "Chapter \($0.offset + 1). This page explains \($0.element) in some detail, with several sentences about \($0.element)." }, asPicture: false)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdf = PageReader.readFile(pdfURL)
        check("pdf: reads every page of a text PDF", pdf?.pageCount == 12 && pdf?.kind == "PDF" && (pdf?.passages.count ?? 0) >= 12)
        check("pdf: finds page 3 for parabolas", pdf?.relevant(to: "how do parabolas work", limit: 1).first?.page == 3)
        check("pdf: finds page 8 for plate tectonics", pdf?.relevant(to: "tell me about tectonics", limit: 1).first?.page == 8)

        // A scanned PDF (a picture of text): read with on-device character recognition
        let scanURL = makePDF(["Mitochondria are the powerhouse of the cell. They produce ATP through respiration.",
                               "The Treaty of Westphalia ended the Thirty Years War in 1648."], asPicture: true)
        defer { try? FileManager.default.removeItem(at: scanURL) }
        let scan = PageReader.readFile(scanURL)
        let scanText = scan?.passages.map(\.text).joined(separator: " ").lowercased() ?? ""
        check("pdf: a scan has no text layer but is still read", scanText.contains("mitochondria") && scanText.contains("westphalia"))
        check("pdf: the scan is noted", scan?.note?.contains("scanned") == true)
        check("pdf: scan pages keep their numbers", scan?.relevant(to: "westphalia treaty", limit: 1).first?.page == 2)
    }
}

extension FeatureTests {
    private static var docSession: ClaudeSession?

    /// Margin --doctest: a 40-page PDF, a question about one page, a real Claude answer from only the matching passages.
    static func liveDocumentTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let filler = ["tides", "volcanoes", "bridges", "bees", "glaciers", "railways", "coffee", "lenses", "deserts", "satellites"]
        var pages = (1...40).map { n in
            "Chapter \(n). \(filler[n % filler.count].capitalized) are discussed here at length. " + String(repeating: "The author describes \(filler[n % filler.count]) and gives examples of \(filler[n % filler.count]). ", count: 6)
        }
        pages[16] = "Chapter 17. The Treaty of Zorbania, signed in 1873, ended the Salt War. Its key term was that the river Quell became the border, and both nations agreed to a 12-year ban on fortifications along it. " + String(repeating: "Historians consider the Quell border a model of negotiated peace. ", count: 4)
        let url = makePDF(pages, asPicture: false)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PageReader.readFile(url) else { print("DOCTEST FAIL: couldn't read the PDF"); exit(1) }
        let question = "What did the treaty say about fortifications?"
        let found = doc.relevant(to: question)
        check("the right page is among the matches", found.contains { $0.page == 17 })
        let sent = Prompts.firstWithDocument(app: "Preview", doc: doc, selection: "", passages: found, question: question, overview: false)
        let wholeBook = doc.characters
        print("document: \(doc.passages.count) passages, \(wholeBook) characters; sending \(found.count) passages, \(sent.count) characters (\(100 * sent.count / max(1, wholeBook))% of it)")
        check("only a fraction of the document is sent", sent.count * 5 < wholeBook)

        let session = ClaudeSession(model: Settings.shared.model, webSearch: false)
        docSession = session
        var answer = ""
        var usage = ClaudeSession.Usage()
        session.onUsage = { usage = $0 }
        session.onEvent = { event in
            switch event {
            case .delta(let t): answer += t
            case .error(let m): print("DOCTEST FAIL: \(m)"); exit(1)
            case .turnDone:
                print("--- answer (\(usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens) tokens in, \(usage.outputTokens) out)\n\(answer)")
                let lower = answer.lowercased()
                check("the answer has the 12-year ban", lower.contains("12") || lower.contains("twelve"))
                check("…and cites page 17", lower.contains("17"))
                check("…and was a small call (under 5,000 input tokens)", usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens < 5000)
                session.stop()
                print(failures == 0 ? "DOCTEST PASS" : "DOCTEST FAIL (\(failures))")
                exit(failures == 0 ? 0 : 1)
            default: break
            }
        }
        do { try session.start() } catch { print("DOCTEST FAIL: \(error.localizedDescription)"); exit(1) }
        session.send(sent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("DOCTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}

// MARK: - Screenshot titles, one-shot Claude calls

extension FeatureTests {
    private static func oneShotChecks(_ check: (String, Bool) -> Void) {
        check("screenshots: titles from on-screen text", ScreenshotLabel.heuristicTitle("File Edit View\nSupply and Demand: Market Equilibrium\n12 34") == "Supply and Demand: Market Equilibrium".replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "  ", with: " ")
              && ScreenshotLabel.heuristicTitle("12 34 56") == nil)
        check("screenshots: names are safe for files", ScreenshotLabel.sanitize("a/b: c*d?  e") == "a b c d e" && ScreenshotLabel.sanitize(String(repeating: "word ", count: 30)).count <= 60)

        // Running Claude once: reading its JSON envelope
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"[\"A title\"]","usage":{"input_tokens":12,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":9},"total_cost_usd":0.01,"duration_api_ms":1500}"#
        if case .success(let r) = ClaudeOneShot.parse(Data(envelope.utf8)) {
            check("oneshot: result, tokens and cost", r.text == "[\"A title\"]" && r.tokens == 3021 && r.usage.costUSD == 0.01)
        } else { check("oneshot: result, tokens and cost", false) }
        if case .success(let r) = ClaudeOneShot.parse(Data("[\(envelope)]".utf8)) { check("oneshot: array form", r.text == "[\"A title\"]") } else { check("oneshot: array form", false) }
        check("oneshot: an error result fails", { if case .failure = ClaudeOneShot.parse(Data(#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"nope"}"#.utf8)) { return true } else { return false } }())
        check("oneshot: JSON found inside chatter", (ClaudeOneShot.json(from: "Here: [\"a\", \"b\"] done") as? [String]) == ["a", "b"])
    }
}

extension FeatureTests {
    private static func voiceRouting(_ check: (String, Bool) -> Void) {
        check("voice: calendar still wins", CommandCenter.route("add tidy desktop to my calendar tomorrow at 9") == .calendar)
        check("voice: a file job is just a question now", CommandCenter.route("tidy my desktop") == .ask)
        check("voice: a question still goes to Claude", CommandCenter.route("why does ice float") == .ask)
    }
}

/// Where the tests put the chats they open: the bottom-right corner of the main screen, so they never cover the middle of the
/// screen where you're working. (A chat there grows upward as its answer fills in. Test chats are click-through anyway: they
/// can't take clicks or typing.)
enum TestSpot {
    static func mouse(on screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]) -> NSPoint {
        NSPoint(x: screen.visibleFrame.maxX - 40, y: screen.visibleFrame.minY + 40)
    }
}

extension FeatureTests {
    /// Runs the main loop until `done()` or the time runs out.
    static func pump(_ seconds: TimeInterval = 8, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func fakeReply(_ text: String, tokens: Int = 600) -> Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure> {
        .success(ClaudeOneShot.Reply(text: text, usage: ClaudeSession.Usage(inputTokens: tokens - 100, outputTokens: 100)))
    }
}
