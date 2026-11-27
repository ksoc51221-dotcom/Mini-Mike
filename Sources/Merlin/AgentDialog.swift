import AppKit

// The one yes/no dialog of Merlin's agents (2026-11-27). The old dialogs were app-modal NSAlerts run inside
// `DispatchQueue.main.sync`. Two things went wrong at once (Merlin: "I can't even click run or close it"):
// 1. An alert sits at the modal-panel level (8); Merlin's dock window is at the status-bar level (25) and covers the
//    right half of the screen, so it lies over a centred alert's buttons. A click there hits the dock, which the modal
//    session blocks: only a beep. Every other Merlin window (the Agents window, the dock) was blocked the same way.
// 2. The alert ran inside a main-queue block, so no other main-queue work ran: the Agents window kept its old status
//    ("Looking in Contacts"), and the dock could not finish its work.
// Now: a normal panel above the dock (pop-up-menu level), never modal, so the rest of Merlin keeps working. The tool's
// own thread waits for the answer. Return and Esc say no, the close button says no, and after 60 s it says no by itself.

/// One question for the user: a plain sentence, the two buttons, and what is behind "Show details".
struct AgentQuestion: Equatable {
    /// One plain sentence: Send “hi” to baby on WhatsApp?
    var title: String
    /// A short text under the title (who, the text of a message, an event's time).
    var detail: String = ""
    /// A line in orange, for a recipient that is not in the user's words.
    var warning: String?
    /// Long text behind "Show details" (a script, a long email).
    var details: String?
    var yes: String
    var no: String
    /// The agent that asks; shown small above the title.
    var agent: String?

    /// "Agent “Price ceilings”: Add this event?" → the agent's name and the plain title.
    static func split(_ title: String) -> (agent: String?, title: String) {
        let head = "Agent “"
        guard title.hasPrefix(head), let end = title.range(of: "”: ") else { return (nil, title) }
        let name = String(title[title.index(title.startIndex, offsetBy: head.count)..<end.lowerBound])
        return (name, String(title[end.upperBound...]))
    }

    /// The title, the agent's name moved out of it.
    init(title: String, detail: String = "", warning: String? = nil, details: String? = nil, yes: String, no: String, agent: String? = nil) {
        let s = Self.split(title)
        self.title = s.title
        self.detail = detail
        self.warning = warning.flatMap { $0.isEmpty ? nil : $0 }
        self.details = details
        self.yes = yes
        self.no = no
        self.agent = agent ?? s.agent
    }
}

enum AgentDialog {
    static let timeout: TimeInterval = 60
    /// Above the dock (status-bar level) and its cards.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
    /// Tests: the panel stays off-screen and invisible, and never takes the keyboard.
    nonisolated(unsafe) static var hidden = false

    /// Send “hi” to baby on WhatsApp? (a long text: Send this message to baby on WhatsApp?)
    static func sendTitle(_ text: String, to: String, app: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = t.count <= 40 && !t.contains("\n") ? "“\(t)”" : "this message"
        return "Send \(what) to \(to) on \(app)?"
    }

    /// Any thread. Off the main thread it waits on that thread, so the main queue keeps running. On the main thread it
    /// handles events itself until the answer (never modal: the other windows still work).
    static func ask(_ q: AgentQuestion, timeout: TimeInterval = AgentDialog.timeout) -> Bool {
        if Thread.isMainThread {
            let c = AgentDialogController(q, timeout: timeout)
            c.show()
            while c.answer == nil {
                if let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
            }
            return c.answer ?? false
        }
        final class Box { var controller: AgentDialogController?; var yes = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let c = AgentDialogController(q, timeout: timeout) { yes in
                box.yes = yes
                done.signal()
            }
            box.controller = c
            c.show()
        }
        // The panel's own clock says no at the limit; this is only a guard if the main thread is stuck.
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            DispatchQueue.main.async { box.controller?.finish(false) }
            return false
        }
        return box.yes
    }
}

/// The panel: it can take the keyboard without making Merlin the active app; Esc is no.
final class AgentDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    /// Return and Enter say no, always (the yes button has no key, so no key can ever say yes).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, [36, 76].contains(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AgentDialogController: NSObject, NSWindowDelegate {
    let question: AgentQuestion
    let panel: AgentDialogPanel
    let yesButton: NSButton
    let noButton: NSButton
    let detailsButton: NSButton
    let countdown: NSTextField
    private let detailsView: NSScrollView
    private(set) var answer: Bool?
    private(set) var secondsLeft: Int
    private var timer: Timer?
    private let deadline: Date
    private let onAnswer: ((Bool) -> Void)?

    init(_ q: AgentQuestion, timeout: TimeInterval = AgentDialog.timeout, onAnswer: ((Bool) -> Void)? = nil) {
        question = q
        self.onAnswer = onAnswer
        deadline = Date(timeIntervalSinceNow: timeout)
        secondsLeft = Int(timeout.rounded(.up))
        panel = AgentDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                                 styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        yesButton = NSButton(title: q.yes, target: nil, action: nil)
        noButton = NSButton(title: q.no, target: nil, action: nil)
        detailsButton = NSButton(title: "Show details", target: nil, action: nil)
        countdown = NSTextField(labelWithString: "")
        detailsView = NSScrollView()
        super.init()
        build()
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isSelectable = false
        l.preferredMaxLayoutWidth = 372
        return l
    }

    private func build() {
        panel.title = question.agent.map { "Agent \($0)" } ?? "Merlin"
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = AgentDialog.level // after isFloatingPanel, which sets the floating level
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(false) }

        var rows: [NSView] = []
        if let agent = question.agent { rows.append(label("Agent \(agent) asks:", size: 11, color: .secondaryLabelColor)) }
        rows.append(label(question.title, size: 15, weight: .semibold))
        if let w = question.warning { rows.append(label("⚠︎ " + w, size: 12, weight: .medium, color: .systemOrange)) }
        if !question.detail.isEmpty {
            let d = label(question.detail, size: 13, color: .secondaryLabelColor)
            d.isSelectable = true
            rows.append(d)
        }
        if let details = question.details, !details.isEmpty {
            detailsButton.bezelStyle = .inline
            detailsButton.setButtonType(.pushOnPushOff)
            detailsButton.target = self
            detailsButton.action = #selector(toggleDetails)
            rows.append(detailsButton)
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 372, height: 170))
            text.string = details
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.autoresizingMask = [.width]
            text.textContainerInset = NSSize(width: 6, height: 6)
            detailsView.documentView = text
            detailsView.hasVerticalScroller = true
            detailsView.borderType = .lineBorder
            detailsView.translatesAutoresizingMaskIntoConstraints = false
            detailsView.widthAnchor.constraint(equalToConstant: 372).isActive = true
            detailsView.heightAnchor.constraint(equalToConstant: 170).isActive = true
            detailsView.isHidden = true
            rows.append(detailsView)
        }

        // "No" is the Return button; the yes button has no key, so a key pressed for another app can never say yes.
        noButton.keyEquivalent = "\r"
        noButton.bezelStyle = .push
        noButton.target = self
        noButton.action = #selector(sayNo)
        yesButton.keyEquivalent = ""
        yesButton.bezelStyle = .push
        yesButton.target = self
        yesButton.action = #selector(sayYes)
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countdown.textColor = .tertiaryLabelColor
        updateCountdown()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [countdown, spacer, yesButton, noButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 372).isActive = true
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    func show() {
        if AgentDialog.hidden {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            panel.orderFrontRegardless()
        } else {
            // Centred on the screen with the pointer, a little above the middle (where a dialog is looked for).
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                let s = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: (f.midX - s.width / 2).rounded(), y: (f.midY - s.height / 2 + f.height / 8).rounded()))
            }
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        secondsLeft = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        updateCountdown()
        if deadline.timeIntervalSinceNow <= 0 { finish(false) }
    }

    /// Tests: one tick of the clock now.
    func debugTick() { tick() }

    private func updateCountdown() {
        countdown.stringValue = "Says “\(question.no)” in \(secondsLeft) s"
    }

    @objc private func toggleDetails() {
        detailsView.isHidden.toggle()
        detailsButton.title = detailsView.isHidden ? "Show details" : "Hide details"
        let top = panel.frame.maxY
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    @objc private func sayYes() { finish(true) }
    @objc private func sayNo() { finish(false) }

    var detailsShown: Bool { !detailsView.isHidden }

    /// The one end: the answer once, the clock off, the panel gone.
    func finish(_ yes: Bool) {
        guard answer == nil else { return }
        answer = yes
        timer?.invalidate()
        timer = nil
        panel.delegate = nil
        panel.orderOut(nil)
        onAnswer?(yes)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}
