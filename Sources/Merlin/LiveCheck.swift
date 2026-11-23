import AppKit
import SwiftUI

/// `Merlin --livecheck <dir>`: real model calls through the chat's own code path (AskModel → AskPanelController routing →
/// ClaudeSession / LocalSession), checked end to end, with nothing on screen.
///
/// - Nothing is shown: chats are built but never ordered in front, no screenshot is taken (the chat is told one already came
///   back empty), the quick model sees a picture drawn in code, and every picture is drawn offscreen into a bitmap.
/// - Nothing of yours changes: Context, Rules and the engine are in-memory test values, the library and usage log are
///   throwaway ones, and nothing is saved. Your settings are only read (model, Quick Answers, screen context).
/// - The proxy is never started: if it is switched on but not running, the run stops before any call.
/// - About 11 real calls; it always exits within 5 minutes. Writes raw answers (.txt) and pictures (.png) into `dir`.
@MainActor
enum LiveCheck {
    private static var failures = 0
    private static var lines: [String] = []
    private static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var jobs: [Job] = []
    private static var calls = 0
    private static var mathFailures: [String] = []
    private static let emptySuite = "com.kien.merlin.livecheck.empty"
    private static let rulesSuite = "com.kien.merlin.livecheck.rules"
    private static var emptySource: Settings!
    private static var rulesSource: Settings!
    private static var tempDir: URL!

    static let testContext = "My name is Priya. My cat is called Biscuit."
    static let testRules = "End every answer with the word DONE in capitals."
    static let problem = "Solve 3x^2 - 12x + 9 = 0"

    private static func log(_ s: String) {
        print(s)
        lines.append(s)
    }

    private static func check(_ name: String, _ ok: Bool) {
        log((ok ? "ok   " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    private static func note(_ s: String) { log("     " + s) }

    // MARK: - One chat

    /// A chat built the way the shortcut builds one, wired headless, plus what its `claude` process printed.
    final class Job {
        let name: String
        let chat: AskPanelController
        var initModel: String?
        var sessionID: String?
        var raws: [String] = []
        var current = ""
        var usages: [String] = []
        var models: [String] = []
        /// Names of the tools the model called (WebSearch / WebFetch), in order.
        var tools: [String] = []
        weak var tapped: ClaudeSession?

        init(name: String, chat: AskPanelController) {
            self.name = name
            self.chat = chat
        }

        var claude: ClaudeSession? {
            (chat.debugSession as? ClaudeSession) ?? (chat.debugSession as? LocalSession)?.debugClaude
        }

        var systemPrompt: String {
            (chat.debugSession as? ClaudeSession)?.startingSystemPrompt ?? (chat.debugSession as? LocalSession)?.startingSystemPrompt ?? ""
        }

        func attachTap() {
            guard let claude, claude !== tapped else { return }
            tapped = claude
            claude.debugLineTap = { [weak self] line in self?.take(line) }
        }

        func take(_ line: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return }
            switch type {
            case "system" where obj["subtype"] as? String == "init":
                initModel = obj["model"] as? String
                sessionID = obj["session_id"] as? String
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_use" {
                    if let name = block["name"] as? String { tools.append(name) }
                }
            case "stream_event":
                if let e = obj["event"] as? [String: Any], e["type"] as? String == "content_block_delta",
                   let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                    current += t
                }
            case "result":
                raws.append(current)
                current = ""
                let u = obj["usage"] as? [String: Any] ?? [:]
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let used = (obj["modelUsage"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
                models.append(used.joined(separator: ","))
                let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0
                usages.append("in=\(n("input_tokens")) cache_write=\(n("cache_creation_input_tokens")) cache_read=\(n("cache_read_input_tokens")) out=\(n("output_tokens")) session_cost_usd=\(String(format: "%.4f", cost))")
            default:
                break
            }
        }
    }

    private static func newChat(_ name: String, text: String, image: Data? = nil, engine: Router.Plan.Engine? = nil) -> Job {
        var selection = Selection(text: text, appName: "Preview", context: ContextBox(resolved: nil), pid: 0, mouse: NSPoint(x: 300, y: 300))
        selection.regionImage = image
        let chat = AskPanelController(selection: selection, iconFrame: NSRect(x: 300, y: 300, width: 22, height: 22))
        chat.debugWireHeadless(engine: engine)
        chat.debugModel.instantText = true
        chat.debugModel.onLearnChange = nil // the toggle must not write your saved Learn setting
        chat.debugModel.speech.canAutoPlay = { false }
        let job = Job(name: name, chat: chat)
        jobs.append(job)
        return job
    }

    /// Runs one question with `personal` as the Context/Rules store (read once, when the chat's session starts).
    private static func ask(_ job: Job, personal: Settings? = nil, _ action: () -> Void) {
        Prompts.personalSource = personal ?? emptySource
        action()
        Prompts.personalSource = emptySource
        job.attachTap()
        calls += 1
    }

    /// Waits for the chat to have `turns` finished turns. The answer as shown, and the raw text the model wrote.
    private static func answer(_ job: Job, turns: Int, seconds: Double = 120) async -> (shown: String, raw: String)? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let t = job.chat.debugTurns
            if t.count >= turns, let last = t.last, last.done {
                let raw = job.raws.count >= turns ? job.raws[turns - 1] : (job.raws.last ?? "")
                let i = turns
                write("\(job.name)-turn\(i).raw.txt", raw)
                write("\(job.name)-turn\(i).shown.txt", last.answer)
                let engine = job.chat.debugEngine
                let plan = job.chat.debugPlan
                note("[\(job.name) #\(i)] engine=\(engine) plan=\(plan.map { "\($0.engine)\($0.lean ? " lean" : "") (\($0.why))\($0.sees ? " sees" : "")" } ?? "-") cli-model=\(job.initModel ?? "?") answered-by=\(job.models.last ?? "?")")
                note("[\(job.name) #\(i)] \(job.usages.last ?? "no usage reported")")
                note("[\(job.name) #\(i)] → " + last.answer.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(600))
                if last.isError { note("[\(job.name) #\(i)] ERROR TURN") }
                return (last.answer, raw)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        check("\(job.name): answer #\(turns) arrived (timed out after \(Int(seconds))s)", false)
        return nil
    }

    private static var suffix = ""

    /// `name.ext` → `name<suffix>.ext`.
    private static func named(_ file: String) -> String {
        guard !suffix.isEmpty, let dot = file.firstIndex(of: ".") else { return file + suffix }
        return String(file[..<dot]) + suffix + String(file[dot...])
    }

    private static func write(_ file: String, _ text: String) {
        try? text.write(to: out.appendingPathComponent(named(file)), atomically: true, encoding: .utf8)
    }

    // MARK: - Reading the answers

    private static func words(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

    private static func has(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The two roots (1 and 3) given as the answer.
    private static func revealsRoots(_ s: String) -> Bool {
        (has(#"x\s*=\s*1(?![\d.])"#, s) && has(#"x\s*=\s*3(?![\d.])"#, s))
            || has(#"(?<![\d.])1\s*(?:and|or|,)\s*(?:x\s*=\s*)?3(?![\d.])"#, s) || has(#"(?<![\d.])3\s*(?:and|or|,)\s*(?:x\s*=\s*)?1(?![\d.])"#, s)
            || has(#"\{\s*1\s*,\s*3\s*\}"#, s)
    }

    private static func factored(_ s: String) -> Bool {
        has(#"\(\s*x\s*-\s*1\s*\)\s*\(\s*x\s*-\s*3\s*\)"#, s) || has(#"\(\s*x\s*-\s*3\s*\)\s*\(\s*x\s*-\s*1\s*\)"#, s)
    }

    struct MathReport {
        var display = 0, inline = 0, auto = 0
        var failed: [String] = []
        var autoFailed: [String] = []
        /// Shown text that still has a raw ^ or a \command after MathPretty: maths nobody handled.
        var leftovers: [String] = []
    }

    /// The answer through the same pieces the chat view uses: Answer.pieces → MarkdownText.segments → MathRender.blocks →
    /// paragraphs and lines → MathRender.inlinePieces (with AutoMath) → MathRender.render, at the sizes MathBlock/MathLine use.
    private static func analyse(_ answer: String) -> MathReport {
        var r = MathReport()
        // An equation that can't be typeset is shown as text (through MathPretty): check that text too.
        func fallback(_ latex: String) {
            if has(#"\^|\\[A-Za-z]+"#, MathPretty.prettify(latex)) { r.leftovers.append(latex) }
        }
        func line(_ text: String) {
            for piece in MathRender.inlinePieces(text) {
                switch piece {
                case .inline(let l), .block(let l):
                    r.inline += 1
                    if MathRender.render(l, size: 15, display: false, dark: false).image == nil { r.failed.append(l); fallback(l) }
                case .auto(let l, let raw):
                    r.auto += 1
                    if MathRender.render(l, size: 15, display: false, dark: false).image == nil { r.autoFailed.append("\(l)  (shown as: \(raw))") }
                case .text(let t):
                    let pretty = MathPretty.prettify(t)
                    if has(#"\^|\\[A-Za-z]+"#, pretty) { r.leftovers.append(t.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        for piece in Answer.pieces(answer, hidePartial: false) {
            guard case .text(let t) = piece else { continue }
            for seg in MarkdownText.segments(t.trimmingCharacters(in: .newlines)) where !seg.isCode {
                for b in MathRender.blocks(seg.text) {
                    switch b {
                    case .block(let l):
                        r.display += 1
                        if MathRender.render(l, size: 18, display: true, dark: false).image == nil { r.failed.append(l); fallback(l) }
                    case .text(let p), .inline(let p), .auto(_, let p):
                        let tidy = p.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                        for para in tidy.components(separatedBy: "\n\n") where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            for l in MarkdownText.lines(para) { line(l.text) }
                        }
                    }
                }
            }
        }
        return r
    }

    private static func mathChecks(_ label: String, shown: String, raw: String, expectDelimiters: Bool) {
        let r = analyse(shown)
        let delimiters = raw.contains("$") || raw.contains("\\(") || raw.contains("\\[")
        note("[\(label)] maths: raw uses LaTeX delimiters=\(delimiters) ($$=\(raw.components(separatedBy: "$$").count - 1 > 0)), display=\(r.display) inline=\(r.inline) auto(AutoMath)=\(r.auto)")
        if expectDelimiters {
            check("\(label): the raw answer writes maths in $…$ / $$…$$ as the prompt asks", delimiters)
            check("\(label): MathRender finds the equations (at least one display or inline piece)", r.display + r.inline > 0)
        }
        check("\(label): every delimited equation typesets (\(r.failed.count) of \(r.display + r.inline) failed)", r.failed.isEmpty)
        for f in r.failed { note("[\(label)] did not typeset: \(f)"); mathFailures.append("\(label): \(f)") }
        if !r.autoFailed.isEmpty {
            note("[\(label)] AutoMath found \(r.autoFailed.count) it could not typeset (shown as raw text by design):")
            for f in r.autoFailed { note("    \(f)"); mathFailures.append("\(label) (auto): \(f)") }
        }
        check("\(label): no raw ^ or \\command is left in the shown text", r.leftovers.isEmpty)
        for l in r.leftovers { note("[\(label)] left raw: \(l.prefix(200))") }
    }

    // MARK: - Pictures

    private static func render(_ name: String, question: String, answer: String, footer: String, dark: Bool = false) {
        let width = AskPanelController.width - 32
        let view = VStack(alignment: .leading, spacing: 8) {
            Text(question).font(.geist(13, .semibold)).fixedSize(horizontal: false, vertical: true)
            AnswerView(text: answer, streaming: false, speech: SpeechStore())
            Text(footer).font(.geist(11, .medium)).foregroundStyle(Theme.inkSecondary.color)
        }
        .foregroundStyle(Theme.ink.color)
        .frame(width: width, alignment: .leading)
        .padding(16)
        .background(Color(white: dark ? 0.16 : 0.97)) // a solid backdrop: dark text snapshots read blank without one
        .environment(\.colorScheme, dark ? .dark : .light)
        // A hosted view, not ImageRenderer: display equations sit in a ScrollView, which ImageRenderer leaves blank.
        // The view is never put in a window, so nothing shows; it is drawn into a 2x bitmap.
        var image: CGImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let host = NSHostingView(rootView: view)
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: width + 32, height: 100)
            host.layoutSubtreeIfNeeded()
            host.frame.size.height = max(40, host.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            if let rep = NSBitmapImageRep.rgba(pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2)) {
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                image = rep.cgImage
            }
        }
        let file = out.appendingPathComponent(named(name + ".png"))
        let ok = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }.map { (try? $0.write(to: file)) != nil } ?? false
        check("picture \(named(name + ".png")) drawn", ok)
    }

    /// The snip: known words, a number and a red circle, drawn in code.
    private static func testImage() -> Data? {
        guard let rep = NSBitmapImageRep.rgba(pixelsWide: 800, pixelsHigh: 450), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 450).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 54), .foregroundColor: NSColor.black]
        NSAttributedString(string: "MERLIN TEST 4729", attributes: attrs).draw(at: NSPoint(x: 40, y: 300))
        NSColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 320, y: 50, width: 180, height: 180)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("C-snip-input.png"))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    // MARK: - The run

    static func run(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true // belt and braces: even a shown chat could not take keys or clicks
        Motion.still = true
        out = URL(fileURLWithPath: directory, isDirectory: true)
        // Options after the folder: only=<name>,<name> (just those chats) and suffix=<text> (added to every file name,
        // so a re-run sits next to the earlier pictures instead of replacing them).
        if let i = CommandLine.arguments.firstIndex(of: "--livecheck") {
            for option in CommandLine.arguments.dropFirst(i + 2) {
                if option.hasPrefix("only=") {
                    only = option.dropFirst(5).split(separator: ",").map(String.init)
                    note("only these chats: \(only!.joined(separator: ", "))")
                } else if option.hasPrefix("suffix=") {
                    suffix = String(option.dropFirst(7))
                }
            }
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-livecheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        Library.overrideDirectory = tempDir.appendingPathComponent("Library") // before anything touches Library.shared
        UsageLog.url = tempDir.appendingPathComponent("usage.jsonl")
        for suite in [emptySuite, rulesSuite] { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        emptySource = Settings(defaults: UserDefaults(suiteName: emptySuite)!)
        rulesSource = Settings(defaults: UserDefaults(suiteName: rulesSuite)!)
        rulesSource.personalContext = testContext
        rulesSource.personalRules = testRules
        Prompts.personalSource = emptySource

        // Always ends, whatever happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 290) {
            check("whole run finished inside the deadline", false)
            finish()
        }

        // D. The proxy, before any call (a call would start it if it's on but not running).
        let settings = Settings.shared
        note("settings (read only): model=\(settings.model.rawValue) quickAnswers=\(settings.localMode) quickModel=\(settings.localModel) effort=\(settings.localEffort) webSearch=\(settings.webSearch) screenContext=\(settings.screenContext.rawValue) screenPermission=\(ScreenCapture.hasPermission)")
        let enabled = BiliProxy.enabled, listening = BiliProxy.isListening()
        note("proxy: enabled=\(enabled) listening on 127.0.0.1:\(BiliProxy.port)=\(listening)")
        if enabled && !listening {
            check("proxy is on but not running: stopping here so no call starts it", false)
            finish()
        }
        var env: [String: String] = [:]
        BiliProxy.apply(to: &env) // safe: it is either off or already running, so this starts nothing
        let routed = env["ANTHROPIC_BASE_URL"]
        check("D: long-lived chats are routed \(routed.map { "through the proxy (\($0))" } ?? "directly (proxy off)") as the current state says",
              enabled ? routed == "http://127.0.0.1:\(BiliProxy.port)" : routed == nil)

        Task { @MainActor in await learnClaude(); await snip(); laneDone() }
        Task { @MainActor in await learnOff(); await learnQuick(); await rules(engine: nil); laneDone() }
        Task { @MainActor in await mathsQuick(); await mathsClaude(); await rules(engine: .claude); laneDone() }
        lanesLeft += 1
        redraw()
        sample()
        symbols()
        lanesLeft += 1
        Task { @MainActor in await cleanChat(sonnet: false); await cleanChat(sonnet: true); laneDone() }
        Task { @MainActor in await bypass(cleanEnvironment: false); await bypass(cleanEnvironment: true); laneDone() }
        lanesLeft += 1
        Task { @MainActor in await webCheck(); laneDone() }

        app.run()
        exit(0)
    }

    /// `--livecheck <dir> only=<name>,<name>` runs just those chats (e.g. only=A-off,A-rules-claude), to save calls.
    private static var only: [String]?
    private static func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

    private static var lanesLeft = 3
    private static func laneDone() {
        lanesLeft -= 1
        if lanesLeft == 0 { Task { @MainActor in await wrapUp() } }
    }

    // A. Learn off: the answer is direct.
    private static func learnOff() async {
        guard wanted("A-off") else { return }
        let job = newChat("A-off", text: problem)
        check("A: with Learn off the system prompt has no highlight rule", !job.systemPrompt.contains(Prompts.learnRule))
        ask(job) { job.chat.debugAsk("Solve it.") }
        guard let a = await answer(job, turns: 1) else { return }
        check("A: Learn off answers directly (x = 1 and x = 3)", revealsRoots(a.shown))
        check("A: no rule text leaks without Rules (doesn't end with DONE)", !endsWithDone(a.shown))
        mathChecks("A-off", shown: a.shown, raw: a.raw, expectDelimiters: job.chat.debugEngine == "claude")
        render("A-learn-off", question: "Solve it.", answer: a.shown, footer: "\(job.chat.debugEngine) · cli model \(job.initModel ?? "?")")
        job.chat.debugSession?.stop()
    }

    // L. Learn mode: key words marked ==like this==. A study question, Learn on, answered by Claude (Sonnet) and by the quick model.
    static let learnQuestion = "Why does the trolley speed up, and how do I work out by how much?"
    static let learnHighlight = "A 2 kg trolley on a frictionless track is pushed by a constant 6 N force."

    static let econQuestion = "Explain this."
    static let econHighlight = "When the price of a good rises, the quantity demanded falls, because buyers switch to substitutes and their real income buys less. This is why a demand curve slopes downward."

    private static func learnClaude() async { await learnCase("L-learn-claude", engine: .claude) }
    private static func learnQuick() async { await learnCase("L-learn-quick", engine: nil); await learnCase("L-learn-quick-econ", engine: nil, question: econQuestion, highlight: econHighlight)
        await learnCase("L-learn-fact", engine: nil, question: "What is the SI unit of force?", highlight: learnHighlight, marks: 0...2, wordLimit: 0...40)
        await learnCase("L-learn-long", engine: nil, question: "Summarise this so I can revise from it.", highlight: longHighlight, marks: 2...8, wordLimit: 200...700, structured: true)
        await learnCase("L-learn-long-claude", engine: .claude, question: "Summarise this so I can revise from it.", highlight: longHighlight, marks: 2...8, wordLimit: 200...700, structured: true) }

    /// A dense passage: a good summary has to keep its numbers and names.
    static let longHighlight = """
    Photosynthesis happens in two linked stages inside the chloroplast. The light-dependent reactions take place on the thylakoid membranes, which are stacked into grana. Light is absorbed by chlorophyll a and b and by carotenoids in photosystem II (P680) and photosystem I (P700). In photosystem II, light energy excites electrons, which leave the chlorophyll and are replaced by electrons from the photolysis of water: 2H2O gives 4H+, 4e- and O2. The excited electrons pass along an electron transport chain of carriers including plastoquinone and cytochrome b6f, losing energy that is used to pump protons from the stroma into the thylakoid lumen. The resulting proton gradient drives ATP synthase, making ATP from ADP and inorganic phosphate; this is called photophosphorylation. In non-cyclic photophosphorylation the electrons continue to photosystem I, are excited again, and are passed through ferredoxin to NADP reductase, which reduces NADP+ to NADPH. In cyclic photophosphorylation, electrons from photosystem I return to the transport chain, producing ATP but no NADPH and no oxygen. The light-independent reactions, the Calvin cycle, occur in the stroma. First, in carbon fixation, the enzyme RuBisCO joins CO2 to the five-carbon sugar ribulose bisphosphate (RuBP), forming an unstable six-carbon compound that splits at once into two molecules of glycerate 3-phosphate (GP). Second, in reduction, each GP is reduced to triose phosphate (TP) using ATP and NADPH from the light-dependent stage. Third, in regeneration, five out of every six TP molecules are used to rebuild RuBP, which costs more ATP. For every three turns of the cycle, three CO2 are fixed, nine ATP and six NADPH are used, and one TP leaves the cycle; two TP are needed to make one glucose, so one glucose takes six turns, 18 ATP and 12 NADPH. Three factors commonly limit the rate: light intensity, which limits ATP and NADPH supply; carbon dioxide concentration, normally about 0.04 percent of air, which limits fixation; and temperature, because RuBisCO and the other enzymes work fastest around 25 to 30 degrees Celsius and denature above about 45. RuBisCO can also react with oxygen instead of CO2, a wasteful process called photorespiration that becomes worse in hot, dry conditions when stomata close.
    """

    private static func learnCase(_ name: String, engine: Router.Plan.Engine?, question: String? = nil, highlight: String? = nil,
                                  marks: ClosedRange<Int> = 2...5, wordLimit: ClosedRange<Int>? = nil, structured: Bool = false) async {
        guard wanted(name) else { return }
        let question = question ?? learnQuestion, highlight = highlight ?? learnHighlight
        let job = newChat(name, text: highlight, engine: engine)
        let model = job.chat.debugModel
        model.toggleLearn()
        check("\(name): Learn is on for this chat", model.learnApplies)
        ask(job) { job.chat.debugAsk(question) }
        let system = job.systemPrompt
        write("\(name).system.txt", system)
        check("\(name): the system prompt carries the highlight rule", system.contains(Prompts.learnRule))
        note("[\(name)] the rule is \(Prompts.learnRule.count) characters, about \(Prompts.learnRule.count / 4) input tokens (an estimate, not measured)")
        guard let a = await answer(job, turns: 1) else { return }
        let marked = Highlights.split(a.raw).filter { $0.marked }.map(\.text)
        note("[\(name)] \(marked.count) marks: \(marked.map { "“\($0)”" }.joined(separator: ", "))")
        note("[\(name)] answer length: \(words(a.shown)) words")
        check("\(name): \(marks.lowerBound)-\(marks.upperBound) marks (got \(marked.count))", marks.contains(marked.count))
        if let wordLimit { check("\(name): \(wordLimit.lowerBound)-\(wordLimit.upperBound) words (got \(words(a.shown)))", wordLimit.contains(words(a.shown))) }
        if structured {
            check("\(name): opens with In short", a.shown.contains("In short:"))
            check("\(name): ends with Remember", a.shown.contains("Remember:"))
            check("\(name): uses bullets, no # headings or tables", a.raw.contains("\n- ") && !a.raw.contains("\n#") && !a.raw.contains("|--"))
            let kept = ["P680", "P700", "RuBisCO", "18", "12", "0.04", "photorespiration", "ferredoxin", "cyclic"]
            let lost = kept.filter { !a.shown.localizedCaseInsensitiveContains($0) }
            check("\(name): keeps the passage's details (lost: \(lost.isEmpty ? "none" : lost.joined(separator: ", ")))", lost.count <= 1)
        }
        check("\(name): no mark is a whole sentence (each ≤ 8 words)", marked.allSatisfy { words($0) <= 8 })
        check("\(name): no raw == is left after stripping", !Highlights.strip(a.raw).contains("=="))
        check("\(name): no mark sits inside maths or code", marked.allSatisfy { !$0.contains("$") && !$0.contains("`") })
        mathChecks(name, shown: a.shown, raw: a.raw, expectDelimiters: false)
        render(name, question: question, answer: a.shown,
               footer: "Learn on · \(job.chat.debugEngine) · cli model \(job.initModel ?? "?") · \(marked.count) marks")
        job.chat.debugSession?.stop()
    }

    /// No model call: a fixed answer with every kind of mark, drawn in light and dark (only when `only=` names `sample`).
    static let sampleAnswer = """
    A constant force gives a **==constant acceleration==**: ==Newton's second law== says $F = ma$, so $a = F/m = 6/2 = 3\\,\\text{m/s}^2$.

    1. Find the ==resultant force== on the trolley: here it is just the 6 N push, because there is no friction.
    2. Divide by the mass, in ==kilograms==, to get ==a = F/m==.
    3. Because ==a is constant==, the speed grows by the same amount every second, so $v = u + at$ and $a == b$ in code stays plain.

    Use `a == b` in code and ==**bold inside a mark**== or ==a mark long enough that it has to wrap onto the next line==, and ==unclosed
    """
    private static func sample() {
        guard only?.contains("sample") == true else { return }
        for dark in [false, true] {
            render(dark ? "sample-dark" : "sample-light", question: "Why does the trolley speed up?", answer: sampleAnswer,
                   footer: "Fixed sample, no model call · \(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// D. One short quick-model chat with the proxy switched off in memory (the app's own switch, through the registration
    /// domain, which is never saved), and the CLI's debug log on, to see every API request it makes after the answer.
    /// `cleanEnvironment` also leaves out the CLAUDE_* variables this process inherited (from the Claude app that ran it).
    private static func bypass(cleanEnvironment: Bool) async {
        let name = cleanEnvironment ? "D-bypass-cleanenv" : "D-bypass"
        guard wanted(name) else { return }
        let job = newChat(name, text: "Photosynthesis turns light into chemical energy.")
        let debugLog = out.appendingPathComponent(named(name + "-cli-debug.log"))
        try? FileManager.default.removeItem(at: debugLog)
        var saved: [String: String] = [:]
        if cleanEnvironment {
            for (key, value) in ProcessInfo.processInfo.environment
            where key.hasPrefix("CLAUDE") || key == "AI_AGENT" || key == "BAGGAGE" || key.hasPrefix("COMPACT_PLUS") {
                saved[key] = value
                unsetenv(key)
            }
            note("[\(name)] left out \(saved.count) inherited variables: \(saved.keys.sorted().joined(separator: " "))")
        }
        UserDefaults.standard.register(defaults: ["useBilliContext": false])
        ClaudeSession.debugExtraArguments = ["--debug-file", debugLog.path]
        var env: [String: String] = [:]
        BiliProxy.apply(to: &env)
        check("\(name): the proxy is off for this chat only (no ANTHROPIC_BASE_URL set)", !BiliProxy.enabled && env["ANTHROPIC_BASE_URL"] == nil)
        ask(job) { job.chat.debugAsk("In one sentence, what does this mean?") }
        ClaudeSession.debugExtraArguments = []
        UserDefaults.standard.register(defaults: ["useBilliContext": true])
        for (key, value) in saved { setenv(key, value, 1) }
        guard await answer(job, turns: 1) != nil else { return }
        // The side request comes after the answer: give it time before the session is stopped.
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        job.chat.debugSession?.stop()
        let log = (try? String(contentsOf: debugLog, encoding: .utf8)) ?? ""
        let requests = log.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains("/v1/messages") || $0.contains("querySource") || $0.contains("[API") }
        note("[\(name)] CLI debug log: \(log.count) chars, \(requests.count) lines about API requests (see \(debugLog.lastPathComponent))")
        check("\(name): the CLI wrote a debug log", !log.isEmpty)
    }

    /// No model call: draws an answer saved by an earlier run again with today's code (only when `only=` names `redraw`).
    /// Used to compare list layout before and after a change on the very same text.
    private static func redraw() {
        guard only?.contains("redraw") == true else { return }
        // (saved answer, picture name, run the maths checks on it)
        let saved = [("L-learn-claude-turn1.raw.txt", "L-learn-claude-redrawn", false),
                     ("L-learn-quick-turn1.raw.txt", "L-learn-quick-redrawn", false)]
        for (source, name, maths) in saved {
            guard let raw = try? String(contentsOf: out.appendingPathComponent(source), encoding: .utf8) else {
                check("redraw: \(source) is there from an earlier run", false)
                continue
            }
            let text = Answer.withoutMeta(raw) // what the chat shows
            if maths { mathChecks("redraw \(name)", shown: text, raw: raw, expectDelimiters: true) }
            check("redraw \(name): no ** left on screen", !shownText(text).contains("**"))
            render(name, question: learnQuestion, answer: text, footer: "Redrawn from \(source) (no model call)")
        }
    }

    /// The answer's prose as the chat shows it (markdown applied, equations as their LaTeX), to look for stray marks.
    private static func shownText(_ answer: String) -> String {
        var out = ""
        for piece in Answer.pieces(answer, hidePartial: false) {
            guard case .text(let t) = piece else { continue }
            for seg in MarkdownText.segments(t) where !seg.isCode {
                for b in MathRender.blocks(seg.text) {
                    guard case .text(let p) = b else { continue }
                    for para in p.components(separatedBy: "\n\n") {
                        for l in MarkdownText.lines(para) {
                            for ip in MathRender.inlinePieces(l.text) {
                                if case .text(let t) = ip { out += String(MarkdownText.inline(t).characters) }
                            }
                            out += "\n"
                        }
                    }
                }
            }
        }
        return out
    }

    /// E. A normal proxied chat, run from this shell (which still has the Claude app's variables): with the cleaned
    /// environment no side query should follow the answer (see the proxy log for `_sub`). The Sonnet one keeps a CLI
    /// debug log, to read the effort it used.
    private static func cleanChat(sonnet: Bool) async {
        let name = sonnet ? "E-sonnet" : "E-quick"
        guard wanted(name) else { return }
        let job = newChat(name, text: "Photosynthesis turns light into chemical energy.", engine: sonnet ? .claude : nil)
        let debugLog = out.appendingPathComponent(named(name + "-cli-debug.log"))
        if sonnet { ClaudeSession.debugExtraArguments = ["--debug-file", debugLog.path] }
        ask(job) { job.chat.debugAsk("In one sentence, what does this mean?") }
        ClaudeSession.debugExtraArguments = []
        guard await answer(job, turns: 1) != nil else { return }
        try? await Task.sleep(nanoseconds: 12_000_000_000) // a side query would go out around now
        job.chat.debugSession?.stop()
        if sonnet {
            let log = (try? String(contentsOf: debugLog, encoding: .utf8)) ?? ""
            let sideQueries = log.components(separatedBy: "\n").filter { $0.contains("source=side_query") }.count
            let effort = log.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains("effort") }
            note("[\(name)] CLI debug log: side queries=\(sideQueries); lines about effort: \(effort.count)")
            for line in effort.prefix(6) { note("    " + String(line.prefix(220))) }
            check("\(name): no side query in the CLI's own log", sideQueries == 0)
        }
    }

    /// No model call: which LaTeX commands models like to write SwiftMath can typeset, and what is shown when it can't
    /// (only when `only=` names `symbols`). The list is the unit tests' (`FeatureTests.symbolSamples`).
    private static func symbols() {
        guard only?.contains("symbols") == true else { return }
        for latex in FeatureTests.symbolSamples {
            let typeset = MathRender.render(latex, size: 18, display: true, dark: false).image != nil
            let shown = String(MarkdownText.inline(MathRender.fallbackText(latex)).characters)
            note("symbol \(typeset ? "TYPESETS" : "fails   ") \(latex)   → fallback shows: \(shown)")
        }
        render("symbols", question: "Each sample, then typeset", answer: FeatureTests.symbolSamples.map { "`\($0)`\n\n$$\($0)$$" }.joined(separator: "\n\n"),
               footer: "MathRender.render after substitutes (no model call)")
    }

    private static func endsWithDone(_ s: String) -> Bool {
        let tail = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "*_`")))
        return tail.hasSuffix("DONE")
    }

    // A. Rules and Context reach the model and change the answer.
    private static func rules(engine: Router.Plan.Engine?) async {
        let name = engine == .claude ? "A-rules-claude" : "A-rules"
        guard wanted(name) else { return }
        let job = newChat(name, text: "Cats sleep for 12 to 16 hours a day.", engine: engine)
        var system = ""
        // Read inside: ClaudeSession works its prompt out again on every read, so read it while the test store is in place.
        ask(job, personal: rulesSource) {
            job.chat.debugAsk("What's my cat's name, and roughly how many hours a day will she sleep?")
            system = job.systemPrompt
        }
        check("\(name): Context and Rules are in the session's system prompt", system.contains(testContext) && system.contains(testRules))
        write("\(name).system.txt", system)
        guard let a = await answer(job, turns: 1) else { return }
        check("\(name): Context reached the model (it knows the cat is Biscuit)", a.shown.contains("Biscuit"))
        check("\(name): the Rule changed the answer (ends with DONE)", endsWithDone(a.shown))
        render(name, question: "What's my cat's name, and roughly how many hours a day will she sleep?", answer: a.shown,
               footer: "Rules + Context set · \(job.chat.debugEngine) · cli model \(job.initModel ?? "?")")
        job.chat.debugSession?.stop()
    }

    // B. Maths through whoever the router picks (with Quick Answers on, that is the quick model).
    private static func mathsQuick() async {
        guard wanted("B-maths-quick") else { return }
        let job = newChat("B-maths-quick", text: "the quadratic formula")
        ask(job) { job.chat.debugAsk("What is the quadratic formula, and how would I use it on 2x^2 + 3x - 2 = 0?") }
        let system = job.systemPrompt
        note("[B-maths-quick] system prompt has the maths (LaTeX) rule: \(system.contains(Prompts.mathsRule))")
        write("B-maths-quick.system.txt", system)
        guard let a = await answer(job, turns: 1) else { return }
        mathChecks("B-maths-quick", shown: a.shown, raw: a.raw, expectDelimiters: system.contains(Prompts.mathsRule))
        render("B-maths-quick", question: "What is the quadratic formula, and how would I use it on 2x^2 + 3x - 2 = 0?", answer: a.shown,
               footer: "\(job.chat.debugEngine) · cli model \(job.initModel ?? "?")")
        job.chat.debugSession?.stop()
    }

    // B. Physics formulas from Claude (the engine button set to Claude).
    private static func mathsClaude() async {
        guard wanted("B-maths-claude") else { return }
        let job = newChat("B-maths-claude", text: "A simple pendulum, and a rocket leaving Earth.", engine: .claude)
        let q = "Give the formula for the period of a simple pendulum and the formula for escape velocity, and say what each symbol means."
        ask(job) { job.chat.debugAsk(q) }
        let system = job.systemPrompt
        check("B-maths-claude: the session's system prompt asks for LaTeX", system.contains(Prompts.mathsRule))
        write("B-maths-claude.system.txt", system)
        guard let a = await answer(job, turns: 1) else { return }
        mathChecks("B-maths-claude", shown: a.shown, raw: a.raw, expectDelimiters: true)
        check("B-maths-claude: it uses a fraction or root (\\frac or \\sqrt)", a.raw.contains("\\frac") || a.raw.contains("\\sqrt"))
        render("B-maths-claude", question: q, answer: a.shown, footer: "\(job.chat.debugEngine) · cli model \(job.initModel ?? "?")")
        render("B-maths-claude-dark", question: q, answer: a.shown, footer: "\(job.chat.debugEngine) · cli model \(job.initModel ?? "?")", dark: true)
        job.chat.debugSession?.stop()
    }

    // W. Web everywhere: the quick engine (Haiku) searches when the question needs it and not otherwise. Chats W-latest and
    // W-plain go through the chat's own routing (the quick engine, your web setting read as it is); W-plain-off is the same
    // plain question sent to a quick session built without the web tools, to measure what carrying them costs per question.
    // 3 real calls.
    private static let webPlainSelection = "A closure captures the variables around it by reference, so a later change is visible inside it."
    private static let webPlainQuestion = "Explain this more simply."
    private static let webLatestQuestion = "What is the latest stable version of Swift, and what is its release date?"

    private static func webCheck() async {
        let settings = Settings.shared
        for (name, text, question, expectSearch) in [("W-latest", "Swift is Apple's programming language.", webLatestQuestion, true),
                                                    ("W-plain", webPlainSelection, webPlainQuestion, false)] {
            guard wanted(name) else { continue }
            let job = newChat(name, text: text, engine: .local)
            let started = Date()
            ask(job) { job.chat.debugAsk(question) }
            let plan = job.chat.debugPlan
            let system = job.systemPrompt
            write("\(name).system.txt", system)
            note("[\(name)] webSetting=\(settings.webSearch) plan.web=\(plan?.web == true) quick-engine=\(plan?.isLocal == true) tools-launched=\(job.claude?.toolNames.joined(separator: ",") ?? "-") rule-in-prompt=\(system.contains(Prompts.quickWebRule))")
            check("\(name): quick engine with the web tools and the rule (web setting on)",
                  plan?.isLocal == true && plan?.web == true && job.claude?.toolNames == ["WebSearch", "WebFetch"] && system.contains(Prompts.quickWebRule))
            guard let a = await answer(job, turns: 1) else { return }
            let seconds = Date().timeIntervalSince(started)
            note("[\(name)] web tools called: \(job.tools.isEmpty ? "none" : job.tools.joined(separator: ", ")) · wall time \(String(format: "%.1f", seconds)) s · footnote: \(job.chat.debugFootnote)")
            check("\(name): \(expectSearch ? "searched the web" : "did NOT search the web")", expectSearch ? !job.tools.isEmpty : job.tools.isEmpty)
            check("\(name): the answer is not empty and has no raw tool output", !a.shown.isEmpty && !a.shown.contains("tool_use") && !a.shown.contains("\"type\":"))
            if expectSearch { check("\(name): ends with Sources and a link", has(#"Sources?:?[\s\S]*\]\(http"#, a.shown) || has(#"Sources?:?[\s\S]*https?://"#, a.shown)) }
            job.chat.debugSession?.stop()
        }
        guard wanted("W-plain-off") else { return }
        // The same plain question to a quick Haiku session without the web tools or the rule.
        let model = settings.localModel
        let features = Prompts.features(question: webPlainQuestion, selection: webPlainSelection, context: nil)
        let session = LocalSession(model: model, system: Prompts.quickSystem(seeing: true, model: model, features: features, web: false), web: false)
        let text = Prompts.first(app: "Preview", selection: webPlainSelection, context: nil, question: webPlainQuestion,
                                 hasScreenshot: false, hasSnip: false, selectionLimit: Prompts.maxSelection, earlier: [])
        var shown = "", usage: ClaudeSession.Usage?, done = false, failed: String?
        var toolCalls: [String] = []
        session.onEvent = { event in
            switch event {
            case .delta(let t): shown += t
            case .turnDone: done = true
            case .error(let r), .unavailable(let r): failed = r; done = true
            case .activity: break
            }
        }
        session.onUsage = { usage = $0 }
        session.debugClaude?.debugLineTap = { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "assistant" else { return }
            for block in ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []) where block["type"] as? String == "tool_use" {
                toolCalls.append(block["name"] as? String ?? "?")
            }
        }
        check("W-plain-off: launched with no tools", session.debugClaude?.toolNames == [] && !(session.startingSystemPrompt.contains(Prompts.quickWebRule)))
        write("W-plain-off.system.txt", session.startingSystemPrompt)
        let started = Date()
        do { try session.start() } catch { check("W-plain-off: started", false); return }
        session.send(text, images: [])
        calls += 1
        while !done && Date().timeIntervalSince(started) < 120 { try? await Task.sleep(nanoseconds: 250_000_000) }
        let seconds = Date().timeIntervalSince(started)
        write("W-plain-off-turn1.shown.txt", shown)
        if let u = usage {
            note("[W-plain-off] in=\(u.inputTokens) cache_write=\(u.cacheCreationTokens) cache_read=\(u.cacheReadTokens) out=\(u.outputTokens) · total-in=\(u.inputTokens + u.cacheCreationTokens + u.cacheReadTokens) · web tools called: \(toolCalls.isEmpty ? "none" : toolCalls.joined(separator: ", ")) · wall time \(String(format: "%.1f", seconds)) s")
        }
        note("[W-plain-off] → " + shown.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(600))
        check("W-plain-off: answered, no error", done && failed == nil && !shown.isEmpty)
        session.stop()
    }

    // C. A snip answered by the quick model, with the picture.
    private static func snip() async {
        guard wanted("C-snip") else { return }
        guard let jpeg = testImage() else { return check("C: test picture drawn", false) }
        let job = newChat("C-snip", text: "", image: jpeg)
        let q = "What text and number does this show, and what shape and colour is next to it?"
        ask(job) { job.chat.debugAsk(q) }
        let plan = job.chat.debugPlan
        check("C: a snip goes to the quick model, which sees it (plan: \(plan.map { "\($0.engine) \($0.why) sees=\($0.sees)" } ?? "none"))",
              plan?.isLocal == true && plan?.sees == true && job.chat.debugEngine == "local")
        guard let a = await answer(job, turns: 1) else { return }
        let low = a.shown.lowercased()
        check("C: the answer reads the number 4729", a.shown.contains("4729"))
        check("C: the answer reads the words MERLIN TEST", low.contains("merlin test"))
        check("C: the answer sees the red circle", low.contains("red") && low.contains("circle"))
        check("C: the CLI started Haiku 5.5 (\(job.initModel ?? "?"))", job.initModel == "claude-haiku-5-5")
        check("C: Haiku 5.5 is the model that answered (\(job.models.last ?? "?"))", job.models.last?.contains("claude-haiku-5-5") == true)
        check("C: the chat labels it Answered by \(EngineLabel.full(Settings.shared.localModel))", job.chat.debugTurns.last?.localModel == "claude-haiku-5-5")
        render("C-snip-answer", question: q, answer: a.shown, footer: "Answered by \(EngineLabel.full(Settings.shared.localModel)) · cli model \(job.initModel ?? "?")")
        job.chat.debugSession?.stop()
    }

    private static func wrapUp() async {
        // D. Every chat went out the way the proxy state says.
        let ids = jobs.compactMap(\.sessionID)
        note("session ids (look for them in the proxy log): \(ids.joined(separator: " "))")
        check("D: every chat's long-lived session answered (\(jobs.filter { !$0.raws.isEmpty }.count) of \(jobs.count))", jobs.allSatisfy { !$0.raws.isEmpty })
        if !mathFailures.isEmpty {
            note("LaTeX that did not typeset:")
            for f in mathFailures { note("  " + f) }
        }
        finish()
    }

    private static func finish() -> Never {
        for job in jobs { job.chat.debugSession?.stop() }
        Prompts.personalSource = Settings.shared
        for suite in [emptySuite, rulesSuite] { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        log("real model calls sent: \(calls)")
        log(failures == 0 ? "LIVECHECK PASS" : "LIVECHECK FAIL (\(failures))")
        write("livecheck-log.txt", lines.joined(separator: "\n"))
        exit(failures == 0 ? 0 : 1)
    }
}
