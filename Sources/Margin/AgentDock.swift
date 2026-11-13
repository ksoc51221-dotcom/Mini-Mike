import AppKit

/// Tracks every agent (up to `Settings.maxAgents`): which ones are open, and the sidebar they rest in.
///
/// Chats stay where you put them. Any number can be open at once (each is its own window), clicking elsewhere doesn't tuck
/// them away, and nothing closes a chat but you: the × deletes it, the minimize button (or Esc) sends it to the sidebar.
/// (With "Chats stay open" off in the menu, it works the old way: one chat at a time, put away when you click off it.)
final class AgentDock {
    private final class Entry {
        let agent: AskPanelController
        init(_ agent: AskPanelController) { self.agent = agent }
        var id: ObjectIdentifier { ObjectIdentifier(agent) }
    }

    private var entries: [Entry] = []
    /// The chats on screen, least recently used first; the last one is the one you used most recently.
    private var openIDs: [ObjectIdentifier] = []
    private let sidebar = AgentSidebar()
    /// Chats hidden while a snip is being taken.
    private var hiddenForSnip: [AskPanelController] = []

    private var stayOpen: Bool { Settings.shared.chatsStayOpen }
    private var openAgents: [AskPanelController] { openIDs.compactMap { id in entries.first { $0.id == id }?.agent } }
    /// The chat you used last.
    private var front: AskPanelController? { openAgents.last }

    var count: Int { entries.count }
    /// Room for another chat (a chat that's open and still empty makes way for it).
    var hasRoom: Bool { entries.count - openAgents.filter(\.isEmptyChat).count < Settings.shared.maxAgents }
    var sidebarIsOpen: Bool { sidebar.isOpen }

    init() {
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onStar = { [weak self] id in self?.entries.first(where: { $0.id == id })?.agent.toggleStar() }
        sidebar.onDelete = { [weak self] id in
            self?.entries.first(where: { $0.id == id })?.agent.close()
        }
    }

    func toggleSidebar() { sidebar.toggle() }

    private func markOpen(_ agent: AskPanelController) {
        let id = ObjectIdentifier(agent)
        openIDs.removeAll { $0 == id }
        openIDs.append(id)
    }

    private func markClosed(_ agent: AskPanelController) {
        let id = ObjectIdentifier(agent)
        openIDs.removeAll { $0 == id }
    }

    /// Clears the way for a snip so the picture is of your screen, not of Margin: open chats hide for a moment (and come
    /// back in `finishSnip`). With chats set to the old way, the open one goes to the sidebar.
    func prepareForSnip() {
        if stayOpen {
            hiddenForSnip = openAgents
            hiddenForSnip.forEach { $0.setHiddenForCapture(true) }
        } else {
            front?.dismissGesture()
        }
    }

    /// The snip is over (taken or cancelled): the chats that hid for it come back.
    func finishSnip() {
        hiddenForSnip.forEach { $0.setHiddenForCapture(false) }
        hiddenForSnip = []
    }

    /// Opens an agent for a Tab+\ snip.
    func openSnip(jpeg: Data, mouse: NSPoint, app: NSRunningApplication?) {
        let selection = Selection(text: "", appName: app?.localizedName ?? "your screen",
                                  context: ContextBox(resolved: nil),
                                  pid: app?.processIdentifier ?? 0, mouse: mouse, regionImage: jpeg)
        open(selection, iconFrame: NSRect(x: mouse.x + 6, y: mouse.y - 32, width: 26, height: 26))
    }

    /// Option+Shift+Tab. With the mouse over an open chat: that chat takes the keyboard (or, if you're already typing in
    /// it, is put away). Anywhere else: a new chat opens at the mouse, next to the ones already open.
    func chatShortcut(newChat: () -> Selection?) {
        if stayOpen {
            let mouse = NSEvent.mouseLocation
            if let under = openAgents.last(where: { $0.frame.contains(mouse) }) {
                if under.isFocused { under.dismissGesture() } else { markOpen(under); syncSidebar(); under.focus() }
                return
            }
        } else if let current = front {
            if current.isFocused { current.dismissGesture() } else { current.focus() }
            return
        }
        guard let selection = newChat() else { return }
        let m = selection.mouse
        open(selection, iconFrame: NSRect(x: m.x + 6, y: m.y - 32, width: 26, height: 26))
    }

    /// ⌃⇧L: the chat you're using (only that one) moves between Claude and the model on this Mac, and a short note says so.
    func toggleEngineOfOpenChat() {
        guard let current = openAgents.last(where: \.isFocused) ?? front, !current.isEmptyChat else {
            Toast.show("Open a chat first. ⌃⇧L moves one chat between Claude and your Mac.", near: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1))
            return
        }
        let message = current.toggleEngine()
        let f = current.debugPanelFrame
        Toast.show(message, near: NSRect(x: f.midX, y: f.maxY, width: 1, height: 1))
    }

    /// Tap Shift twice: a screenshot of the screen goes into the open chat as context for the next question.
    func attachScreenshotToOpenChat() {
        guard let current = openAgents.last(where: \.isFocused) ?? front else {
            Toast.show("Open a chat first, then tap Shift twice to add a screenshot.", near: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1))
            return
        }
        current.attachScreenshot()
    }

    /// A video agent (YouTube, listen along, or a file), opening near `point`.
    func openVideo(_ source: VideoSource, near point: NSPoint) {
        let selection = Selection(text: "", appName: "Video", context: ContextBox(resolved: nil),
                                  pid: 0, mouse: point, video: source)
        open(selection, iconFrame: NSRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
    }

    /// A spoken question. It goes to the chat you're typing in as a follow-up; with nothing highlighted it goes to the chat
    /// you used last; otherwise (new text highlighted) a new chat opens about it and asks.
    func openChat(_ selection: Selection, asking question: String) {
        let target = stayOpen ? (openAgents.last(where: \.isFocused) ?? (selection.isBlank ? front : nil)) : front
        if let current = target, !current.isEmptyChat {
            markOpen(current)
            syncSidebar()
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

    /// A chat about a screenshot from the dashboard (the picture is sent with the first question).
    func openChat(aboutImage jpeg: Data, appName: String) {
        openSnip(jpeg: jpeg, mouse: NSEvent.mouseLocation, app: nil, appName: appName)
    }

    private func openSnip(jpeg: Data, mouse: NSPoint, app: NSRunningApplication?, appName: String) {
        let selection = Selection(text: "", appName: appName, context: ContextBox(resolved: nil),
                                  pid: app?.processIdentifier ?? 0, mouse: mouse, regionImage: jpeg)
        open(selection, iconFrame: NSRect(x: mouse.x + 6, y: mouse.y - 32, width: 26, height: 26))
    }

    func open(_ selection: Selection, iconFrame: NSRect) {
        // Full house: say so, and leave the chats you have open alone. (A chat that's open but still empty has nothing to
        // keep, so it makes way for the new one.)
        let limit = Settings.shared.maxAgents
        let empties = openAgents.filter(\.isEmptyChat)
        guard entries.count - empties.count < limit else {
            Toast.show(Self.fullMessage, near: iconFrame)
            return
        }
        empties.forEach { $0.close() }
        // Old way: only one chat is open at a time; the one on screen goes to the sidebar.
        if !stayOpen { front?.dismissGesture() }
        let agent = AskPanelController(selection: selection, iconFrame: iconFrame)
        wire(agent, iconFrame: iconFrame)
        agent.cascade = cascadeOffset(for: agent)
        entries.append(Entry(agent))
        markOpen(agent)
        syncSidebar()
        agent.show()
    }

    private func wire(_ agent: AskPanelController, iconFrame: NSRect) {
        agent.onMinimizeRequest = { [weak self, weak agent] in
            if let agent { self?.minimize(agent) }
        }
        agent.onUpdate = { [weak self] in self?.syncSidebar() }
        agent.onClosed = { [weak self, weak agent] in
            if let agent { self?.remove(agent) }
        }
        agent.onFocused = { [weak self, weak agent] in
            guard let self, let agent, self.openIDs.contains(ObjectIdentifier(agent)) else { return }
            self.markOpen(agent) // the chat you click or type in becomes the one you "used last"
        }
        agent.onOpenVideo = { [weak self, weak agent] source in
            agent?.close() // this chat becomes a video agent in the same spot
            self?.openVideo(source, near: NSPoint(x: iconFrame.midX, y: iconFrame.midY))
        }
    }

    /// How far to nudge a chat so it doesn't sit on another open chat's corner: down and to the right, a step at a time (like
    /// windows cascade). Near a screen edge, where that would pile them up, it tries the other diagonals.
    private func cascadeOffset(for agent: AskPanelController) -> NSPoint {
        let others = openAgents.filter { $0 !== agent }
        func taken(_ offset: NSPoint) -> Bool {
            let spot = agent.candidateTopLeft(cascade: offset)
            return others.contains { abs($0.frame.minX - spot.x) < 24 && abs($0.frame.maxY - spot.y) < 24 }
        }
        if !taken(.zero) { return .zero }
        let directions: [(CGFloat, CGFloat)] = [(1, -1), (-1, -1), (1, 1), (-1, 1)]
        for k in 1...10 {
            for (dx, dy) in directions {
                let offset = NSPoint(x: dx * Self.cascadeStep * CGFloat(k), y: dy * Self.cascadeStep * CGFloat(k))
                if !taken(offset) { return offset }
            }
        }
        return .zero
    }
    static let cascadeStep: CGFloat = 32

    static var fullMessage: String {
        "All \(Settings.shared.maxAgents) chats are in use. Hover one in the sidebar and click × to delete it."
    }

    // MARK: - Sidebar

    private func syncSidebar() {
        sidebar.sync(entries.map { entry in
            let agent = entry.agent
            let isOpen = openIDs.contains(entry.id)
            let subtitle: String
            switch agent.phase {
            case .idle: subtitle = isOpen ? "Open" : "Waiting for your question"
            case .working: subtitle = agent.activity ?? "Working on it…"
            case .done: subtitle = isOpen ? "Open" : "Done. Click to read"
            case .failed: subtitle = "Something went wrong"
            }
            // The status leads and, once Claude has filed the chat, its sector trails ("Done. Click to read · Math"),
            // so a narrow row clips the sector, never the status.
            let filed = agent.sector.map { " · \($0)" } ?? ""
            return AgentSidebar.Row(id: entry.id, title: agent.title, subtitle: subtitle + filed, phase: agent.phase, isOpen: isOpen,
                                     starred: agent.isStarred, canStar: Settings.shared.saveHistory)
        })
    }

    /// A click on a row: opens that chat, or puts it away if it's already open.
    private func select(_ id: ObjectIdentifier) {
        guard let agent = entries.first(where: { $0.id == id })?.agent else { return }
        if openIDs.contains(id) { minimize(agent) } else { expand(agent) }
    }

    // MARK: - Minimize / expand

    private func minimize(_ agent: AskPanelController) {
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        let id = entries[index].id
        markClosed(agent)
        syncSidebar()
        // The chat flies into its row's circle; the row lights up where it lands.
        agent.minimize(into: sidebar.discFrame(at: index)) { [weak self] in self?.sidebar.flash(id) }
    }

    private func expand(_ agent: AskPanelController) {
        if !stayOpen, let current = front, current !== agent { current.dismissGesture() }
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        let from = sidebar.discFrame(at: index)
        agent.cascade = cascadeOffset(for: agent)
        markOpen(agent)
        syncSidebar()
        agent.expand(from: from, beside: sidebar.frame)
    }

    private func remove(_ agent: AskPanelController) {
        guard let index = entries.firstIndex(where: { $0.agent === agent }) else { return }
        entries.remove(at: index)
        markClosed(agent)
        syncSidebar()
    }

    // MARK: - Debug hooks for --demo

    var debugAgents: [AskPanelController] { entries.map(\.agent) }
    /// The chats on screen now (not minimized), least recently used first.
    var debugOpenAgents: [AskPanelController] { openAgents }
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
        f.font = .margin(12)
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
