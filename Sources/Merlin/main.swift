import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = SelectionWatcher()
    private let trigger = TriggerIcon()
    private let dock = AgentDock()
    private let hotkeys = Hotkeys()
    private let voice = VoiceController()
    private var statusMenu: StatusMenu!
    private var trustTimer: Timer?
    private let pointAsk = PointToAsk()
    /// Point to ask with talk held: whichever arrives first (the picture or the words) waits here for the other.
    private var pendingPicture: (jpeg: Data, png: Data, mouse: NSPoint, app: NSRunningApplication?, at: Date)?
    private var pendingSpoken: String?
    /// A point-to-ask picture is being taken.
    private var pointCapturing = false
    /// A spoken command came while pointing: the picture that comes next is not asked about (no chat opens).
    private var dropComingPicture = false
    /// "Open microeconomics note", "show my chats": commands that act and open no chat (spoken here, typed in a blank chat).
    private lazy var commands = CommandRunner.live(dock: dock)
    private let agent = AgentLoop()
    /// Quick answers (a spoken fact question): their own loop, so a running command never blocks one.
    private let answerer = AgentLoop()
    /// Merlin agents: up to 3 at once, a queue of 5, $1.00 a task and $3.00 a day. Each dialog names its agent.
    private(set) lazy var agents = AgentPool(
        makeTools: { [weak self] name in
            self?.commands.actions.map { runner in
                AgentTools(runner: runner, confirmScript: { line, source in AgentTools.liveConfirmScript("Agent “\(name)”: \(line)", source) },
                           mail: MailBackend(read: MailTools.liveRead, compose: MailTools.liveCompose,
                                             confirmSend: { d, warn in MailTools.liveConfirmSend(d, ["Agent “\(name)” wrote this email.", warn].compactMap { $0 }.joined(separator: " ")) }),
                           messages: MessagesBackend(send: MessagesTools.liveSend,
                                                     confirm: { to, text, warn in MessagesTools.liveConfirm(to, text, ["Agent “\(name)” wrote this message.", warn].compactMap { $0 }.joined(separator: " ")) }))
            }
        },
        saveNote: AgentPool.liveSaveNote,
        openNote: AgentPool.liveOpenNote,
        report: { line in
            let m = NSEvent.mouseLocation
            Toast.show(line, near: NSRect(x: m.x, y: m.y, width: 1, height: 1))
        })
    private var agentRow: AgentRowPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyMode()
        installEditMenu()
        SelectionReader.configure()
        Speech.clearLeftovers()

        statusMenu = StatusMenu()
        statusMenu.onPauseChanged = { [weak self] paused in
            if paused { self?.trigger.hide() }
        }
        statusMenu.agentCount = { [weak self] in self?.dock.count ?? 0 }
        // The hidden edge panel (chats and notes at the middle of the right screen edge). It never shows during point to
        // ask or while a point-to-ask picture is taken (a snip, a drag and a full-screen app are checked inside).
        let edge = EdgePanelController.shared
        edge.isBlocked = { [weak self] in
            guard let self else { return false }
            return self.pointAsk.isActive || self.pointCapturing
        }
        edge.start()
        statusMenu.onShowEdgePanel = { edge.show(.chats) }
        CommandRunner.shared = commands
        LibraryAssistant.actionHook = commands.actions
        // A request typed in a blank chat goes to the same agent loop; its lines show where the chat was.
        AgentLoop.typedHook = { [weak self] text, spot in
            self?.runAgent(text) { line in Toast.show(line, near: NSRect(x: spot.x, y: spot.y, width: 1, height: 1)) }
        }
        // Merlin agents: a long task runs in the background (one at a time, a queue behind it), with a row and Stop.
        agentRow = AgentRowPanel(pool: agents)
        // Timers and reminders: banners show while Merlin is in front too; one that ends while Merlin runs also says so here.
        NotificationPresenter.install()
        TimerStore.shared.onFinish = { [weak self] t in
            self?.voice.say(t.label.isEmpty ? (t.isReminder ? "Reminder: \(ActionCommand.duration(t.seconds)) are up" : "Your timer is done") : "Reminder: \(t.label)")
        }
        statusMenu.onHistory = { notebook in LibraryWindow.shared.show(notebook: notebook) }
        statusMenu.onScreenshots = { LibraryWindow.shared.show(mode: .screenshots) }
        statusMenu.onBin = { LibraryWindow.shared.show(mode: .bin) }
        // The Library's settings are a page inside the Library window; the sector editor is its Sectors section.
        LibraryHooks.openSettings = { LibraryWindow.shared.showSettings() }
        LibraryHooks.openSectorEditor = { LibraryWindow.shared.showSettings(section: .sectors) }
        LibrarySettingsHooks.openSectorEditor = { LibraryWindow.shared.showSettings(section: .sectors) }
        Library.shared.applyRetention() // Bin auto-empty and screenshot retention, at launch and not only when the window opens
        LibraryWindow.shared.onNewChat = { [weak self] in self?.chatShortcut() }
        LibraryWindow.shared.onAsk = { [weak self] text, prompt in self?.dock.openChat(about: text, asking: prompt) }
        LibraryWindow.shared.onAskImage = { [weak self] jpeg, app in self?.dock.openChat(aboutImage: jpeg, appName: app) }
        ScreenshotInbox.shared.start() // every screenshot you take is kept in the dashboard
        statusMenu.onSnip = { [weak self] in self?.startSnip() }
        statusMenu.onChat = { [weak self] in self?.chatShortcut() }
        statusMenu.onSummarizeVideo = { [weak self] choice in self?.summarizeVideo(choice) }
        hotkeys.onSnip = { [weak self] in self?.startSnip() }
        hotkeys.onChat = { [weak self] in self?.chatShortcut() }
        hotkeys.onTalkStart = { [weak self] in self?.voice.talkStart() }
        hotkeys.onTalkEnd = { [weak self] in self?.voice.talkEnd() }
        // Talk on a lone modifier, cut short by another key or a click (Control+C): the recording is thrown away.
        hotkeys.onTalkCancel = { [weak self] in
            self?.voice.dismiss()
            self?.pendingPicture = nil
        }
        hotkeys.onPointStart = { [weak self] from, to in
            self?.dropComingPicture = false
            self?.pointAsk.begin(from: from, to: to)
        }
        hotkeys.onPointMove = { [weak self] p in self?.pointAsk.move(to: p) }
        hotkeys.onPointCancel = { [weak self] in
            self?.pointAsk.cancel()
            self?.flushSpoken()
        }
        hotkeys.onPointEnd = { [weak self] withTalk in self?.finishPoint(withTalk: withTalk) }
        hotkeys.onHistory = { LibraryWindow.shared.toggle() }
        hotkeys.onSystemShot = { ScreenshotInbox.shared.noteCaptureKey() }
        hotkeys.onEngine = { [dock] in dock.toggleEngineOfOpenChat() }
        hotkeys.onEdgePanel = { edge.toggleFromShortcut() }
        hotkeys.onPointerMoved = { p in edge.tapMoved(p) } // on the tap's thread: a few rect checks, nothing more
        hotkeys.onDoubleShift = { [dock] in dock.attachScreenshotToOpenChat() }
        voice.onCommand = { [weak self] text in self?.voiceCommand(text) }
        voice.warmUp() // loads the speech model now, so the first talk is as quick as any other

        watcher.onSelection = { [weak self] selection, point in
            self?.trigger.show(selection, at: point)
        }
        watcher.onDismissSignal = { [weak self] in self?.trigger.hide() }
        trigger.onClick = { [weak self] selection, iconFrame in
            self?.dock.open(selection, iconFrame: iconFrame)
        }

        if AXIsProcessTrusted() {
            watcher.start()
            hotkeys.start()
        } else {
            requestTrust()
        }
        if Settings.shared.screenContext != .off, !ScreenCapture.hasPermission {
            ScreenCapture.requestPermission()
        }
    }

    /// Shows the system's own permission prompt, then waits until the user grants it.
    private func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        statusMenu.refresh()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.watcher.start()
            self?.hotkeys.start()
            self?.statusMenu.refresh()
        }
    }

    /// Option+Shift+Tab: a chat at the mouse, with whatever's highlighted (or nothing), any time.
    /// Pressing it again while you're typing in that chat puts it away.
    private func chatShortcut() {
        trigger.hide()
        let mouse = NSEvent.mouseLocation
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Read any highlighted text first (Accessibility only, never a synthetic ⌘C), then open.
        SelectionReader.read(app: app, mouse: mouse, allowCopy: false) { [weak self] found in
            self?.dock.chatShortcut {
                found ?? Selection(text: "", appName: app.localizedName ?? "your screen",
                                   context: ContextBox(resolved: nil), pid: app.processIdentifier,
                                   mouse: mouse, bundleID: app.bundleIdentifier)
            }
        }
    }

    /// Something you said: a calendar request or a question. A chat that's open takes it as a follow-up.
    private func voiceCommand(_ spoken: String) {
        let text = CommandCenter.cleaned(spoken)
        guard !text.isEmpty else { return }
        trigger.hide()
        let route = CommandCenter.route(text, sheets: Library.shared.sheets.map(\.name), actions: commands.actionContext)
        switch route {
        case .video(let intent):
            return summarizeVideo(intent)
        case .openNote, .addToNote, .newNote, .openChats, .openNotes, .act:
            // A command acts at once and opens no chat. A point-to-ask picture meant for these words is dropped.
            pendingPicture = nil
            pendingSpoken = nil
            if pointAsk.isActive || pointCapturing { dropComingPicture = true }
            if let line = commands.run(route) { voice.say(line) }
            return
        case .ask where pendingPicture == nil && !pointAsk.isActive && !pointCapturing && AgentRequest.looksLikeRequest(text, context: commands.actionContext):
            // No rule fits, but it asks Merlin to do something: the agent loop (Claude with Merlin's tools).
            return runAgent(text) { [weak self] line in
                guard let self, !self.voice.isTalking else { return }
                self.voice.say(line)
            }
        case .ask where pendingPicture == nil && !pointAsk.isActive && !pointCapturing && !dock.hasOpenChat
                        && AgentRequest.looksLikeQuickQuestion(text):
            // A short fact question with no chat open: Haiku with web search answers in seconds, next to the mouse.
            return quickAnswer(text)
        case .calendar, .ask:
            break
        }
        // Said while pointing: the words go with the point-to-ask picture, in a new chat.
        if let picture = pendingPicture {
            pendingPicture = nil
            if Date().timeIntervalSince(picture.at) < 60 {
                return askAboutSnip(jpeg: picture.jpeg, png: picture.png, mouse: picture.mouse, app: picture.app, asking: text)
            }
        }
        if pointAsk.isActive || pointCapturing {
            pendingSpoken = text // the picture isn't taken yet: `finishPoint` picks the words up
            return
        }
        askSpoken(text)
    }

    /// The agent loop (C1b): Claude gets the words and Merlin's tools and does the task; `report` shows the status lines
    /// and the last line. If Claude reads the words as a question, they go to a chat as before.
    private func runAgent(_ text: String, report: @escaping (String) -> Void) {
        let mouse = NSEvent.mouseLocation, app = NSWorkspace.shared.frontmostApplication
        guard let runner = commands.actions else { return askSpoken(text, mouse: mouse, app: app) }
        let tools = AgentTools(runner: runner, confirmScript: AgentTools.liveConfirmScript)
        tools.onStep = { line in report(line + "…") }
        tools.saveNote = AgentPool.liveSaveNote
        tools.startAgent = { [weak self] task in self?.agents.start(task) ?? "Agents aren't ready." }
        report("Working on it…")
        agent.run(text, tools: tools) { [weak self] outcome in
            switch outcome {
            case .done(let line), .failed(let line): report(line)
            case .question: self?.askSpoken(text, mouse: mouse, app: app)
            }
        }
    }

    /// A quick answer, unless text is highlighted (then the question is about it: a chat, as before). A question
    /// Claude says needs more, or a failure, goes to a chat too.
    private func quickAnswer(_ text: String) {
        let mouse = NSEvent.mouseLocation, app = NSWorkspace.shared.frontmostApplication
        guard let app, !answerer.isRunning, let runner = commands.actions else { return askSpoken(text, mouse: mouse, app: app) }
        SelectionReader.read(app: app, mouse: mouse, allowCopy: false) { [weak self] found in
            guard let self else { return }
            if let found, !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return self.dock.openChat(found, asking: text)
            }
            self.voice.say("Looking it up…")
            let tools = AgentTools(runner: runner, confirmScript: { _, _ in false })
            self.answerer.run(text, tools: tools, profile: .answer) { [weak self] outcome in
                guard let self else { return }
                if case .done(let line) = outcome, !line.hasPrefix("Stopped:") {
                    let words = Double(line.split(separator: " ").count)
                    Toast.show(line, near: NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1), seconds: min(20, 3 + words / 3))
                } else {
                    self.askSpoken(text, mouse: mouse, app: app)
                }
            }
        }
    }

    /// A spoken question with no picture: to the open chat, or a new one about what's highlighted.
    /// `mouse` and `app`: read when the words came (the agent loop hands a question back seconds later).
    private func askSpoken(_ text: String, mouse: NSPoint = NSEvent.mouseLocation,
                           app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let app else { return }
        SelectionReader.read(app: app, mouse: mouse, allowCopy: false) { [weak self] found in
            let selection = found ?? Selection(text: "", appName: app.localizedName ?? "your screen",
                                               context: ContextBox(resolved: nil), pid: app.processIdentifier,
                                               mouse: mouse, bundleID: app.bundleIdentifier)
            self?.dock.openChat(selection, asking: text)
        }
    }

    /// Tab+\ (or the menu item): box an area you can't highlight and ask about it.
    private func startSnip() {
        guard !Settings.shared.paused, !Snipper.isActive else { return }
        trigger.hide()
        guard canCapture() else { return }
        let app = NSWorkspace.shared.frontmostApplication
        dock.prepareForSnip() // open chats step aside for a moment so they aren't in the picture
        Snipper.run(finished: { [weak self] in self?.dock.finishSnip() }) { [weak self] jpeg, png, mouse in
            self?.askAboutSnip(jpeg: jpeg, png: png, mouse: mouse, app: app)
        }
    }

    /// Screen Recording is allowed; if not, asks for it and says why.
    private func canCapture() -> Bool {
        guard ScreenCapture.hasPermission else {
            let mouse = NSEvent.mouseLocation
            ScreenCapture.requestPermission()
            Toast.show("Snipping needs Screen Recording permission. Turn Merlin on in System Settings → Privacy & Security → Screen Recording.",
                       near: NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 1))
            return false
        }
        return true
    }

    /// A snip (or point-to-ask picture) is taken: keep it, then open a chat about it (asking `question` if one was spoken).
    private func askAboutSnip(jpeg: Data, png: Data, mouse: NSPoint, app: NSRunningApplication?, asking question: String? = nil,
                              source: ScreenshotRecord.Source = .snip) {
        // Every snip is kept in the dashboard, whether or not there's a free chat to ask about it.
        ScreenshotInbox.shared.addSnip(png: png, app: app, source: source)
        guard dock.hasRoom else {
            Toast.show("Saved to your screenshots. " + AgentDock.fullMessage, near: NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 1))
            return
        }
        dock.openSnip(jpeg: jpeg, mouse: mouse, app: app, asking: question)
    }

    /// Point to ask: Shift was let go. Takes the area around the trail and asks about it, like a snip. With talk held,
    /// the picture waits for the spoken question (or takes the one already heard).
    private func finishPoint(withTalk: Bool) {
        guard let rect = pointAsk.end() else { return flushSpoken() }
        guard !Settings.shared.paused, !Snipper.isActive, canCapture() else { return flushSpoken() }
        trigger.hide()
        let app = NSWorkspace.shared.frontmostApplication
        pointCapturing = true
        dock.prepareForSnip()
        var taken = false
        Snipper.run(rect: rect, afterHiding: pointAsk.overlayWindowNumber, finished: { [weak self] in
            self?.dock.finishSnip()
        }) { [weak self] jpeg, png, mouse in
            guard let self else { return }
            taken = true
            self.pointCapturing = false
            if self.dropComingPicture {
                self.dropComingPicture = false // the words were a command; it already ran, and the picture is dropped
            } else if let spoken = self.pendingSpoken {
                self.pendingSpoken = nil
                self.askAboutSnip(jpeg: jpeg, png: png, mouse: mouse, app: app, asking: spoken, source: .point)
            } else if withTalk && self.voice.isBusy {
                self.pendingPicture = (jpeg, png, mouse, app, Date()) // the words are still on their way
            } else {
                self.askAboutSnip(jpeg: jpeg, png: png, mouse: mouse, app: app, source: .point)
            }
        }
        // `finished` runs before the picture is read; if no picture came, the words (if any) go on without it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !taken, self.pointCapturing else { return }
            self.pointCapturing = false
            self.dropComingPicture = false
            self.flushSpoken()
        }
    }

    /// Words spoken while pointing, when no picture is coming after all: ask them as usual.
    private func flushSpoken() {
        guard let text = pendingSpoken else { return }
        pendingSpoken = nil
        askSpoken(text)
    }

    /// "Summarize this video" said aloud: the same summarizer as the menu's.
    private func summarizeVideo(_ intent: VideoIntent) {
        switch intent {
        case .youtube(let id?): dock.openVideo(.youtube(id: id), near: NSEvent.mouseLocation)
        case .youtube(nil): summarizeVideo(.youtubeTab)
        case .listenAlong: summarizeVideo(.listen)
        }
    }

    /// Menu bar → Summarize Video.
    private func summarizeVideo(_ choice: VideoMenuChoice) {
        let mouse = NSEvent.mouseLocation
        let near = NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 1)
        switch choice {
        case .youtubeTab:
            // Opening Merlin's menu (or speaking) doesn't change the front app, so this is the browser you were in.
            switch VideoIntent.locate() {
            case .video(let id): dock.openVideo(.youtube(id: id), near: mouse)
            case let problem: Toast.show(VideoIntent.explain(problem), near: near)
            }
        case .listen:
            guard ScreenCapture.hasPermission else {
                ScreenCapture.requestPermission()
                return Toast.show("Listening needs Screen & System Audio Recording permission.", near: near)
            }
            dock.openVideo(.listen, near: mouse)
        case .file:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
            panel.message = "Choose a video or audio file to summarize"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dock.openVideo(.file(url), near: mouse)
        }
    }

    /// Menu-less apps don't get ⌘C/⌘V/⌘A in text fields without an Edit menu.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

Migration.runIfNeeded() // first of all: copies the old Margin settings and data folder, once. Skips every test/shot flag.
if CommandLine.arguments.contains("--mcp") { MCPServer.runStdio() } // before any UI/font setup: stdout is protocol-only
MerlinFonts.register()
let arguments = CommandLine.arguments

/// The word right after the flag at `arguments[i]`, if there is one.
func argument(after i: Int) -> String? { arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
if arguments.contains("--selftest") { SelfTest.claudeRoundTrip() }
// Headless: sends one request through the Library Assistant's real path (prompt, Haiku, parse) and prints what came back. Runs nothing.
if let i = arguments.firstIndex(of: "--assistantcheck"), i + 1 < arguments.count {
    MainActor.assumeIsolated {
        let assistant = LibraryAssistant()
        let prompt = assistant.userPrompt(arguments[i + 1], history: [])
        switch ClaudeOneShot.runSync(prompt, system: LibraryAssistant.systemPrompt, model: .haiku, effort: "low", timeout: 90) {
        case .failure(let failure): print("FAILURE: \(failure.localizedDescription)")
        case .success(let reply):
            print("REPLY: \(reply.text)")
            if let plan = LibraryAssistant.parse(reply.text) {
                print("PARSED say=\(plan.say) actions=\(plan.actions.map(\.type)) risk=\(LibraryAssistant.risk(of: plan))")
            } else { print("PARSE FAILED") }
        }
    }
    exit(0)
}
if let i = arguments.firstIndex(of: "--livecheck"), i + 1 < arguments.count { MainActor.assumeIsolated { LiveCheck.run(directory: arguments[i + 1]) } }
if let i = arguments.firstIndex(of: "--settingsshots"), arguments.indices.contains(i + 1) { MainActor.assumeIsolated { LibrarySettingsView.renderShots(to: URL(fileURLWithPath: arguments[i + 1])); LibrarySettingsView.renderShortcutShots(to: URL(fileURLWithPath: arguments[i + 1])) }; exit(0) }
if arguments.contains("--agenttest") { FeatureTests.agentLiveTest() }
if arguments.contains("--workertest") { FeatureTests.workerLiveTest() }
if arguments.contains("--unittest") { SelfTest.unitTests() }
if let i = arguments.firstIndex(of: "--orbtest") { OrbTests.golden(path: argument(after: i) ?? "third_party/thinking-orbs/orbs-golden.json") }
if arguments.contains("--localtest") { LocalTests.live(withClaude: arguments.contains("claude")) }
if arguments.contains("--capturetest") { SelfTest.captureTest() }
if let i = arguments.firstIndex(of: "--calendardemo") {
    let dir = (argument(after: i) ?? NSTemporaryDirectory())
    MainActor.assumeIsolated { FeatureTests.calendarDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--voicetest") { FeatureTests.voiceTest(phrase: argument(after: i)) }
if arguments.contains("--doctest") { FeatureTests.liveDocumentTest() }
if arguments.contains("--visualrendertest") { FeatureTests.visualRenderTest() }
if arguments.contains("--visualsandboxtest") { FeatureTests.visualSandboxTest() }
if let i = arguments.firstIndex(of: "--visualshots"), i + 2 < arguments.count {
    MainActor.assumeIsolated { FeatureTests.visualShots(svg: arguments[i + 1], directory: arguments[i + 2]) }
}
if let i = arguments.firstIndex(of: "--visuallive") { MainActor.assumeIsolated { FeatureTests.visualLiveTest(directory: argument(after: i) ?? NSTemporaryDirectory()) } }
if arguments.contains("--voicecheck") { FeatureTests.voiceCheck() }
if arguments.contains("--voicelag") { FeatureTests.voiceLag() }
if arguments.contains("--voicedictation") { FeatureTests.dictationTest() }
// `--loadcheck <dir>`: loads a COPY of a Library folder and prints what was read against what is on disk. Never point it at the real folder.
if let i = arguments.firstIndex(of: "--loadcheck"), let dir = argument(after: i) {
    let url = URL(fileURLWithPath: dir)
    func files(_ sub: String) -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(sub).path)) ?? []).filter { $0.hasSuffix(".json") }.count }
    let before = (files("chats"), files("notes"), files("screenshots"), files("bin"))
    let lib = Library(directory: url)
    print("on disk before: chats=\(before.0) notes=\(before.1) screenshots=\(before.2) bin=\(before.3)")
    print("loaded:         chats=\(lib.chats.count) notes=\(lib.notes.count) screenshots=\(lib.screenshots.count) bin=\(lib.binned.count) sheets=\(lib.sheets.count)")
    lib.flush()
    print("on disk after:  chats=\(files("chats")) notes=\(files("notes")) screenshots=\(files("screenshots")) bin=\(files("bin"))")
    exit(0)
}
if arguments.contains("--trailcheck") { PointToAsk.liveTrailCheck() }
if arguments.contains("--voicemodelcheck") { Dictation.printModelStatus() }
if arguments.contains("--namingtest") { FeatureTests.liveNamingTest() }
if arguments.contains("--videochattest") { FeatureTests.videoChatTest() }
if arguments.contains("--switchtest") { FeatureTests.liveSwitchTest() }
if arguments.contains("--historytest") { FeatureTests.liveHistoryTest() }
if arguments.contains("--bintest") { FeatureTests.liveBinTest() }
if arguments.contains("--screenshottest") { FeatureTests.liveScreenshotTest() }
if let i = arguments.firstIndex(of: "--pilldemo") {
    let dir = (argument(after: i) ?? NSTemporaryDirectory())
    MainActor.assumeIsolated { FeatureTests.pillDemo(directory: dir) }
}
if arguments.contains("--libtest") { FeatureTests.liveLibraryTest() }
if arguments.contains("--tokenbench") { FeatureTests.tokenBench() }
if let i = arguments.firstIndex(of: "--uishots"), i + 1 < arguments.count { MainActor.assumeIsolated { UIShots.run(directory: arguments[i + 1]) } }
// The edge dock's real Liquid Glass on the real screen, fixtures only: six pictures into the folder, then exit.
if let i = arguments.firstIndex(of: "--edgeglasscheck"), i + 1 < arguments.count { MainActor.assumeIsolated { FeatureTests.edgeGlassCheck(directory: arguments[i + 1]) } }
if let i = arguments.firstIndex(of: "--chromeshots"), i + 1 < arguments.count { MainActor.assumeIsolated { ChromeShots.run(directory: arguments[i + 1]) } }
if let i = arguments.firstIndex(of: "--orbshots"), i + 1 < arguments.count { MainActor.assumeIsolated { ThinkingOrb.renderShots(to: URL(fileURLWithPath: arguments[i + 1], isDirectory: true)) } }
if let i = arguments.firstIndex(of: "--glyphshots"), i + 1 < arguments.count { MainActor.assumeIsolated { GlyphGallery.renderShots(to: URL(fileURLWithPath: arguments[i + 1], isDirectory: true)); exit(0) } }
if let i = arguments.firstIndex(of: "--sectorshots"), i + 1 < arguments.count { MainActor.assumeIsolated { SectorEditorView.renderShots(to: URL(fileURLWithPath: arguments[i + 1], isDirectory: true)); exit(0) } }
if let i = arguments.firstIndex(of: "--libdemo") {
    let dir = (argument(after: i) ?? NSTemporaryDirectory())
    MainActor.assumeIsolated { FeatureTests.libraryDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--sidebartest") {
    SelfTest.sidebarTest(outputDirectory: argument(after: i))
}
if let i = arguments.firstIndex(of: "--glowtest") {
    SelfTest.glowTest(outputDirectory: argument(after: i))
}
if let i = arguments.firstIndex(of: "--placetest") {
    SelfTest.placeTest(outputDirectory: argument(after: i))
}
if arguments.contains("--permtest") {
    // What macOS currently lets this copy of Merlin do (run via `open`, so it's checked as Merlin itself).
    print("accessibility: \(AXIsProcessTrusted())")
    print("screen recording: \(ScreenCapture.hasPermission)")
    exit(0)
}
if arguments.contains("--micprobe") {
    // Is the microphone quick to start? Needs the permission already granted (this never asks for it). Run via `open`.
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .authorized else {
        print("microphone permission: \(["not asked yet", "restricted", "denied", "allowed"][status.rawValue]); nothing was recorded")
        exit(0)
    }
    setvbuf(stdout, nil, _IONBF, 0)
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task {
        print(await Dictation.probe(seconds: 1.5))
        exit(0)
    }
    NSApplication.shared.run()
}
if arguments.contains("--saytest") { SelfTest.sayTest() }
if let i = arguments.firstIndex(of: "--youtubetest") {
    SelfTest.youtubeTest(id: (argument(after: i) ?? "arj7oStGLkU"))
}
if let i = arguments.firstIndex(of: "--videodemo") {
    Demo.videos(outputDirectory: (argument(after: i) ?? NSTemporaryDirectory()))
}
if let i = arguments.firstIndex(of: "--graphtest") {
    let dir = argument(after: i)
    MainActor.assumeIsolated { SelfTest.graphTest(outputDirectory: dir) }
}
if let i = arguments.firstIndex(of: "--localdemo") {
    LocalTests.demo(outputDirectory: (argument(after: i) ?? NSTemporaryDirectory()))
}
if let i = arguments.firstIndex(of: "--summarydemo") {
    Demo.summaries(outputDirectory: (argument(after: i) ?? NSTemporaryDirectory()))
}
if let i = arguments.firstIndex(of: "--graphdemo") {
    let dir = (argument(after: i) ?? NSTemporaryDirectory())
    MainActor.assumeIsolated { Demo.graphs(outputDirectory: dir) } // top-level code runs on the main thread
}
if let i = arguments.firstIndex(of: "--voicedemo") {
    Demo.voice(outputDirectory: (argument(after: i) ?? NSTemporaryDirectory()))
}
if let i = arguments.firstIndex(of: "--render-icon"), arguments.indices.contains(i + 1) {
    ClaudeMark.renderIconset(to: arguments[i + 1])
}
if let i = arguments.firstIndex(of: "--demo") {
    Demo.run(outputDirectory: (argument(after: i) ?? NSTemporaryDirectory()))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
