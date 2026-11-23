import Foundation

extension FeatureTests {
    /// Commands that act and do not start a chat (R4): the router reads them by strict rules (zero tokens), questions stay
    /// questions, calendar and video keep priority, and the runner's result lines are right. Fake actions and a throwaway
    /// Library: no windows, no Claude.
    static func commandChecks(_ check: (String, Bool) -> Void) {
        let sheets = ["Microeconomics terms", "Physics terms", "Macro note"]
        func r(_ text: String, _ names: [String] = sheets) -> CommandCenter.Route {
            CommandCenter.route(CommandCenter.cleaned(text), sheets: names)
        }
        /// The text alone, with "Hey Merlin," in front, and with a full stop / question mark / "!" at the end.
        func all(_ text: String, _ expected: CommandCenter.Route, _ names: [String] = sheets) -> Bool {
            [text, "Hey Merlin, " + text, "hey merlin " + text, text + ".", text + "!", "Hey Merlin, " + text + "?"]
                .allSatisfy { r($0, names) == expected }
        }

        // MARK: Each route
        check("commands: 'open microeconomics note' opens it", all("open microeconomics note", .openNote("microeconomics")))
        check("commands: 'Open the Microeconomics note please'", r("Open the Microeconomics note please") == .openNote("Microeconomics"))
        check("commands: 'show the balance sheet' and 'open the cheat sheet' are questions, not commands",
              r("show the balance sheet") == .ask && r("open the cheat sheet") == .ask && r("show me a balance sheet", []) == .ask)
        check("commands: 'go to my physics notes' / 'bring up the macro note'",
              all("go to my physics notes", .openNote("physics")) && all("bring up the macro note", .openNote("macro")))
        check("commands: 'open note called macro terms'", all("open the note called macro terms", .openNote("macro terms")))
        check("commands: 'show my physics terms' opens the sheet of that exact name",
              all("show my physics terms", .openNote("physics terms")))
        check("commands: …but not when there is no such sheet", r("show my physics terms", []) == .ask && r("show my physics terms", ["Chemistry"]) == .ask)
        check("commands: 'add this to microeconomics terms' (sheet exists)", all("add this to microeconomics terms", .addToNote("microeconomics terms")))
        check("commands: …and stays a question with no such sheet", r("add this to microeconomics terms", []) == .ask)
        check("commands: 'add that to my macro note'", all("add that to my macro note", .addToNote("macro")))
        check("commands: 'put it in my physics note' / 'save the answer to the physics note' / 'add to physics note'",
              r("put it in my physics note") == .addToNote("physics") && r("save the answer to the physics note") == .addToNote("physics")
              && r("add to physics note") == .addToNote("physics"))
        check("commands: 'make a new note called macro terms'", all("make a new note called macro terms", .newNote("macro terms")))
        check("commands: 'create a note named X' / 'new note X' / 'start a new sheet called X'",
              all("create a note named Revision plan", .newNote("Revision plan")) && all("new note called chemistry", .newNote("chemistry"))
              && r("start a new sheet called chemistry") == .newNote("chemistry"))
        check("commands: 'show my chats' / 'open chats' / 'show me my chats'",
              all("show my chats", .openChats) && r("open chats") == .openChats && r("show me my chats") == .openChats)
        check("commands: 'show my notes' / 'open notes' / 'go to my notes'",
              all("show my notes", .openNotes) && all("open notes", .openNotes) && r("go to my notes") == .openNotes)
        check("commands: a sheet's exact name works without the word 'note'",
              r("open microeconomics terms") == .openNote("microeconomics terms") && r("open Macro") == .openNote("Macro"))
        check("commands: 'open economy' opens a sheet named Economy only if one exists",
              r("open economy") == .ask && r("open economy", ["Economy"]) == .openNote("economy"))

        // MARK: Not commands
        let questions = ["what is an open economy", "open economy", "show me how supply shifts", "add 5 and 7",
                         "make a table of terms", "create a study plan", "explain my notes on elasticity",
                         "show my notes on elasticity", "how do I open a note", "can you show my notes", "is my note saved",
                         "does open source mean free", "make a note", "make a new note", "start a new note",
                         "create a note about photosynthesis", "make notes on chapter 4", "make a note of this",
                         "save this to my notes", "add this to the list", "open the notes app",
                         "open a new note", "show me pictures of cats", "open YouTube",
                         "make a note of the deadline", "make a note to call mum", "create a note in my physics folder",
                         "make a sheet of practice problems", "make note cards", "create sheet music", "start note taking",
                         "new note chemistry", "create a note called", "make a new note called about photosynthesis",
                         "open the microeconomics note and then explain the second term to me in detail please now"]
        let wrong = questions.filter { r($0) != .ask || r("Hey Merlin, " + $0) != .ask }
        check("commands: questions and near-commands stay questions (\(wrong.joined(separator: " | ")))", wrong.isEmpty)
        check("commands: more than 12 words is never a command",
              r("open the microeconomics note right now because I need to read it for my test") == .ask)

        // MARK: Calendar and video keep priority
        check("commands: 'add lunch with Anna to my calendar tomorrow at 1' stays calendar",
              r("add lunch with Anna to my calendar tomorrow at 1") == .calendar)
        check("commands: 'summarize this video' stays video", r("Hey Merlin, summarize this video") == .video(.youtube(id: nil)))
        check("commands: old callers (no sheets) still route as before",
              CommandCenter.route("add lunch to my calendar tomorrow at noon") == .calendar && CommandCenter.route("why is the sky blue") == .ask)
        check("commands: isNoteCommand is only true for the five new routes",
              CommandCenter.Route.openNote("x").isNoteCommand && CommandCenter.Route.openChats.isNoteCommand
              && !CommandCenter.Route.calendar.isNoteCommand && !CommandCenter.Route.ask.isNoteCommand
              && !CommandCenter.Route.video(.listenAlong).isNoteCommand)

        // MARK: Typed and spoken give the same route
        let both = ["open microeconomics note", "Hey Merlin, add this to my macro note.", "make a new note called macro terms",
                    "show my chats", "open notes", "what is an open economy", "add lunch with Anna to my calendar tomorrow at 1"]
        let same = both.allSatisfy { text in
            let typed = CommandRunner.commandRoute(text, sheets: sheets)
            let spoken = CommandCenter.route(CommandCenter.cleaned(text), sheets: sheets)
            return typed == (spoken.isNoteCommand ? spoken : nil)
        }
        check("commands: the typed path and the spoken path give the same route", same)
        check("commands: the typed path gives nil for questions, calendar and video",
              CommandRunner.commandRoute("what is an open economy", sheets: sheets) == nil
              && CommandRunner.commandRoute("add lunch with Anna to my calendar tomorrow at 1", sheets: sheets) == nil
              && CommandRunner.commandRoute("summarize this video", sheets: sheets) == nil)

        // MARK: The runner (fake actions, throwaway Library)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merlin-commands-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = Library(directory: dir)
        var opened: [UUID] = []
        var shown: [EdgePanelModel.Section] = []
        var answer: String? = nil
        var panelCanShow = true
        let runner = CommandRunner(library: library,
                                   openSheet: { opened.append($0) },
                                   appendAnswer: { SheetActions.append(answer: answer, toSheetNamed: $0, library: library) },
                                   showPanel: { shown.append($0); return panelCanShow })

        check("runner: no sheets at all → 'You have no notes yet.'",
              runner.run(.openNote("microeconomics")) == "You have no notes yet." && opened.isEmpty)
        answer = "Elasticity is how much demand reacts to price."
        check("runner: add with no sheets at all → 'You have no notes yet.'", runner.run(.addToNote("macro")) == "You have no notes yet.")
        answer = nil

        let micro = library.createSheet(named: "Microeconomics terms")
        library.createSheet(named: "Macroeconomics terms")
        library.createSheet(named: "Physics terms")
        check("runner: open → 'Opened Microeconomics terms' and opens that sheet",
              runner.run(.openNote("microeconomics")) == "Opened Microeconomics terms" && opened.last == micro?.id)
        let before = opened.count
        let miss = runner.run(.openNote("microeconomic"))
        check("runner: a near-miss name does not match and gives the two closest (\(miss ?? "nil"))",
              miss == "No note with that name. Closest: Microeconomics terms, Macroeconomics terms." && opened.count == before)
        check("runner: add with no finished answer → 'There is no answer to add yet.'",
              runner.run(.addToNote("microeconomics")) == "There is no answer to add yet.")
        answer = "| Term | Meaning |\n|---|---|\n| Elasticity | How much demand reacts to price |"
        check("runner: add → 'Added to Microeconomics terms', and the sheet has the answer",
              runner.run(.addToNote("microeconomics terms")) == "Added to Microeconomics terms"
              && (library.findSheet("microeconomics").sheet?.markup.contains("Elasticity") ?? false))
        check("runner: add to an unknown name gives the closest, never a guess",
              runner.run(.addToNote("chemistry"))?.hasPrefix("No note with that name. Closest: ") == true
              && !(library.findSheet("physics").sheet?.markup.contains("Elasticity") ?? true))
        let made = runner.run(.newNote("macro notes list"))
        check("runner: new → 'Made the note Macro notes list' and opens it (\(made ?? "nil"))",
              made == "Made the note Macro notes list" && library.sheets.contains { $0.name == "Macro notes list" }
              && opened.last == library.findSheet("macro notes list").sheet?.id)
        let count = library.sheets.count
        check("runner: new with a name that exists → opens it, says so, makes no second sheet",
              runner.run(.newNote("physics terms")) == "That note exists already. Opened it."
              && library.sheets.count == count && opened.last == library.findSheet("physics").sheet?.id)
        check("runner: 'Showing your chats' / 'Showing your notes' and the panel gets the list",
              runner.run(.openChats) == "Showing your chats" && runner.run(.openNotes) == "Showing your notes" && shown == [.chats, .notes])
        panelCanShow = false
        check("runner: a panel that can't show says so (never a false 'Showing')", runner.run(.openChats) == CommandRunner.panelBusy)
        check("runner: not a note command → nil", runner.run(.ask) == nil && runner.run(.calendar) == nil)
        check("runner: a full spoken command end to end",
              runner.commandRoute("Hey Merlin, open the physics note.").flatMap(runner.run) == "Opened Physics terms")
        check("runner: titled keeps the words and capitalises only the first letter",
              CommandRunner.titled("macro terms") == "Macro terms" && CommandRunner.titled(" GDP ") == "GDP")
    }
}
