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
        statusMenu.sidebarIsOpen = { [weak self] in self?.dock.sidebarIsOpen ?? true }
        statusMenu.onToggleSidebar = { [weak self] in self?.dock.toggleSidebar() }
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
        hotkeys.onPointStart = { [weak self] from, to in self?.pointAsk.begin(from: from, to: to) }
        hotkeys.onPointMove = { [weak self] p in self?.pointAsk.move(to: p) }
        hotkeys.onPointCancel = { [weak self] in
            self?.pointAsk.cancel()
            self?.flushSpoken()
        }
        hotkeys.onPointEnd = { [weak self] withTalk in self?.finishPoint(withTalk: withTalk) }
        hotkeys.onHistory = { LibraryWindow.shared.toggle() }
        hotkeys.onSystemShot = { ScreenshotInbox.shared.noteCaptureKey() }
        hotkeys.onEngine = { [dock] in dock.toggleEngineOfOpenChat() }
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
        switch CommandCenter.route(text) {
        case .video(let intent):
            return summarizeVideo(intent)
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

    /// A spoken question with no picture: to the open chat, or a new one about what's highlighted.
    private func askSpoken(_ text: String) {
        let mouse = NSEvent.mouseLocation
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
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
            if let spoken = self.pendingSpoken {
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
if arguments.contains("--unittest") { SelfTest.unitTests() }
if arguments.contains("--localtest") { LocalTests.live(withClaude: arguments.contains("claude")) }
if arguments.contains("--capturetest") { SelfTest.captureTest() }
if let i = arguments.firstIndex(of: "--calendardemo") {
    let dir = (argument(after: i) ?? NSTemporaryDirectory())
    MainActor.assumeIsolated { FeatureTests.calendarDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--voicetest") { FeatureTests.voiceTest(phrase: argument(after: i)) }
if arguments.contains("--doctest") { FeatureTests.liveDocumentTest() }
if arguments.contains("--voicecheck") { FeatureTests.voiceCheck() }
if arguments.contains("--voicelag") { FeatureTests.voiceLag() }
if arguments.contains("--voicedictation") { FeatureTests.dictationTest() }
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
if let i = arguments.firstIndex(of: "--chromeshots"), i + 1 < arguments.count { MainActor.assumeIsolated { ChromeShots.run(directory: arguments[i + 1]) } }
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
