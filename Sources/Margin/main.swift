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
        // The Library's Settings and sector editor are one window: the editor is the Sectors section of the settings.
        LibraryHooks.openSettings = { LibrarySettingsWindow.show() }
        LibraryHooks.openSectorEditor = { LibrarySettingsWindow.show(section: .sectors) }
        LibrarySettingsHooks.openSectorEditor = { LibrarySettingsWindow.show(section: .sectors) }
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
        hotkeys.onHistory = { LibraryWindow.shared.toggle() }
        hotkeys.onSystemShot = { ScreenshotInbox.shared.noteCaptureKey() }
        hotkeys.onEngine = { [dock] in dock.toggleEngineOfOpenChat() }
        hotkeys.onDoubleShift = { [dock] in dock.attachScreenshotToOpenChat() }
        voice.onCommand = { [weak self] text in self?.voiceCommand(text) }
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
        case .video(let intent):
            return summarizeVideo(intent)
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
        let app = NSWorkspace.shared.frontmostApplication
        dock.prepareForSnip() // open chats step aside for a moment so they aren't in the picture
        Snipper.run(finished: { [weak self] in self?.dock.finishSnip() }) { [weak self] jpeg, png, mouse in
            // Every snip is kept in the dashboard, whether or not there's a free chat to ask about it.
            ScreenshotInbox.shared.addSnip(png: png, app: app)
            guard let self else { return }
            guard self.dock.hasRoom else {
                Toast.show("Saved to your screenshots. " + AgentDock.fullMessage, near: NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 1))
                return
            }
            self.dock.openSnip(jpeg: jpeg, mouse: mouse, app: app)
        }
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

if CommandLine.arguments.contains("--mcp") { MCPServer.runStdio() } // before any UI/font setup: stdout is protocol-only
MarginFonts.register()
let arguments = CommandLine.arguments

/// The word right after the flag at `arguments[i]`, if there is one.
func argument(after i: Int) -> String? { arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
if arguments.contains("--selftest") { SelfTest.claudeRoundTrip() }
if let i = arguments.firstIndex(of: "--settingsshots"), arguments.indices.contains(i + 1) { MainActor.assumeIsolated { LibrarySettingsView.renderShots(to: URL(fileURLWithPath: arguments[i + 1])) }; exit(0) }
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
