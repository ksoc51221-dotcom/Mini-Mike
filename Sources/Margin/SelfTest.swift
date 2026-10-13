import AppKit
import SwiftUI
import AVFoundation

/// Headless checks runnable from the terminal:
///   Margin --selftest   real round trip through the claude CLI (question + follow-up)
///   Margin --unittest   pure helpers + clipboard snapshot/restore
///   Margin --capturetest  Screen Recording permission + one screenshot
enum SelfTest {
    static func claudeRoundTrip() -> Never {
        // A fake "screenshot" with a word that only the image contains.
        let screenshot = renderTestImage("Project codename: BLUE HERON")
        let selection = Selection(
            text: "the codename above",
            appName: "Claude",
            context: ContextBox(resolved: nil),
            pid: 0, mouse: .zero)
        let questions = [
            "What's the codename on my screen? Also, what is the latest stable Swift release? Check the web.",
            "Spell that codename backwards.",
        ]
        let session = ClaudeSession(model: Settings.shared.model, webSearch: true)
        var turn = 0
        var answer = ""
        var sawActivity = false
        var sentAt = Date()

        print("claude: \(ClaudeSession.claudePath ?? "NOT FOUND")  model: \(Settings.shared.model.rawValue)")
        session.onEvent = { (event: ClaudeSession.Event) in
            switch event {
            case .delta(let text):
                answer += text
                print(text, terminator: "")
                fflush(stdout)
            case .activity(let label):
                sawActivity = true
                answer = ""
                print(String(format: "\n[%.1fs] %@", Date().timeIntervalSince(sentAt), label))
            case .turnDone:
                print(String(format: "\n--- turn %d done (%.1fs) ---", turn + 1, Date().timeIntervalSince(sentAt)))
                if turn == 0 {
                    guard answer.uppercased().contains("BLUE HERON") else {
                        print("SELFTEST FAIL: screenshot wasn't read")
                        exit(1)
                    }
                    guard sawActivity else {
                        print("SELFTEST FAIL: no web search happened")
                        exit(1)
                    }
                }
                turn += 1
                if turn < questions.count {
                    answer = ""
                    sentAt = Date()
                    session.send(questions[turn])
                } else {
                    session.stop()
                    print("SELFTEST PASS")
                    exit(0)
                }
            case .error(let message), .unavailable(let message):
                print("\nSELFTEST FAIL: \(message)")
                exit(1)
            }
        }
        do { try session.start() } catch {
            print("SELFTEST FAIL: \(error.localizedDescription)")
            exit(1)
        }
        sentAt = Date()
        session.send(Prompts.first(app: selection.appName, selection: selection.text, context: nil,
                                   question: questions[0], hasScreenshot: true),
                     images: [screenshot])
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            print("\nSELFTEST FAIL: timed out")
            exit(2)
        }
        dispatchMain()
    }

    /// Margin --saytest: asks Claude to pronounce a word in context and renders the clip it returns.
    static func sayTest() -> Never {
        let session = ClaudeSession(model: Settings.shared.model, webSearch: Settings.shared.webSearch)
        var answer = ""
        print("asking how to pronounce «замок» in «Я закрыл дверь на замок» (the lock, stressed замо́к)…")
        session.onEvent = { (event: ClaudeSession.Event) in
            switch event {
            case .delta(let text):
                answer += text
            case .activity(let label):
                print("[\(label)]")
                answer = ""
            case .turnDone:
                print(answer)
                let clips = Answer.pieces(answer).compactMap { piece -> SayRequest? in
                    if case .say(let r) = piece { return r } else { return nil }
                }
                guard let first = clips.first else { print("SAYTEST FAIL: no <say> tag"); exit(1) }
                for clip in clips { print("clip: \(clip.text)  lang=\(clip.lang)  ipa=\(clip.cleanIPA ?? "none")") }
                guard first.cleanIPA != nil else { print("SAYTEST FAIL: no IPA"); exit(1) }
                // The IPA must pair word-for-word with the text, or the voice ignores it.
                let words = Speech.wordRanges(first.spokenText).count
                let ipaWords = first.cleanIPA!.split(whereSeparator: \.isWhitespace)
                    .filter { !$0.trimmingCharacters(in: Speech.punctuation).isEmpty }.count
                print("words: \(words), IPA words: \(ipaWords)")
                guard words == ipaWords || words == 1 else { print("SAYTEST FAIL: IPA doesn't pair with the words"); exit(1) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-say-\(UUID().uuidString).m4a")
                Speech.render(first, slow: false, to: url) { result in
                    try? FileManager.default.removeItem(at: url)
                    switch result {
                    case .success(let r):
                        print(String(format: "rendered %.2fs of audio", r.duration))
                        print("SAYTEST PASS")
                        exit(0)
                    case .failure(let e):
                        print("SAYTEST FAIL: \(e.localizedDescription)")
                        exit(1)
                    }
                }
            case .error(let message), .unavailable(let message):
                print("SAYTEST FAIL: \(message)")
                exit(1)
            }
        }
        do { try session.start() } catch {
            print("SAYTEST FAIL: \(error.localizedDescription)")
            exit(1)
        }
        if CommandLine.arguments.contains("sentence") {
            session.send(Prompts.first(app: "Safari", selection: "Я закрыл дверь на замок, потому что было поздно.",
                                       context: nil, question: "How do I pronounce this sentence? Say it for me."))
        } else {
            session.send(Prompts.first(app: "Safari", selection: "замок", context: "Я закрыл дверь на замок.",
                                       question: "How do I pronounce this? Say it for me."))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("SAYTEST FAIL: timed out"); exit(2) }
        dispatchMain()
    }

    /// Margin --youtubetest [id]: reads a real video's transcript and has Claude summarize it.
    private static var liveSession: ClaudeSession?

    /// Margin --placetest [dir]: shows the sidebar with all 4 agents (finished) on your real screen and checks each
    /// circle sits where the dock expects it, each aura is centered on its circle, the sidebar fits on the screen,
    /// and the painted check is centered inside the circle. With a folder, saves a picture of the sidebar.
    static func placeTest(outputDirectory: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sidebar = AgentSidebar(open: true)
        let owners = (0..<Settings.shared.maxAgents).map { _ in NSObject() }
        let titles = ["What does by reference mean here?", "Explain supply and demand", "Snip from Preview", "Summarize this video"]
        sidebar.sync(owners.enumerated().map { i, o in
            AgentSidebar.Row(id: ObjectIdentifier(o), title: titles[i], subtitle: "Done. Click to read",
                             phase: i == 1 ? .working : .done, isOpen: i == 0)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { // after the check has painted itself in
            var ok = true
            let screen = (NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!).visibleFrame
            let frame = sidebar.debugPanelFrame
            let fits = screen.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            ok = ok && fits
            print(String(format: "sidebar %.0f×%.0f at (%.0f, %.0f) — %@ the screen's usable area",
                         frame.width, frame.height, frame.minX, frame.minY, fits ? "inside" : "OUTSIDE"))
            for (i, row) in sidebar.debugRows.enumerated() {
                let off = hypot(row.aura.x - row.disc.x, row.aura.y - row.disc.y)
                let misplaced = hypot(row.disc.x - row.expected.x, row.disc.y - row.expected.y)
                ok = ok && off < 0.5 && misplaced < 0.5
                print(String(format: "row %d: circle (%.0f, %.0f)  aura off by %.1f pt  circle off its slot by %.1f pt",
                             i, row.disc.x, row.disc.y, off, misplaced))
            }
            ok = ok && sidebar.debugRows.count == owners.count
            // The check's ink box, in units of the circle's radius (0 = centered).
            if let box = BrushCheck.inkBox(side: 200) {
                let off = hypot(box.midX, box.midY)
                ok = ok && off < 0.08
                print(String(format: "check: x %.2f…%.2f, y %.2f…%.2f, off center by %.2f of the radius",
                             box.minX, box.maxX, box.minY, box.maxY, off))
            }
            if let outputDirectory, let rep = sidebar.debugSnapshot() {
                let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("sidebar.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("saved \(url.path)")
            }
            print(ok ? "PLACETEST PASS" : "PLACETEST FAIL")
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    /// Margin --glowtest [dir]: opens a chat with Option+Shift+Tab's code path and checks its glow follows it
    /// through pop-up, resize, minimize, expand and close. With a folder, saves a picture of the glow.
    static func glowTest(outputDirectory: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dock = AgentDock()
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        func aligned(_ agent: AskPanelController) -> Bool {
            let want = agent.debugPanelFrame.insetBy(dx: -PanelGlow.reach, dy: -PanelGlow.reach)
            let got = agent.debugGlow.debugFrame
            return abs(want.minX - got.minX) < 1 && abs(want.minY - got.minY) < 1
                && abs(want.width - got.width) < 1 && abs(want.height - got.height) < 1
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let mouse = TestSpot.mouse(on: screen)
        func newChat() -> AskPanelController? {
            dock.chatShortcut {
                Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: mouse)
            }
            return dock.debugAgents.last
        }
        // Only weak references to the chats are kept here: like in the app, the dock is their only owner,
        // so closing one really frees it, and its glow must not be left behind on screen.
        weak var first = newChat()
        check("shortcut opened a blank chat", first?.title == "Chat from Safari")

        after(1.4) { // after the pop-up bloom has settled
            guard let agent = first else { print("GLOWTEST FAIL: chat vanished"); exit(1) }
            check("glow is showing once the chat pops up", agent.debugGlow.debugIsVisible)
            check("glow surrounds the chat", aligned(agent))
            check("glow fades with the chat", abs(agent.debugGlow.debugAlpha - agent.debugPanelAlpha) < 0.02)
            if let outputDirectory {
                let out = URL(fileURLWithPath: outputDirectory).appendingPathComponent("chat-glow.png")
                try? agent.debugGlow.debugImage(chat: agent.debugSnapshot())?
                    .representation(using: .png, properties: [:])?.write(to: out)
                print("saved \(out.path)")
            }
            dock.debugMinimize(agent)
        }
        after(2.2) {
            guard let agent = first else { return }
            check("glow leaves when the chat minimizes", !agent.debugGlow.debugIsVisible)
            dock.debugExpand(agent)
        }
        after(3.1) {
            guard let agent = first else { return }
            check("glow comes back when the chat expands", agent.debugGlow.debugIsVisible && aligned(agent))
            agent.debugToggleSize()
        }
        after(4.0) {
            guard let agent = first else { return }
            check("glow follows the chat when it grows", aligned(agent))
            agent.close() // the dock lets go of it right away
        }
        after(4.8) {
            check("the closed chat was freed", first == nil)
            check("no glow is left on screen after closing", PanelGlow.visibleWindowCount == 0)
            // The shortcut again while typing in a chat puts it away (here: it closes, since it's idle).
            weak var second = newChat()
            after(1.0) {
                second?.debugDismissFromShortcut()
                after(0.8) {
                    check("pressing the shortcut again put the chat away", second == nil)
                    check("still no glow left on screen", PanelGlow.visibleWindowCount == 0)
                    print(failures == 0 ? "GLOWTEST PASS" : "GLOWTEST FAIL (\(failures))")
                    exit(failures == 0 ? 0 : 1)
                }
            }
        }
        app.run()
        exit(0)
    }

    /// Margin --sidebartest [dir]: runs the sidebar's rules on your real screen with test chats (no Claude questions
    /// are asked): clicking away keeps a chat, a row reopens it, dragging places it, only × deletes, the sidebar folds
    /// and fits 4 chats. With a folder, saves a picture of the sidebar.
    static func sidebarTest(outputDirectory: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let wasOpen = Settings.shared.sidebarOpen
        Settings.shared.sidebarOpen = true
        let dock = AgentDock()
        let sidebar = dock.debugSidebar
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        func finish() -> Never {
            Settings.shared.sidebarOpen = wasOpen
            print(failures == 0 ? "SIDEBARTEST PASS" : "SIDEBARTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let mouse = TestSpot.mouse(on: screen)
        let icon = NSRect(x: mouse.x, y: mouse.y, width: 26, height: 26)
        func selection(_ text: String) -> Selection {
            Selection(text: text, appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: mouse)
        }
        func sameCorner(_ a: NSRect, _ b: NSRect) -> Bool { abs(a.minX - b.minX) < 1.5 && abs(a.maxY - b.maxY) < 1.5 }

        // Only weak references to the chats are kept: like in the app, the dock is their only owner.
        dock.open(selection("closures capture variables by reference"), iconFrame: icon)
        weak var first = dock.debugAgents.last
        first?.debugInject(question: "What does by reference mean here?", answer: "It means the closure sees later changes.")

        after(1.0) {
            check("sidebar appears with the chat's row", sidebar.debugIsVisible && sidebar.debugTitles().count == 1)
            check("the new chat starts open", first?.debugIsMinimized == false)
            first?.dismissGesture() // what clicking anywhere else does
        }
        after(1.9) {
            check("clicking away keeps the chat (it is not deleted)", first != nil && dock.count == 1)
            check("…it goes to the sidebar", first?.debugIsMinimized == true && sidebar.debugTitles().count == 1)
            sidebar.debugClickRow(0)
        }
        after(2.9) {
            guard let agent = first else { finish() }
            check("clicking its row opens it again", !agent.debugIsMinimized && agent.debugPanelAlpha > 0.9)
            let before = agent.debugPanelFrame
            check("the chat's header is a drag handle", agent.debugDragHeader(by: NSSize(width: -260, height: -110)))
            let moved = agent.debugPanelFrame
            check("the chat moves when dragged", abs(moved.minX - (before.minX - 260)) < 1.5 && abs(moved.minY - (before.minY - 110)) < 1.5)
            check("…and is remembered as placed", agent.debugIsPlaced)
            agent.debugToggleSize()
            after(1.0) {
                check("making it bigger keeps its top-left corner where you put it", sameCorner(agent.debugPanelFrame, moved))
                dock.debugMinimize(agent)
                after(1.0) {
                    check("it minimizes into the sidebar", agent.debugIsMinimized)
                    sidebar.debugClickRow(0)
                    after(1.0) {
                        check("it reopens right where you left it", sameCorner(agent.debugPanelFrame, moved))
                        sidebar.debugClickDelete(0) // the × on its row
                    }
                }
            }
        }
        after(7.2) {
            check("× on the row deletes the chat", first == nil && dock.count == 0)
            check("no row is left", sidebar.debugTitles().isEmpty)
        }
        after(8.0) {
            check("an empty sidebar goes away", !sidebar.debugIsVisible)
            // A chat with nothing in it has nothing to keep: clicking away just removes it.
            dock.chatShortcut { Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: mouse) }
            weak var blank = dock.debugAgents.last
            check("a blank chat opens", blank != nil)
            after(0.8) {
                blank?.dismissGesture()
                after(0.8) {
                    check("clicking away from a blank chat removes it", blank == nil && dock.count == 0)
                    fold()
                }
            }
        }
        func fold() {
            dock.open(selection("one"), iconFrame: icon)
            weak var agent = dock.debugAgents.last
            after(0.8) {
                let openWidth = sidebar.debugPanelFrame.width
                sidebar.setOpen(false)
                after(0.6) {
                    check("folding shrinks the sidebar to a strip", sidebar.debugPanelFrame.width < 40 && openWidth > 200)
                    check("the fold is remembered", Settings.shared.sidebarOpen == false)
                    if let agent { dock.debugMinimize(agent) }
                    after(0.8) {
                        check("a chat still minimizes while the sidebar is folded", agent?.debugIsMinimized == true)
                        sidebar.setOpen(true)
                        after(0.6) {
                            check("unfolding brings the rows back", sidebar.debugPanelFrame.width > 200 && Settings.shared.sidebarOpen)
                            agent?.close()
                            after(0.5) { four() }
                        }
                    }
                }
            }
        }
        func four() {
            let questions = ["Explain supply and demand", "Graph y = x² − 4x + 3", "Summarize this video", "What is opportunity cost?"]
            for q in questions {
                dock.open(selection(q), iconFrame: icon)
                dock.debugAgents.last?.debugInject(question: q, answer: "Answer.")
            }
            after(1.2) {
                check("four chats fit", dock.count == 4 && sidebar.debugTitles().count == 4)
                let frame = sidebar.debugPanelFrame
                let visible = (NSScreen.screens.first { $0.isBuiltIn } ?? screen).visibleFrame
                check("the sidebar fits on screen with four rows", visible.insetBy(dx: -0.5, dy: -0.5).contains(frame))
                let rows = sidebar.debugRows
                check("every circle is in its slot with its aura centered",
                      rows.count == 4 && rows.allSatisfy {
                          hypot($0.disc.x - $0.expected.x, $0.disc.y - $0.expected.y) < 0.5
                              && hypot($0.aura.x - $0.disc.x, $0.aura.y - $0.disc.y) < 0.5
                      })
                check("only the newest chat is open", dock.debugAgents.filter { !$0.debugIsMinimized }.count == 1)
                if let outputDirectory, let rep = sidebar.debugSnapshot() {
                    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("sidebar-four.png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("saved \(url.path)")
                }
                dock.open(selection("a fifth"), iconFrame: icon)
                check("a fifth chat is refused", dock.count == 4)
                check("…and the open chat is left alone", dock.debugAgents.filter { !$0.debugIsMinimized }.count == 1)
                dock.debugAgents.forEach { $0.close() }
                after(0.8) {
                    check("deleting them all empties the dock", dock.count == 0)
                    finish()
                }
            }
        }
        app.run()
        exit(0)
    }

    /// Margin --graphtest [dir]: asks Claude (for real) for three visuals and checks each answer has a graph
    /// that draws with nothing skipped. With a folder, saves pictures of what it drew.
    @MainActor
    static func graphTest(outputDirectory: String?) -> Never {
        let asks: [(selection: String, question: String)] = [
            ("When demand increases, the equilibrium price and quantity both rise.", "Show me this visually"),
            ("y = x² − 4x + 3 factors as (x − 1)(x − 3), so its roots are 1 and 3 and its vertex is at (2, −1).",
             "Can you graph this?"),
            ("The derivative at a point is the slope of the tangent line there.",
             "Show this as a graph or visual model, then tell me what to notice."),
        ]
        var failures = 0
        func run(_ i: Int) {
            guard i < asks.count else {
                print(failures == 0 ? "GRAPHTEST PASS" : "GRAPHTEST FAIL (\(failures))")
                exit(failures == 0 ? 0 : 1)
            }
            let ask = asks[i]
            let session = ClaudeSession(model: Settings.shared.model, webSearch: false)
            liveSession = session
            var answer = ""
            let started = Date()
            session.onEvent = { event in
                switch event {
                case .delta(let text): answer += text
                case .activity: answer = ""
                case .turnDone:
                    let graphs = Answer.pieces(answer).compactMap { piece -> String? in
                        if case .graph(let json) = piece { return json } else { return nil }
                    }
                    print(String(format: "\n[%d] %@ (%.0fs)", i + 1, ask.question, Date().timeIntervalSince(started)))
                    print(answer.replacingOccurrences(of: #"<graph>[\s\S]*?</graph>"#, with: "<graph>…</graph>", options: .regularExpression))
                    guard let json = graphs.first, let spec = GraphSpec.parse(json) else {
                        print("FAIL no graph that parses")
                        failures += 1
                        return run(i + 1)
                    }
                    print("graph: \(json)")
                    let scene = GraphScene.build(spec, values: spec.initialValues, plotSize: CGSize(width: 340, height: 210))
                    let drew = scene.curves.contains { !$0.segments.isEmpty } || !scene.figures.isEmpty || !scene.strokes.isEmpty
                    if !spec.problems.isEmpty { print("problems: \(spec.problems)") }
                    if spec.problems.isEmpty && drew {
                        print("ok   graph draws cleanly (\(scene.curves.count) curves, \(scene.dots.count) points, \(spec.sliders.count) sliders)")
                    } else {
                        print("FAIL graph has problems or draws nothing")
                        failures += 1
                    }
                    if let outputDirectory {
                        let renderer = ImageRenderer(content:
                            GraphCanvas(spec: spec, values: spec.initialValues, hover: nil, dark: true)
                                .frame(width: 340, height: 340 * spec.aspect).padding(10).background(Color(white: 0.16)))
                        renderer.scale = 2
                        if let image = renderer.cgImage {
                            let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("live-\(i + 1).png")
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                            print("saved \(url.path)")
                        }
                    }
                    session.stop()
                    run(i + 1)
                case .error(let m), .unavailable(let m):
                    print("FAIL [\(i + 1)] \(m)")
                    failures += 1
                    run(i + 1)
                }
            }
            do {
                try session.start()
            } catch {
                print("GRAPHTEST FAIL: \(error.localizedDescription)")
                exit(1)
            }
            session.send(Prompts.first(app: "Safari", selection: ask.selection, context: nil, question: ask.question))
        }
        if let outputDirectory { try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true) }
        setvbuf(stdout, nil, _IOLBF, 0) // show progress line by line, even through a pipe
        run(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 400) { print("GRAPHTEST FAIL: timed out"); exit(2) }
        // A real run loop (not just dispatchMain): SwiftUI's ImageRenderer needs one to draw the pictures.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    static func youtubeTest(id: String) -> Never {
        Task { @MainActor in
            do {
                let started = Date()
                let t = try await YouTube.transcript(for: id)
                print(String(format: "transcript in %.1fs: \"%@\" by %@, %@, %d words, language %@ (%@)",
                             Date().timeIntervalSince(started), t.title, t.channel ?? "?",
                             VideoTranscript.clock(t.duration ?? 0), t.wordCount, t.languageName, t.origin))
                print(t.formatted().split(separator: "\n").prefix(2).joined(separator: "\n"))
                let session = ClaudeSession(model: Settings.shared.model, webSearch: false)
                liveSession = session // its output handlers hold it weakly; keep it past this Task
                var answer = ""
                session.onEvent = { event in
                    switch event {
                    case .delta(let text): answer += text
                    case .activity: answer = ""
                    case .turnDone:
                        print("\n" + answer)
                        let hasLinks = answer.contains("youtu.be/\(id)?t=")
                        print(hasLinks ? "YOUTUBETEST PASS" : "YOUTUBETEST FAIL: no timestamp links")
                        exit(hasLinks ? 0 : 1)
                    case .error(let m), .unavailable(let m):
                        print("YOUTUBETEST FAIL: \(m)")
                        exit(1)
                    }
                }
                try session.start()
                let link = VideoSource.youtube(id: id).link
                session.send(Prompts.video(t, link: link, request: Prompts.videoRequest(.english, language: t.languageName, link: link)))
            } catch {
                print("YOUTUBETEST FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("YOUTUBETEST FAIL: timed out"); exit(2) }
        dispatchMain()
    }

    /// Margin --capturetest: checks Screen Recording permission and grabs one frame.
    static func captureTest() -> Never {
        print("screen recording permission: \(ScreenCapture.hasPermission)")
        ScreenCapture.capture(.screen, at: NSEvent.mouseLocation, pid: 0) { data in
            if let data, let rep = NSBitmapImageRep(data: data) {
                print("CAPTURE PASS: \(rep.pixelsWide)x\(rep.pixelsHigh) JPEG, \(data.count / 1024) KB")
                exit(0)
            }
            print("CAPTURE FAIL (no permission for this process, or capture error)")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("CAPTURE FAIL: timed out"); exit(2) }
        dispatchMain()
    }

    private static func renderTestImage(_ text: String) -> Data {
        let image = NSImage(size: NSSize(width: 520, height: 140), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 24, y: 56), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.black,
            ])
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    static func unitTests() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }

        LocalTests.unit(check)

        // Context window trimming
        let doc = "Para one is about setup.\nPara two says closures capture variables by reference here.\nPara three wraps up."
        check("context: whole doc when small",
              SelectionReader.contextWindow(in: doc, around: "capture variables", radius: 800) == doc)
        let cut = SelectionReader.contextWindow(in: doc, around: "capture variables", radius: 30)
        check("context: trims partial paragraphs at cut edges",
              cut == "Para two says closures capture variables by reference here.")
        check("context: nil when it adds nothing",
              SelectionReader.contextWindow(in: "just this", around: "just this", radius: 800) == nil)
        check("context: nil when selection not found",
              SelectionReader.contextWindow(in: doc, around: "missing", radius: 800) == nil)

        // Graph math
        func ev(_ src: String, _ vals: [String: Double] = [:], functions: [String: (Double) -> Double] = [:]) -> Double {
            guard let e = try? MathExpr.parse(src, functions: Set(functions.keys)) else { return .nan }
            let env = MathEnv(values: vals)
            env.functions = functions
            return e.value(env)
        }
        func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }
        check("math: 2x^2 - 3x + 1 at x = 2 is 3", near(ev("2x^2 - 3x + 1", ["x": 2]), 3))
        check("math: vertex form a(x - h)^2 + k multiplies", near(ev("a(x - h)^2 + k", ["a": 2, "h": 1, "k": -3, "x": 3]), 5))
        check("math: x² and -x^2", near(ev("x²", ["x": 3]), 9) && near(ev("-x^2", ["x": 3]), -9))
        check("math: 2^-1 and (x+1)(x-1)", near(ev("2^-1"), 0.5) && near(ev("(x+1)(x-1)", ["x": 3]), 8))
        check("math: functions and constants", near(ev("sin(pi/2) + sqrt(16) + abs(-2) + ln(e) + log(100)"), 10))
        check("math: 0.7x and a typographic minus", near(ev("8 − 0.7x + shift", ["x": 2, "shift": 1]), 7.6))
        check("math: curves as functions, point coordinates",
              near(ev("f(2) + E.x", ["E.x": 1.5], functions: ["f": { $0 * $0 }]), 5.5))
        check("math: if() with comparisons", near(ev("if(x < 0, -x, x^2)", ["x": -2]), 2) && near(ev("if(x < 0, -x, x^2)", ["x": 3]), 9))
        check("math: cube root of a negative", near(ev("(-8)^(1/3)"), -2))
        check("math: sin x without parentheses", near(ev("sin x", ["x": .pi / 2]), 1))
        check("math: broken input is an error", (try? MathExpr.parse("2*(x")) == nil && (try? MathExpr.parse("2 $ 3")) == nil)

        // Graphs
        let size = CGSize(width: 360, height: 220)
        let supplyDemand = """
        {"title":"Supply and demand","x":{"label":"Quantity","min":0,"max":10,"numbers":false},
         "y":{"label":"Price","min":0,"max":10,"numbers":false},
         "sliders":[{"name":"shift","label":"Demand shift","min":-2,"max":2,"value":0}],
         "plots":[{"name":"D","y":"8-0.7*x+shift","label":"D","color":"blue"},{"name":"S","y":"1+0.6*x","label":"S","color":"orange"}],
         "points":[{"name":"E","intersect":["D","S"],"label":"E","guides":["Q*","P*"]}],
         "areas":[{"between":["D","E.y"],"from":0,"to":"E.x","label":"CS"},{"between":["E.y","S"],"from":0,"to":"E.x","label":"PS"}],}
        """
        if let g = GraphSpec.parse(supplyDemand) {
            check("graph: supply and demand reads cleanly (trailing comma forgiven)", g.problems.isEmpty && g.plots.count == 2)
            let scene = GraphScene.build(g, values: g.initialValues, plotSize: size)
            let e = scene.dots.first?.at ?? .zero
            check("graph: equilibrium where D meets S", near(Double(e.x), 7 / 1.3, 1e-6) && near(Double(e.y), 1 + 0.6 * 7 / 1.3, 1e-6))
            let cs = scene.regions.first.map { GraphScene.area($0.polygon) } ?? 0
            check("graph: consumer surplus is the triangle's area", near(cs, 0.5 * (7 / 1.3) * (8 - (1 + 0.6 * 7 / 1.3)), 1e-3))
            var shifted = g.initialValues
            shifted["shift"] = 1
            let moved = GraphScene.build(g, values: shifted, plotSize: size).dots.first?.at.x ?? 0
            check("graph: dragging the slider moves the equilibrium", near(Double(moved), 8 / 1.3, 1e-6))
        } else {
            check("graph: supply and demand reads", false)
        }
        let quadratic = GraphSpec.parse(#"""
        {"x":{"min":-1,"max":5},"plots":[{"name":"f","y":"x^2 - 4x + 3"}],
         "points":[{"label":"root","intersect":["f","0"],"all":true},{"label":"vertex","x":2,"y":"f(2)"}],
         "lines":[{"tangent":"f","at":4,"label":"tangent"}]}
        """#)
        let qs = quadratic.map { GraphScene.build($0, values: [:], plotSize: size) }
        let roots = qs?.dots.filter { $0.label == "root" }.map { Double($0.at.x) } ?? []
        check("graph: both roots of x² − 4x + 3", roots.count == 2 && near(roots[0], 1, 1e-6) && near(roots[1], 3, 1e-6))
        check("graph: vertex from f(2)", qs?.dots.last.map { near(Double($0.at.y), -1) } == true)
        if let t = qs?.strokes.first {
            check("graph: tangent at x = 4 has slope 4", near(Double((t.to.y - t.from.y) / (t.to.x - t.from.x)), 4, 1e-4))
        } else {
            check("graph: tangent drawn", false)
        }
        check("graph: y range fits the curve", qs.map { $0.yRange.contains(-1) && $0.yRange.contains(8) } == true)
        let broken = GraphSpec.parse(#"{"plots":[{"y":"x^2 + q"},{"y":"2x"}],"points":[{"on":"nope","x":1}]}"#)
        check("graph: an unknown name skips just that part", broken?.plots.count == 1 && broken?.problems.count == 2)
        check("graph: not JSON means no graph", GraphSpec.parse("{plots: oops") == nil)
        check("graph: 0 and 1 are numbers, not true/false",
              GraphSpec.parse(#"{"x":{"min":0,"max":1},"plots":[{"y":"x"}]}"#)?.problems.isEmpty == true)
        if let c = GraphSpec.parse(#"{"equal":true,"x":{"min":-1.5,"max":1.5},"y":{"min":-1.5,"max":1.5},"shapes":[{"circle":[0,0,1]}]}"#) {
            let s = GraphScene.build(c, values: [:], plotSize: CGSize(width: 400, height: 250))
            check("graph: equal scale keeps circles round", near(s.xRange.span / 400, s.yRange.span / 250, 1e-9))
        }
        check("graph: tan(x) breaks at its asymptotes instead of drawing a wall",
              GraphSpec.parse(#"{"x":{"min":-3,"max":3},"y":{"min":-5,"max":5},"plots":[{"y":"tan(x)"}]}"#)
                .map { GraphScene.build($0, values: [:], plotSize: size).curves[0].segments.count } == 3)
        check("graph: trig ticks in π", GraphRenderer.ticks(0...(2 * .pi), pixels: 360, piStyle: true).map(\.1)
              == ["0", "π/2", "π", "3π/2", "2π"])
        check("graph: round-number ticks", GraphRenderer.ticks(0...10, pixels: 300, piStyle: true).map(\.1) == ["0", "2", "4", "6", "8", "10"])
        let taught = Answer.pieces(Prompts.graphs).compactMap { piece -> GraphSpec? in
            if case .graph(let json) = piece { return GraphSpec.parse(json) } else { return nil }
        }
        check("prompt: the graphs Claude is shown as examples draw cleanly",
              taught.count == 2 && taught.allSatisfy { $0.problems.isEmpty }
              && !Prompts.graphs.contains("\\\n") && !Prompts.system(webSearch: true).contains("\\\n"))
        check("answer: text, graph, text", Answer.pieces("Look:\n<graph>{\"plots\":[]}</graph>\nNotice the vertex.")
              == [.text("Look:\n"), .graph("{\"plots\":[]}"), .text("\nNotice the vertex.")])
        check("answer: a graph still streaming shows as drawing",
              Answer.pieces("Here: <graph>{\"plo", hidePartial: true) == [.text("Here: "), .drawing])
        check("answer: a half-typed <gra is hidden", Answer.pieces("Here: <gra", hidePartial: true) == [.text("Here: ")])
        check("answer: a code fence around a graph is dropped",
              Answer.pieces("See:\n```json\n<graph>{}</graph>\n```\nDone.") == [.text("See:\n"), .graph("{}"), .text("\nDone.")])

        check("markdown: list items get bullets, bold still works",
              String(MarkdownText.inline("- **term**: meaning\n* other").characters) == "• term: meaning\n• other")

        // Summaries
        let longPassage = String(repeating: "Opportunity cost is the value of the next-best choice. ", count: 160)
        check("summary: long passages are kept whole for summaries (cut at 4000 characters otherwise)",
              Prompts.first(app: "Safari", selection: longPassage, context: nil, question: Prompts.Summary.meaning.prompt,
                            selectionLimit: Prompts.maxSummarySelection).contains(longPassage)
              && !Prompts.first(app: "Safari", selection: longPassage, context: nil, question: "What?").contains(longPassage))
        check("summary: two choices, recognized as summaries",
              Prompts.Summary.allCases.count == 2 && Prompts.Summary.allCases.allSatisfy { Prompts.isSummary($0.prompt) }
              && !Prompts.isSummary(Prompts.emptySubmit))

        // Keyboard shortcuts
        let optShift: CGEventFlags = [.maskAlternate, .maskShift]
        check("hotkey: Option+Shift+Tab opens a chat", Hotkeys.action(keyCode: 48, flags: optShift, tabHeld: true) == .chat)
        check("hotkey: plain Tab and Shift+Tab pass through",
              Hotkeys.action(keyCode: 48, flags: [], tabHeld: true) == nil
              && Hotkeys.action(keyCode: 48, flags: .maskShift, tabHeld: true) == nil)
        check("hotkey: Cmd+Option+Shift+Tab and Ctrl+Option+Shift+Tab pass through",
              Hotkeys.action(keyCode: 48, flags: optShift.union(.maskCommand), tabHeld: true) == nil
              && Hotkeys.action(keyCode: 48, flags: optShift.union(.maskControl), tabHeld: true) == nil)
        check("hotkey: Tab+\\ snips, \\ alone types", Hotkeys.action(keyCode: 42, flags: [], tabHeld: true) == .snip
              && Hotkeys.action(keyCode: 42, flags: [], tabHeld: false) == nil)
        let blank = Prompts.first(app: "Safari", selection: "", context: nil, question: "What is this chart?", hasScreenshot: true)
        check("prompt: a blank chat says nothing is highlighted",
              blank.contains("Nothing is highlighted") && blank.contains("screenshot") && !blank.contains("Highlighted: «"))

        // Markdown segments
        let segs = MarkdownText.segments("Intro text\n```js\nconst a = 1;\n```\nAfter")
        check("markdown: 3 segments", segs.count == 3)
        check("markdown: code body strips language tag", segs.count == 3 && segs[1].isCode && segs[1].text == "const a = 1;")
        check("markdown: unclosed fence while streaming is code",
              MarkdownText.segments("Hi\n```\nlet x").last?.isCode == true)

        // Prompt building
        let p = Prompts.first(app: "Claude", selection: "foo", context: nil, question: "why?")
        check("prompt: omits empty context", !p.contains("Surrounding"))
        check("prompt: includes question", p.hasSuffix("Question: why?"))

        let shot = Prompts.first(app: "Claude", selection: "foo", context: nil, question: "why?", hasScreenshot: true)
        check("prompt: mentions screenshot", shot.contains("screenshot"))
        check("prompt: web rules only when search is on",
              Prompts.system(webSearch: true).contains("web search") && !Prompts.system(webSearch: false).contains("web search"))

        let snipPrompt = Prompts.first(app: "Preview", selection: "", context: nil, question: "what is this?",
                                       hasScreenshot: true, hasSnip: true)
        check("prompt: snip explains both images",
              snipPrompt.contains("first attached image") && snipPrompt.contains("second image") && !snipPrompt.contains("Highlighted"))

        // Streaming markdown never flashes raw symbols
        check("soften: closes open bold", MarkdownText.softenPartial("this is **imp") == "this is **imp**")
        check("soften: drops a half-typed marker", MarkdownText.softenPartial("this is *") == "this is ")
        check("soften: closes open code", MarkdownText.softenPartial("use `let x") == "use `let x`")
        check("soften: hides a link's half-typed URL",
              MarkdownText.softenPartial("see [swift.org](https://www.sw") == "see swift.org")
        check("soften: leaves finished text alone",
              MarkdownText.softenPartial("**done** and [a](b)") == "**done** and [a](b)")

        // Snip downscaling
        let big = NSImage(size: NSSize(width: 3000, height: 1000), flipped: false) { r in
            NSColor.systemPurple.setFill(); r.fill(); return true
        }
        let bigPNG = NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let snipJPEG = Snipper.downscaledJPEG(bigPNG).flatMap { NSBitmapImageRep(data: $0) }
        check("snip: downscaled to Claude's 1568px edge, aspect kept",
              snipJPEG?.pixelsWide == 1568 && abs((snipJPEG?.pixelsHigh ?? 0) - 523) <= 1)

        // Tool activity labels
        check("activity: search query",
              ClaudeSession.activityLabel(tool: "WebSearch", input: ["query": "swift 6.4"]) == "Searching “swift 6.4”")
        check("activity: fetch host without www",
              ClaudeSession.activityLabel(tool: "WebFetch", input: ["url": "https://www.swift.org/install/"]) == "Reading swift.org")
        check("activity: placeholder before input arrives",
              ClaudeSession.activityLabel(tool: "WebSearch", input: nil) == "Searching the web…")

        // Voice clips: <say> tags
        let pieces = Answer.pieces("Say it: <say lang=\"ru-RU\" ipa=\"zɐˈmok\">замо́к</say> — lock.")
        check("say: text, clip, text", pieces.count == 3)
        if pieces.count == 3, case .say(let r) = pieces[1] {
            check("say: attributes parsed", r.lang == "ru-RU" && r.ipa == "zɐˈmok" && r.text == "замо́к")
        } else { check("say: attributes parsed", false) }
        check("say: hides a tag still streaming in", Answer.pieces("Hear it: <say lang=\"ru", hidePartial: true) == [.text("Hear it: ")])
        check("say: hides a half-typed opener", Answer.pieces("Hear it: <sa", hidePartial: true) == [.text("Hear it: ")])
        if case .say(let r)? = Answer.pieces("<say>привет</say>").first {
            check("say: Cyrillic defaults to Russian", r.lang == "ru-RU")
        } else { check("say: Cyrillic defaults to Russian", false) }
        check("say: stress marks aren't spoken", SayRequest(text: "замо́к", lang: "ru-RU", ipa: nil).spokenText == "замок")
        check("say: IPA slashes trimmed", SayRequest(text: "x", lang: "ru-RU", ipa: "/zɐˈmok/").cleanIPA == "zɐˈmok")
        let phrase = Speech.utterance(for: SayRequest(text: "Как дела́", lang: "ru-RU", ipa: "kak dʲɪˈla"), slow: false)
        var ipaRuns = 0
        phrase.attributedSpeechString.enumerateAttribute(NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute),
                                                         in: NSRange(location: 0, length: phrase.attributedSpeechString.length)) { v, _, _ in
            if v != nil { ipaRuns += 1 }
        }
        check("say: IPA applied word by word", ipaRuns == 2)

        // Real synthesis with the Mac's own voice (offline), into a playable .m4a
        var rendered: Speech.Rendered?
        var renderError: Error?
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("margin-test-\(UUID().uuidString).m4a")
        Speech.render(SayRequest(text: "замо́к", lang: "ru-RU", ipa: "zɐˈmok"), slow: false, to: audioURL) { result in
            switch result {
            case .success(let r): rendered = r
            case .failure(let e): renderError = e
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while rendered == nil && renderError == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let renderError { print("     render error: \(renderError.localizedDescription)") }
        check("speech: renders an audio file", rendered.map { $0.duration > 0.2 && FileManager.default.fileExists(atPath: $0.url.path) } ?? false)
        check("speech: file is playable", (try? AVAudioPlayer(contentsOf: audioURL)).map { $0.duration > 0.2 } ?? false)
        check("speech: waveform has bars", rendered?.waveform.count == Speech.bars)
        check("speech: silence trimmed", Speech.trimSilence([0, 0, 0, 0.5, 0.4, 0, 0], sampleRate: 1) == [0.5, 0.4])
        try? FileManager.default.removeItem(at: audioURL)

        // Sentences: dashes and punctuation don't throw off the IPA pairing
        let sentence = Speech.utterance(for: SayRequest(text: "Да — я закры́л дверь на замо́к.", lang: "ru-RU",
                                                         ipa: "da ja zɐˈkrɨl dvʲerʲ nə zɐˈmok."), slow: false)
        var sentenceRuns = 0
        sentence.attributedSpeechString.enumerateAttribute(NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute),
                                                           in: NSRange(location: 0, length: sentence.attributedSpeechString.length)) { v, _, _ in
            if v != nil { sentenceRuns += 1 }
        }
        check("say: sentence IPA pairs word by word, skipping the dash", sentenceRuns == 6)

        // Videos
        check("youtube: watch link", YouTube.videoID(in: "https://www.youtube.com/watch?v=arj7oStGLkU&t=42") == "arj7oStGLkU")
        check("youtube: short link", YouTube.videoID(in: "see youtu.be/arj7oStGLkU?si=x") == "arj7oStGLkU")
        check("youtube: shorts", YouTube.videoID(in: "youtube.com/shorts/abcdefghijk") == "abcdefghijk")
        check("youtube: v= not first", YouTube.videoID(in: "https://m.youtube.com/watch?feature=share&v=arj7oStGLkU") == "arj7oStGLkU")
        check("youtube: not a video", YouTube.videoID(in: "https://youtube.com/@TED") == nil)
        let xml = #"<transcript><text start="0.5" dur="2">It&amp;#39;s <i>fine</i></text><text start="61.2" dur="2">next &quot;bit&quot;</text></transcript>"#
        let parsed = YouTube.parseCaptions(xml)
        check("captions: seconds format + entities", parsed == [.init(start: 0.5, text: "It's fine"), .init(start: 61.2, text: "next \"bit\"")])
        check("captions: milliseconds format", YouTube.parseCaptions(#"<p t="1500" d="900"><s>Привет</s> мир</p>"#)
              == [.init(start: 1.5, text: "Привет мир")])
        let transcript = VideoTranscript(title: "T", channel: nil, duration: 3700, languageCode: "ru", origin: "test",
                                         segments: [.init(start: 0, text: "a"), .init(start: 10, text: "b"),
                                                    .init(start: 31, text: "c"), .init(start: 3661, text: "d")])
        check("transcript: 30-second paragraphs with times", transcript.formatted() == "[0:00] a b\n[0:31] c\n[1:01:01] d")
        check("transcript: language name", transcript.languageName == "Russian" && !transcript.isEnglish)
        check("video prompt: timestamp links", Prompts.videoRequest(.english, language: "English", link: "https://youtu.be/x")
              .contains("(https://youtu.be/x?t=245)"))

        FeatureTests.run(check)

        // Clipboard snapshot/restore (restores the user's real clipboard afterwards too)
        let pb = NSPasteboard.general
        let userClipboard = PasteboardSnapshot.take(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("MARGIN-ORIGINAL", forType: .string)
        item.setData(Data("{\\rtf1 MARGIN}".utf8), forType: .rtf)
        pb.writeObjects([item])
        let snap = PasteboardSnapshot.take(pb)
        pb.clearContents()
        pb.setString("SOMETHING-COPIED", forType: .string)
        snap.restore(to: pb)
        check("pasteboard: string restored", pb.string(forType: .string) == "MARGIN-ORIGINAL")
        check("pasteboard: rtf restored", pb.data(forType: .rtf) == Data("{\\rtf1 MARGIN}".utf8))
        userClipboard.restore(to: pb)

        print(failures == 0 ? "UNITTEST PASS" : "UNITTEST FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
