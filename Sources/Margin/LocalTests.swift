import AppKit
import Foundation

/// Tests for Local mode: the router, the Ollama plumbing, the usage log, and (with `--localtest`) a real
/// round trip through Ollama and the chat window.
enum LocalTests {
    // MARK: - Unit tests (no Ollama, no Claude)

    static func unit(_ check: (String, Bool) -> Void) {
        let passage = "Opportunity cost is the value of the next-best alternative you give up when you make a choice."

        func plan(_ prompt: String, selection: String = passage, context: String? = nil, snip: Bool = false,
                  blank: Bool = false, video: Bool = false, local: Bool = true, usable: Bool = true) -> Router.Plan {
            Router.plan(.init(prompt: prompt, selection: selection, context: context, hasSnip: snip, isBlank: blank,
                              isVideo: video, localMode: local, localUsable: usable))
        }
        func claudeFull(_ p: Router.Plan) -> Bool { p.engine == .claude && !p.lean }
        func claudeLean(_ p: Router.Plan) -> Bool { p.engine == .claude && p.lean }

        // Who answers
        let simpler = Prompts.chips[0].prompt
        check("router: Local mode off sends a quick question to Claude, as before",
              claudeFull(plan(simpler, local: false)))
        for chip in Prompts.chips.prefix(3) {
            check("router: the \(chip.label) chip is answered locally", plan(chip.prompt).isLocal)
        }
        check("router: a typed clarifying question is local", plan("What does 'marginal' mean here?").isLocal)
        check("router: Ollama known to be down sends it to Claude", claudeFull(plan(simpler, usable: false)))
        check("router: Pronounce is a lean Claude call", claudeLean(plan(Prompts.pronounce)))
        check("router: Visualize is a lean Claude call", claudeLean(plan(Prompts.visualize)))
        check("router: lean even with Local mode off", claudeLean(plan(Prompts.pronounce, local: false)))
        for kind in Prompts.Summary.allCases {
            check("router: a short \(kind.title) summary is local", plan(kind.prompt).isLocal)
            check("router: a long summary (3,500 characters) is local too", plan(kind.prompt, selection: String(repeating: "word ", count: 700)).isLocal)
            check("router: a summary over \(Router.maxLocalSummary) characters is a lean Claude call",
                  claudeLean(plan(kind.prompt, selection: String(repeating: "word ", count: 4500))))
            check("router: a summary with Local mode off is a lean Claude call", claudeLean(plan(kind.prompt, local: false)))
        }
        check("router: a summary of the screen (nothing highlighted) keeps the screenshot",
              claudeFull(plan(Prompts.Summary.meaning.prompt, selection: "", blank: true)))
        check("router: a blank chat goes to Claude with the screenshot", claudeFull(plan("What is this?", selection: "", blank: true)))
        check("router: a snip with a typed question goes to Claude in full", claudeFull(plan("What is this?", selection: "", snip: true)))
        check("router: pronouncing a snip is lean", claudeLean(plan(Prompts.pronounce, selection: "", snip: true)))
        check("router: video goes to Claude in full", claudeFull(plan("Summarize this video", video: true)))
        check("router: a highlight past \(Router.maxLocalSelection) characters goes to Claude",
              claudeFull(plan(simpler, selection: String(repeating: "x", count: Router.maxLocalSelection + 1))))

        // Language
        check("router: Russian text goes to Claude", claudeFull(plan(simpler, selection: "Я закрыл дверь на замок.")))
        check("router: so does a Russian word in a question", claudeFull(plan("What does замок mean?")))
        check("router: Chinese goes to Claude", claudeFull(plan(simpler, selection: "我喜欢学习")))
        check("router: Greek and math letters are fine", plan(simpler, selection: "Let θ = π/3 and x ≥ α², so ℝ").isLocal)
        check("router: accented Latin is fine", plan(simpler, selection: "Le café est très près d'ici, naïve façade").isLocal)
        check("router: a Russian summary is lean Claude", claudeLean(plan(Prompts.Summary.meaning.prompt, selection: "Привет, как дела?")))
        check("language: counts only other scripts",
              Router.nonLatinLetterCount("Привет") == 6 && Router.nonLatinLetterCount("日本語") == 3
              && Router.nonLatinLetterCount("θ π σ ℝ 𝑥 é") == 0)

        // Questions only Claude can answer well
        let needsClaude = [
            "What's the latest version of this?", "Is this still current?", "Verify this for me", "Is this accurate?",
            "Fact-check that", "Check if that's right", "What happened in 2026?", "What's the price of it?",
            "Look up the source", "Give me a source", "Is it true?", "What does this button do?",
            "What's in the screenshot?", "How do you say this in French?", "Pronounce it slowly", "Translate this",
            "Draw this", "Plot the function", "Make a chart of it", "Explain with a diagram", "Solve for x",
            "Calculate the total", "Can you search for it?",
        ]
        for q in needsClaude {
            check("router: \"\(q)\" goes to Claude", claudeFull(plan(q)))
        }
        let staysLocal = [
            "Why does that matter?", "What does 'source code' mean here?", "What is open source?",
            "Can you give me a real-life example?", "I don't get the second sentence", "What's opportunity cost?",
            "How is that different from a sunk cost?", "Say that in simpler words", "Explain it like I'm ten",
            "What does 'marginal' mean?", "Who first described this idea?",
        ]
        for q in staysLocal {
            check("router: \"\(q)\" stays local", plan(q).isLocal)
        }
        check("router: the quick-question chips don't trip the keywords",
              Prompts.chips.prefix(3).allSatisfy { !Router.needsClaude($0.prompt) } && !Router.needsClaude(Prompts.deeper)
              && !Router.needsClaude(Prompts.emptySubmit))

        // Follow-ups
        let local = plan(simpler)
        let lean = plan(Prompts.pronounce)
        let full = plan(simpler, local: false)
        check("follow-up: a local chat stays local for an ordinary question", !Router.needsEscalation("And why is that?", from: local))
        check("follow-up: a local chat moves to Claude to check something", Router.needsEscalation("Is that the latest?", from: local))
        check("follow-up: a local chat moves to Claude to pronounce", Router.needsEscalation("How do I say it?", from: local))
        check("follow-up: a lean Claude chat can still draw and pronounce", !Router.needsEscalation("Draw it, and say it", from: lean))
        check("follow-up: a lean Claude chat moves to a full one for the web", Router.needsEscalation("What's the latest on this?", from: lean))
        check("follow-up: ... or for the screen", Router.needsEscalation("What does this button do?", from: lean))
        check("follow-up: a full Claude chat never moves", !Router.needsEscalation("What's the latest on this?", from: full))
        check("warm-up: only for a text highlight with Local mode on",
              Router.mayGoLocal(selection: passage, hasSnip: false, isVideo: false, localMode: true)
              && !Router.mayGoLocal(selection: passage, hasSnip: false, isVideo: false, localMode: false)
              && !Router.mayGoLocal(selection: "", hasSnip: false, isVideo: false, localMode: true)
              && !Router.mayGoLocal(selection: passage, hasSnip: true, isVideo: false, localMode: true)
              && !Router.mayGoLocal(selection: "замок", hasSnip: false, isVideo: false, localMode: true))

        // Think-tag filter
        func filtered(_ pieces: [String]) -> String {
            var f = ThinkFilter()
            return pieces.map { f.feed($0) }.joined() + f.finish()
        }
        check("think: nothing to remove", filtered(["Hello ", "there."]) == "Hello there.")
        check("think: a block is removed", filtered(["<think>secret</think>Hello"]) == "Hello")
        check("think: tags split across chunks", filtered(["<thi", "nk>abc</th", "ink>\n\nHel", "lo"]) == "Hello")
        check("think: the blank lines after a block go too", filtered(["<think>\n</think>\n\nAnswer."]) == "Answer.")
        check("think: leading blank lines go", filtered(["\n\n", "Answer"]) == "Answer")
        check("think: an unfinished block is dropped", filtered(["Before <think>half a thought"]) == "Before ")
        check("think: a lone < is shown once it can't be a tag", filtered(["a <", "b> c"]) == "a <b> c")
        check("think: a half-arrived tag at the end is released", filtered(["a <thi"]) == "a <thi")
        check("think: math with < is untouched", filtered(["if x < 3 and y > 2"]) == "if x < 3 and y > 2")

        // Ollama replies
        let line = #"{"model":"qwen3:8b","message":{"role":"assistant","content":"Hi"},"done":false}"#
        check("ollama: a content line", LocalSession.chunk(from: line) == LocalSession.Chunk(text: "Hi"))
        let end = #"{"message":{"role":"assistant","content":""},"done":true,"total_duration":2500000000,"prompt_eval_count":120,"eval_count":45}"#
        let last = LocalSession.chunk(from: end)
        check("ollama: the last line carries the counts",
              last?.done == true && last?.promptTokens == 120 && last?.outputTokens == 45 && last?.totalSeconds == 2.5)
        check("ollama: an error line", LocalSession.chunk(from: #"{"error":"model 'x' not found"}"#)?.error == "model 'x' not found")
        check("ollama: junk is ignored", LocalSession.chunk(from: "not json") == nil)
        let tags = Data(#"{"models":[{"name":"qwen3:8b"},{"name":"llama3.2:latest"}]}"#.utf8)
        check("ollama: finds an installed model", OllamaClient.hasModel("qwen3:8b", inTags: tags))
        check("ollama: a name without a tag means :latest", OllamaClient.hasModel("llama3.2", inTags: tags))
        check("ollama: a missing model", !OllamaClient.hasModel("qwen3:14b", inTags: tags) && !OllamaClient.hasModel("qwen3", inTags: tags))
        check("ollama: an empty server", !OllamaClient.hasModel("qwen3:8b", inTags: Data("{}".utf8)))
        let down = LocalSession.explain(URLError(.cannotConnectToHost))
        check("ollama: connection refused reads as not running", down.1 == .notRunning && down.0.contains("isn't running"))
        let missing = LocalSession.explain(LocalSession.ServerError(status: 404, message: "model \"qwen3:8b\" not found, try pulling it first"))
        check("ollama: 404 reads as model missing", missing.1 == .modelMissing && missing.0.contains("ollama pull"))
        check("ollama: usable means ready or not checked yet",
              OllamaClient.Status.unknown.isUsable && OllamaClient.Status.ready.isUsable
              && !OllamaClient.Status.notRunning.isUsable && !OllamaClient.Status.modelMissing.isUsable)

        // Prompts
        check("prompt: the local prompt has no voice or graph rules",
              !Prompts.localSystem.contains("<say") && !Prompts.localSystem.contains("<graph") && !Prompts.localSystem.contains("screenshot"))
        check("prompt: the local prompt owns up to what it can't check", Prompts.localSystem.contains("can't search the web"))
        let moved = Prompts.first(app: "Safari", selection: "foo", context: nil, question: "Is that the latest?",
                                  earlier: [("Explain this more simply.", "It means foo.")])
        check("prompt: an escalated chat carries what was said, before the new question",
              moved.contains("Q: Explain this more simply.\nA: It means foo.")
              && (moved.range(of: "A: It means foo.")!.upperBound <= moved.range(of: "Question: Is that the latest?")!.lowerBound))
        check("prompt: no earlier exchanges adds nothing",
              !Prompts.first(app: "Safari", selection: "foo", context: nil, question: "why?").contains("Earlier in this chat"))
        let speaking = "Say <say lang=\"ru-RU\" ipa=\"zɐˈmok\">замо́к</say> like this. <graph>{\"plots\":[]}</graph> See?"
        let plain = Answer.plainText(speaking)
        check("prompt: voice clips and graphs become plain words in a history",
              plain.contains("“замо́к”") && plain.contains("[a graph was shown here]") && !plain.contains("<"))

        // Usage log and savings estimates
        check("savings: a local first question saves the 3.5k base plus screenshot and web tools",
              UsageLog.savedByLocal(followUp: false, screenshot: true, web: true) == 7000)
        check("savings: a local follow-up", UsageLog.savedByLocal(followUp: true, screenshot: true, web: true) == 7100)
        check("savings: nothing extra to save with the screenshot and web off",
              UsageLog.savedByLocal(followUp: false, screenshot: false, web: false) == 3500
              && UsageLog.savedByLean(screenshot: false, web: false) == 0)
        check("savings: a lean call saves the screenshot and web tools", UsageLog.savedByLean(screenshot: true, web: true) == 3500)
        func entry(_ engine: String, lean: Bool = false, input: Int = 0, cached: Int = 0, output: Int = 0, saved: Int = 0, daysAgo: Double = 0) -> UsageLog.Entry {
            var e = UsageLog.Entry(engine: engine, saved: saved)
            e.lean = lean
            e.input = input
            e.cached = cached
            e.output = output
            e.time = Date().addingTimeInterval(-daysAgo * 86_400)
            return e
        }
        let log = [entry("claude", input: 100, cached: 3000, output: 150),
                   entry("claude", lean: true, input: 80, cached: 1500, output: 120, saved: 3500),
                   entry("local", input: 400, output: 60, saved: 7000),
                   entry("local", input: 450, output: 70, saved: 7000),
                   UsageLog.Entry.reask(saving: 7000)]
        let sum = UsageLog.summarize(log)
        check("log: counts each engine", sum.claudeAnswers == 2 && sum.leanCalls == 1 && sum.localAnswers == 2)
        check("log: totals Claude tokens, cached included", sum.claudeTokens == 100 + 3000 + 150 + 80 + 1500 + 120)
        check("log: an \"Ask Claude\" takes its saving back", sum.saved == 3500 + 7000)
        check("log: percent of what it would have been", sum.savedPercent == Int((Double(10_500) / Double(4950 + 10_500) * 100).rounded()))
        let old = [entry("claude", input: 10, output: 10, daysAgo: 30)]
        check("log: the report separates the last week", UsageLog.report(old + log).contains("Last 7 days"))
        check("log: an empty log says so", UsageLog.report([]).contains("Nothing recorded yet"))

        let saved = UsageLog.url
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-usage-\(UUID().uuidString).jsonl")
        UsageLog.url = temp
        UsageLog.record(UsageLog.Entry(engine: "local", lean: false, why: "quick question", first: true,
                                       usage: ClaudeSession.Usage(inputTokens: 5, outputTokens: 7), saved: 7000))
        UsageLog.record(.reask(saving: 7000))
        let back = UsageLog.load()
        UsageLog.url = saved
        try? FileManager.default.removeItem(at: temp)
        check("log: written and read back", back.count == 2 && back[0].engine == "local" && back[0].input == 5
              && back[0].output == 7 && back[1].saved == -7000)
        check("log: no text is ever stored",
              Set(Mirror(reflecting: back[0]).children.compactMap { $0.label })
                  .isSubset(of: ["time", "engine", "lean", "why", "first", "input", "output", "cached", "costUSD", "seconds", "saved"]))
    }

    // MARK: - Pictures: Margin --localdemo [dir]

    /// Opens chats in Local mode and saves what they look like: the opening footnote, a local answer with its
    /// label and the Ask Claude button. Needs Ollama; makes no Claude calls.
    static func demo(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let settings = Settings.shared
        settings.localMode = true
        UsageLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-localdemo-\(UUID().uuidString).jsonl")
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        let passage = "Opportunity cost is the value of the next-best alternative you give up when you make a choice. "
            + "Because time and money are scarce, every decision involves a trade-off."
        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 560, y: screen.visibleFrame.maxY - 140)
        dock.open(Selection(text: passage, appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: point),
                  iconFrame: NSRect(x: point.x, y: point.y - 26, width: 26, height: 26))
        guard let chat = dock.debugAgents.last else { print("LOCALDEMO FAIL"); exit(1) }
        after(1.0) {
            save("local-1-opening.png", chat.debugSnapshot())
            chat.debugAsk(Prompts.chips[0].prompt)
            func wait(_ tries: Int) {
                if chat.phase == .done || chat.phase == .failed || tries == 0 {
                    after(1.5) {
                        save("local-2-answer.png", chat.debugSnapshot())
                        chat.debugAsk("Why does that matter for a student?")
                        func wait2(_ tries: Int) {
                            if chat.phase == .done || chat.phase == .failed || tries == 0 {
                                after(1.5) {
                                    save("local-3-followup.png", chat.debugSnapshot())
                                    chat.close()
                                    after(0.4) { print("LOCALDEMO DONE"); exit(0) }
                                }
                            } else { after(0.5) { wait2(tries - 1) } }
                        }
                        after(0.3) { wait2(180) }
                    }
                } else { after(0.5) { wait(tries - 1) } }
            }
            after(0.3) { wait(180) }
        }
        app.run()
        exit(0)
    }

    // MARK: - Live test: Margin --localtest [claude]

    /// Needs Ollama running with the model. With `claude`, also makes a few real (small) Claude calls to check
    /// the escalation, fall-back and lean paths.
    static func live(withClaude: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let settings = Settings.shared
        let wasLocal = settings.localMode
        settings.localMode = true
        let tempLog = FileManager.default.temporaryDirectory.appendingPathComponent("margin-localtest-\(UUID().uuidString).jsonl")
        UsageLog.url = tempLog

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func finish() -> Never {
            settings.localMode = wasLocal
            try? FileManager.default.removeItem(at: tempLog)
            print(failures == 0 ? "LOCALTEST PASS" : "LOCALTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        /// Polls every 0.2 s until `done`, then runs `then`; fails the test on timeout.
        func wait(_ what: String, seconds: Double, until done: @escaping () -> Bool, then: @escaping () -> Void) {
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                if done() {
                    timer.invalidate()
                    then()
                } else if Date().timeIntervalSince(start) > seconds {
                    timer.invalidate()
                    check("\(what) (timed out after \(Int(seconds))s)", false)
                    finish()
                }
            }
        }
        let passage = "Opportunity cost is the value of the next-best alternative you give up when you make a choice. "
            + "Because time and money are scarce, every decision involves a trade-off."
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let mouse = TestSpot.mouse(on: screen)
        let icon = NSRect(x: mouse.x, y: mouse.y, width: 22, height: 22)
        func newChat(_ text: String = passage) -> AskPanelController {
            let chat = AskPanelController(selection: Selection(text: text, appName: "Safari", context: ContextBox(resolved: nil),
                                                               pid: 0, mouse: mouse), iconFrame: icon)
            chat.show()
            return chat
        }

        OllamaClient.shared.refresh { status in
            check("Ollama is running with \(settings.localModel)", status == .ready)
            guard status == .ready else { finish() }

            // 0. The menu: the switch, its status line (which fills in once Ollama answers), Token Savings.
            let menu = NSMenu()
            let statusMenu = StatusMenu()
            statusMenu.menuNeedsUpdate(menu)
            let titles = menu.items.map(\.title)
            check("menu: Local Mode is there and on", menu.items.first { $0.title == "Local Mode (Ollama)" }?.state == .on)
            check("menu: Token Savings… is there", titles.contains("Token Savings…"))
            let info = menu.items.first { $0.indentationLevel == 1 && !$0.isEnabled }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                check("menu: the status line says the model is ready", info?.title == "Ready · \(settings.localModel)")
                _ = statusMenu // keeps the menu bar item alive until here
            }

            // 1. The session on its own: streaming, counts, a follow-up that remembers.
            let direct = LocalSession(model: settings.localModel)
            var deltas = 0, text = "", usage = ClaudeSession.Usage(), done = false
            direct.onUsage = { usage = $0 }
            direct.onEvent = { event in
                switch event {
                case .delta(let t): deltas += 1; text += t
                case .turnDone: done = true
                case .error(let m), .unavailable(let m): print("   session said: \(m)"); done = true
                case .activity: break
                }
            }
            direct.send(Prompts.first(app: "Safari", selection: passage, context: nil, question: Prompts.chips[0].prompt), images: [])
            wait("local answer", seconds: 90, until: { done }) {
                print("   → \(text.replacingOccurrences(of: "\n", with: " "))")
                check("session: the answer streamed in pieces", deltas > 3)
                check("session: it answered about the passage", ["cost", "give up", "giving up", "trade-off", "tradeoff", "alternative"].contains { text.lowercased().contains($0) })
                check("session: no thinking tags leak", !text.contains("<think"))
                check("session: it reports token counts", usage.inputTokens > 50 && usage.outputTokens > 5)
                done = false; text = ""
                direct.send("In five words or fewer, what term were we just talking about?", images: [])
                wait("local follow-up", seconds: 60, until: { done }) {
                    print("   → \(text.replacingOccurrences(of: "\n", with: " "))")
                    check("session: a follow-up remembers the chat", text.lowercased().contains("opportunity"))
                    direct.stop()
                    chatTests()
                }
            }
        }

        // 2. The chat window: routing, label, footnote, buttons.
        func chatTests() {
            let chat = newChat()
            check("chat: nothing is started before the first question", chat.debugEngine == "none")
            check("chat: the footnote promises quick answers on this Mac", chat.debugFootnote.contains("stay on your Mac"))
            chat.debugAsk(Prompts.chips[0].prompt)
            wait("chat's local answer", seconds: 90, until: { chat.phase == .done || chat.phase == .failed }) {
                let turn = chat.debugTurns.last
                print("   → \((turn?.answer ?? "").replacingOccurrences(of: "\n", with: " "))")
                check("chat: the quick question was routed locally", chat.debugPlan?.isLocal == true && chat.debugEngine == "local")
                check("chat: the answer is labelled with the local model", turn?.localModel == settings.localModel)
                check("chat: the footnote says it stayed on this Mac", chat.debugFootnote.contains("on your Mac"))
                check("chat: the answer is there", (turn?.answer.count ?? 0) > 20 && turn?.isError == false)
                check("chat: Ask Claude is offered", chat.debugCanAskClaude)
                chat.debugAsk("Why does that matter for a student?")
                wait("chat's local follow-up", seconds: 60, until: { chat.phase == .done || chat.phase == .failed }) {
                    check("chat: a follow-up stays local", chat.debugEngine == "local" && chat.debugTurns.last?.localModel != nil)
                    let log = UsageLog.load()
                    check("chat: both local answers were logged with tokens",
                          log.filter { $0.engine == "local" }.count == 2 && log.allSatisfy { $0.input > 0 })
                    guard withClaude else {
                        chat.close()
                        finish()
                    }
                    claudeTests(chat)
                }
            }
        }

        // 3. Real Claude calls (small): ask Claude instead, a follow-up that needs Claude, a lean call, a fall-back.
        func claudeTests(_ chat: AskPanelController) {
            chat.debugAskClaudeInstead()
            check("claude: the local answer was cleared for Claude", chat.debugTurns.last?.answer.isEmpty == true
                  && chat.debugTurns.last?.localModel == nil)
            wait("Claude's answer to Ask Claude", seconds: 120, until: { chat.phase == .done || chat.phase == .failed }) {
                let turn = chat.debugTurns.last
                print("   → \((turn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
                check("claude: Ask Claude moved the chat to Claude", chat.debugEngine == "claude" && chat.debugPlan?.lean == false)
                check("claude: and it answered", chat.phase == .done && (turn?.answer.count ?? 0) > 20 && turn?.localModel == nil)
                check("claude: the footnote now says what Claude can use", chat.debugFootnote.contains("web search"))
                check("claude: the earlier local exchange stayed in the chat", chat.debugTurns.count == 2)
                check("claude: taking the answer back is logged", UsageLog.load().contains { $0.engine == "reask" && $0.saved < 0 })
                chat.close()

                // A follow-up that needs the web moves a local chat over.
                let second = newChat()
                second.debugAsk(Prompts.chips[0].prompt)
                wait("second chat's local answer", seconds: 90, until: { second.phase == .done || second.phase == .failed }) {
                    second.debugAsk("Is that the latest definition economists use today?")
                    wait("escalated follow-up", seconds: 120, until: { second.phase == .done || second.phase == .failed }) {
                        let turn = second.debugTurns.last
                        print("   → \((turn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
                        check("claude: a follow-up that needs the web moved to Claude", second.debugEngine == "claude" && turn?.localModel == nil)
                        check("claude: and was answered", second.phase == .done && (turn?.answer.count ?? 0) > 20)
                        second.close()
                        leanTest()
                    }
                }
            }
        }

        func leanTest() {
            let chat = newChat("замок")
            chat.debugAsk(Prompts.pronounce)
            wait("lean pronunciation", seconds: 120, until: { chat.phase == .done || chat.phase == .failed }) {
                let turn = chat.debugTurns.last
                print("   → \((turn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
                check("lean: Pronounce used a lean Claude call", chat.debugEngine == "claude" && chat.debugPlan?.lean == true)
                check("lean: the footnote says text only, no web", chat.debugFootnote.contains("text only") && chat.debugFootnote.contains("web search off"))
                check("lean: it still spoke", (turn?.answer.contains("<say") ?? false))
                check("lean: the lean call was logged as a saving",
                      UsageLog.load().contains { $0.engine == "claude" && $0.lean && $0.input + $0.cached > 0 })
                chat.close()
                fallbackTest()
            }
        }

        func fallbackTest() {
            let real = OllamaClient.baseURL
            let chat = newChat()
            // Let the chat's own check of Ollama finish first, then make Ollama unreachable before the question.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                OllamaClient.baseURL = URL(string: "http://127.0.0.1:9")! // nothing listens here
                chat.debugAsk(Prompts.chips[0].prompt)
                wait("fall back to Claude", seconds: 120, until: { chat.phase == .done || chat.phase == .failed }) {
                    OllamaClient.baseURL = real
                    let turn = chat.debugTurns.last
                    print("   → \((turn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
                    check("fall-back: with Ollama unreachable the question went to Claude",
                          chat.debugEngine == "claude" && chat.phase == .done && (turn?.answer.count ?? 0) > 20 && turn?.localModel == nil)
                    check("fall-back: the footnote says why", chat.debugFootnote.contains("Ollama isn't running"))
                    OllamaClient.shared.refresh { _ in
                        chat.close()
                        finish()
                    }
                }
            }
        }

        app.run()
        exit(0)
    }
}

// MARK: - Token savings

extension FeatureTests {
    static func savingChecks(_ check: (String, Bool) -> Void) {
        // Quick Answers on Haiku: what the quick model may see and answer.
        func plan(_ prompt: String, selection: String = "a parabola", snip: Bool = false, blank: Bool = false, sees: Bool = true) -> Router.Plan {
            Router.plan(.init(prompt: prompt, selection: selection, hasSnip: snip, isBlank: blank, localMode: true, localSeesImages: sees))
        }
        check("haiku: a snip goes to the quick model, which can see it", plan("What is this?", selection: "", snip: true).isLocal && plan("What is this?", selection: "", snip: true).sees)
        check("haiku: a blank chat goes to the quick model, with the screenshot", plan("What's on my screen?", selection: "", blank: true).isLocal)
        check("haiku: a question about the screen stays with the quick model", plan("What does this button do on my screen?").isLocal)
        check("haiku: the web, quizzes and pronunciation still go to Claude",
              !plan("What's the latest version?", snip: true).isLocal && !plan(Prompts.quiz).isLocal && !plan(Prompts.pronounce, snip: true).isLocal)
        check("haiku: a model that can't see (Ollama) still sends snips and the screen to Claude",
              !plan("What is this?", selection: "", snip: true, sees: false).isLocal && !plan("What does this button do on my screen?", sees: false).isLocal)
        check("haiku: a chat that sees isn't moved to Claude for a screen question",
              !Router.needsEscalation("What about this button on my screen?", from: plan("Explain this")) && Router.needsEscalation("latest price?", from: plan("Explain this")))

        // The Qwen/Claude button's words.
        check("button: Claude says Claude", EngineLabel.name(local: false, model: "qwen3:8b") == "Claude")
        check("button: qwen3:8b says Qwen", EngineLabel.name(local: true, model: "qwen3:8b") == "Qwen")
        check("button: llama3.2:3b says Llama, an odd name still says something", EngineLabel.name(local: true, model: "llama3.2:3b") == "Llama"
              && EngineLabel.name(local: true, model: "3b") == "Local")

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
        check("video: the model picks the shape from the video's type", req.contains("what kind of video it is") && req.contains("not a fixed template")
              && !req.contains("Executive Summary") && !req.contains("📌"))
        check("video: …keeps timestamps as links and stays proportionate", req.contains("https://youtu.be/abc?t=") && req.contains("scale the length to the video"))
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
            check("the summary has real content", answer.count > 200)
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
