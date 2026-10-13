import AppKit
import ServiceManagement

/// The menu-bar item: pause, model, launch at login, permissions, quit.
final class StatusMenu: NSObject, NSMenuDelegate {
    var onPauseChanged: ((Bool) -> Void)?
    var agentCount: () -> Int = { 0 }
    var onSnip: (() -> Void)?
    var onChat: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onHistory: ((_ notebook: Bool) -> Void)?
    var onTaskBox: (() -> Void)?
    var onAgentBar: (() -> Void)?
    var onQuickTask: ((TaskSpec) -> Void)?
    var sidebarIsOpen: () -> Bool = { true }
    var onSummarizeVideo: ((VideoMenuChoice) -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings = Settings.shared

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        // The spark normally; a warning bubble while permission is missing.
        let image = trusted
            ? ClaudeMark.menuBarImage()
            : NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Margin")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = settings.paused
        item.button?.toolTip = trusted ? (settings.paused ? "Margin (paused)" : "Margin") : "Margin needs Accessibility permission"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()

        let status = !trusted ? "Needs Accessibility permission"
            : settings.paused ? "Paused" : "Active: highlight text anywhere"
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        let agents = NSMenuItem(title: "Agents: \(agentCount()) of \(settings.maxAgents)", action: nil, keyEquivalent: "")
        agents.isEnabled = false
        menu.addItem(agents)

        if !trusted {
            menu.addItem(action("Grant Accessibility Permission…", #selector(openAccessibilitySettings)))
        }
        if settings.screenContext != .off, !ScreenCapture.hasPermission {
            menu.addItem(action("Grant Screen Recording Permission…", #selector(openScreenRecordingSettings)))
        }
        menu.addItem(.separator())

        let chat = action("New Chat", #selector(chatFromMenu))
        chat.keyEquivalent = "\t" // shown as ⌥⇧⇥; the global shortcut itself lives in Hotkeys
        chat.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(chat)
        menu.addItem(action(sidebarIsOpen() ? "Fold Chat Sidebar" : "Unfold Chat Sidebar", #selector(toggleSidebarFromMenu)))
        let tasksItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let tasksMenu = NSMenu()
        let bar = action("Show Agents", #selector(agentBarFromMenu))
        bar.keyEquivalent = "a" // shown as ⌘⇧A; the global shortcut itself lives in Hotkeys
        bar.keyEquivalentModifierMask = [.command, .shift]
        tasksMenu.addItem(bar)
        tasksMenu.addItem(action("New Job…", #selector(taskBoxFromMenu)))
        tasksMenu.addItem(.separator())
        tasksMenu.addItem(action("Tidy Desktop", #selector(tidyDesktopFromMenu)))
        tasksMenu.addItem(action("Tidy Downloads", #selector(tidyDownloadsFromMenu)))
        tasksItem.submenu = tasksMenu
        menu.addItem(tasksItem)
        // Voice has no set-up: hold the keys and talk (English).
        let talk = NSMenuItem(title: "Voice: hold ⌘⇧V to talk", action: nil, keyEquivalent: "")
        talk.isEnabled = false
        menu.addItem(talk)
        let talkAgent = NSMenuItem(title: "Add A to talk to an agent", action: nil, keyEquivalent: "")
        talkAgent.isEnabled = false
        menu.addItem(talkAgent)
        let history = action("Chat History…", #selector(historyFromMenu))
        history.keyEquivalent = "l" // shown as ⌘⇧L; the global shortcut itself lives in Hotkeys
        history.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(history)
        menu.addItem(action("Notebook…", #selector(notebookFromMenu)))

        let snip = action("Snip & Ask…   (hold Tab, press \\)", #selector(snipFromMenu))
        snip.isEnabled = trusted && !settings.paused
        menu.addItem(snip)

        let videoItem = NSMenuItem(title: "Summarize Video", action: nil, keyEquivalent: "")
        let videoMenu = NSMenu()
        for choice in VideoMenuChoice.allCases {
            let mi = action(choice.title, #selector(summarizeVideo(_:)))
            mi.representedObject = choice.rawValue
            mi.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            videoMenu.addItem(mi)
        }
        videoItem.submenu = videoMenu
        menu.addItem(videoItem)
        menu.addItem(.separator())

        menu.addItem(action(settings.paused ? "Resume Margin" : "Pause Margin", #selector(togglePause)))

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for choice in ModelChoice.allCases {
            let mi = action(choice.title, #selector(pickModel(_:)))
            mi.representedObject = choice.rawValue
            mi.state = choice == settings.model ? .on : .off
            modelMenu.addItem(mi)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let web = action("Web Search", #selector(toggleWebSearch))
        web.state = settings.webSearch ? .on : .off
        menu.addItem(web)

        let local = action("Local Mode (Ollama)", #selector(toggleLocalMode))
        local.state = settings.localMode ? .on : .off
        menu.addItem(local)
        let localInfo = NSMenuItem(title: Self.localInfo(for: settings.localMode ? OllamaClient.shared.status : nil),
                                   action: nil, keyEquivalent: "")
        localInfo.isEnabled = false
        localInfo.indentationLevel = 1
        menu.addItem(localInfo)
        if settings.localMode {
            // Look again now; the line updates while the menu is open.
            OllamaClient.shared.refresh { [weak localInfo] status in localInfo?.title = Self.localInfo(for: status) }
        }

        let screenItem = NSMenuItem(title: "Screen Context", action: nil, keyEquivalent: "")
        let screenMenu = NSMenu()
        for mode in ScreenContext.allCases {
            let mi = action(mode.title, #selector(pickScreenContext(_:)))
            mi.representedObject = mode.rawValue
            mi.state = mode == settings.screenContext ? .on : .off
            screenMenu.addItem(mi)
        }
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)

        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Token Savings…", #selector(showSavings)))
        menu.addItem(action("How to Use Margin", #selector(showHelp)))
        menu.addItem(action("Quit Margin", #selector(quit), key: "q"))
    }

    /// The grey line under the Local Mode switch: what it does, or what's wrong with it.
    private static func localInfo(for status: OllamaClient.Status?) -> String {
        let model = Settings.shared.localModel
        switch status {
        case nil: return "Quick questions answered on this Mac"
        case .unknown?: return "Checking Ollama…"
        case .ready?: return "Ready · \(model)"
        case .notRunning?: return "Ollama isn't running: open the Ollama app"
        case .modelMissing?: return "Not installed: run `ollama pull \(model)`"
        }
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func togglePause() {
        settings.paused.toggle()
        refresh()
        onPauseChanged?(settings.paused)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = ModelChoice(rawValue: raw) else { return }
        settings.model = choice
    }

    @objc private func summarizeVideo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = VideoMenuChoice(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.onSummarizeVideo?(choice) }
    }

    @objc private func toggleSidebarFromMenu() { onToggleSidebar?() }
    @objc private func agentBarFromMenu() { DispatchQueue.main.async { [weak self] in self?.onAgentBar?() } }
    @objc private func taskBoxFromMenu() { DispatchQueue.main.async { [weak self] in self?.onTaskBox?() } }
    @objc private func tidyDesktopFromMenu() { quickTidy(.desktopDirectory) }
    @objc private func tidyDownloadsFromMenu() { quickTidy(.downloadsDirectory) }
    private func quickTidy(_ dir: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: dir, in: .userDomainMask).first else { return }
        DispatchQueue.main.async { [weak self] in self?.onQuickTask?(.tidy(url)) }
    }
    @objc private func historyFromMenu() { DispatchQueue.main.async { [weak self] in self?.onHistory?(false) } }
    @objc private func notebookFromMenu() { DispatchQueue.main.async { [weak self] in self?.onHistory?(true) } }

    @objc private func chatFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.onChat?() }
    }

    @objc private func snipFromMenu() {
        // Let the menu finish closing before the region picker takes over the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.onSnip?() }
    }

    @objc private func toggleWebSearch() {
        settings.webSearch.toggle()
    }

    @objc private func toggleLocalMode() {
        settings.localMode.toggle()
        if settings.localMode { OllamaClient.shared.refresh() }
    }

    @objc private func showSavings() {
        alert("Token savings", UsageLog.report(UsageLog.load()))
    }

    @objc private func pickScreenContext(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScreenContext(rawValue: raw) else { return }
        settings.screenContext = mode
        if mode != .off, !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
    }

    @objc private func openScreenRecordingSettings() {
        ScreenCapture.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showHelp() {
        alert("How to use Margin", """
        1. Highlight text in any app, by dragging or double-clicking.
        2. Click the small spark that appears next to your cursor.
        3. Ask what's confusing, or just press Return for a simpler explanation.

        Learning a language? Tap "Pronounce" (or ask "how do I say this?") and Claude answers with a \
        voice message you can play, slow down, or drag out as an audio file.

        Long passage? Tap "Summarize", then pick "Overall meaning" (the main point and what supports it) or \
        "Keywords & concepts" (the key terms, each explained in a line).

        Want to see it? Tap "Visualize" (or ask for a graph) and Claude draws an interactive graph or \
        diagram: drag its sliders to see what changes, hover to read values, and drag it out to keep it.

        Want to ask without highlighting anything? Press Option-Shift-Tab for a chat right at your \
        mouse (anything you've highlighted comes along). Press it again to put the chat away.

        Can't highlight it (a scanned PDF, an image, a diagram)? Hold Tab and press \\, then drag \
        a box around it. Press Space to pick a whole window, or Esc to cancel.

        Your chats rest in the black sidebar at the top-right of your screen, up to 4 at once. Each \
        row has a circle that glows purple while the chat works and green when the answer is ready. \
        Click a row to open that chat; click it again to put it back. Hover a row and click × to \
        delete it. Fold the sidebar with the button in its header (or from this menu) to leave just a \
        strip of dots.

        Drag the top of a chat to put it anywhere on your screen; it stays there. Clicking anywhere \
        else, pressing Esc, or the Minimize button puts the chat back in the sidebar, never deletes it. \
        Only the × on the chat or on its sidebar row deletes a chat.

        Talk to it: hold Cmd-Shift-V, say it, let go. It starts recording the instant you press. Ask a \
        question, say "add dinner to my calendar tomorrow 7 to 8" for a calendar card, or hold A as well \
        (Cmd-Shift-V then A) to give an agent a job like "organize my downloads".

        Agents (Cmd-Shift-A): a black bar at the top of your screen with a pixel cat for each background \
        agent (Tidy, Find, Study, Batch, or anything you say about your files, like "scatter these \
        screenshots around the desktop"). A sitting cat is waiting, a running cat is working, a loaf is done. \
        When an agent needs your OK, Allow and Deny are right on its cat, and a big job tells you its token \
        cost first. Minimized, the agents are a small strip on the right edge of your screen.

        Cmd-Shift-L opens your chat history. Type or say "summarize this video" in any chat to summarize the \
        YouTube video in your browser. With Local Mode on, summaries (including videos in English) are \
        written on your Mac; if one needs deeper analysis, press Control-Shift-L to move just that chat to \
        Claude (press it again to move it back). Other chats and new chats are not affected.

        Your chats are saved on this Mac, filed into sectors (Math, Language…) and named when you close them (never one you renamed yourself): see \
        "Chat History…" and "Notebook…" in this menu. Tap "Quiz me" to be quizzed on a chat, "Keep" to save an \
        answer to your notebook.

        Want to use fewer Claude tokens? Turn on Local Mode (needs the free Ollama app and its qwen3:8b model). \
        Quick questions and short summaries are then answered by a model on your Mac, with a note saying so and \
        an "Ask Claude" button if you want a better answer. Pronunciation, graphs, fact checks, snips and videos \
        always go to Claude. "Token Savings…" shows what this saved.

        Your highlighted text and screenshot are only sent to Claude after you click the ? and ask, and not at all \
        for a question your Mac answers itself.
        """)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

enum VideoMenuChoice: String, CaseIterable {
    case youtubeTab, listen, file

    var title: String {
        switch self {
        case .youtubeTab: return "YouTube Video in Current Tab"
        case .listen: return "Listen Along…"
        case .file: return "Video or Audio File…"
        }
    }

    var symbol: String {
        switch self {
        case .youtubeTab: return "play.rectangle"
        case .listen: return "waveform"
        case .file: return "film"
        }
    }
}
