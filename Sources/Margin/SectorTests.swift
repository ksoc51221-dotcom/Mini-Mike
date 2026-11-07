import Foundation

extension FeatureTests {
    /// User sectors: create, rename, merge, delete, reorder; descriptions in the prompt; rules; re-file preview; undo.
    static func sectorChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("margin-sectortest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let library = Library(directory: dir)

        func chat(_ title: String, _ sector: String, app: String = "Safari", quote: String = "", locked: Bool = false) -> ChatRecord {
            var c = ChatRecord(title: title, sector: sector, app: app, quote: quote, turns: [.init(question: title, answer: "Because.")])
            c.sectorLocked = locked
            return c
        }
        let variance = chat("Variance vs standard deviation", "Other", quote: "regression and variance")
        let parabola = chat("Plot a parabola", "Other", app: "Desmos")
        let closure = chat("Closures in Swift", "Computer Science")
        let mine = chat("My own filing", "Other", quote: "variance again", locked: true)
        let lang = chat("Past tense", "Language")
        for c in [variance, parabola, closure, mine, lang] { library.save(c) }
        library.flush()

        // Seeding and saving
        let store = SectorStore(directory: dir, library: library)
        check("sectors: seeded from the defaults", Sector.defaults.allSatisfy { store.names.contains($0) })
        check("sectors: Other is last", store.names.last == Sector.other)
        check("sectors: nothing is written until something changes", !fm.fileExists(atPath: store.fileURL.path))
        check("sectors: the first eight hues are all different", Set(store.sectors.prefix(8).map(\.colorIndex)).count == 8)
        check("sectors: repeated hues change shape",
              store.sectors.contains { $0.colorIndex == 0 && $0.glyph != .circle })
        check("sectors: Theme has the eight hues", Theme.sectorHues.count == 8 && Theme.sectorHueNames.count == 8)
        check("sectors: the library lists them", library.allSectors.first == store.names.first)

        // Create
        let stats = store.create(name: "  Statistics  ", description: "statistics, calculus, anything with formulas")
        check("sectors: create trims and adds above Other", stats?.name == "Statistics" && store.names.last == Sector.other
              && store.names.firstIndex(of: "Statistics")! < store.names.count - 1)
        check("sectors: a duplicate name is refused (any case)", store.create(name: "statistics") == nil && store.create(name: "   ") == nil)
        check("sectors: a long name is cut to 24", store.create(name: String(repeating: "x", count: 40))?.name.count == 24)
        check("sectors: saved to sectors.json", fm.fileExists(atPath: store.fileURL.path))
        let reloaded = SectorStore(directory: dir, library: Library(directory: dir.appendingPathComponent("elsewhere")))
        check("sectors: they survive a restart", reloaded.sector(named: "Statistics")?.description.hasPrefix("statistics") == true)

        // Style
        let s0 = store.style(for: "Math")
        check("sectors: style gives colour and shape", s0.1 == store.sector(named: "Math")?.glyph)
        check("sectors: an unknown name gets a quiet circle", store.style(for: "Nope").1 == .circle)

        // Prompt: only non-empty descriptions
        let hints = store.hints
        check("sectors: hints skip empty descriptions", hints.count == 1 && hints["Statistics"] != nil)
        let rule = Prompts.metaRule(["Math", "Statistics"], hints: hints)
        check("sectors: the meta rule carries the description", rule.contains("Statistics = statistics, calculus"))
        check("sectors: …but not for sectors without one", !rule.contains("Math ="))
        check("sectors: no descriptions, no extra words", !Prompts.metaRule(["Math"]).contains("Sector guide"))
        check("sectors: the guide stays short", Prompts.metaRule(["A"], hints: ["A": String(repeating: "w", count: 500)]).count < 520)
        check("sectors: the library hands out hints", library.sectorHintsForPrompt["Statistics"] != nil)
        check("sectors: naming prompt carries them too", ChatNaming.system(sectors: ["Statistics"], hints: hints).contains("Statistics = statistics"))

        // Rules
        let mathID = store.sector(named: "Math")!.id
        store.update(mathID) { $0.keywords = ["variance", "regression"]; $0.apps = ["Desmos"] }
        check("rules: a keyword files a chat", store.ruleMatch(for: variance) == "Math")
        check("rules: an app files a chat", store.ruleMatch(for: parabola) == "Math")
        check("rules: no rule, no match", store.ruleMatch(for: closure) == nil)
        store.update(store.sector(named: "Computer Science")!.id) { $0.keywords = ["ode"] }
        check("rules: short keywords match whole words only", store.ruleMatch(for: chat("Code review", "Other")) == nil)
        check("rules: a rule beats Claude's guess on save",
              { var c = chat("Variance of a sample", "Physics"); library.save(c); c = library.chat(c.id)!; return c.sector == "Math" }())
        check("rules: …but never on a locked chat", { library.save(mine); return library.chat(mine.id)?.sector == "Other" }())
        let autoNamed = chat("Spread of data", "Other", quote: "variance")
        library.save(autoNamed)
        library.applyAutoName(autoNamed.id, title: nil, sector: "Biology")
        check("rules: …and beats the auto-name too", library.chat(autoNamed.id)?.sector == "Math")

        // Re-file preview and apply, with undo
        library.save(variance) // resaving files it by rule already; put it back to test the preview
        _ = library.applySectors([variance.id: "Other", parabola.id: "Other"], lock: false)
        let preview = store.refilePreview()
        check("refile: lists unlocked chats a rule would move", Set(preview.map(\.id)).isSuperset(of: [variance.id, parabola.id]))
        check("refile: never lists a locked chat", !preview.contains { $0.id == mine.id })
        check("refile: previewing changes nothing", library.chat(variance.id)?.sector == "Other")
        let undo = store.applyRefile(preview, only: [variance.id])
        check("refile: only the ticked chat moves", library.chat(variance.id)?.sector == "Math" && library.chat(parabola.id)?.sector == "Other")
        check("refile: the lock stays as it was", library.chat(variance.id)?.sectorLocked == false)
        library.undo(undo)
        check("refile: undo puts it back", library.chat(variance.id)?.sector == "Other" && library.chat(variance.id)?.sectorLocked == false)
        _ = library.applySectors([mine.id: "Biology"], lock: nil)
        check("refile: a chat locked after the preview is skipped",
              store.applyRefile([RefileMove(id: mine.id, title: "x", from: "Other", to: "Math")], only: [mine.id]).isEmpty
              && library.chat(mine.id)?.sector == "Biology")

        // Moving many chats
        let u = library.move(ids: [variance.id, parabola.id], toSector: "Physics")
        check("move(ids): files and locks them all",
              [variance.id, parabola.id].allSatisfy { library.chat($0)?.sector == "Physics" && library.chat($0)?.sectorLocked == true })
        library.undo(u)
        check("move(ids): undo restores sector and lock",
              library.chat(variance.id)?.sector == "Other" && library.chat(variance.id)?.sectorLocked == false)

        // Rename
        let physicsID = store.sector(named: "Physics")!.id
        library.save(chat("Newton's second law", "Physics", locked: true))
        check("rename: refused when the name is taken", !store.rename(physicsID, to: "math"))
        check("rename: works", store.rename(physicsID, to: "Physical Science"))
        check("rename: re-files the chats (even locked ones)",
              library.chats.filter { $0.sector == "Physical Science" }.count == 1 && !library.chats.contains { $0.sector == "Physics" })
        check("rename: Other can't be renamed", !store.rename(store.sector(named: Sector.other)!.id, to: "Misc"))

        // Merge
        let before = library.chats.filter { $0.sector == "Math" }.count
        let statsID = store.sector(named: "Statistics")!.id
        library.save(chat("Mean and median", "Statistics"))
        check("merge: a into b", store.merge(mathID, into: statsID))
        check("merge: a is gone, its chats are in b", store.sector(named: "Math") == nil
              && library.chats.filter { $0.sector == "Statistics" }.count == before + 1)
        check("merge: b gets a's rules", Set(store.sector(statsID)!.keywords).isSuperset(of: ["variance", "regression"]))
        check("merge: not into itself", !store.merge(statsID, into: statsID))

        // Delete
        let csID = store.sector(named: "Computer Science")!.id
        check("delete: works", store.delete(csID))
        check("delete: its chats go to Other", library.chat(closure.id)?.sector == Sector.other && store.sector(named: "Computer Science") == nil)
        check("delete: Other stays", !store.delete(store.sector(named: Sector.other)!.id) && store.sector(named: Sector.other) != nil)
        check("delete: it's gone from the prompt list", !library.sectorsForPrompt.contains("Computer Science"))

        // Reorder
        let first = store.names[0]
        store.reorder(from: IndexSet(integer: 0), to: 3)
        check("reorder: moves a sector", store.names[2] == first && store.sectors.map(\.order) == Array(0..<store.sectors.count))
        let again = SectorStore(directory: dir, library: Library(directory: dir.appendingPathComponent("elsewhere")))
        check("reorder: persists", again.names == store.names)

        // A new name from Claude is adopted
        library.save(chat("Light and lenses", "Optics Lab"))
        check("sync: a sector Claude coined joins the list", store.sector(named: "Optics Lab") != nil)

        // Help me describe
        let titles = SectorDescriber.titles(for: "Language", in: library)
        check("describe: sends the chat titles of that sector", titles == ["Past tense"])
        let long = Library(directory: dir.appendingPathComponent("many"))
        for i in 1...12 { long.save(chat("Chat number \(i)", "Math")) }
        check("describe: at most 8 titles", SectorDescriber.titles(for: "Math", in: long).count == 8)
        check("describe: the prompt names the sector", SectorDescriber.prompt(sector: "Math", titles: ["a"]).contains("Section name: Math"))
        let parsed = SectorDescriber.parse("```json\n{\"description\": \"Statistics and calculus.\", \"keywords\": [\"Mean\", \"mean\", \"integral\", \"a\", \"b\", \"c\", \"d\", \"e\"]}\n```")
        check("describe: reads one sentence and up to 6 unique keywords",
              parsed?.description == "Statistics and calculus." && parsed?.keywords == ["mean", "integral", "a", "b", "c", "d"])
        check("describe: nonsense is nil", SectorDescriber.parse("hello") == nil)
        let saved = SectorDescriber.claudeRun
        defer { SectorDescriber.claudeRun = saved }
        var seenPrompt = "", seenModel = ModelChoice.sonnet, got: SectorDescriber.Suggestion?
        SectorDescriber.claudeRun = { prompt, _, model, done in
            seenPrompt = prompt
            seenModel = model
            done(.success(ClaudeOneShot.Reply(text: "{\"description\": \"Foreign languages.\", \"keywords\": [\"grammar\"]}", usage: .init())))
        }
        SectorDescriber.describe(sector: "Language", in: library) { if case .success(let s) = $0 { got = s } }
        check("describe: runs on Haiku with the titles", seenModel == .haiku && seenPrompt.contains("Past tense"))
        check("describe: hands back the suggestion", got == SectorDescriber.Suggestion(description: "Foreign languages.", keywords: ["grammar"]))
        glyphChecks(check)
    }

    static func glyphChecks(_ check: (String, Bool) -> Void) {
        let old = #"[{"id":"7B0E3A52-1C2D-4E55-9A10-3F6D2B7C8E01","name":"Math","order":0,"colorIndex":1,"glyph":"diamond","description":"calculus","keywords":["integral"],"apps":[]}]"#
        let decoded = try? JSONDecoder().decode([UserSector].self, from: Data(old.utf8))
        check("glyphs: old sector JSON without icon decodes", decoded?.first?.icon == nil && decoded?.first?.glyph == .diamond && decoded?.first?.colorIndex == 1)
        let bare = try? JSONDecoder().decode([UserSector].self, from: Data(#"[{"name":"Old","order":2,"colorIndex":3}]"#.utf8))
        check("glyphs: very old sector JSON decodes", bare?.first?.name == "Old")
        if var s = decoded?.first {
            s.icon = .galaxy
            let back = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(UserSector.self, from: $0) }
            check("glyphs: icon round-trips", back?.icon == .galaxy)
        }
        let names = ["Math", "Physics", "Chemistry", "Biology", "Computer Science", "Economics", "Language", "History", "Writing", "Health", "Business", "Other"]
        check("glyphs: 12 defaults map to 12 distinct glyphs", Set(names.map { GlyphKind.defaultFor(sector: $0) }).count == 12)
        check("glyphs: unknown names pick the same glyph every time",
              GlyphKind.defaultFor(sector: "Thesis") == GlyphKind.defaultFor(sector: "Thesis") && GlyphKind.extras.contains(GlyphKind.defaultFor(sector: "Thesis")))
        check("glyphs: every glyph has a title", GlyphKind.allCases.allSatisfy { !$0.title.isEmpty })
        check("glyphs: at least 28 glyphs, pickable excludes status", GlyphKind.allCases.count >= 28 && GlyphKind.sectorPickable.allSatisfy { !GlyphKind.status.contains($0) })
    }
}
