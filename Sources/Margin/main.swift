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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        LibraryWindow.shared.onAsk = { [weak self] text, prompt in self?.dock.openChat(about: text, asking: prompt) }
        statusMenu.onSnip = { [weak self] in self?.startSnip() }
        statusMenu.onChat = { [weak self] in self?.chatShortcut() }
        statusMenu.onSummarizeVideo = { [weak self] choice in self?.summarizeVideo(choice) }
        hotkeys.onSnip = { [weak self] in self?.startSnip() }
        hotkeys.onChat = { [weak self] in self?.chatShortcut() }
        hotkeys.onTalkStart = { [weak self] forAgent in self?.voice.talkStart(forAgent: forAgent) }
        hotkeys.onTalkAgent = { [weak self] in self?.voice.switchToAgent() }
        hotkeys.onTalkEnd = { [weak self] in self?.voice.talkEnd() }
        AgentBar.shared.start() // the minimized agent strip on the right edge
        hotkeys.onTasks = { AgentBar.shared.toggle() }
        hotkeys.onHistory = { LibraryWindow.shared.toggle() }
        hotkeys.onEngine = { [dock] in dock.toggleEngineOfOpenChat() }
        statusMenu.onAgentBar = { AgentBar.shared.show() }
        TaskBox.shared.onVideo = { [weak self] intent in self?.summarizeVideo(intent) }
        statusMenu.onTaskBox = { AgentBar.shared.show(newJob: true) }
        statusMenu.onQuickTask = { spec in
            TaskEngine.shared.start(spec)
            AgentBar.shared.show()
        }
        voice.onCommand = { [weak self] text, forAgent in
            if forAgent { self?.agentVoiceCommand(text) } else { self?.voiceCommand(text) }
        }
        voice.warmUp() // loads the speech model now, so the first ⌘⇧V is as quick as any other

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
        case .agents:
            return AgentBar.shared.show()
        case .video(let intent):
            return summarizeVideo(intent)
        case .task(let spec):
            if case .tidy(let folder) = spec, FileSafety.root(containing: folder.appendingPathComponent("x")) == nil {
                return Toast.show("I only tidy Desktop, Downloads and Documents.", near: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1))
            }
            // The new agent's cat appears in the agent bar, running.
            TaskEngine.shared.start(spec)
            return AgentBar.shared.show()
        case .calendar, .ask:
            break
        }
        let mouse = NSEvent.mouseLocation
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        SelectionReader.read(app: app, mouse: mouse, allowCopy: false) { [weak self] found in
            let selection = found ?? Selection(text: "", appName: app.localizedName ?? "your screen",
                                               context: ContextBox(resolved: nil), pid: app.processIdentifier,
                                               mouse: mouse, bundleID: app.bundleIdentifier)
            self?.dock.openChat(selection, asking: text)
        }
    }

    /// ⌘⇧V+A: what you said is a job for an agent, read loosely ("tidy up" is the desktop). If it isn't one the agents
    /// know, the new-job box opens with your words in it.
    private func agentVoiceCommand(_ spoken: String) {
        let text = CommandCenter.cleaned(spoken)
        guard !text.isEmpty else { return }
        trigger.hide()
        if CommandCenter.wantsAgentBar(text) { return AgentBar.shared.show() }
        if let video = VideoIntent.parse(text) { return summarizeVideo(video) }
        guard let spec = TaskRouter.parse(text) else {
            return AgentBar.shared.show(newJob: true, prefill: text,
                                        message: "That doesn't sound like a job for your files. " + TaskRouter.help)
        }
        if case .tidy(let folder) = spec, FileSafety.root(containing: folder.appendingPathComponent("x")) == nil {
            return AgentBar.shared.show(newJob: true, prefill: text,
                                        message: "I only work in Desktop, Downloads and Documents. “\(folder.lastPathComponent)” is somewhere else.")
        }
        TaskEngine.shared.start(spec)
        AgentBar.shared.show()
    }

    /// Tab+\ (or the menu item): box an area you can't highlight and ask about it.
    private func startSnip() {
        guard !Settings.shared.paused, !Snipper.isActive else { return }
        trigger.hide()
        let mouse = NSEvent.mouseLocation
        let near = NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 1)
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            Toast.show("Snipping needs Screen Recording permission. Turn Margin on in System Settings → Privacy & Security → Screen Recording.", near: near)
            return
        }
        dock.prepareForSnip()
        guard dock.hasRoom else {
            Toast.show(AgentDock.fullMessage, near: near)
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        Snipper.run { [weak self] jpeg, mouse in
            self?.dock.openSnip(jpeg: jpeg, mouse: mouse, app: app)
        }
    }

    /// "Summarize this video" said aloud (or typed in the agent box): the same summarizer as the menu's.
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
            // Opening Margin's menu (or speaking) doesn't change the front app, so this is the browser you were in.
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

let arguments = CommandLine.arguments
if arguments.contains("--selftest") { SelfTest.claudeRoundTrip() }
if arguments.contains("--unittest") { SelfTest.unitTests() }
if arguments.contains("--localtest") { LocalTests.live(withClaude: arguments.contains("claude")) }
if arguments.contains("--capturetest") { SelfTest.captureTest() }
if let i = arguments.firstIndex(of: "--calendardemo") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { FeatureTests.calendarDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--voicetest") { FeatureTests.voiceTest(phrase: arguments.indices.contains(i + 1) ? arguments[i + 1] : nil) }
if arguments.contains("--doctest") { FeatureTests.liveDocumentTest() }
if arguments.contains("--voicecheck") { FeatureTests.voiceCheck() }
if arguments.contains("--voicelag") { FeatureTests.voiceLag() }
if arguments.contains("--voicedictation") { FeatureTests.dictationTest() }
if arguments.contains("--namingtest") { FeatureTests.liveNamingTest() }
if arguments.contains("--videochattest") { FeatureTests.videoChatTest() }
if arguments.contains("--customtest") { FeatureTests.liveCustomTest() }
if arguments.contains("--switchtest") { FeatureTests.liveSwitchTest() }
if let i = arguments.firstIndex(of: "--pilldemo") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { FeatureTests.pillDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--taskdemo") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { FeatureTests.taskDemo(directory: dir) }
}
if arguments.contains("--libtest") { FeatureTests.liveLibraryTest() }
if arguments.contains("--tokenbench") { FeatureTests.tokenBench() }
if let i = arguments.firstIndex(of: "--agentbartest"), i + 1 < arguments.count { FeatureTests.agentBarTest(directory: arguments[i + 1]) }
if let i = arguments.firstIndex(of: "--catsheet"), i + 1 < arguments.count { FeatureTests.catSheet(path: arguments[i + 1]) }
if let i = arguments.firstIndex(of: "--libdemo") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { FeatureTests.libraryDemo(directory: dir) }
}
if let i = arguments.firstIndex(of: "--sidebartest") {
    SelfTest.sidebarTest(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : nil)
}
if let i = arguments.firstIndex(of: "--glowtest") {
    SelfTest.glowTest(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : nil)
}
if let i = arguments.firstIndex(of: "--placetest") {
    SelfTest.placeTest(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : nil)
}
if arguments.contains("--permtest") {
    // What macOS currently lets this copy of Margin do (run via `open`, so it's checked as Margin itself).
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
    SelfTest.youtubeTest(id: arguments.indices.contains(i + 1) ? arguments[i + 1] : "arj7oStGLkU")
}
if let i = arguments.firstIndex(of: "--videodemo") {
    Demo.videos(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory())
}
if let i = arguments.firstIndex(of: "--graphtest") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : nil
    MainActor.assumeIsolated { SelfTest.graphTest(outputDirectory: dir) }
}
if let i = arguments.firstIndex(of: "--localdemo") {
    LocalTests.demo(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory())
}
if let i = arguments.firstIndex(of: "--summarydemo") {
    Demo.summaries(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory())
}
if let i = arguments.firstIndex(of: "--graphdemo") {
    let dir = arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { Demo.graphs(outputDirectory: dir) } // top-level code runs on the main thread
}
if let i = arguments.firstIndex(of: "--voicedemo") {
    Demo.voice(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory())
}
if let i = arguments.firstIndex(of: "--render-icon"), arguments.indices.contains(i + 1) {
    ClaudeMark.renderIconset(to: arguments[i + 1])
}
if let i = arguments.firstIndex(of: "--demo") {
    Demo.run(outputDirectory: arguments.indices.contains(i + 1) ? arguments[i + 1] : NSTemporaryDirectory())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
