import Foundation

extension FeatureTests {
    /// Sheets (named notes, R2): old library files still load and keep every field; adding to a sheet joins matching
    /// tables and puts the rest under a dated divider; names match without guessing; Tidy never loses text; MCP and
    /// search see sheets. Everything runs in a throwaway folder and never calls Claude.
    static func sheetChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merlin-sheets-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let notesDir = dir.appendingPathComponent("notes", isDirectory: true)
        let binDir = dir.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // MARK: Old files (written before sheets existed: no name, markup or updated)
        let oldID = UUID(), chatID = UUID(), binnedID = UUID(), futureID = UUID()
        let oldNote = """
        {"app":"Safari","body":"The extra cost of one more unit.","chatID":"\(chatID.uuidString)","created":"2026-10-01T10:00:00Z","id":"\(oldID.uuidString)","kind":"answer","question":"Define marginal cost","quote":"MC = dTC/dQ","sector":"Economics","title":"Marginal cost"}
        """
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let oldBin = """
        {"deleted":"\(recent)","id":"\(binnedID.uuidString)","kind":"note","note":{"app":"Preview","body":"Second syllable.","created":"2026-09-02T08:30:00Z","id":"\(binnedID.uuidString)","kind":"missed","question":"Which is stressed in zamok?","quote":"","sector":"Language","title":"Russian stress"}}
        """
        let futureNote = """
        {"app":"","body":"From a newer Merlin.","created":"2026-11-01T10:00:00Z","id":"\(futureID.uuidString)","kind":"future-kind","question":"Q","quote":"","sector":"Other","title":"Future"}
        """
        try? Data(oldNote.utf8).write(to: notesDir.appendingPathComponent("\(oldID.uuidString).json"))
        try? Data(futureNote.utf8).write(to: notesDir.appendingPathComponent("\(futureID.uuidString).json"))
        let garbage = notesDir.appendingPathComponent("garbage.json")
        try? Data("this is not JSON {".utf8).write(to: garbage)
        try? Data(oldBin.utf8).write(to: binDir.appendingPathComponent("note-\(binnedID.uuidString).json"))

        let library = Library(directory: dir)
        let loaded = library.notes.first { $0.id == oldID }
        check("sheets: an old note file (no name/markup) loads with all its old fields",
              loaded?.title == "Marginal cost" && loaded?.question == "Define marginal cost" && loaded?.body == "The extra cost of one more unit."
              && loaded?.app == "Safari" && loaded?.quote == "MC = dTC/dQ" && loaded?.sector == "Economics" && loaded?.chatID == chatID
              && loaded?.kind == .answer && loaded?.name == "" && loaded?.markup == "" && loaded?.updated == nil
              && loaded?.created == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        check("sheets: a note with a kind this version doesn't know still loads (as a kept answer)",
              library.notes.first { $0.id == futureID }?.body == "From a newer Merlin." && library.notes.first { $0.id == futureID }?.kind == .answer)
        let binned = library.binItem(binnedID)
        check("sheets: an old Bin item holding a note loads", binned?.note?.question == "Which is stressed in zamok?" && binned?.note?.kind == .missed)
        check("sheets: the old Bin note can be put back", library.restore(binnedID) && library.notes.first { $0.id == binnedID }?.app == "Preview")

        // A re-save (a sector rename writes the note again) keeps every old field.
        library.replaceSector("Economics", with: "Econ")
        library.flush()
        let raw = (try? Data(contentsOf: notesDir.appendingPathComponent("\(oldID.uuidString).json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check("sheets: a re-saved old note keeps every old field",
              raw["title"] as? String == "Marginal cost" && raw["question"] as? String == "Define marginal cost"
              && raw["body"] as? String == "The extra cost of one more unit." && raw["app"] as? String == "Safari"
              && raw["quote"] as? String == "MC = dTC/dQ" && raw["sector"] as? String == "Econ"
              && raw["chatID"] as? String == chatID.uuidString && raw["kind"] as? String == "answer"
              && raw["created"] as? String == "2026-10-01T10:00:00Z" && raw["id"] as? String == oldID.uuidString)
        check("sheets: a note file that can't be read is never deleted (load, save, delete, flush)",
              { library.delete(note: futureID); library.flush(); _ = Library(directory: dir); return fm.fileExists(atPath: garbage.path) }())

        // MARK: Store
        guard let econ = library.createSheet(named: "Microeconomics terms") else { check("sheets: create", false); return }
        check("sheets: a new sheet is a named note with empty markup", econ.isSheet && econ.name == "Microeconomics terms" && econ.markup.isEmpty
              && econ.question == "Microeconomics terms")
        check("sheets: a second sheet with the same name gives the first back", library.createSheet(named: "microeconomics  Terms")?.id == econ.id
              && library.sheets.count == 1)
        check("sheets: an empty name makes nothing", library.createSheet(named: "  ") == nil)
        let physics = library.createSheet(named: "Physics formulas")!
        check("sheets: rename works, a taken name is refused",
              library.renameSheet(physics.id, to: "Physics terms") && !library.renameSheet(physics.id, to: "Microeconomics terms")
              && library.sheet(physics.id)?.name == "Physics terms")
        library.appendToSheet(econ.id, "Hello")
        check("sheets: most recently changed comes first", library.sheets.first?.id == econ.id)
        let reloadedSheet = Library(directory: { library.flush(); return dir }()).sheet(econ.id)
        check("sheets: a sheet round-trips through its file", reloadedSheet?.name == "Microeconomics terms" && reloadedSheet?.markup == "Hello"
              && reloadedSheet?.kind == .sheet && reloadedSheet?.updated != nil)
        library.deleteSheet(physics.id)
        check("sheets: deleting a sheet moves it to the Bin", library.sheet(physics.id) == nil && library.binItem(physics.id)?.note?.name == "Physics terms")
        check("sheets: a sheet comes back from the Bin", library.restore(physics.id) && library.sheet(physics.id)?.name == "Physics terms")

        // MARK: Merge
        let date = ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!
        let sheetMD = """
        Intro line.

        | Term | Definition |
        |:-----|-----------:|
        | Elasticity | Responsiveness of demand |
        | Utility | Satisfaction |

        A closing remark.
        """
        let more = """
        | term | definition  |
        |---|---|
        | Utility | Satisfaction |
        | Marginal cost | Cost of one more unit |
        """
        let merged = SheetMerge.append(markup: sheetMD, adding: more, date: date)
        check("merge: rows join a table with the same header (case and spaces ignored)",
              merged.contains("| Utility | Satisfaction |\n| Marginal cost | Cost of one more unit |\n\nA closing remark."))
        check("merge: a duplicate row is skipped", merged.components(separatedBy: "| Utility | Satisfaction |").count == 2)
        check("merge: the rest of the sheet is unchanged (alignment row, blank lines, prose)",
              merged.hasPrefix("Intro line.\n\n| Term | Definition |\n|:-----|-----------:|\n| Elasticity |") && merged.hasSuffix("A closing remark.")
              && !merged.contains("---\n\n*"))
        check("merge: only duplicates and nothing else: the sheet is unchanged",
              SheetMerge.append(markup: sheetMD, adding: "| Term | Definition |\n|---|---|\n| Utility | Satisfaction |", date: date) == sheetMD)
        let prose = SheetMerge.append(markup: "Just words.", adding: "More words.", date: date)
        check("merge: a sheet with no table: new content goes under a dated divider", prose == "Just words.\n\n---\n\n*23 Nov 2026*\n\nMore words.")
        let other = SheetMerge.append(markup: sheetMD, adding: "| Name | Year |\n|---|---|\n| Smith | 1776 |", date: date)
        check("merge: a table with other columns goes under the divider", other.hasPrefix(sheetMD) && other.hasSuffix("*23 Nov 2026*\n\n| Name | Year |\n|---|---|\n| Smith | 1776 |"))
        let mixed = SheetMerge.append(markup: sheetMD, adding: "Here are more:\n\n| Term | Definition |\n|---|---|\n| Price | What you pay |\n\nHope that helps.", date: date)
        check("merge: matching rows join, the prose around them goes under the divider",
              mixed.contains("| Price | What you pay |\n\nA closing remark.") && mixed.hasSuffix("*23 Nov 2026*\n\nHere are more:\n\nHope that helps."))
        check("merge: an empty sheet just takes the content", SheetMerge.append(markup: "  \n", adding: more, date: date) == more)
        check("merge: a table inside a code fence is not a table",
              SheetMerge.tables(in: "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```".components(separatedBy: "\n")).isEmpty)

        // MARK: Names
        let names = ["Microeconomics terms", "Macroeconomics", "Physics formulas", "My notes"]
        check("names: case-free and filler words ignored", SheetNames.match("my MICROECONOMICS note", in: names).match == "Microeconomics terms"
              && SheetNames.match("the microeconomics", in: names).match == "Microeconomics terms"
              && SheetNames.match("physics formulas sheet", in: names).match == "Physics formulas")
        let near = SheetNames.match("microeconomic", in: names)
        check("names: a near miss is never guessed; the two closest names are offered",
              near.match == nil && near.closest.count == 2 && near.closest.first == "Microeconomics terms")
        let none = SheetNames.match("chemistry", in: names)
        check("names: no close match gives no match and two names", none.match == nil && none.closest.count == 2)
        check("names: a name of only filler words still matches itself", SheetNames.match("my notes", in: names).match == "My notes")
        let twin = SheetNames.match("micro", in: ["Micro terms", "micro notes"])
        check("names: two sheets that read the same: neither is picked, both are offered", twin.match == nil && Set(twin.closest) == ["Micro terms", "micro notes"])
        check("names: the store finds a sheet by name", library.findSheet("microeconomics").sheet?.id == econ.id && library.findSheet("micro").sheet == nil)

        // MARK: Save to note
        let answer = """
        Here are the terms:

        | Term | Definition |
        |---|---|
        | Lock | <say lang="ru-RU">замок</say> means lock |
        | ==Cost== | $C = F + V$ |

        <graph>{"type":"line"}</graph>
        <meta title="Terms" sector="Economics"/>
        """
        let md = SheetActions.markup(fromAnswer: answer)
        check("save to note: the table markup is kept, a <say> inside a cell keeps its words in its row",
              md.contains("| Lock | замок means lock |") && md.contains("| ==Cost== | $C = F + V$ |") && md.contains("|---|---|"))
        check("save to note: Merlin's tags (<graph>, <meta>, <say>) are removed", !md.contains("<graph") && !md.contains("<meta") && !md.contains("<say"))
        library.setMarkup(econ.id, "")
        SheetActions.saveAnswer(answer, toSheet: econ.id, library: library, date: date)
        check("save to note: an empty sheet takes the answer as Markdown", library.sheet(econ.id)?.markup == md)
        let newSheet = SheetActions.saveAnswer(answer, toNewSheet: "Russian words", library: library)
        check("save to note: New note… makes a named sheet with the answer", newSheet?.name == "Russian words" && newSheet?.markup == md)
        check("save to note: by name (R4) saves, or offers names without guessing",
              SheetActions.append(answer: "| Term | Definition |\n|---|---|\n| Rent | Payment |", toSheetNamed: "microeconomics terms", library: library, date: date) == .saved(name: "Microeconomics terms")
              && library.sheet(econ.id)?.markup.contains("| Rent | Payment |") == true
              && { if case .noMatch(let c) = SheetActions.append(answer: "x", toSheetNamed: "chemistry", library: library) { return c.count == 2 } else { return false } }()
              && SheetActions.append(answer: nil, toSheetNamed: "microeconomics", library: library) == .nothingToSave)

        // MARK: Tidy (a fake Claude; no real call)
        let realRun = SheetTidy.claudeRun
        defer { SheetTidy.claudeRun = realRun }
        func fake(_ result: Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) {
            SheetTidy.claudeRun = { _, _, done in done(result) }
        }
        let before = "elasticity - how much demand moves\nutility = satisfaction"
        library.setMarkup(econ.id, before)
        var outcome: SheetTidy.Outcome?
        fake(fakeReply("```markdown\n| Term | Definition |\n|---|---|\n| Elasticity | How much demand moves |\n| Utility | Satisfaction |\n```"))
        SheetTidy.run(sheet: econ.id, library: library) { outcome = $0 }
        let tidied = "| Term | Definition |\n|---|---|\n| Elasticity | How much demand moves |\n| Utility | Satisfaction |"
        check("tidy: success replaces the text (its code fence removed)", library.sheet(econ.id)?.markup == tidied && outcome == .tidied(old: before, new: tidied))
        check("tidy: Undo is kept outside the page, so it survives looking at another note",
              SheetTidy.undoable(econ.id, library: library) == outcome)
        check("tidy: undo restores the old text", outcome.map { SheetTidy.undo($0, sheet: econ.id, library: library) } == true
              && library.sheet(econ.id)?.markup == before)
        check("tidy: a second undo does nothing (the text is not the tidied one any more)",
              outcome.map { SheetTidy.undo($0, sheet: econ.id, library: library) } == false && library.sheet(econ.id)?.markup == before
              && SheetTidy.undoable(econ.id, library: library) == nil)
        fake(.failure(.failed("network down")))
        SheetTidy.run(sheet: econ.id, library: library) { outcome = $0 }
        check("tidy: a failure keeps the old text and says so", library.sheet(econ.id)?.markup == before
              && { if case .failed(let m) = outcome { return m.contains("unchanged") } else { return false } }())
        fake(fakeReply("   \n "))
        SheetTidy.run(sheet: econ.id, library: library) { outcome = $0 }
        check("tidy: an empty reply keeps the old text", library.sheet(econ.id)?.markup == before && { if case .failed = outcome { return true } else { return false } }())
        SheetTidy.claudeRun = { _, _, done in
            library.setMarkup(econ.id, before + "\nmy new line") // you typed while Claude worked
            done(fakeReply("Rewritten"))
        }
        SheetTidy.run(sheet: econ.id, library: library) { outcome = $0 }
        check("tidy: an edit made while Claude worked is kept", library.sheet(econ.id)?.markup == before + "\nmy new line")
        var sentPrompt = "", sentSystem = ""
        SheetTidy.claudeRun = { p, s, done in sentPrompt = p; sentSystem = s; done(.failure(.timedOut)) }
        SheetTidy.run(sheet: econ.id, instruction: "make a table of term, definition, formula", library: library) { _ in }
        check("tidy: the note and your instruction are what is sent", sentPrompt == before + "\nmy new line"
              && sentSystem.contains("keep every fact") && sentSystem.contains("term, definition, formula"))

        // MARK: Edit → Done never drops text that arrived meanwhile
        check("edit: text added at the end while editing joins the edit",
              SheetEdit.commit(draft: "A edited", base: "A", current: "A\n\nB", date: date) == "A edited\n\nB")
        check("edit: any other change while editing is kept under a divider",
              SheetEdit.commit(draft: "A edited", base: "A", current: "Z", date: date) == "A edited\n\n---\n\n*23 Nov 2026*\n\nZ")
        check("edit: an untouched draft keeps a row that joined a table mid-sheet (no duplicate)",
              SheetEdit.commit(draft: "| A | B |\n|---|---|\n| 1 | 2 |\n\nEnd.", base: "| A | B |\n|---|---|\n| 1 | 2 |\n\nEnd.",
                               current: "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nEnd.", date: date) == "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nEnd.")
        let twoBlocks = "```swift\nlet a = 1\n```\n\n```python\nb = 2\n```"
        check("save to note: code blocks are kept exactly; only a fence around a dropped graph goes",
              SheetActions.markup(fromAnswer: twoBlocks) == twoBlocks
              && SheetActions.markup(fromAnswer: "Look:\n```json\n<graph>{\"a\":1}</graph>\n```\nDone.") == "Look:\n\nDone.")
        check("edit: a divider line splits the page; one inside code does not",
              SheetEdit.sections("a\n\n---\n\nb\n```\n---\n```").count == 2)

        // MARK: Search and MCP
        library.setMarkup(econ.id, MarkdownTable.economicsSample)
        library.flush()
        check("search: a sheet is found by its name", library.search(notes: "microeconomics").contains { $0.id == econ.id })
        check("search: a sheet is found by the text in a table cell", library.search(notes: "willing").contains { $0.id == econ.id })
        let server = MCPServer(directory: dir)
        func tool(_ name: String, _ args: String) -> String {
            let reply = server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
            let obj = reply.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return ((obj?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        }
        let got = tool("get_note", #"{"id":"\#(econ.id.uuidString)"}"#)
        check("mcp: get_note returns a sheet's markup (tables as tables)", got.hasPrefix("# Microeconomics terms") && got.contains(MarkdownTable.economicsSample))
        check("mcp: search_library finds a sheet by name and by cell text",
              tool("search_library", #"{"query":"microeconomics"}"#).contains(econ.id.uuidString)
              && tool("search_library", #"{"query":"willing"}"#).contains(econ.id.uuidString))
    }
}
