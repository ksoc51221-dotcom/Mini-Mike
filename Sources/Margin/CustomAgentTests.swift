import AppKit

/// Where the tests put the chats they open: the bottom-right corner of the main screen, so they never cover the middle of the
/// screen where you're working. (A chat there grows upward as its answer fills in. Test chats are click-through anyway: they
/// can't take clicks or typing.)
enum TestSpot {
    static func mouse(on screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]) -> NSPoint {
        NSPoint(x: screen.visibleFrame.maxX - 40, y: screen.visibleFrame.minY + 40)
    }
}

extension FeatureTests {
    /// A made-up set of folders named like the real ones.
    struct FakeHome {
        let base: URL
        let desktop: URL, downloads: URL, documents: URL
        var roots: [URL] { [desktop, downloads, documents] }

        init() {
            let fm = FileManager.default
            base = fm.temporaryDirectory.appendingPathComponent("margin-custom-\(UUID().uuidString)")
            desktop = base.appendingPathComponent("Desktop")
            downloads = base.appendingPathComponent("Downloads")
            documents = base.appendingPathComponent("Documents")
            for d in roots { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        }

        @discardableResult
        func make(_ path: String, in root: URL, daysOld: Int = 0, bytes: Int = 10) -> URL {
            let fm = FileManager.default
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 65, count: bytes))
            if daysOld > 0 { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(daysOld) * 86_400)], ofItemAtPath: url.path) }
            return url
        }

        /// Five screenshots in a Screenshots folder, a note, a hidden file, an app, and an old PDF in Downloads.
        func fill() {
            for n in 1...5 { make("Screenshots/Screenshot \(n).png", in: desktop) }
            make("notes.txt", in: desktop)
            make(".hidden", in: desktop)
            try? FileManager.default.createDirectory(at: desktop.appendingPathComponent("Thing.app/Contents"), withIntermediateDirectories: true)
            make("old.pdf", in: downloads, daysOld: 60)
            make("new.pdf", in: downloads)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// Runs the main loop until `done()` or the time runs out.
    static func pump(_ seconds: TimeInterval = 8, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func fakeReply(_ text: String, tokens: Int = 600) -> Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure> {
        .success(ClaudeOneShot.Reply(text: text, usage: ClaudeSession.Usage(inputTokens: tokens - 100, outputTokens: 100)))
    }

    /// A Finder that remembers what it was asked and answers like the real one (every icon was at 5,6).
    final class FakeFinder: @unchecked Sendable {
        var scripts: [String] = []
        var denied = false
        var selection: [String] = []

        func run(_ script: String) -> (output: String, error: String) {
            scripts.append(script)
            if denied { return ("", "execution error: Not authorized to send Apple events to Finder. (-1743)") }
            if script.contains("selection as alias list") { return (selection.joined(separator: "\n") + "\n", "") }
            var out = "ARR\tsnap to grid\n"
            let pattern = try! NSRegularExpression(pattern: #"set p to position of item "((?:[^"\\]|\\.)*)" of desktop"#)
            let ns = script as NSString
            for m in pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
                out += "POS\t\(ns.substring(with: m.range(at: 1)))\t5\t6\n"
            }
            return (out, "")
        }
    }

    static func customAgentChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let savedRoots = FileSafety.roots, savedLedgers = FileSafety.ledgerDirectory, savedRunner = FinderDesktop.runner
        let savedDesktop = CustomAgent.desktopRoot, savedAsk = CustomAgent.ask, savedGate = CustomAgent.gateTokens, savedHard = CustomAgent.hardLimitTokens
        let home = FakeHome()
        home.fill()
        FileSafety.roots = home.roots
        FileSafety.ledgerDirectory = home.base.appendingPathComponent("ledgers")
        CustomAgent.desktopRoot = home.desktop
        let finder = FakeFinder()
        FinderDesktop.runner = { finder.run($0) }
        let savedLocal = CustomAgent.localPlanning
        CustomAgent.localPlanning = false // these tests are about Claude's plans; the Mac's own rules come at the end
        defer {
            CustomAgent.localPlanning = savedLocal
            FileSafety.roots = savedRoots; FileSafety.ledgerDirectory = savedLedgers; FinderDesktop.runner = savedRunner
            CustomAgent.desktopRoot = savedDesktop; CustomAgent.ask = savedAsk; CustomAgent.gateTokens = savedGate; CustomAgent.hardLimitTokens = savedHard
            home.remove()
        }

        // MARK: Understanding the request
        func isCustom(_ s: String, strict: Bool = false) -> Bool {
            if case .custom = TaskRouter.parse(s, strict: strict) ?? .find("") { return true } else { return false }
        }
        check("custom: “scatter these screenshots” is a custom job", isCustom("Scatter these screenshots"))
        check("custom: the user's own words are a custom job",
              isCustom("take all the screenshots out of the Screenshots folder and scatter them around the desktop"))
        check("custom: …also by voice", isCustom("scatter my screenshots around the desktop", strict: true))
        check("custom: renaming files", isCustom("rename my pdfs Paper 1, Paper 2 and so on"))
        check("custom: putting files somewhere", isCustom("put all my pdfs into a Papers folder"))
        check("custom: tidying with a how is a custom job, not the stock tidy", isCustom("tidy my desktop and put the pdfs into a Papers folder"))
        check("custom: plain “tidy my desktop” is still the Tidy agent", { if case .tidy = TaskRouter.parse("tidy my desktop") ?? .find("") { return true } else { return false } }())
        check("custom: “organize my screenshots” is still the Tidy agent", { if case .tidy = TaskRouter.parse("organize my screenshots") ?? .find("") { return true } else { return false } }())
        check("custom: a photo request isn't a file job by voice", !isCustom("take a photo of the whiteboard", strict: true)
              && !isCustom("remove the background from this image", strict: true))
        check("custom: a question isn't a file job", !isCustom("why does ice float") && !isCustom("what's the capital of France", strict: true))
        check("custom: the pitch sentence, typed or spoken", isCustom("Take all my screenshots and scatter them around the desktop.")
              && isCustom("Take all my screenshots and scatter them around the desktop.", strict: true)
              && CommandCenter.route("Take all my screenshots and scatter them around the desktop.") == .task(.custom("Take all my screenshots and scatter them around the desktop.")))
        check("custom: gibberish is nothing", TaskRouter.parse("banana") == nil)
        check("custom: a custom job is routed by voice", CommandCenter.route("scatter my screenshots around the desktop") == .task(.custom("scatter my screenshots around the desktop")))
        check("custom: titles are short", CustomAgent.title(for: "take all the screenshots out of the Screenshots folder").count <= 33)

        // MARK: What Claude is shown
        let listing = CustomAgent.list(roots: [home.desktop])
        check("list: the Desktop's folders and files (\(listing.entries.count) items)", listing.entries.count == 7) // notes.txt, Screenshots/ and its 5 pngs
        check("list: no hidden files and no apps", !listing.entries.contains { $0.name == ".hidden" || $0.name == "Thing.app" })
        check("list: grouped by folder, with sizes and ages", listing.text.contains("Desktop/Screenshots:") && listing.text.contains("|Screenshot 1.png|1|0"))
        check("list: a folder's name ends in a slash", listing.text.contains("|Screenshots/|"))
        check("list: ids count up from 1", listing.entries.map(\.id) == Array(1...listing.entries.count))
        let second = home.desktop.appendingPathComponent("Screenshots/Screenshot 2.png").standardizedFileURL.resolvingSymlinksInPath().path
        let marked = CustomAgent.list(roots: [home.desktop], selected: [second])
        check("list: what's selected in Finder is starred", marked.entries.filter(\.selected).map(\.name) == ["Screenshot 2.png"]
              && marked.text.contains("*\(marked.entries.first { $0.selected }!.id)|Screenshot 2.png"))
        check("list: it's capped, and says how many are left out", { let l = CustomAgent.list(roots: [home.desktop], limit: 3); return l.entries.count == 3 && l.notShown > 0 && l.text.contains("more items not shown") }())
        let dl = CustomAgent.list(roots: [home.downloads])
        check("list: ages are in days", dl.entries.first { $0.name == "old.pdf" }?.ageDays == 60 && dl.entries.first { $0.name == "new.pdf" }?.ageDays == 0)
        check("list: kinds", listing.entries.first { $0.name == "Screenshot 1.png" }?.kind == "image" && dl.entries.first { $0.name == "old.pdf" }?.kind == "pdf")

        check("scope: the Desktop unless it says otherwise", CustomAgent.scope(for: "scatter my screenshots", roots: home.roots) == [home.desktop])
        check("scope: Downloads when named", CustomAgent.scope(for: "delete old files in my downloads", roots: home.roots) == [home.downloads])
        check("scope: everywhere means all three", CustomAgent.scope(for: "find duplicates everywhere", roots: home.roots).count == 3)
        check("selection: “these” means what's selected", CustomAgent.refersToSelection("scatter these screenshots") && !CustomAgent.refersToSelection("scatter my screenshots"))

        // MARK: Choosing files
        func ids(_ v: Any?) -> [String] { CustomAgent.resolve(v, in: listing).map(\.name) }
        let shots = (1...5).map { "Screenshot \($0).png" }
        check("choose: by folder and extension", ids(["under": "Desktop/Screenshots", "ext": ["png"]]) == shots)
        check("choose: by a folder's own name", ids(["under": "Screenshots"]) == shots)
        check("choose: by words in the name", ids(["name": "nothing like this"]).isEmpty && ids(["name": "Screenshot 3"]) == ["Screenshot 3.png"] && ids(["name": "shot 3"]) == ["Screenshot 3.png"])
        check("choose: by kind", ids(["kind": "image"]) == shots)
        check("choose: by ids", CustomAgent.resolve([2, 3] as [Any], in: listing).map(\.id) == [2, 3] && CustomAgent.resolve("1, 3", in: listing).map(\.id) == [1, 3])
        check("choose: “all” leaves folders out", ids("all") == ["notes.txt"] + shots)
        check("choose: folders only when asked", ids(["kind": "folder"]) == ["Screenshots"])
        check("choose: nothing selected means nothing", ids("selected").isEmpty)
        check("choose: marked ones", CustomAgent.resolve("selected", in: marked).map(\.name) == ["Screenshot 2.png"])
        let oldList = CustomAgent.list(roots: [home.downloads])
        check("choose: older than N days", CustomAgent.resolve(["olderThanDays": 30], in: oldList).map(\.name) == ["old.pdf"])
        check("choose: newer than N days", CustomAgent.resolve(["newerThanDays": 30], in: oldList).map(\.name) == ["new.pdf"])

        // MARK: Reading Claude's plan
        let scatterJSON = """
        ```json
        {"say":"I'll bring the screenshots onto the Desktop and scatter them.","steps":[
         {"do":"move","files":{"under":"Desktop/Screenshots","ext":["png"]},"to":"Desktop","label":"Move 5 screenshots onto the Desktop"},
         {"do":"place","files":{"under":"Desktop/Screenshots","ext":["png"]},"layout":"scatter"}]}
        ```
        """
        let parsed = CustomAgent.parsePlan(scatterJSON, listing: listing)
        check("plan: Claude's JSON is read, even in a code fence", parsed?.steps.count == 2 && parsed?.notes.isEmpty == true)
        check("plan: …each step keeps its files", parsed?.steps.first?.files.count == 5 && parsed?.steps.last?.files.count == 5)
        check("plan: …and its own label", parsed?.steps.first?.label == "Move 5 screenshots onto the Desktop")
        check("plan: a missing label is filled in", parsed?.steps.last?.label.contains("Scatter 5 icons") == true)
        let groups = parsed.map { p in p.steps.enumerated().map { CustomAgent.group(for: $1, index: $0) } } ?? []
        check("plan: it's shown as groups with files to look at", groups.count == 2 && groups[0].files.count == 5 && groups[0].key == "step0")

        let bad = CustomAgent.parsePlan("""
        {"say":"x","steps":[
         {"do":"move","files":"all","to":"/etc"},
         {"do":"move","files":"all","to":"Desktop/../../elsewhere"},
         {"do":"move","files":"all","to":"Desktop/.secret"},
         {"do":"format","files":"all"},
         {"do":"trash","files":[]},
         {"do":"folder","path":"Desktop"},
         {"do":"write","path":"Documents/run.sh","text":"rm -rf /"},
         {"do":"write","path":"list.txt","text":"hello"},
         {"do":"trash","files":{"name":"notes"}}]}
        """, listing: listing)
        check("plan: only the safe step survives (\(bad?.steps.count ?? -1) of 9)", bad?.steps.count == 1 && bad?.steps.first.map { if case .trash = $0.action { return true } else { return false } } == true)
        check("plan: every dropped step says why (\(bad?.notes.count ?? -1))", bad?.notes.count == 8)
        check("plan: a destination outside the three folders is refused", bad?.notes.first?.contains("isn't inside Desktop, Downloads or Documents") == true)
        check("plan: no destination is ever outside", CustomAgent.resolveFolder("/etc", roots: home.roots) == nil && CustomAgent.resolveFolder("Desktop/../x", roots: home.roots) == nil
              && CustomAgent.resolveFolder("~/Library", roots: home.roots) == nil && CustomAgent.resolveFolder("Library/x", roots: home.roots) == nil)
        check("plan: folders are made inside the allowed ones", CustomAgent.resolveFolder("desktop/Papers/Econ", roots: home.roots) == home.desktop.appendingPathComponent("Papers/Econ")
              && CustomAgent.resolveFolder(home.documents.path + "/School", roots: home.roots) == home.documents.appendingPathComponent("School"))
        check("plan: slashes in names are tamed", !CustomAgent.cleanName("../../etc/passwd").contains("/") && !CustomAgent.cleanName("../x").hasPrefix("."))
        check("plan: nobody names a hidden file", !CustomAgent.cleanName(".hidden").hasPrefix("."))

        let cannot = CustomAgent.parsePlan(#"{"cannot":"I can't open files to read them, but I can sort by name."}"#, listing: listing)
        check("plan: “can't” is passed on", cannot?.cannot?.contains("can't open files") == true && cannot?.steps.isEmpty == true)
        check("plan: not JSON is nothing", CustomAgent.parsePlan("Sure! I'd be happy to help.", listing: listing) == nil)

        let renamed = CustomAgent.parsePlan(#"{"say":"r","steps":[{"do":"rename","files":{"kind":"image"},"pattern":"Slide {n}"},{"do":"rename","names":{"1":"Meeting notes"}}]}"#, listing: listing)
        if case .rename(let names)? = renamed?.steps.first?.action {
            check("plan: a pattern numbers the files and keeps each extension", names.values.sorted() == (1...5).map { "Slide \($0).png" })
        } else { check("plan: a pattern numbers the files and keeps each extension", false) }
        if case .rename(let names)? = renamed?.steps.last?.action {
            check("plan: single renames keep the extension too", names.values.first == "Meeting notes.txt")
        } else { check("plan: single renames keep the extension too", false) }
        let write = CustomAgent.parsePlan(#"{"say":"w","steps":[{"do":"write","path":"Documents/list.txt","text":"a\nb"}]}"#, listing: listing)
        check("plan: a short text file can be written", write?.steps.count == 1)
        let many = (0..<30).map { _ in #"{"do":"folder","path":"Desktop/A"}"# }.joined(separator: ",")
        check("plan: steps are capped", CustomAgent.parsePlan("{\"say\":\"m\",\"steps\":[\(many)]}", listing: listing)?.steps.count == CustomAgent.maxSteps)

        // AppleScript text
        check("finder: names are quoted for AppleScript", FinderDesktop.quote("He said \"hi\" \\o/.png") == #""He said \"hi\" \\o/.png""#)
        check("finder: a name with a line break isn't sent", !FinderDesktop.isSafeName("a\nb.png") && FinderDesktop.isSafeName("a b.png"))

        // MARK: What it costs
        let small = CustomAgent.estimateTokens(listing: listing, request: "scatter these screenshots")
        check("cost: a small job is well under the warning (\(small) tokens)", small < CustomAgent.gateTokens && small > 1_500)
        var big = listing
        big.entries = (1...400).map { CustomAgent.Entry(id: $0, url: home.desktop.appendingPathComponent("Some long document name \($0).pdf"), root: "Desktop", rel: "Desktop/Some long document name \($0).pdf", isDir: false, sizeKB: 120, ageDays: 14, kind: "pdf") }
        let bigTokens = CustomAgent.estimateTokens(listing: big, request: "rename all of these")
        check("cost: 400 files is over the warning (\(bigTokens) tokens)", bigTokens >= CustomAgent.gateTokens)
        check("cost: tokens are written plainly", CustomAgent.tokensLabel(850) == "850" && CustomAgent.tokensLabel(14_200) == "14.2k" && CustomAgent.tokensLabel(4_000) == "4k")

        // MARK: Doing it (pretend Claude, pretend Finder)
        var asked = 0
        CustomAgent.ask = { _, _ in asked += 1; return fakeReply(scatterJSON) }
        let task = BackgroundTask(kind: .custom, title: "Scatter")
        CustomAgent(request: "take all the screenshots out of the Screenshots folder and scatter them around the desktop").run(task)
        pump { task.state == .needsApproval }
        check("run: a small job goes straight to a plan, no warning", task.state == .needsApproval && task.gate == nil && task.plan != nil && asked == 1)
        check("run: the plan says what Allow does (\(task.plan?.summary ?? "-"))", task.plan?.summary == "2 steps · 10 items" && task.plan?.canApprove == true)
        check("run: Claude's tokens are counted (\(task.tokens))", task.tokens == 600)
        check("run: the note says names only, and warns about Finder", task.plan?.notes.contains { $0.contains("names only") } == true
              && task.plan?.notes.contains { $0.contains("Sort By") } == true)
        check("run: nothing has moved yet", fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 1.png").path))
        check("run: the bar can show Allow", task.canQuickApprove && task.approvalSummary == "2 steps · 10 items")

        // A name already taken on the Desktop: the moved file becomes "Screenshot 1 2.png" and is still found by the next step.
        home.make("Screenshot 1.png", in: home.desktop)
        TaskEngine.shared.approve(task)
        pump { task.state == .done }
        check("run: Allow does the whole plan (\(task.report?.headline ?? task.detail))", task.state == .done && task.report?.headline == "Done: moved 5, placed 5")
        check("run: the screenshots are on the Desktop", (2...5).allSatisfy { fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshot \($0).png").path) }
              && fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshot 1 2.png").path))
        check("run: …and nothing was overwritten", fm.contents(atPath: home.desktop.appendingPathComponent("Screenshot 1.png").path)?.count == 10)
        let positionScript = finder.scripts.first { $0.contains("set position of item") && $0.contains("ARR") } ?? ""
        check("run: Finder was asked to place each one, by the name it ended up with", (2...5).allSatisfy { positionScript.contains("\"Screenshot \($0).png\"") } && positionScript.contains("\"Screenshot 1 2.png\""))
        check("run: …and the pre-existing Screenshot 1.png was left alone", !positionScript.contains("item \"Screenshot 1.png\""))
        check("run: Sort By is switched to None so they stay put", positionScript.contains("set arrangement of icon view options of window of desktop to not arranged"))
        check("run: the report says what it cost", task.report?.lines.contains { $0.contains("600 tokens") } == true)
        check("run: it can be undone", task.canUndo && task.onUndo != nil)

        task.onUndo?(task)
        pump { task.undone }
        check("undo: the screenshots are back in their folder", task.undone && (2...5).allSatisfy { fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot \($0).png").path) }
              && fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 1.png").path))
        check("undo: the other Screenshot 1.png is where it was", fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshot 1.png").path)
              && !fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshot 1 2.png").path))
        let restore = finder.scripts.last ?? ""
        check("undo: Finder is told to put the icons and Sort By back", restore.contains("to {5, 6}") && restore.contains("snap to grid"))

        // Finder says no: the files still move, and the report says what to switch on.
        for n in 1...3 { home.make("Pics/p\(n).jpg", in: home.desktop) }
        finder.denied = true
        let steps = CustomAgent.parsePlan(#"{"say":"s","steps":[{"do":"move","files":{"under":"Pics"},"to":"Desktop"},{"do":"place","files":{"under":"Pics"},"layout":"grid"}]}"#,
                                          listing: CustomAgent.list(roots: [home.desktop]))?.steps ?? []
        var ledger = FileSafety.Ledger(title: "t")
        let outcome = CustomAgent.execute(steps, ledger: &ledger)
        check("permission: the files are moved and Margin says Finder needs a yes", outcome.parts == ["moved 3"] && outcome.notes.first?.contains("Automation") == true
              && !ledger.records.contains { $0.kind == .positioned })
        finder.denied = false

        // A rename in place (the new name doesn't exist yet, and the folder may be reached by more than one spelling).
        let inPlace = CustomAgent.parsePlan(#"{"say":"r","steps":[{"do":"rename","files":{"ext":["pdf"]},"pattern":"Paper {n}"}]}"#,
                                            listing: CustomAgent.list(roots: [home.downloads]))?.steps ?? []
        var ledger3 = FileSafety.Ledger(title: "t3")
        let out3 = CustomAgent.execute(inPlace, ledger: &ledger3)
        check("do: renaming in place works (\(out3.skipped.map(\.reason)))", out3.skipped.isEmpty && out3.parts == ["renamed 2"]
              && fm.fileExists(atPath: home.downloads.appendingPathComponent("Paper 1.pdf").path) && fm.fileExists(atPath: home.downloads.appendingPathComponent("Paper 2.pdf").path))
        _ = FileSafety.undo(&ledger3)
        check("undo: …and back", fm.fileExists(atPath: home.downloads.appendingPathComponent("new.pdf").path) && fm.fileExists(atPath: home.downloads.appendingPathComponent("old.pdf").path))

        // Trash, rename and folder steps, then undo them all.
        let plan2 = CustomAgent.parsePlan(#"""
        {"say":"p","steps":[
          {"do":"folder","path":"Documents/School/Econ"},
          {"do":"move","files":{"ext":["pdf"]},"to":"Documents/School/Econ"},
          {"do":"rename","files":{"ext":["pdf"]},"pattern":"Reading {n}"},
          {"do":"trash","files":{"name":"notes"}},
          {"do":"write","path":"Documents/School/Econ/readme.txt","text":"Econ readings"}]}
        """#, listing: CustomAgent.list(roots: home.roots))
        check("plan: a five-step plan reads", plan2?.steps.count == 5 && plan2?.notes.isEmpty == true)
        var ledger2 = FileSafety.Ledger(title: "t2")
        let out2 = CustomAgent.execute(plan2?.steps ?? [], ledger: &ledger2)
        let econ = home.documents.appendingPathComponent("School/Econ")
        let econFiles = ((try? fm.contentsOfDirectory(atPath: econ.path)) ?? []).sorted()
        check("do: moved, renamed (by where they went), trashed and written (\(out2.parts.joined(separator: ", ")); \(econFiles))",
              econFiles == ["Reading 1.pdf", "Reading 2.pdf", "readme.txt"] && !fm.fileExists(atPath: home.desktop.appendingPathComponent("notes.txt").path))
        check("do: nothing is skipped", out2.skipped.isEmpty)
        let undone = FileSafety.undo(&ledger2)
        check("undo: all of it comes back (\(undone.restored) restored)", fm.fileExists(atPath: home.desktop.appendingPathComponent("notes.txt").path)
              && fm.fileExists(atPath: home.downloads.appendingPathComponent("old.pdf").path) && fm.fileExists(atPath: home.downloads.appendingPathComponent("new.pdf").path)
              && !fm.fileExists(atPath: econ.appendingPathComponent("readme.txt").path) && undone.couldNotRestore.isEmpty)
        check("undo: the folders it made are gone", !fm.fileExists(atPath: home.documents.appendingPathComponent("School").path))

        // MARK: The warning before a big job
        CustomAgent.gateTokens = 100
        asked = 0
        let gated = BackgroundTask(kind: .custom, title: "Gate")
        CustomAgent(request: "scatter my screenshots").run(gated)
        pump { gated.state == .needsApproval }
        check("gate: a bigger job asks first and hasn't called Claude (\(gated.gate?.summary ?? "-"))", gated.state == .needsApproval && gated.gate != nil && gated.plan == nil && asked == 0)
        check("gate: it says the cost in tokens", gated.gate?.detail.contains("tokens") == true && gated.gate?.summary.contains("tokens") == true)
        check("gate: the bar can show Allow for it", gated.canQuickApprove && gated.approvalSummary.contains("tokens"))
        TaskEngine.shared.approve(gated)
        pump { gated.plan != nil }
        check("gate: Go ahead then asks Claude and shows the plan", gated.gate == nil && gated.plan != nil && asked == 1 && gated.state == .needsApproval)

        let refused = BackgroundTask(kind: .custom, title: "Refuse")
        asked = 0
        CustomAgent(request: "scatter my screenshots").run(refused)
        pump { refused.gate != nil }
        TaskEngine.shared.deny(refused)
        pump(0.4) { false }
        check("gate: Cancel spends nothing and changes nothing", refused.state == .cancelled && asked == 0 && refused.gate == nil)

        CustomAgent.hardLimitTokens = 200
        let tooBig = BackgroundTask(kind: .custom, title: "Huge")
        CustomAgent(request: "scatter my screenshots").run(tooBig)
        pump { tooBig.isFinished }
        check("gate: a job too big for one go asks for a narrower one", { if case .failed(let m) = tooBig.state { return m.contains("narrower") } else { return false } }() && asked == 0)
        CustomAgent.gateTokens = savedGate; CustomAgent.hardLimitTokens = savedHard

        // MARK: When Claude doesn't cooperate
        var replies = ["Sure! Here you go.", scatterJSON]
        CustomAgent.ask = { _, _ in fakeReply(replies.removeFirst(), tokens: 500) }
        let retry = BackgroundTask(kind: .custom, title: "Retry")
        CustomAgent(request: "scatter my screenshots").run(retry)
        pump { retry.state == .needsApproval }
        check("claude: bad JSON is asked for again, and both calls are counted (\(retry.tokens))", retry.plan != nil && retry.tokens == 1000)

        CustomAgent.ask = { _, _ in fakeReply("nonsense") }
        let hopeless = BackgroundTask(kind: .custom, title: "Hopeless")
        CustomAgent(request: "scatter my screenshots").run(hopeless)
        pump { hopeless.isFinished }
        check("claude: if it still isn't a plan, the person is told", { if case .failed(let m) = hopeless.state { return m.contains("understand") } else { return false } }())

        CustomAgent.ask = { _, _ in fakeReply(#"{"cannot":"That needs reading inside the files; I only see names."}"#) }
        let cant = BackgroundTask(kind: .custom, title: "Can't")
        CustomAgent(request: "delete the screenshots that show my password").run(cant)
        pump { cant.isFinished }
        check("claude: “can't” is shown as it is", { if case .failed(let m) = cant.state { return m.contains("only see names") } else { return false } }())

        CustomAgent.ask = { _, _ in .failure(.timedOut) }
        let slow = BackgroundTask(kind: .custom, title: "Slow")
        CustomAgent(request: "scatter my screenshots").run(slow)
        pump { slow.isFinished }
        check("claude: a failed call fails the task, nothing changed", slow.state != .done && fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 2.png").path))

        // Selection: “these” asks Finder what's selected and hands Claude the stars.
        var prompt = ""
        CustomAgent.ask = { p, _ in prompt = p; return fakeReply(#"{"say":"s","steps":[{"do":"place","files":"selected","layout":"row"}]}"#) }
        finder.selection = [home.desktop.appendingPathComponent("Screenshots/Screenshot 2.png").path, "/Users/nobody/elsewhere.png"]
        let sel = BackgroundTask(kind: .custom, title: "Selected")
        CustomAgent(request: "line up these").run(sel)
        pump { sel.state == .needsApproval }
        check("selection: Finder's selection is starred in what Claude reads", prompt.contains("*") && prompt.contains("Screenshot 2.png") && sel.plan != nil)

        // MARK: The jobs the Mac plans by itself (no Claude, no tokens)
        CustomAgent.localPlanning = true
        func job(_ s: String) -> LocalJobs.Job? { LocalJobs.interpret(s) }
        check("local: scatter my screenshots", job("scatter my screenshots")?.action == .place(.scatter) && job("scatter my screenshots")?.object == .screenshots)
        check("local: the pitch sentence", job("Take all my screenshots and scatter them around the desktop.")?.action == .place(.scatter))
        check("local: “the screenshots out of the Screenshots folder”", job("take all the screenshots out of the Screenshots folder and scatter them around the desktop")?.object == .screenshots)
        check("local: these in a grid means the selection", job("arrange these in a grid")?.object == .selection && job("arrange these in a grid")?.action == .place(.grid))
        check("local: a row, a column", job("line up my pdfs in a row")?.action == .place(.row) && job("arrange my images in a column")?.action == .place(.column))
        check("local: old installers in Downloads", job("trash the old installers in my downloads") == LocalJobs.Job(action: .trash, object: .installers, olderDays: 30, rootName: "Downloads", wantsSelection: false, fallback: nil))
        check("local: older than 2 weeks", job("delete dmgs older than 2 weeks")?.olderDays == 14 && job("remove zips older than a month")?.olderDays == 30)
        check("local: put into a folder", job("put all my pdfs into a Papers folder")?.action == .move(folder: "Papers"))
        check("local: folder called", job("move my screenshots to a folder called school stuff")?.action == .move(folder: "School Stuff"))
        check("local: “to the trash” is the trash", job("move my pdfs to the trash")?.action == .trash)
        check("local: a root is a destination too", job("move my pdfs to documents")?.action == .move(folder: "Documents"))
        for t in ["rename my pdfs Paper 1 and Paper 2", "delete everything", "scatter", "why does ice float", "trash screenshots bigger than 5 MB",
                  "put my files into a folder", "delete the duplicates", "sort my downloads by date", "move my pdfs and then rename them", "make me a sandwich"] {
            check("local: “\(t)” is left to Claude", job(t) == nil)
        }

        home.make("Installers/app.dmg", in: home.downloads, daysOld: 60)
        home.make("fresh.dmg", in: home.downloads)
        CustomAgent.ask = { _, _ in asked += 1; return fakeReply("{}") }
        asked = 0
        let localScatter = BackgroundTask(kind: .custom, title: "Local scatter")
        CustomAgent(request: "scatter my screenshots").run(localScatter)
        pump { localScatter.state == .needsApproval }
        check("local: a plan appears without asking Claude (asked \(asked))", localScatter.plan != nil && asked == 0 && localScatter.tokens == 0 && localScatter.gate == nil)
        check("local: moves them out of the folder, then scatters (\(localScatter.plan?.groups.map(\.title) ?? []))", localScatter.plan?.groups.count == 2
              && localScatter.plan?.groups.first?.title.contains("onto the Desktop") == true && localScatter.plan?.groups.last?.title == "Scatter 6 icons on the Desktop") // the 5 in the folder and the one already loose
        check("local: the plan says it cost nothing", localScatter.plan?.notes.contains { $0.contains("no Claude tokens") } == true)
        TaskEngine.shared.approve(localScatter)
        pump { localScatter.state == .done }
        check("local: it runs like any plan (\(localScatter.report?.headline ?? localScatter.detail))", localScatter.report?.headline == "Done: moved 5, placed 6"
              && localScatter.report?.lines.contains { $0.contains("no Claude tokens") } == true)
        localScatter.onUndo?(localScatter)
        pump { localScatter.undone }
        check("local: and it undoes", localScatter.undone && fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 3.png").path))

        let localTrash = BackgroundTask(kind: .custom, title: "Local trash")
        CustomAgent(request: "trash the old installers in my downloads").run(localTrash)
        pump { localTrash.state == .needsApproval }
        check("local: only the old installer is in the trash plan", localTrash.plan?.groups.count == 1 && localTrash.plan?.groups.first?.files == ["Downloads/Installers/app.dmg"] && asked == 0)
        TaskEngine.shared.deny(localTrash)

        let localMove = BackgroundTask(kind: .custom, title: "Local move")
        CustomAgent(request: "put all my pdfs into a Papers folder").run(localMove)
        pump { localMove.state == .needsApproval }
        check("local: a folder is made, then the files go in (\(localMove.plan?.groups.map(\.title) ?? []))", localMove.plan?.groups.count == 2 && localMove.plan?.groups.first?.title.contains("Make the folder") == true && asked == 0)
        TaskEngine.shared.approve(localMove)
        pump { localMove.state == .done }
        check("local: the PDFs are in Downloads/Papers", fm.fileExists(atPath: home.downloads.appendingPathComponent("Papers/old.pdf").path) && fm.fileExists(atPath: home.downloads.appendingPathComponent("Papers/new.pdf").path))
        localMove.onUndo?(localMove)
        pump { localMove.undone }
        check("local: …and Undo takes the folder away too", fm.fileExists(atPath: home.downloads.appendingPathComponent("new.pdf").path) && !fm.fileExists(atPath: home.downloads.appendingPathComponent("Papers").path))

        let localNone = BackgroundTask(kind: .custom, title: "Local none")
        CustomAgent(request: "scatter my videos").run(localNone)
        pump { localNone.isFinished }
        check("local: nothing to scatter says so, without Claude", localNone.state == .done && localNone.report?.headline.contains("didn't find any videos") == true && asked == 0)

        CustomAgent.ask = { _, _ in asked += 1; return fakeReply(#"{"say":"s","steps":[{"do":"rename","files":{"ext":["pdf"]},"pattern":"Paper {n}"}]}"#) }
        let twist = BackgroundTask(kind: .custom, title: "Twist")
        CustomAgent(request: "rename my pdfs Paper 1 and Paper 2").run(twist)
        pump { twist.state == .needsApproval }
        check("local: a job with a twist still goes to Claude", asked == 1 && twist.tokens == 600)
    }
}

// MARK: - Live

extension FeatureTests {
    /// Margin --customtest: the real Claude plans some made-up jobs on a made-up Desktop (a pretend Finder, never yours).
    /// Passing means the plan is valid, safe, does what was asked, and the job's cost is shown.
    static func liveCustomTest() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let fm = FileManager.default
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let home = FakeHome()
        home.fill()
        for n in 1...3 { home.make("Screenshot 2026-10-0\(n) at 10.00.00 AM.png", in: home.desktop) }
        home.make("Screen Shot 2026-09-30 at 9.12.44 AM.png", in: home.desktop)
        home.make("Budget.xlsx", in: home.desktop)
        FileSafety.roots = home.roots
        FileSafety.ledgerDirectory = home.base.appendingPathComponent("ledgers")
        CustomAgent.desktopRoot = home.desktop
        let finder = FakeFinder()
        FinderDesktop.runner = { finder.run($0) }
        CustomAgent.localPlanning = false // this run is about Claude's plans
        defer { home.remove() }

        func run(_ request: String) -> BackgroundTask {
            let task = BackgroundTask(kind: .custom, title: CustomAgent.title(for: request))
            let t0 = Date()
            CustomAgent(request: request).run(task)
            pump(120) { task.state != .working }
            let est = CustomAgent.estimateTokens(listing: CustomAgent.list(roots: CustomAgent.scope(for: request)), request: request)
            print("   “\(request)” → \(task.state) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(task.tokens) tokens (estimated \(est))")
            return task
        }

        // 0. The AppleScript we'd send Finder is real AppleScript (compiled, not run: nothing is sent to Finder).
        let scripts = [("place", FinderDesktop.positionScript([.init(name: "He said \"hi\" \\o/.png", x: 120, y: 340), .init(name: "a b.png", x: 5, y: 6)], freeArrangement: true)),
                       ("restore", FinderDesktop.restoreScript([.init(name: "a b.png", x: 5, y: 6)], arrangement: "snap to grid")),
                       ("selection", FinderDesktop.selectionScript)]
        for (name, script) in scripts {
            let file = home.base.appendingPathComponent("\(name).applescript")
            try? script.write(to: file, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            p.arguments = ["-o", home.base.appendingPathComponent("\(name).scpt").path, file.path]
            let err = Pipe()
            p.standardError = err
            try? p.run()
            p.waitUntilExit()
            check("applescript: the \(name) script compiles", p.terminationStatus == 0)
            if p.terminationStatus != 0 { print(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        }

        // 1. The user's own sentence
        let scatter = run("take all the screenshots out of the Screenshots folder and scatter them around the desktop")
        check("scatter: it made a plan", scatter.state == .needsApproval && scatter.plan != nil)
        if let plan = scatter.plan {
            for g in plan.groups { print("   • \(g.title) — \(g.subtitle) (\(g.files.count) files)") }
            print("   note: \(plan.notes.joined(separator: " | "))")
        }
        check("scatter: no warning for a small job", scatter.gate == nil)
        check("scatter: it cost under 4,000 tokens (\(scatter.tokens)), as the estimate said it would be about", scatter.tokens > 0 && scatter.tokens < 4000)
        TaskEngine.shared.approve(scatter)
        pump(30) { scatter.state == .done }
        print("   \(scatter.report?.headline ?? scatter.detail)")
        let onDesktop = ((try? fm.contentsOfDirectory(atPath: home.desktop.path)) ?? []).filter { $0.hasPrefix("Screenshot ") && $0.hasSuffix(".png") }
        check("scatter: the 5 folder screenshots came out onto the Desktop (\(onDesktop.count) there)", onDesktop.count >= 5)
        check("scatter: the Screenshots folder is empty of them", ((try? fm.contentsOfDirectory(atPath: home.desktop.appendingPathComponent("Screenshots").path)) ?? []).filter { $0.hasSuffix(".png") }.isEmpty)
        let placed = finder.scripts.filter { $0.contains("set position of item") }.joined()
        check("scatter: Finder was asked to place the icons", placed.contains("Screenshot 1.png") && placed.contains("set position of item"))
        check("scatter: the budget spreadsheet was left alone", fm.fileExists(atPath: home.desktop.appendingPathComponent("Budget.xlsx").path) && !placed.contains("Budget.xlsx"))
        scatter.onUndo?(scatter)
        pump(15) { scatter.undone }
        check("scatter: Undo puts the screenshots back", fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 3.png").path))

        // 2. A job with a "how": rename and file
        let rename = run("rename my two PDFs in Downloads to Paper 1 and Paper 2, and put them in a folder called Papers in Documents")
        check("rename: it made a plan", rename.state == .needsApproval && rename.plan != nil)
        if let plan = rename.plan { for g in plan.groups { print("   • \(g.title) — \(g.subtitle)"); g.files.forEach { print("       \($0)") } } }
        TaskEngine.shared.approve(rename)
        pump(30) { rename.state == .done }
        print("   \(rename.report?.headline ?? rename.detail) \(rename.report?.lines ?? [])")
        let papers = ((try? fm.contentsOfDirectory(atPath: home.documents.appendingPathComponent("Papers").path)) ?? []).sorted()
        print("   Documents/Papers: \(papers)")
        check("rename: both PDFs are in Documents/Papers, renamed", papers.count == 2 && papers.allSatisfy { $0.hasPrefix("Paper ") && $0.hasSuffix(".pdf") })

        // 3. Something it can't do
        let impossible = run("delete every screenshot that has my password in it")
        print("   \(impossible.detail)")
        check("impossible: it says so instead of guessing, and touches nothing", { if case .failed = impossible.state { return true } else { return impossible.state == .needsApproval && (impossible.plan?.groups.isEmpty ?? true) == false } }()
              && fm.fileExists(atPath: home.desktop.appendingPathComponent("Screenshots/Screenshot 1.png").path))
        if impossible.state == .needsApproval { TaskEngine.shared.deny(impossible) }

        print(failures == 0 ? "CUSTOMTEST PASS" : "CUSTOMTEST FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Token savings

extension FeatureTests {
    static func savingChecks(_ check: (String, Bool) -> Void) {
        // Names only, unless the request is about age or size.
        let home = FakeHome()
        home.fill()
        defer { home.remove() }
        let listing = CustomAgent.list(roots: [home.desktop])
        let lean = listing.text(detail: false), full = listing.text(detail: true)
        check("saving: a names-only list is shorter (\(lean.count) vs \(full.count) characters)", lean.count < full.count - 20 && !lean.contains("|1|0") && lean.contains("|Screenshot 1.png"))
        check("saving: …but still marks folders and selections", lean.contains("|Screenshots/") && CustomAgent.list(roots: [home.desktop], selected: [home.desktop.appendingPathComponent("notes.txt").standardizedFileURL.resolvingSymlinksInPath().path]).text(detail: false).contains("*"))
        check("saving: sizes and ages are sent when the request is about them",
              ["trash files older than a month", "delete the biggest downloads", "move last week's screenshots", "archive anything from 2 years ago", "recent pdfs"].allSatisfy(CustomAgent.needsDetail))
        check("saving: …and not when it isn't", !CustomAgent.needsDetail("put my pdfs in a folder called Econ") && !CustomAgent.needsDetail("rename these Paper 1, Paper 2"))
        check("saving: the planning prompt is short (\(CustomAgent.systemPrompt.count) characters)", CustomAgent.systemPrompt.count < 2_000)

        // Graph templates: drawn on the Mac, no Claude.
        for t in GraphTemplates.all {
            let spec = GraphSpec.parse(t.json)
            check("graph template: “\(t.name)” draws with nothing skipped (\(spec?.problems ?? ["unreadable"]))", spec != nil && spec?.problems.isEmpty == true && !(spec?.plots.isEmpty ?? true))
        }
        func tpl(_ prompt: String, _ selection: String) -> String? { GraphTemplates.match(prompt: prompt, selection: selection)?.name }
        check("graph template: Visualize on supply and demand", tpl(Prompts.visualize, "When demand rises while supply stays fixed, the equilibrium price goes up.") == "Supply and demand")
        check("graph template: a typed request", tpl("draw the parabola for me", "") == "Parabola" && tpl("show me the sine wave", "") == "Wave")
        check("graph template: the highlight can carry it", tpl(Prompts.visualize, "The vertex of a quadratic is where the parabola turns; its roots are where it crosses zero.") == "Parabola")
        check("graph template: derivative and bell curve and growth", tpl(Prompts.visualize, "The derivative is the slope of the tangent line at a point.") == "Tangent line"
              && tpl(Prompts.visualize, "A normal distribution is a bell curve set by its mean and standard deviation.") == "Bell curve"
              && tpl("graph this", "Compound interest is exponential growth.") == "Exponential")
        check("graph template: one passing word isn't enough", tpl(Prompts.visualize, "The supply chain was disrupted last year by a storm.") == nil)
        check("graph template: no graph asked, no graph drawn", tpl("explain this simpler", "supply and demand curves shift when demand rises") == nil)
        check("graph template: anything unrelated goes to Claude", tpl(Prompts.visualize, "The French Revolution began in 1789.") == nil)
        check("graph template: a tie goes to Claude", tpl(Prompts.visualize, "A surplus and a shortage, and a quadratic with a vertex.") == nil)
        let tAnswer = GraphTemplates.answer(GraphTemplates.all[0])
        check("graph template: the answer reads as a graph piece", Answer.pieces(tAnswer).contains { if case .graph = $0 { return true } else { return false } })
        let ts = TemplateSession(GraphTemplates.all[1])
        var got: [String] = []
        ts.onEvent = { e in switch e { case .delta(let t): got.append("delta:\(t.count)"); case .turnDone: got.append("done"); case .unavailable: got.append("unavailable"); default: got.append("other") } }
        ts.send("Visualize", images: [])
        ts.send("what about a bigger a?", images: [])
        pump(2) { got.count >= 3 }
        check("graph template: the session answers at once and hands follow-ups to Claude (\(got))", got.count == 3 && got[0].hasPrefix("delta:") && got[1] == "done" && got[2] == "unavailable")

        // ⌃⇧L and the new video summary
        check("hotkey: ⌃⇧L switches the chat's engine", Hotkeys.action(keyCode: 37, flags: [.maskControl, .maskShift], tabHeld: false) == .engine)
        check("hotkey: …and only that chord", Hotkeys.action(keyCode: 37, flags: .maskControl, tabHeld: false) == nil
              && Hotkeys.action(keyCode: 37, flags: [.maskControl, .maskShift, .maskCommand], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 37, flags: [.maskControl, .maskShift, .maskAlternate], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 37, flags: [.maskCommand, .maskShift], tabHeld: false) == .history)
        let req = Prompts.videoRequest(.english, language: "English", link: "https://youtu.be/abc")
        check("video: the summary asks for the five sections", ["📌", "🔑", "⏱️", "🛠️", "💡", "Executive Summary & Overview", "Key Takeaways & Core Concepts",
                                                           "Topic-by-Topic Breakdown", "Actionable Steps & Implementation", "Important Quotes, Tools & References"].allSatisfy(req.contains))
        check("video: …keeps timestamps as links, stays tight, and skips empty sections", req.contains("https://youtu.be/abc?t=") && req.contains("about 450 words") && req.contains("Leave the whole section out"))
        let lines = (0..<400).map { VideoTranscript.Segment(start: TimeInterval($0 * 10), text: "Sentence number \($0) says something about the topic of the talk.") }
        let long = VideoTranscript(title: "Talk", channel: "Chan", duration: 4000, languageCode: "en", origin: "captions", segments: lines)
        let parts = VideoDigest.chunks(long, limit: 3000)
        check("video: a long transcript is read in parts (\(parts.count)), each within the limit", parts.count > 3 && parts.allSatisfy { $0.count <= 3000 })
        check("video: …and nothing is lost or cut mid-line", parts.joined(separator: "\n") == long.formatted() )
        let short = VideoTranscript(title: "Short", channel: nil, duration: 60, languageCode: "en", origin: "captions", segments: Array(lines.prefix(6)))
        check("video: a short one is a single part", VideoDigest.chunks(short).count == 1)
        let final = VideoDigest.finalPrompt(transcript: long, link: nil, notes: ["[0:00] a", "[1:00] b"], request: "REQ")
        check("video: the final prompt carries the notes, not the transcript", final.contains("[1:00] b") && !final.contains("Sentence number 5") && final.hasSuffix("REQ"))
        check("video: a short video sends its transcript", VideoDigest.finalPrompt(transcript: short, link: nil, notes: nil, request: "REQ").contains("Sentence number 5"))
        let linked = VideoDigest.linkify("**[1:05]** a, [0:07] b, [1:02:03] c, [4:05](https://x.y?t=245) d, [12] e", link: "https://youtu.be/abc")
        check("video: plain times become links from the time itself (\(linked))", linked.contains("[1:05](https://youtu.be/abc?t=65)") && linked.contains("[0:07](https://youtu.be/abc?t=7)")
              && linked.contains("[1:02:03](https://youtu.be/abc?t=3723)") && linked.contains("[4:05](https://x.y?t=245) d") && linked.contains("[12] e"))
        check("video: the link instruction is swapped for plain times on the Mac", Prompts.videoRequest(.english, language: "English", link: "https://youtu.be/abc")
              .replacingOccurrences(of: Prompts.stampPhrase(link: "https://youtu.be/abc"), with: Prompts.stampPhrase(link: nil)).contains("the time in brackets"))
        let idx = VideoDigest.index(long)
        let fu = VideoDigest.followUp("what does sentence number 321 say", index: idx)
        check("video: a follow-up gets only the matching passages", fu.contains("Sentence number 321") && fu.count < 6000 && fu.hasSuffix("what does sentence number 321 say"))

        // Chat naming: the on-Mac model first, Haiku only if it can't.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-savenaming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        func chat() -> ChatRecord {
            ChatRecord(title: "Chat from Safari", sector: "Other", app: "Safari", quote: "Opportunity cost",
                       turns: (0..<3).map { .init(question: "Question \($0)", answer: "Answer \($0) about trade-offs.") })
        }
        let savedLocal = ChatNaming.useLocal, savedGen = ChatNaming.localGenerate, savedClaude = ChatNaming.claudeRun
        defer { ChatNaming.useLocal = savedLocal; ChatNaming.localGenerate = savedGen; ChatNaming.claudeRun = savedClaude }
        var claudeCalls = 0
        ChatNaming.claudeRun = { _, _, _, done in claudeCalls += 1; done(.success(.init(text: #"{"title":"Haiku title","sector":"Economics"}"#, usage: .init(inputTokens: 500, outputTokens: 100)))) }

        let a = chat()
        library.save(a)
        ChatNaming.useLocal = { true }
        ChatNaming.localGenerate = { _, _, done in done(#"{"title":"Opportunity cost and trade-offs","sector":"economics"}"#) }
        var cost = -1
        ChatNaming.rename(a.id, in: library) { cost = $0 }
        check("saving: with Local Mode on, the Mac names the chat for 0 Claude tokens", cost == 0 && claudeCalls == 0 && library.chat(a.id)?.title == "Opportunity cost and trade-offs" && library.chat(a.id)?.sector == "Economics")

        let b = chat()
        library.save(b)
        ChatNaming.localGenerate = { _, _, done in done("I think it's about economics.") }
        ChatNaming.rename(b.id, in: library) { cost = $0 }
        check("saving: a useless local answer falls back to Haiku (\(cost) tokens)", cost == 600 && claudeCalls == 1 && library.chat(b.id)?.title == "Haiku title")

        let c = chat()
        library.save(c)
        ChatNaming.localGenerate = { _, _, done in done(nil) }
        ChatNaming.rename(c.id, in: library) { cost = $0 }
        check("saving: Ollama not answering falls back to Haiku too", cost == 600 && claudeCalls == 2)

        let d = chat()
        library.save(d)
        ChatNaming.useLocal = { false }
        var localCalls = 0
        ChatNaming.localGenerate = { _, _, done in localCalls += 1; done(nil) }
        ChatNaming.rename(d.id, in: library) { cost = $0 }
        check("saving: with Local Mode off, it's Haiku and Ollama is never asked", localCalls == 0 && claudeCalls == 3 && cost == 600)
    }
}

// MARK: - Live: ⌃⇧L and local video summaries

extension FeatureTests {
    /// Margin --switchtest: with Local Mode on, real Ollama and real Claude: (1) ⌃⇧L moves ONE chat to Claude and back while
    /// another chat, Local Mode and a brand-new chat stay local; (2) a long summary of highlighted text is answered on this
    /// Mac; (3) a real TED talk is summarized on this Mac in the five-section structure with no Claude call.
    static func liveSwitchTest() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let settings = Settings.shared
        let wasLocal = settings.localMode
        settings.localMode = true
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let mouse = TestSpot.mouse(on: screen)
        let icon = NSRect(x: mouse.x, y: mouse.y, width: 22, height: 22)
        let passage = "Opportunity cost is the value of the next-best alternative you give up when you make a choice. "
            + "Because time and money are scarce, every decision involves a trade-off."
        func newChat(_ text: String = passage, video: VideoSource? = nil) -> AskPanelController {
            let chat = AskPanelController(selection: Selection(text: text, appName: "Safari", context: ContextBox(resolved: nil),
                                                               pid: 0, mouse: mouse, video: video), iconFrame: icon)
            chat.show()
            return chat
        }
        func settled(_ chat: AskPanelController, _ seconds: Double = 120) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if chat.phase == .done || chat.phase == .failed { return chat.phase == .done }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return false
        }
        func finish() -> Never {
            settings.localMode = wasLocal
            print(failures == 0 ? "SWITCHTEST PASS" : "SWITCHTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }

        Task { @MainActor in
            OllamaClient.shared.refresh { _ in }
            try? await Task.sleep(nanoseconds: 800_000_000)
            check("Ollama is ready", OllamaClient.shared.status == .ready)

            // 1. One chat moves; nothing else does.
            let a = newChat(), b = newChat()
            a.debugAsk(Prompts.chips[0].prompt)
            b.debugAsk(Prompts.chips[0].prompt)
            check("chat A answered on the Mac", await settled(a) && a.debugEngine == "local")
            check("chat B answered on the Mac", await settled(b) && b.debugEngine == "local")
            let message = a.toggleEngine()
            print("   ⌃⇧L → \(message)")
            check("⌃⇧L tells you it's Claude now", message.contains("uses Claude") && message.contains("unchanged"))
            check("chat A is answered again by Claude", await settled(a) && a.debugEngine == "claude" && a.debugTurns.last?.localModel == nil
                  && (a.debugTurns.last?.answer.count ?? 0) > 20 && a.debugTurns.count == 1)
            check("chat B is still on the Mac", b.debugEngine == "local" && b.debugPlan?.isLocal == true)
            check("Local Mode itself wasn't switched off", settings.localMode)
            let c = newChat()
            c.debugAsk(Prompts.chips[0].prompt)
            check("a brand-new chat still starts on the Mac", await settled(c) && c.debugEngine == "local")
            a.debugAsk("Why does that matter for a student?")
            check("a follow-up in A stays on Claude", await settled(a) && a.debugEngine == "claude")
            let back = a.toggleEngine()
            print("   ⌃⇧L → \(back)")
            let backDone = await settled(a)
            check("⌃⇧L again returns A to the Mac", back.contains("runs on your Mac") && backDone && a.debugEngine == "local" && a.debugTurns.count == 2)
            let needsClaude = newChat()
            needsClaude.debugAsk("Search the web for the latest news about this")
            _ = await settled(needsClaude)
            check("a question that needs the web starts on Claude", needsClaude.debugEngine == "claude")
            let stay = needsClaude.toggleEngine()
            check("…and ⌃⇧L won't force it onto the Mac (\(stay))", stay.contains("needs Claude") && needsClaude.debugEngine == "claude")
            [a, b, c, needsClaude].forEach { $0.close() }

            // 2. A long summary, on the Mac.
            let long = String(repeating: passage + " ", count: 25)
            let s = newChat(long)
            s.debugSummarize(.meaning)
            check("a \(long.count)-character summary is answered on the Mac", await settled(s) && s.debugEngine == "local" && (s.debugTurns.last?.answer.count ?? 0) > 80)
            s.close()

            // 3. A real talk, summarized on the Mac.
            let t0 = Date()
            let v = newChat("", video: .youtube(id: "arj7oStGLkU"))
            var sawParts = false
            let end = Date().addingTimeInterval(400)
            while Date() < end, v.phase != .done, v.phase != .failed {
                if v.debugVideoStatus?.contains("Reading part") == true { sawParts = true }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            while v.debugTurns.last?.done != true, Date() < end { try? await Task.sleep(nanoseconds: 300_000_000) } // the answer is still being typed out
            let answer = v.debugTurns.last?.answer ?? ""
            print("   video summary in \(Int(Date().timeIntervalSince(t0))) s:\n" + answer)
            check("the talk was summarized on the Mac, not by Claude", v.debugEngine == "local" && v.debugVideoLocal && v.debugTurns.last?.localModel != nil)
            check("it read the transcript in parts first", sawParts)
            check("the summary has the sections", answer.contains("Executive Summary") && answer.contains("Key Takeaways") && answer.contains("Breakdown"))
            check("…with timestamps that link to the right moment", answer.contains("youtu.be/arj7oStGLkU?t="))
            v.debugAsk("What are the three characters he talks about?")
            check("a follow-up about it is answered too", await settled(v, 180) && (v.debugTurns.last?.answer.lowercased().contains("monkey") ?? false))

            // 4. The same video chat, moved to Claude with ⌃⇧L (it re-reads the whole transcript: a few thousand tokens).
            let turnsBefore = v.debugTurns.count
            let moved = v.toggleEngine()
            print("   ⌃⇧L → \(moved)")
            let movedDone = await settled(v, 240)
            let redone = v.debugTurns.last?.answer ?? ""
            check("⌃⇧L moves the video chat to Claude, which answers that question again", moved.contains("uses Claude") && movedDone && v.debugEngine == "claude"
                  && !v.debugVideoLocal && v.debugTurns.count == turnsBefore)
            check("…the answer is Claude's (it has a model label of nil) and about this video", v.debugTurns.last?.localModel == nil && redone.lowercased().contains("monkey"))
            v.close()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) { print("SWITCHTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}
