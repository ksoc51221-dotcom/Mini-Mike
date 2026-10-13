import AppKit

/// Tracks every agent (up to `Settings.maxAgents`): which one is open, and the sidebar they rest in.
final class AgentDock {
    private final class Entry {
        let agent: AskPanelController
        init(_ agent: AskPanelController) { self.agent = agent }
        var id: ObjectIdentifier { ObjectIdentifier(agent) }
    }

    private var entries: [Entry] = []
    private weak var expanded: AskPanelController?
    private let sidebar = AgentSidebar()

    var count: Int { entries.count }
    var hasRoom: Bool { entries.count < Settings.shared.maxAgents }
    var sidebarIsOpen: Bool { sidebar.isOpen }

    // Background agents live in their own window at the top of the screen (AgentBar), not in this sidebar.
    init() {
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onDelete = { [weak self] id in
            self?.entries.first(where: { $0.id == id })?.agent.close()
        }
    }

    func toggleSidebar() { sidebar.toggle() }

    /// Clears the stage before a snip: the open chat goes to the sidebar.
    func prepareForSnip() {
        expanded?.dismissGesture()
    }

    /// Opens an agent for a Tab+\ snip.
    func openSnip(jpeg: Data, mouse: NSPoint, app: NSRunningApplication?) {
        let selection = Selection(text: "", appName: app?.localizedName ?? "your screen",
                                  context: ContextBox(resolved: nil),
                                  pid: app?.processIdentifier ?? 0, mouse: mouse, regionImage: jpeg)
        open(selection, iconFrame: NSRect(x: mouse.x + 6, y: mouse.y - 32, width: 26, height: 26))
    }

    /// Option+Shift+Tab. If you're typing in the open chat, it's put away (into the sidebar);
    /// if a chat is open but you're elsewhere, it takes the keyboard; otherwise a new chat opens at the mouse.
    func chatShortcut(newChat: () -> Selection?) {
        if let current = expanded {
            if current.isFocused { current.dismissGesture() } else { current.focus() }
            return
        }
        guard let selection = newChat() else { return }
        let m = selection.mouse
        open(selection, iconFrame: NSRect(x: m.x + 6, y: m.y - 32, width: 26, height: 26))
    }

    /// ⌃⇧L: the open chat (only that one) moves between Claude and the model on this Mac, and a short note says so.
    func toggleEngineOfOpenChat() {
        guard let current = expanded, !current.isEmptyChat else {
            Toast.show("Open a chat first. ⌃⇧L moves one chat between Claude and your Mac.", near: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1))
            return
        }
        let message = current.toggleEngine()
        let f = current.debugPanelFrame
        Toast.show(message, near: NSRect(x: f.midX, y: f.maxY, width: 1, height: 1))
    }

    /// A video agent (YouTube, listen along, or a file), opening near `point`.
    func openVideo(_ source: VideoSource, near point: NSPoint) {
        let selection = Selection(text: "", appName: "Video", context: ContextBox(resolved: nil),
                                  pid: 0, mouse: point, video: source)
        open(selection, iconFrame: NSRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
    }

    /// A spoken question: a chat that's open takes it as a follow-up; otherwise a new chat opens (with whatever is
    /// highlighted) and asks it.
    func openChat(_ selection: Selection, asking question: String) {
        if let current = expanded, !current.isEmptyChat {
            current.ask(question, display: question)
            return
        }
        let m = selection.mouse
        open(selection, iconFrame: NSRect(x: m.x + 6, y: m.y - 32, width: 26, height: 26))
        debugAgents.last?.ask(question, display: question)
    }

    /// A chat about some saved text that starts by asking `prompt` (the History window's "Quiz me on this").
    func openChat(about text: String, asking prompt: String) {
        let m = NSEvent.mouseLocation
        let selection = Selection(text: text, appName: "Margin", context: ContextBox(resolved: nil), pid: 0, mouse: m)
        open(selection, iconFrame: NSRect(x: m.x, y: m.y - 26, width: 26, height: 26))
        debugAgents.last?.ask(prompt, display: prompt == Prompts.quiz ? Prompts.quizLabel : prompt)
    }

    func open(_ selection: Selection, iconFrame: NSRect) {
        // Full house: say so, and leave the chat you have open alone (unless it's empty and about to go away).
        let limit = Settings.shared.maxAgents
        guard entries.count < limit || expanded?.isEmptyChat == true else {
            Toast.show(Self.fullMessage, near: iconFrame)
            return
        }
        // Only one chat is open at a time; the one on screen goes to the sidebar (an empty one just goes away).
        expanded?.dismissGesture()
        let agent = AskPanelController(selection: selection, iconFrame: iconFrame)
        agent.onMinimizeRequest = { [weak self, weak agent] in
            if let agent { self?.minimize(agent) }
        }
        agent.onUpdate = { [weak self] in self?.syncSidebar() }
        agent.onClosed = { [weak self, weak agent] in
            if let agent { self?.remove(agent) }
        }
        agent.onOpenVideo = { [weak self, weak agent] source in
            agent?.close() // this chat becomes a video agent in the same spot
            self?.openVideo(source, near: NSPoint(x: iconFrame.midX, y: iconFrame.midY))
        }
        entries.append(Entry(agent))
        expanded = agent
        syncSidebar()
        agent.show()
    }

    static var fullMessage: String {
        "All \(Settings.shared.maxAgents) chats are in use. Hover one in the sidebar and click × to delete it."
    }

    // MARK: - Sidebar

    private func syncSidebar() {
        sidebar.sync(entries.map { entry in
            let agent = entry.agent
            let isOpen = agent === expanded
            let subtitle: String
            switch agent.phase {
            case .idle: subtitle = isOpen ? "Open" : "Waiting for your question"
            case .working: subtitle = agent.activity ?? "Working on it…"
            case .done: subtitle = isOpen ? "Open" : "Done. Click to read"
            case .failed: subtitle = "Something went wrong"
            }
            // Once Claude has filed the chat, its sector leads the status line ("Math · Done. Click to read").
            let filed = agent.sector.map { "\($0) · " } ?? ""
            return AgentSidebar.Row(id: entry.id, title: agent.title, subtitle: filed + subtitle, phase: agent.phase, isOpen: isOpen)
        })
    }

    /// A click on a row: opens that chat, or puts it away if it's the one already open.
    private func select(_ id: ObjectIdentifier) {
        guard let agent = entries.first(where: { $0.id == id })?.agent else { return }
        if expanded === agent { minimize(agent) } else { expand(agent) }
    }

    // MARK: - Minimize / expand

    private func minimize(_ agent: AskPanelController) {
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        let id = entries[index].id
        if expanded === agent { expanded = nil }
        syncSidebar()
        // The chat flies into its row's circle; the row lights up where it lands.
        agent.minimize(into: sidebar.discFrame(at: index)) { [weak self] in self?.sidebar.flash(id) }
    }

    private func expand(_ agent: AskPanelController) {
        if let current = expanded, current !== agent { current.dismissGesture() }
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        let from = sidebar.discFrame(at: index)
        expanded = agent
        syncSidebar()
        agent.expand(from: from, beside: sidebar.frame)
    }

    private func remove(_ agent: AskPanelController) {
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        entries.remove(at: index)
        if expanded === agent { expanded = nil }
        syncSidebar()
    }

    // MARK: - Debug hooks for --demo

    var debugAgents: [AskPanelController] { entries.map(\.agent) }
    func debugMinimize(_ agent: AskPanelController) { minimize(agent) }
    func debugExpand(_ agent: AskPanelController) { expand(agent) }
    var debugSidebar: AgentSidebar { sidebar }
}

/// A short message near the cursor that fades on its own.
enum Toast {
    private static var panel: FloatingPanel?
    private static var field: NSTextField?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, near rect: NSRect) {
        let (panel, field) = make()
        field.stringValue = text
        let width: CGFloat = 280
        field.preferredMaxLayoutWidth = width - 24
        let height = field.intrinsicContentSize.height + 18
        let vf = (NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
            ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(rect.minX - 12, vf.minX + 8), vf.maxX - width - 8)
        let y = max(rect.minY - 6 - height, vf.minY + 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private static func make() -> (FloatingPanel, NSTextField) {
        if let panel, let field { return (panel, field) }
        let p = FloatingPanel(size: NSSize(width: 280, height: 50), canKey: false)
        p.ignoresMouseEvents = true
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedMask(radius: 10)
        let f = NSTextField(wrappingLabelWithString: "")
        f.font = .systemFont(ofSize: 12)
        f.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            f.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            f.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        p.contentView = effect
        panel = p
        field = f
        return (p, f)
    }
}
