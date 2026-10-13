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
        fileSafety(check)
        agents(check)
        taskRouting(check)
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
        check("video: voice sends it to the video summarizer, not an agent", CommandCenter.route("summarize this video") == .video(.youtube(id: nil)))
        check("video: …and not to a study agent from the agent box", { if case .video = CommandCenter.route("Hey Margin summarize this video") { return true } else { return false } }()
              || CommandCenter.route(CommandCenter.cleaned("Hey Margin summarize this video")) == .video(.youtube(id: nil)))
        check("video: a textbook summary is still a study agent", { if case .task(.study) = CommandCenter.route("summarize chapter 4 of my econ textbook") { return true } else { return false } }())
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

    /// Margin --libdemo <dir>: pictures of the quiz in four states and the History & Notebook window, filled with
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

        let state = LibraryState()
        let chats = Library.shared.chats
        func card(_ view: some View, width: CGFloat) -> some View {
            view.frame(width: width).background(Color(nsColor: .windowBackgroundColor))
        }
        render("history-list.png", VStack(alignment: .leading, spacing: 8) {
            ForEach(chats.prefix(4)) { ChatRow(chat: $0) }
        }.padding(8), width: 320)
        // The real window, in light mode (a snapshot can't mix the system's dark mode with the window's own blur).
        let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(state: state, onAsk: { _, _ in })))
        window.styleMask = [.titled, .closable, .resizable]
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 980, height: 600))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless() // never activates Margin, so it can't take your keyboard
        func snap(_ name: String) {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            print("  saved \(name)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            state.selectedChat = Library.shared.chats.last?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                snap("history-window.png")
                state.mode = .notebook
                state.selectedNote = Library.shared.notes.first?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    snap("notebook-window.png")
                    window.orderOut(nil)
                    print("LIBDEMO DONE")
                    exit(0)
                }
            }
        }
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
    /// ⌘⇧V talks to a chat; ⌘⇧V then A (or ⌘⇧A then V) talks to an agent; ⌘⇧A alone shows the bar, on key-up.
    static func agentChordChecks(_ check: (String, Bool) -> Void) {
        let keys = Hotkeys()
        var log: [String] = []
        keys.onTalkStart = { log.append($0 ? "talk-agent" : "talk") }
        keys.onTalkAgent = { log.append("agent") }
        keys.onTalkEnd = { log.append("end") }
        keys.onTasks = { log.append("bar") }
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
        let s2 = [key(v, down: true), key(a, down: true), key(a, down: false), key(v, down: false)]
        check("chord: ⌘⇧V then A makes it a job for an agent (\(log))", log == ["talk", "agent", "end"] && s2.allSatisfy { $0 })
        log = []
        let s3 = [key(a, down: true), key(v, down: true), key(v, down: false), key(a, down: false)]
        check("chord: ⌘⇧A then V talks to an agent, and doesn't toggle the bar (\(log))", log == ["talk-agent", "end"] && s3.allSatisfy { $0 })
        log = []
        let s4 = [key(a, down: true)]
        let early = log
        let s5 = [key(a, down: false)]
        check("chord: ⌘⇧A alone shows the bar when A comes up (\(log))", early.isEmpty && log == ["bar"] && (s4 + s5).allSatisfy { $0 })
        log = []
        check("chord: a plain A types normally", !key(a, down: true, []) && !key(a, down: false, []) && log.isEmpty)
        // A key-up that never arrives (the event tap was briefly off) must not make the next typed letters vanish.
        log = []
        _ = key(a, down: true) // ⌘⇧A pressed, its release is lost
        log = []
        let typed = key(a, down: true, []) // later, a plain "a"
        check("chord: after a lost key-up, a plain A is typed normally again", !typed)
        _ = key(a, down: false, [])
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
        check("agents: Cmd+Shift+A shows the agent bar", Hotkeys.action(keyCode: 0, flags: cmdShift, tabHeld: false) == .tasks
              && Hotkeys.action(keyCode: 0, flags: [.maskCommand, .maskControl, .maskShift], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 0, flags: .maskCommand, tabHeld: false) == nil)
        agentChordChecks(check)
        check("agents: 'show my agents' opens the bar", CommandCenter.route("show me my agents") == .agents)
        check("agents: 'what are my agents doing' opens the bar", CommandCenter.route("Hey Margin, what are my agents doing?") == .agents
              || CommandCenter.route(CommandCenter.cleaned("Hey Margin, what are my agents doing?")) == .agents)
        check("agents: 'check on my cats' opens the bar", CommandCenter.route("check on my cats") == .agents)
        check("agents: 'open the agent bar'", CommandCenter.route("open the agent bar") == .agents)
        check("agents: a question about agents is still a question", CommandCenter.route("what is a principal agent problem") == .ask
              && CommandCenter.route("show me pictures of cats") == .ask && CommandCenter.route("what do real estate agents do") == .ask)
        for phrase in ["organize my downloads", "Organize my download.", "can you organize my downloads folder", "Could you organise the downloads",
                       "clean up my desktop please", "sort my screenshots", "organize my downloads for me", "tidy up my downloads folder"] {
            let r = CommandCenter.route(CommandCenter.cleaned(phrase))
            check("voice: “\(phrase)” goes to an agent (\(r))", { if case .task = r { return true } else { return false } }())
        }
        check("agents: a job still starts a job", { if case .task = CommandCenter.route("tidy my downloads") { return true } else { return false } }())
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

// MARK: - File safety

extension FeatureTests {
    private static func fileSafety(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("margin-safety-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("Desktop")
        let outside = base.appendingPathComponent("Elsewhere")
        try? fm.createDirectory(at: allowed, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let savedRoots = FileSafety.roots
        FileSafety.roots = [allowed]
        defer { FileSafety.roots = savedRoots }

        func make(_ name: String, in dir: URL = allowed, _ text: String = "x") -> URL {
            let url = dir.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
            return url
        }
        func refused(_ f: () throws -> Void) -> Bool { (try? f()) == nil }

        let shot = make("Screenshot 1.png")
        let foreign = make("secret.txt", in: outside)
        let hidden = make(".hidden.txt")
        let insideApp = make("Tool.app/Contents/Info.plist")
        let link = allowed.appendingPathComponent("link-to-secret")
        try? fm.createSymbolicLink(at: link, withDestinationURL: foreign)

        check("safety: an item in an allowed folder is fine", !refused { try FileSafety.checkSource(shot) })
        check("safety: nothing outside the allowed folders", refused { try FileSafety.checkSource(foreign) })
        check("safety: not the allowed folder itself", refused { try FileSafety.checkSource(allowed) })
        check("safety: not hidden files", refused { try FileSafety.checkSource(hidden) })
        check("safety: not inside an app", refused { try FileSafety.checkSource(insideApp) })
        check("safety: not a shortcut that points elsewhere", refused { try FileSafety.checkSource(link) })
        check("safety: not a made-up path", refused { try FileSafety.checkSource(allowed.appendingPathComponent("nope.txt")) })
        check("safety: '..' can't climb out", refused { try FileSafety.checkSource(allowed.appendingPathComponent("../Elsewhere/secret.txt")) })
        check("safety: a sibling folder with a similar name isn't inside", refused { try FileSafety.checkSource(make("a.txt", in: base.appendingPathComponent("Desktop2"))) })
        check("safety: can't put things outside", refused { try FileSafety.checkDestination(outside.appendingPathComponent("x.txt")) })
        check("safety: can't put things in hidden folders", refused { try FileSafety.checkDestination(allowed.appendingPathComponent(".cache/x.txt")) })
        check("safety: unique names count up", FileSafety.unique(shot).lastPathComponent == "Screenshot 1 2.png"
              && FileSafety.unique(allowed.appendingPathComponent("new.txt")).lastPathComponent == "new.txt")

        // Moving, with a name clash and new folders
        let a = make("a.pdf", "A"), b = make("b.pdf", "B")
        let dest = allowed.appendingPathComponent("PDFs/2026-10")
        var ledger = FileSafety.Ledger(title: "test")
        var progressed = 0
        let ops = [FileSafety.Op.move(a, to: dest.appendingPathComponent("doc.pdf")), .move(b, to: dest.appendingPathComponent("doc.pdf")),
                   .move(foreign, to: allowed.appendingPathComponent("stolen.txt")), .move(hidden, to: allowed.appendingPathComponent("h.txt"))]
        let outcome = FileSafety.execute(ops, ledger: &ledger, progress: { done, _ in progressed = done })
        check("safety: moved two files", outcome.done == 2 && progressed == 4)
        check("safety: the clash didn't overwrite", (try? String(contentsOf: dest.appendingPathComponent("doc.pdf"))) == "A"
              && (try? String(contentsOf: dest.appendingPathComponent("doc 2.pdf"))) == "B")
        check("safety: forbidden moves were skipped, with reasons", outcome.skipped.count == 2 && fm.fileExists(atPath: foreign.path)
              && !fm.fileExists(atPath: allowed.appendingPathComponent("stolen.txt").path))
        check("safety: the ledger knows what happened", ledger.count == 2 && ledger.records.filter { $0.kind == .createdFolder }.count == 2)

        // Trash, then undo everything
        let junk = make("old.dmg", "junk")
        let t = FileSafety.execute([.trash(junk)], ledger: &ledger)
        check("safety: remove goes to the Trash, not oblivion", t.done == 1 && !fm.fileExists(atPath: junk.path)
              && ledger.records.last.map { fm.fileExists(atPath: $0.now) } == true)
        let undone = FileSafety.undo(&ledger)
        check("safety: undo puts everything back", undone.restored == 3 && undone.couldNotRestore.isEmpty
              && fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path) && fm.fileExists(atPath: junk.path))
        check("safety: contents survived the round trip", (try? String(contentsOf: a)) == "A" && (try? String(contentsOf: junk)) == "junk")
        check("safety: folders Margin made are cleaned up", !fm.fileExists(atPath: dest.path) && !fm.fileExists(atPath: allowed.appendingPathComponent("PDFs").path))

        // A file you moved yourself afterwards is left alone
        var ledger2 = FileSafety.Ledger(title: "t2")
        let c = make("c.txt", "C")
        _ = FileSafety.execute([.move(c, to: allowed.appendingPathComponent("Notes/c.txt"))], ledger: &ledger2)
        try? fm.removeItem(at: allowed.appendingPathComponent("Notes/c.txt"))
        let undone2 = FileSafety.undo(&ledger2)
        check("safety: undo doesn't invent files you've deleted", undone2.restored == 0 && undone2.couldNotRestore == ["c.txt"])

        // Cancelling stops between steps
        var ledger3 = FileSafety.Ledger(title: "t3")
        let d1 = make("d1.txt"), d2 = make("d2.txt")
        var calls = 0
        let cancelled = FileSafety.execute([.move(d1, to: allowed.appendingPathComponent("X/d1.txt")), .move(d2, to: allowed.appendingPathComponent("X/d2.txt"))],
                                           ledger: &ledger3, cancelled: { calls += 1; return calls > 1 })
        check("safety: cancel stops the rest", cancelled.cancelled && cancelled.done == 1 && fm.fileExists(atPath: d2.path))

        // The ledger is written as a file
        let saved = FileSafety.ledgerDirectory
        FileSafety.ledgerDirectory = base.appendingPathComponent("ledgers")
        FileSafety.save(ledger)
        check("safety: the ledger is saved", fm.fileExists(atPath: FileSafety.ledgerDirectory.appendingPathComponent("\(ledger.id.uuidString).json").path))
        FileSafety.ledgerDirectory = saved
    }
}

// MARK: - Background agents

extension FeatureTests {
    private static func agents(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default

        // Kinds
        check("tidy: kinds by name", Tidy.category(forName: "Screenshot 2026-10-09 at 3.41.12 PM.png") == .screenshot
              && Tidy.category(forName: "Screen Recording 2026.mov") == .screenshot
              && Tidy.category(forName: "notes.pdf") == .pdf && Tidy.category(forName: "IMG_1.HEIC") == .image
              && Tidy.category(forName: "Setup.dmg") == .installer && Tidy.category(forName: "a.zip") == .archive
              && Tidy.category(forName: "essay.docx") == .document && Tidy.category(forName: "weird.xyz") == .other
              && Tidy.category(forName: "Screenshots are fun.txt") == .document)
        check("tidy: titles from on-screen text", Tidy.heuristicTitle("File Edit View\nSupply and Demand: Market Equilibrium\n12 34") == "Supply and Demand: Market Equilibrium".replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "  ", with: " ")
              && Tidy.heuristicTitle("12 34 56") == nil)
        check("tidy: names are safe for files", Tidy.sanitize("a/b: c*d?  e") == "a b c d e" && Tidy.sanitize(String(repeating: "word ", count: 30)).count <= 60)
        check("tidy: the prompt numbers the screenshots", Tidy.namePrompt(["one\ntwo", "three"]).hasPrefix("1. one | two\n2. three"))
        check("tidy: token estimate grows with the count", Tidy.nameTokenEstimate(count: 150) > Tidy.nameTokenEstimate(count: 50) && Tidy.nameTokenEstimate(count: 0) == 0)

        // A messy folder, in a temporary allowed area
        let base = fm.temporaryDirectory.appendingPathComponent("margin-tidy-\(UUID().uuidString)")
        let desktop = base.appendingPathComponent("Desktop")
        try? fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let savedRoots = FileSafety.roots
        FileSafety.roots = [desktop]
        defer { FileSafety.roots = savedRoots }
        let now = Date()
        func file(_ name: String, _ text: String, age: TimeInterval = 3600 * 24 * 3) -> URL {
            let u = desktop.appendingPathComponent(name)
            try? Data(text.utf8).write(to: u)
            let d = now.addingTimeInterval(-age)
            try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: u.path)
            return u
        }
        let shot1 = file("Screenshot 2026-10-09 at 3.41.12 PM.png", "s1")
        let shot2 = file("Screenshot 2026-10-09 at 4.00.00 PM.png", "s2")
        _ = file("report.pdf", "pdf-1")
        _ = file("notes.txt", "n")
        _ = file("same-a.txt", "identical content")
        _ = file("same-b.txt", "identical content", age: 3600 * 24 * 2) // newer: this is the one trashed
        _ = file("OldApp.dmg", "installer", age: 3600 * 24 * 60)
        _ = file("NewApp.dmg", "installer2", age: 3600 * 24 * 2)
        _ = file("mystery.xyz", "?")
        _ = file("just-now.txt", "fresh", age: 60)
        try? fm.createDirectory(at: desktop.appendingPathComponent("EmptyFolder"), withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-86400)], ofItemAtPath: desktop.appendingPathComponent("EmptyFolder").path)
        try? fm.createDirectory(at: desktop.appendingPathComponent("MyProject"), withIntermediateDirectories: true)
        try? Data("keep".utf8).write(to: desktop.appendingPathComponent("MyProject/file.txt"))
        try? Data("h".utf8).write(to: desktop.appendingPathComponent(".hidden"))

        let scan = Tidy.scan(desktop, now: now)
        check("tidy: scan sees the loose files", scan.items.count == 9 && scan.skippedRecent == 1 && scan.emptyFolders.count == 1)
        check("tidy: scan leaves your own folders and hidden files out", !scan.items.contains { $0.name == "file.txt" || $0.name == ".hidden" })
        let plan = Tidy.plan(folder: desktop, scan: scan, titles: [shot1: "Supply and demand graph"], screenshotTexts: 2, now: now)
        let keys = plan.groups.map(\.key)
        check("tidy: plan has the right groups", Set(keys) == ["duplicates", "old-installers", "empty-folders", "sort:screenshot", "sort:pdf", "sort:document", "sort:installer"])
        check("tidy: the newer duplicate is the one removed", plan.groups.first { $0.key == "duplicates" }?.files.first?.hasPrefix("same-b.txt") == true)
        check("tidy: one duplicate doesn't also get sorted", plan.groups.first { $0.key == "sort:document" }?.ops.count == 2)
        check("tidy: the plan offers smart names, off by default, with a token cost",
              plan.options.first?.id == "smartNames" && plan.options.first?.on == false && plan.options.first?.detail.contains("tokens") == true)
        check("tidy: notes say what was left alone", plan.notes.contains { $0.contains("other kinds") } && plan.notes.contains { $0.contains("last 10 minutes") })
        let shotGroup = plan.groups.first { $0.key == "sort:screenshot" }
        check("tidy: screenshots go to month folders and get named from their text",
              shotGroup?.ops.count == 2 && shotGroup?.ops.contains { $0.to?.hasSuffix("Screenshots/2026-10/2026-10-06 Supply and demand graph.png") == true || ($0.to?.contains("Supply and demand graph") == true) } == true)
        check("tidy: a screenshot with no title keeps its name", shotGroup?.ops.contains { $0.to?.hasSuffix("Screenshot 2026-10-09 at 4.00.00 PM.png") == true } == true)

        var ledger = FileSafety.Ledger(title: "tidy test")
        let outcome = FileSafety.execute(plan.enabledOps, ledger: &ledger)
        check("tidy: the plan runs without skips", outcome.skipped.isEmpty && outcome.done == plan.enabledOps.count)
        check("tidy: screenshots, PDFs and documents are sorted", fm.fileExists(atPath: desktop.appendingPathComponent("PDFs").path)
              && !fm.fileExists(atPath: shot1.path) && !fm.fileExists(atPath: shot2.path)
              && (try? fm.contentsOfDirectory(atPath: desktop.appendingPathComponent("Documents").path))?.sorted() == ["notes.txt", "same-a.txt"])
        check("tidy: the old installer and duplicate are in the Trash, the new installer is sorted",
              !fm.fileExists(atPath: desktop.appendingPathComponent("OldApp.dmg").path) && !fm.fileExists(atPath: desktop.appendingPathComponent("same-b.txt").path)
              && fm.fileExists(atPath: desktop.appendingPathComponent("Installers/NewApp.dmg").path))
        check("tidy: your own things weren't touched", fm.fileExists(atPath: desktop.appendingPathComponent("MyProject/file.txt").path)
              && fm.fileExists(atPath: desktop.appendingPathComponent("just-now.txt").path) && fm.fileExists(atPath: desktop.appendingPathComponent("mystery.xyz").path)
              && fm.fileExists(atPath: desktop.appendingPathComponent(".hidden").path))
        let undo = FileSafety.undo(&ledger)
        check("tidy: undo restores the whole desktop", undo.couldNotRestore.isEmpty && fm.fileExists(atPath: shot1.path)
              && fm.fileExists(atPath: desktop.appendingPathComponent("OldApp.dmg").path) && fm.fileExists(atPath: desktop.appendingPathComponent("same-b.txt").path)
              && fm.fileExists(atPath: desktop.appendingPathComponent("EmptyFolder").path) && !fm.fileExists(atPath: desktop.appendingPathComponent("PDFs").path))

        // An already-tidy folder
        let tidy = fm.temporaryDirectory.appendingPathComponent("margin-tidy2-\(UUID().uuidString)/Desktop")
        try? fm.createDirectory(at: tidy, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tidy.deletingLastPathComponent()) }
        FileSafety.roots = [tidy]
        check("tidy: nothing to do says so", Tidy.plan(folder: tidy, scan: Tidy.scan(tidy), now: now).groups.isEmpty)
        FileSafety.roots = [desktop]

        // Find
        let (terms, query) = Find.parse("where's the PDF with the elasticity table?")
        check("find: keeps the words that matter", terms == ["elasticity", "table"] && query.contains("com.adobe.pdf") && query.contains("*elasticity*"))
        check("find: nothing to look for is empty", Find.parse("find my files").query.isEmpty)
        let hits = Find.rank(Find.walk([desktop], terms: ["report"]), terms: ["report"])
        check("find: the fallback walk finds files by name", hits.count == 1 && hits[0].url.lastPathComponent == "report.pdf" && hits[0].nameMatches)
        check("find: system folders are never listed", Find.rank(["/Users/x/Library/Caches/report.pdf", "/Users/x/.hidden/r.pdf"], terms: ["report"]).isEmpty)

        // Batch
        let png = fm.temporaryDirectory.appendingPathComponent("margin-batch-\(UUID().uuidString).png")
        let heic = png.deletingPathExtension().appendingPathExtension("heic")
        defer { try? fm.removeItem(at: png); try? fm.removeItem(at: heic) }
        if let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let img = { ctx.setFillColor(NSColor.orange.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48)); return ctx.makeImage() }(),
           let dest = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            _ = CGImageDestinationFinalize(dest)
        }
        let jpeg = BatchAgent.jpegData(from: heic)
        check("batch: HEIC becomes a JPEG", jpeg.map { $0.count > 100 && $0.prefix(2) == Data([0xFF, 0xD8]) } == true)
        let p1 = makePDF(["one", "two"], asPicture: false), p2 = makePDF(["three"], asPicture: false)
        defer { try? fm.removeItem(at: p1); try? fm.removeItem(at: p2) }
        check("batch: PDFs merge into one with every page", BatchAgent.mergedPDF([p1, p2]).flatMap { PDFDocument(data: $0) }?.pageCount == 3)

        // Study
        let json = "Sure!\n```json\n{\"summary\": \"Main idea.\\n- a\\n- b\", \"keywords\": [{\"term\": \"Elasticity\", \"meaning\": \"Responsiveness.\"}], \"questions\": [{\"q\": \"Why?\", \"a\": \"Because.\"}], \"flashcards\": [{\"front\": \"F\\ttab\", \"back\": \"B\"}]}\n```"
        let notes = Study.parse(json)
        check("study: Claude's JSON is read even in a code fence", notes?.keywords.first?.term == "Elasticity" && notes?.questions.count == 1 && notes?.summary.hasPrefix("Main idea.") == true)
        check("study: unusable replies are refused", Study.parse("I cannot do that") == nil && Study.parse("{}") == nil)
        let sec = Study.Section(title: "Chapter 4: Elasticity", pages: 41...58, text: "x")
        let md = Study.markdown(notes!, doc: "Econ 101", section: sec)
        check("study: markdown has the parts", md.contains("# Chapter 4: Elasticity") && md.contains("pages 41–58") && md.contains("## Key terms") && md.contains("- **Elasticity**: Responsiveness.") && md.contains("*Answer:* Because."))
        check("study: flashcards are tab-separated for Anki", Study.flashcardsCSV(notes!.flashcards.map { ($0.front, $0.back) }) == "F tab\tB\n")
        let long = Study.Section(title: "Long", pages: nil, text: String(repeating: "A long paragraph of study text goes here.\n\n", count: 2000))
        check("study: long sections are cut to excerpts", Study.sent(long).excerpted && Study.sent(long).text.count < Study.maxSectionChars + 500 && !Study.sent(sec).excerpted)
        let est1 = Study.estimate(sections: [sec], outputs: [.summary]), est2 = Study.estimate(sections: [sec, sec], outputs: [.summary, .flashcards])
        check("study: the token estimate grows with parts and outputs", est2 > 2 * est1 && est1 > 3500)
        check("study: prompt asks only for what's wanted", Study.prompt(docTitle: "D", section: sec, outputs: [.summary], excerpted: false, text: "t").contains("\"summary\"")
              && !Study.prompt(docTitle: "D", section: sec, outputs: [.summary], excerpted: false, text: "t").contains("flashcards"))

        // A PDF with a real table of contents
        let book = makePDF((1...12).map { "Page \($0) text that is long enough to be indexed properly in the study reader." }, asPicture: false)
        defer { try? fm.removeItem(at: book) }
        if let pdf = PDFDocument(url: book) {
            let root = PDFOutline()
            for (i, (title, page)) in [("Chapter 1: Basics", 0), ("Chapter 2: Demand", 4), ("Chapter 3: Supply", 8)].enumerated() {
                let o = PDFOutline()
                o.label = title
                if let p = pdf.page(at: page) { o.destination = PDFDestination(page: p, at: .zero) }
                root.insertChild(o, at: i)
            }
            pdf.outlineRoot = root
            pdf.write(to: book)
        }
        let study = Study.read(book)
        check("study: a PDF's contents become sections", study?.sections.map(\.title) == ["Chapter 1: Basics", "Chapter 2: Demand", "Chapter 3: Supply"])
        check("study: each section has its own pages", study?.sections[1].pages == 5...8 && study?.sections[1].text.contains("Page 6") == true && study?.sections[1].text.contains("Page 2 ") == false)

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
    private static func taskRouting(_ check: (String, Bool) -> Void) {
        func desk() -> URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
        func dl() -> URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
        check("tasks: tidy my desktop", TaskRouter.parse("tidy my desktop") == .tidy(desk()))
        check("tasks: clean up downloads", TaskRouter.parse("Hey, clean up my downloads folder please") == .tidy(dl()))
        check("tasks: organize screenshots means the desktop", TaskRouter.parse("organize my screenshots") == .tidy(desk()))
        check("tasks: a bare 'tidy' in the box defaults to the desktop, but not by voice", TaskRouter.parse("tidy up") == .tidy(desk()) && TaskRouter.parse("tidy up", strict: true) == nil)
        check("tasks: find a file", TaskRouter.parse("find the PDF about elasticity") == .find("find the PDF about elasticity"))
        check("tasks: where's my file", TaskRouter.parse("where's my tax return pdf", strict: true) != nil)
        check("tasks: a question isn't a task by voice", TaskRouter.parse("where is Paris", strict: true) == nil && TaskRouter.parse("how do I find the derivative", strict: true) == nil)
        let pdf = URL(fileURLWithPath: "/tmp/econ.pdf")
        check("tasks: study notes from a dropped file", TaskRouter.parse("summarize chapter 4 and make flashcards", files: [pdf]) == .study(pdf, hint: "summarize chapter 4 and make flashcards"))
        check("tasks: by voice, 'summarize' needs a book, chapter or file", TaskRouter.parse("summarize chapter 4 of my econ textbook", strict: true) != nil
              && TaskRouter.parse("summarize this paragraph", strict: true) == nil)
        check("tasks: convert HEIC", TaskRouter.parse("convert my HEIC photos to JPG") == .batch(.heicToJpg, []))
        check("tasks: merge PDFs", TaskRouter.parse("merge these PDFs", files: [pdf, URL(fileURLWithPath: "/tmp/b.pdf")]) == .batch(.mergePDFs, [pdf, URL(fileURLWithPath: "/tmp/b.pdf")]))
        check("tasks: read text from images", TaskRouter.parse("extract text from these screenshots") == .batch(.ocrToText, []))
        check("tasks: gibberish is nothing", TaskRouter.parse("banana") == nil && TaskRouter.parse("") == nil)
        check("voice: calendar still wins", CommandCenter.route("add tidy desktop to my calendar tomorrow at 9") == .calendar)
        check("voice: a file job routes to the agents", CommandCenter.route("tidy my desktop") == .task(.tidy(desk())))
        check("voice: a question still goes to Claude", CommandCenter.route("why does ice float") == .ask)
        check("tasks: the limits are the three folders", FileSafety.defaultRoots.count == 3)
        approvalChecks(check)
        customAgentChecks(check)
        savingChecks(check)
    }
}

extension FeatureTests {
    /// What an agent asks, what Allow and Deny do with it.
    static func approvalChecks(_ check: (String, Bool) -> Void) {
        let move = FileSafety.Op.move(URL(fileURLWithPath: "/tmp/a.pdf"), to: URL(fileURLWithPath: "/tmp/PDFs/a.pdf"))
        let trash = FileSafety.Op.trash(URL(fileURLWithPath: "/tmp/old.dmg"))
        var plan = TaskPlan(headline: "Tidy Downloads: 3 changes", groups: [
            PlanGroup(key: "sort:pdf", title: "Sort 2 PDFs", symbol: "doc", ops: [move, move]),
            PlanGroup(key: "old-installers", title: "Move 1 old installer to the Trash", symbol: "trash", ops: [trash], removes: true),
        ])
        check("approve: the plan says what Allow would do (\(plan.summary))", plan.summary == "3 changes · 1 to the Trash")
        plan.groups[1].enabled = false
        check("approve: the summary follows what's switched on (\(plan.summary))", plan.summary == "2 changes")
        plan.groups[0].enabled = false
        check("approve: nothing switched on means nothing to allow", !plan.canApprove)
        plan.groups[0].enabled = true
        check("approve: something switched on can be allowed", plan.canApprove)

        let task = BackgroundTask(kind: .tidy, title: "Tidy Downloads")
        task.plan = plan
        check("approve: not before it's asking", !task.canQuickApprove)
        task.state = .needsApproval
        check("approve: a plan can be allowed from the bar", task.canQuickApprove)
        var ran = 0
        task.onApprove = { _ in ran += 1 }
        TaskEngine.shared.approve(task)
        check("approve: Allow runs the plan", ran == 1)
        TaskEngine.shared.approve(BackgroundTask(kind: .tidy, title: "not asking"))
        check("approve: Allow on an agent that isn't asking does nothing", ran == 1)

        let denied = BackgroundTask(kind: .tidy, title: "Tidy Desktop")
        denied.plan = plan
        denied.state = .needsApproval
        var ranDenied = 0
        denied.onApprove = { _ in ranDenied += 1 }
        TaskEngine.shared.deny(denied)
        check("approve: Deny stops the agent and says nothing changed", denied.state == .cancelled && denied.detail.contains("Denied") && denied.plan == nil)
        TaskEngine.shared.approve(denied)
        check("approve: a denied agent can't be allowed afterwards", ranDenied == 0)

        let study = BackgroundTask(kind: .study, title: "Study")
        study.chooser = TaskChooser(heading: "Which parts?", items: [.init(id: "0", title: "Ch 1", on: true)], optionsHeading: "Make",
                                    options: [.init(id: "summary", title: "Summary", on: true)])
        study.state = .needsApproval
        check("approve: a choice (which chapters, what it costs) is made on the card, not allowed blind", !study.canQuickApprove)
        check("approve: but it can still be allowed there", { var ok = false; study.onApprove = { _ in ok = true }; TaskEngine.shared.approve(study); return ok }())
        check("approve: the bar says how many parts are picked (\(study.approvalSummary))", study.approvalSummary.contains("1 of 1"))
    }
}

extension FeatureTests {
    /// Margin --catsheet <png>: every coat in every pose (sit, the 4 run frames, loaf), on white and on the bar's black.
    static func catSheet(path: String) -> Never {
        let poses: [PixelCat.Pose] = [.sit, .run(0), .run(1), .run(2), .run(3), .loaf]
        let scale = 4
        let cw = (PixelCat.width + 2 * PixelCat.pad) * scale, ch = (PixelCat.height + 2 * PixelCat.pad) * scale
        let gap = 8
        let cols = poses.count * 2, rows = PixelCat.coats.count
        let W = cols * (cw + gap) + gap, H = rows * (ch + gap) + gap
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W / 2, height: H))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: W / 2, y: 0, width: W - W / 2, height: H))
        for r in 0..<rows {
            for (i, pose) in poses.enumerated() {
                for half in 0..<2 {
                    guard let img = PixelCat.image(coat: r, pose: pose, scale: scale) else { continue }
                    let c = half * poses.count + i
                    ctx.draw(img, in: CGRect(x: gap + c * (cw + gap), y: H - (r + 1) * (ch + gap), width: cw, height: ch))
                }
            }
        }
        guard let image = ctx.makeImage() else { exit(1) }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("CATSHEET saved \(path)")
        exit(0)
    }
}

extension FeatureTests {
    /// Margin --agentbartest <dir>: the agent bar. Chats and agents are kept apart; minimized it's a strip on the right
    /// edge, expanded it's a bar at the top centre; each agent has its own cat (sitting, running, loaf); an agent that
    /// needs your OK expands the bar and shows Allow and Deny right on its cat (and on its card); Allow carries the plan
    /// out, Deny changes nothing; the bar stays up while something waits on you. Uses temporary folders and no Claude.
    /// Saves pictures of the bar, the strip and the card to <dir>.
    static func agentBarTest(directory: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let fm = FileManager.default
        let out = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let base = fm.temporaryDirectory.appendingPathComponent("margin-bartest-\(UUID().uuidString)")
        FileSafety.ledgerDirectory = base.appendingPathComponent("ledgers")

        /// A messy folder, like a real Downloads: lots of kinds, an old installer, a duplicate, so the plan is long.
        func messyFolder(_ name: String) -> URL {
            let folder = base.appendingPathComponent(name)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [(String, String, Double)] = [("essay.docx", "essay", 6), ("report.docx", "report", 7), ("old.dmg", "dmg", 45),
                                                     ("new.dmg", "dmg2", 2), ("archive.zip", "zip", 4), ("talk.mp4", "mp4", 8),
                                                     ("song.mp3", "mp3", 9), ("copy of essay.docx", "essay", 1), ("data.csv", "csv", 3)]
            for i in 1...6 { files.append(("paper \(i).pdf", "pdf \(i)", Double(i))) }
            for i in 1...4 { files.append(("photo \(i).jpg", "jpg \(i)", Double(i))) }
            for (n, body, age) in files {
                let url = folder.appendingPathComponent(n)
                try? Data(body.utf8).write(to: url)
                let d = Date().addingTimeInterval(-age * 86400)
                try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: url.path)
            }
            return folder
        }
        let first = messyFolder("Desktop"), second = messyFolder("Downloads")
        FileSafety.roots = [first, second]

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let bar = AgentBar.shared
        let dock = AgentDock()

        func shot(_ name: String) {
            if let rep = bar.debugImage() { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-bar.png")) }
            // The card's own blur isn't in the snapshot, so it's drawn over the dark-mode popover colour.
            if bar.card.isShowing, let image = bar.card.debugImage,
               let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                if let flat = ctx.makeImage() {
                    try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-card.png"))
                }
            }
        }
        func stripShot(_ name: String) {
            if let rep = bar.debugStripImage() { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-strip.png")) }
        }
        func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func until(_ seconds: Double = 30, _ done: @MainActor () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if await done() { return true }
                await sleep(0.1)
            }
            return false
        }
        func centre(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }
        func exists(_ name: String, in folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(name).path) }

        Task { @MainActor in
            // Minimized: a strip on the right edge, half-way down.
            bar.start()
            let vfMain = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let s0 = bar.debugStrip
            check("minimized, it's a strip on the right edge, half-way down (frame \(s0.frame))", s0.visible && s0.alpha > 0.95
                  && abs(s0.frame.maxX - (vfMain.maxX - AgentBar.Layout.stripInset)) < 1.5 && abs(s0.frame.midY - vfMain.midY) < 1.5)
            check("  and the bar isn't showing", !bar.isShowing)
            stripShot("0-empty")

            // Stand-ins for the other states, so every cat pose is on the bar at once.
            let running = BackgroundTask(kind: .study, title: "Study: Econ ch. 4")
            running.detail = "Writing summaries: 2 of 5"
            running.fraction = 0.4
            let done = BackgroundTask(kind: .find, title: "Find: elasticity PDF")
            done.state = .done
            done.report = TaskReport(headline: "Found 3 files")
            TaskEngine.shared.debugTrack(running)
            TaskEngine.shared.debugTrack(done)
            check("agents aren't in the chat sidebar", dock.debugSidebar.debugRowCount == 0)

            // A real Tidy that needs approval.
            guard let tidy = TaskEngine.shared.start(.tidy(first)) else { print("AGENTBARTEST FAIL"); exit(1) }
            let asked = await until(60) { tidy.state == .needsApproval }
            check("the Tidy agent made a plan and is asking", asked)
            _ = await until(5) { bar.isShowing && bar.debugBarAlpha > 0.95 }
            await sleep(0.6)
            let f = bar.debugFrame
            let vf = NSScreen.screens.first { $0.frame.intersects(f) }?.visibleFrame ?? .zero
            check("an agent that needs your OK expands the bar by itself", bar.isShowing && bar.debugBarAlpha > 0.95)
            check("  and the strip is gone meanwhile", !bar.debugStrip.visible || bar.debugStrip.alpha < 0.05)
            check("  at the top centre of the screen (frame \(f))", abs(f.maxY - (vf.maxY - AgentBar.Layout.topGap)) < 1.5 && abs(f.midX - vf.midX) < 1.5)
            check("  with three cats, each a different cat", bar.model.tasks.count == 3 && Set(bar.model.tasks.map { bar.model.coat($0) }).count == 3)
            check("  running, sitting (needs OK) and loaf", AgentSlotView.mood(running) == .running && AgentSlotView.mood(tidy) == .idle
                  && AgentSlotView.mood(done) == .done)
            let i = bar.model.tasks.firstIndex { $0 === tidy } ?? -1
            let r = bar.slotRect(i)
            let card = bar.card.debugState
            check("  and its card open under its cat, big enough for the plan", bar.card.isShowing && bar.card.task === tidy && card.frame.maxY < f.minY
                  && card.frame.height > 300)
            check("chats still aren't in the sidebar", dock.debugSidebar.debugRowCount == 0)
            shot("1-asking")

            // The buttons on the cat.
            check("the cat shows what it wants to do (\(tidy.approvalSummary))", tidy.approvalSummary.contains("change"))
            check("it can be allowed from the bar", tidy.canQuickApprove)
            check("Allow is where it's drawn", bar.hit(at: centre(AgentBar.Layout.allowRect(inSlot: r))) == .allow(i))
            check("Deny is where it's drawn", bar.hit(at: centre(AgentBar.Layout.denyRect(inSlot: r))) == .deny(i))
            let runIndex = bar.model.tasks.firstIndex { $0 === running } ?? 0
            check("an agent that isn't asking has no buttons", bar.hit(at: centre(AgentBar.Layout.allowRect(inSlot: bar.slotRect(runIndex)))) == .slot(runIndex))
            check("a click on the cat itself is the cat", bar.hit(at: NSPoint(x: r.minX + 30, y: r.midY)) == .slot(i))
            check("the far right is the minimize button", bar.hit(at: NSPoint(x: f.width - 18, y: 30)) == .minimize)
            check("next to it is +", bar.hit(at: NSPoint(x: f.width - AgentBar.Layout.pad - AgentBar.Layout.minimizeWidth - 20, y: 30)) == .newJob)

            // Clicking in another app: the bar stays while something is waiting for you (only the card goes).
            bar.debugClickElsewhere()
            await sleep(0.5)
            check("a click elsewhere keeps the bar up while an agent waits for you", bar.isShowing && bar.debugBarAlpha > 0.95)
            check("  and only puts the card away", !bar.card.isShowing)
            bar.handle(.slot(i))
            await sleep(0.5)
            check("clicking the cat brings the card back", bar.card.isShowing && bar.card.task === tidy)
            bar.handle(.slot(i))
            await sleep(0.4)
            check("clicking it again puts the card away", !bar.card.isShowing)
            bar.handle(.slot(i))
            bar.card.hide()
            await sleep(0.04)
            bar.handle(.slot(i)) // a click while the card is still fading out
            await sleep(0.6)
            print("   after the fade-out click: showing \(bar.card.isShowing) \(bar.card.debugState) open \(String(describing: bar.model.openID))")
            check("a click during the fade-out still leaves the card showing", bar.card.isShowing && bar.card.debugState.alpha > 0.95)

            // Minimize and expand.
            bar.hide()
            await sleep(0.8)
            let st = bar.debugStrip
            check("minimizing flies it back to the strip", !bar.isShowing && bar.debugBarAlpha < 0.05 && st.visible && st.alpha > 0.95)
            check("  which has a cat per agent (frame \(st.frame))", st.frame.height > s0.frame.height + 40)
            stripShot("1-three-agents")
            bar.stripClicked()
            await sleep(1.0)
            check("clicking the strip expands the bar", bar.isShowing && bar.debugBarAlpha > 0.95)
            check("  with the waiting agent's card already open", bar.card.isShowing && bar.card.task === tidy)

            // Allow, from the cat.
            let before = (exists("essay.docx", in: first), exists("old.dmg", in: first))
            check("before Allow nothing has moved", before.0 && before.1)
            bar.handle(.allow(i))
            check("Allow closes the card at once", !bar.card.isShowing && tidy.state == .working)
            let finished = await until(30) { tidy.state == .done }
            check("Allow on the cat carries the plan out", finished)
            await sleep(0.8)
            check("  and when it's done its card comes back with what it did", bar.card.isShowing && bar.card.task === tidy)
            check("  the files were sorted", !exists("essay.docx", in: first) && exists("Documents/essay.docx", in: first))
            check("  and the old installer left the folder", !exists("old.dmg", in: first))
            await sleep(0.6)
            check("when it's done its cat is a loaf", AgentSlotView.mood(tidy) == .done)
            shot("2-done")

            // Deny, from the cat: a second agent, a second folder.
            print("   before the 4th agent: bar \(bar.debugFrame.width) wide, \(bar.model.tasks.count) cats")
            guard let other = TaskEngine.shared.start(.tidy(second)) else { print("AGENTBARTEST FAIL"); exit(1) }
            await sleep(0.5)
            print("   0.5 s after starting it: bar \(bar.debugFrame.width) wide, \(bar.model.tasks.count) cats, expanded \(bar.isShowing)")
            _ = await until(60) { other.state == .needsApproval }
            await sleep(0.8)
            check("a second agent asks and gets its own cat", other.state == .needsApproval && bar.model.tasks.contains { $0 === other }
                  && bar.model.coat(other) != bar.model.coat(tidy))
            let j = bar.model.tasks.firstIndex { $0 === other } ?? -1
            check("  and its Deny button is where it's drawn", bar.hit(at: centre(AgentBar.Layout.denyRect(inSlot: bar.slotRect(j)))) == .deny(j))
            shot("3-second-asking")
            bar.handle(.deny(j))
            await sleep(0.5)
            check("Deny stops the agent", other.state == .cancelled)
            check("  and says so on its cat (\(AgentSlotView.status(other).text))", AgentSlotView.status(other).text.contains("Denied"))
            check("  nothing was changed", exists("essay.docx", in: second) && exists("old.dmg", in: second) && !exists("Documents", in: second))
            check("  its cat just sits there", AgentSlotView.mood(other) == .idle)
            check("  and it stays listed", bar.model.tasks.contains { $0 === other })
            let want4 = 2 * AgentBar.Layout.pad + 4 * AgentBar.Layout.slotWidth + 3 * AgentBar.Layout.gap + AgentBar.Layout.gap
                + AgentBar.Layout.newJobWidth + AgentBar.Layout.minimizeWidth
            check("the bar widened for four cats (\(bar.debugFrame.width) of \(want4))", abs(bar.debugFrame.width - want4) < 2 && bar.model.tasks.count == 4)
            shot("4-denied")

            // An open-ended job that would spend a lot of tokens asks first, saying what it costs.
            let big = BackgroundTask(kind: .custom, title: "Rename my 400 PDFs")
            big.gate = TaskGate(headline: "This is a bigger job",
                                detail: "To plan it, Claude would read the names, sizes and ages of 400 items (never what's inside them), about 7.4k tokens. That's more than a small request. Go ahead?",
                                summary: "≈7.4k tokens · 400 items")
            big.detail = "Waiting for your OK (about 7.4k tokens)"
            var wentAhead = 0
            big.onApprove = { t in wentAhead += 1; t.gate = nil; t.state = .working }
            TaskEngine.shared.debugTrack(big)
            await sleep(0.3)
            big.state = .needsApproval // the change is what opens the card
            await sleep(1.2)
            check("a costly job asks first, with its card open", bar.card.isShowing && bar.card.task === big)
            check("  the cat says what it costs (\(AgentSlotView.status(big).text))", AgentSlotView.status(big).text.contains("tokens") || big.approvalSummary.contains("tokens"))
            shot("5-gate")
            let gi = bar.model.tasks.firstIndex { $0 === big } ?? -1
            check("  its Allow button is where it's drawn", gi >= 0 && bar.hit(at: centre(AgentBar.Layout.allowRect(inSlot: bar.slotRect(gi)))) == .allow(gi))
            bar.handle(.allow(gi))
            await sleep(0.3)
            check("  Allow on the cat means go ahead", wentAhead == 1 && big.gate == nil)
            TaskEngine.shared.dismiss(big)
            await sleep(0.5)

            // Nothing is waiting now, so a click elsewhere puts the bar away as usual.
            bar.debugClickElsewhere()
            await sleep(0.8)
            check("with nothing waiting, a click elsewhere minimizes the bar", !bar.isShowing && bar.debugStrip.alpha > 0.95)
            stripShot("2-after")
            bar.toggle()
            await sleep(0.8)
            check("⌘⇧A brings it back", bar.isShowing)
            let doneIndex = bar.model.tasks.firstIndex { $0 === done } ?? 0
            check("a finished agent has a ×", bar.model.closable(doneIndex))
            check("a running one doesn't", !bar.model.closable(runIndex))
            let n = bar.model.tasks.count
            bar.handle(.close(doneIndex))
            await sleep(0.5)
            check("× takes it off the bar", bar.model.tasks.count == n - 1 && !bar.model.tasks.contains { $0 === done })
            bar.handle(.minimize)
            await sleep(0.8)
            check("the minimize button minimizes it", !bar.isShowing && bar.debugStrip.alpha > 0.95)

            // Rapid toggling (a nervous finger, or an agent finishing mid-animation) must never strand the bar half-visible.
            var consistent = 0
            let gaps: [[Double]] = [[0.03, 0.03, 0.03, 0.03, 0.03], [0.1, 0.05, 0.2, 0.02, 0.15], [0.0, 0.0, 0.0, 0.0, 0.0], [0.3, 0.1, 0.1, 0.1, 0.4],
                                    [0.05, 0.12, 0.05, 0.12, 0.05, 0.12]]
            for pattern in gaps {
                for gap in pattern {
                    bar.toggle()
                    await sleep(gap)
                }
                await sleep(1.2)
                let s = bar.debugStrip
                let ok = bar.isShowing
                    ? (bar.debugBarAlpha > 0.95 && (!s.visible || s.alpha < 0.05))
                    : (bar.debugBarAlpha < 0.05 && s.visible && s.alpha > 0.95)
                if ok { consistent += 1 } else {
                    print("   inconsistent after \(pattern): expanded \(bar.isShowing) bar alpha \(bar.debugBarAlpha) strip \(s)")
                }
            }
            check("rapid expand/minimize toggling always ends in a clean state (\(consistent) of \(gaps.count))", consistent == gaps.count)

            bar.hide()
            for t in TaskEngine.shared.tasks { TaskEngine.shared.dismiss(t) }
            try? fm.removeItem(at: base)
            print(failures == 0 ? "AGENTBARTEST PASS" : "AGENTBARTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { print("AGENTBARTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}

extension FeatureTests {
    /// Margin --taskdemo <dir>: Tidy on a fake messy desktop (in a temporary folder; your real folders are never touched):
    /// scan, read the screenshots, show the plan, approve with Claude naming the screenshots (a real, small call), check the
    /// result, undo, check again. Saves pictures of the sidebar and the card at each step.
    @MainActor
    static func taskDemo(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let fm = FileManager.default
        let out = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let base = fm.temporaryDirectory.appendingPathComponent("margin-taskdemo-\(UUID().uuidString)")
        let desktop = base.appendingPathComponent("Desktop")
        try? fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        FileSafety.roots = [desktop]
        FileSafety.ledgerDirectory = base.appendingPathComponent("ledgers")
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func png(_ text: String, name: String, age: TimeInterval) {
            let w = 900, h = 420
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(in: CGRect(x: 30, y: 30, width: w - 60, height: h - 60), withAttributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            guard let image = ctx.makeImage() else { return }
            let url = desktop.appendingPathComponent(name)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            let d = Date().addingTimeInterval(-age)
            try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: url.path)
        }
        png("Supply and Demand\nWhen demand rises, price and quantity both go up.", name: "Screenshot 2026-10-02 at 9.14.05 AM.png", age: 3600 * 24 * 11)
        png("Closures in Swift\nA closure captures variables by reference.", name: "Screenshot 2026-10-05 at 2.30.41 PM.png", age: 3600 * 24 * 8)
        png("Opportunity cost is the value of the next best alternative.", name: "Screenshot 2026-10-09 at 4.02.10 PM.png", age: 3600 * 24 * 4)
        let day: Double = 3600 * 24
        let others: [(String, String, Double)] = [
            ("lecture-notes.pdf", "pdf", day * 5), ("essay draft.docx", "doc", day * 6), ("Zoom.dmg", "dmg", day * 70),
            ("IMG_2041.jpg", "jpg", day * 3), ("copy of notes.txt", "same", day * 2), ("notes.txt", "same", day * 9),
        ]
        for (n, text, age) in others {
            let url = desktop.appendingPathComponent(n)
            try? Data(text.utf8).write(to: url)
            let d = Date().addingTimeInterval(-age)
            try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: url.path)
        }
        let dock = AgentDock()
        func shot(_ name: String) {
            if let rep = AgentBar.shared.debugImage() { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-bar.png")) }
            if let image = AgentBar.shared.card.debugImage { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-card.png")) }
            print("  saved \(name)")
        }
        guard let task = TaskEngine.shared.start(.tidy(desktop)) else { print("TASKDEMO FAIL"); exit(1) }
        var stage = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            switch (stage, task.state) {
            case (0, .working):
                shot("1-working")
                stage = 1
            case (0, .needsApproval), (1, .needsApproval):
                stage = 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    shot("2-plan")
                    let groups = task.plan?.groups.map(\.key) ?? []
                    check("the plan has screenshots, PDFs, documents, installers, images, duplicates", Set(groups) == ["sort:screenshot", "sort:pdf", "sort:document", "sort:installer", "sort:image", "duplicates", "old-installers"] || groups.count >= 5)
                    check("it offers smart names with a token estimate", task.plan?.options.first?.detail.contains("tokens") == true)
                    check("nothing has moved yet", fm.fileExists(atPath: desktop.appendingPathComponent("Screenshot 2026-10-02 at 9.14.05 AM.png").path))
                    task.plan?.options[0].on = true // let Claude name them (a real, small call)
                    task.onApprove?(task)
                    stage = 3
                }
            case (3, .done):
                stage = 4
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    shot("3-done")
                    let shots = (try? fm.contentsOfDirectory(atPath: desktop.appendingPathComponent("Screenshots").path)) ?? []
                    print("   screenshots folder: \(shots)")
                    let sub = shots.flatMap { m in ((try? fm.contentsOfDirectory(atPath: desktop.appendingPathComponent("Screenshots/\(m)").path)) ?? []).map { "\(m)/\($0)" } }
                    print("   named: \(sub)")
                    check("screenshots were sorted into month folders", sub.count == 3)
                    check("Claude named them from what's in them", sub.contains { $0.localizedCaseInsensitiveContains("demand") || $0.localizedCaseInsensitiveContains("supply") }
                          && sub.contains { $0.localizedCaseInsensitiveContains("closure") } && sub.contains { $0.localizedCaseInsensitiveContains("opportunity") })
                    check("the task recorded Claude's tokens", task.tokens > 0)
                    print("   tokens used: \(task.tokens)")
                    check("PDF, document and image were sorted", fm.fileExists(atPath: desktop.appendingPathComponent("PDFs").path)
                          && fm.fileExists(atPath: desktop.appendingPathComponent("Documents/essay draft.docx").path))
                    check("the old installer left the desktop", !fm.fileExists(atPath: desktop.appendingPathComponent("Zoom.dmg").path))
                    check("the duplicate copy was removed, the original kept", fm.fileExists(atPath: desktop.appendingPathComponent("Documents/notes.txt").path)
                          && !fm.fileExists(atPath: desktop.appendingPathComponent("copy of notes.txt").path))
                    check("Undo is offered", task.canUndo)
                    task.onUndo?(task)
                    stage = 5
                }
            case (5, _) where task.undone:
                stage = 6
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    shot("4-undone")
                    check("undo put the desktop back exactly", fm.fileExists(atPath: desktop.appendingPathComponent("Screenshot 2026-10-02 at 9.14.05 AM.png").path)
                          && fm.fileExists(atPath: desktop.appendingPathComponent("Zoom.dmg").path) && fm.fileExists(atPath: desktop.appendingPathComponent("copy of notes.txt").path)
                          && !fm.fileExists(atPath: desktop.appendingPathComponent("Screenshots").path))
                    try? fm.removeItem(at: base)
                    print(failures == 0 ? "TASKDEMO PASS" : "TASKDEMO FAIL (\(failures))")
                    exit(failures == 0 ? 0 : 1)
                }
            default:
                if case .failed(let m) = task.state { print("TASKDEMO FAIL: \(m)"); exit(1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { print("TASKDEMO FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}
