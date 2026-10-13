import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Understanding the request

/// Turns "tidy my desktop" or "find the PDF about elasticity" into a task. The words are read on this Mac by rules.
enum TaskRouter {
    private static func has(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func folder(in text: String) -> URL? {
        let fm = FileManager.default
        if has(#"\bdownloads?\b"#, in: text) { return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first }
        if has(#"\bdocuments?\b(?!\s+(?:about|on|with))"#, in: text) && has(#"\b(?:my|the)\s+documents\b|\bdocuments folder\b"#, in: text) {
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        if has(#"\bdesktop\b|\bscreenshots?\b"#, in: text) { return fm.urls(for: .desktopDirectory, in: .userDomainMask).first }
        return nil
    }

    /// A request that does something to files and folders: "scatter these screenshots", "put my PDFs in a Papers folder".
    /// Needs both something to do and something to do it to, so ordinary questions stay in the chat. `strict` (spoken
    /// commands) only counts the plainest file words, so "take a photo" or "remove the background from this image" don't.
    static func looksLikeFileJob(_ text: String, strict: Bool = false) -> Bool {
        let verb = #"\b(?:scatter|spread|shuffle|arrange|line up|lay out|rename|duplicate|trash|throw (?:away|out)|delete|remove|get rid of|archive|bundle|separate|split|collect|gather|stack|sort|group|tidy|organi[sz]e|move|copy|(?:make|create|add) (?:me )?(?:a |an |some )?(?:new )?folders?)\b|\b(?:put|drop|file|store)\b.*\b(?:in|into|to|onto|on|under|inside)\b|\b(?:take|pull)\b.*\b(?:out of|from|off)\b"#
        let plain = #"files?|folders?|screenshots?|screen shots?|pdfs?|icons?|downloads?|desktop|installers?|dmgs?|zips?"#
        let more = #"|images?|photos?|pictures?|pics|documents?|videos?|recordings?|archives?|spreadsheets?|slides|presentations?|invoices?|receipts?|items|stuff|everything"#
        let noun = "\\b(?:" + plain + (strict ? "" : more) + ")\\b"
        return has(verb, in: text) && has(noun, in: text)
    }

    /// Words that say *how*, which the plain Tidy agent can't follow: only a custom plan can.
    private static func hasSpecifics(_ text: String) -> Bool {
        has(#"\b(?:into|called|named|older|newer|bigger|larger|smaller|than|except|but|only|then|scatter|rename|move|put|copy|archive|group|by (?:type|kind|date|month|year|name|size))\b"#, in: text)
    }

    /// `strict` is for spoken commands, which must clearly be about files before they're taken away from a chat.
    static func parse(_ raw: String, files: [URL] = [], strict: Bool = false) -> TaskSpec? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return nil }
        let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }

        // Batch jobs
        if has(#"\bheic\b|\bheif\b"#, in: text) && has(#"\b(?:convert|change|turn|make|to)\b.*\b(?:jpg|jpeg)\b|\bjpe?g\b"#, in: text) { return .batch(.heicToJpg, files) }
        if has(#"\b(?:merge|combine|join)\b.*\bpdfs?\b"#, in: text) { return .batch(.mergePDFs, pdfs.isEmpty ? files : pdfs) }
        if has(#"\b(?:ocr|extract text|read the text|text from|transcribe)\b.*\b(?:image|images|screenshots?|scans?|pdfs?|photos?)\b|\bocr\b"#, in: text) { return .batch(.ocrToText, files) }

        // Anything with specifics ("scatter", "rename", "put X into Y") is a plan of its own, not the stock tidy.
        if files.isEmpty, looksLikeFileJob(text, strict: strict), hasSpecifics(text) { return .custom(text) }

        // Tidying
        if has(#"\b(?:tidy|clean ?up|clean out|clean|organi[sz]e|declutter|sort out|sort)\b"#, in: text) {
            if let dir = files.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { return .tidy(dir) }
            if let f = folder(in: text) { return .tidy(f) }
            if !strict, let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first { return .tidy(desktop) }
        }

        // Finding
        if has(#"\b(?:find|where(?:'s| is| are| did i)|locate|search (?:for|my)|look for)\b"#, in: text),
           !strict || has(#"\b(?:file|files|pdf|pdfs|document|documents|folder|screenshot|image|photo|spreadsheet|slides|presentation|download|downloads|desktop)\b"#, in: text) {
            return .find(text)
        }

        // Study notes
        let studyWords = has(#"\b(?:summari[sz]e|summary|study|flashcards?|practice questions|quiz|notes? (?:from|on|for|about)|key terms|revision)\b"#, in: text)
        if studyWords {
            let aboutAFile = !files.isEmpty || has(#"\b(?:textbook|book|chapter|chapters|pdf|paper|lecture|slides|handout|notes file|syllabus)\b"#, in: text)
            if aboutAFile || !strict { return .study(files.first, hint: text) }
        }
        if !files.isEmpty, pdfs.count == files.count, pdfs.count > 1 { return nil }
        if let only = files.first, files.count == 1, !strict { return .study(only, hint: text) }
        // Any other job on files: Claude plans it, and you approve the plan.
        if files.isEmpty, looksLikeFileJob(text, strict: strict) { return .custom(text) }
        return nil
    }

    static let help = "Try “tidy my desktop”, “scatter these screenshots around the desktop”, “find the PDF about elasticity”, "
        + "“summarize chapter 4 of my econ textbook”, or drop files here. Anything you can say about your files, I'll plan and show you first."
}

// MARK: - The new-job box (the + in the agent bar)

final class TaskBox {
    static let shared = TaskBox()

    private var panel: TaskBoxPanel?
    private let state = TaskBoxState()
    /// Open a chat instead (the box's last resort for things that aren't file tasks).
    var onNotATask: ((String) -> Void)?
    var onStarted: ((BackgroundTask) -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? hide() : show() }

    /// `below`: the agent bar's frame, to hang the box just under it.
    func show(prefill: String = "", message: String? = nil, below bar: NSRect? = nil) {
        if panel == nil { build() }
        guard let panel else { return }
        state.reset()
        state.text = prefill
        state.message = message
        let mouse = bar.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let bar {
            panel.setFrameOrigin(NSPoint(x: bar.midX - panel.frame.width / 2, y: bar.minY - 8 - panel.frame.height))
        } else {
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.maxY - panel.frame.height - vf.height * 0.2))
        }
        generation += 1
        let mine = generation
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            if self?.generation == mine { panel.alphaValue = 1 }
        })
        state.focus += 1
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.generation == mine else { return } // shown again meanwhile
            panel.orderOut(nil)
        })
    }

    /// Bumped by every show and hide, so an old fade-out can't put away a box that was just shown again.
    private var generation = 0

    private func build() {
        state.onSubmit = { [weak self] in self?.submit() }
        state.onCancel = { [weak self] in self?.hide() }
        state.onChoose = { [weak self] in self?.chooseFiles() }
        let p = TaskBoxPanel(size: NSSize(width: 580, height: 190), canKey: !AskPanelController.demoMode)
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = Theme.roundedMask(radius: 16)
        let host = NSHostingView(rootView: TaskBoxView(state: state))
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect
        host.frame = effect.bounds
        p.onResignKey = { [weak self] in self?.hide() }
        p.onEscape = { [weak self] in self?.hide() }
        panel = p
    }

    /// "Summarize this video" typed in the box goes to the video summarizer, not to an agent.
    var onVideo: ((VideoIntent) -> Void)?

    private func submit() {
        let text = state.text
        let files = state.files
        if files.isEmpty, let video = VideoIntent.parse(text) {
            hide()
            return onVideo?(video) ?? ()
        }
        guard let spec = TaskRouter.parse(text, files: files) else {
            state.message = text.isEmpty && files.isEmpty ? TaskRouter.help : "That doesn't sound like a job for your files. " + TaskRouter.help
            return
        }
        if case .tidy(let folder) = spec, FileSafety.root(containing: folder.appendingPathComponent("x")) == nil {
            state.message = "I only work in Desktop, Downloads and Documents. “\(folder.lastPathComponent)” is somewhere else."
            return
        }
        hide()
        if let task = TaskEngine.shared.start(spec) { onStarted?(task) }
    }

    private func chooseFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.message = "Choose files or a folder for the task"
        panel?.onResignKey = nil // the picker takes focus; don't close the box
        open.begin { [weak self] response in
            guard let self else { return }
            self.panel?.onResignKey = { [weak self] in self?.hide() }
            if response == .OK { self.state.files += open.urls }
            self.panel?.makeKeyAndOrderFront(nil)
            self.state.focus += 1
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class TaskBoxPanel: FloatingPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class TaskBoxState: ObservableObject {
    @Published var text = ""
    @Published var files: [URL] = []
    @Published var message: String?
    @Published var focus = 0
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChoose: (() -> Void)?

    func reset() {
        text = ""
        files = []
        message = nil
    }
}

private let accent = Color(nsColor: Theme.accent)

struct TaskBoxView: View {
    @ObservedObject var state: TaskBoxState
    @FocusState private var focused: Bool
    @State private var dropping = false

    private let chips: [(String, String, String)] = [
        ("Tidy Desktop", "sparkles", "tidy my desktop"),
        ("Tidy Downloads", "arrow.down.circle", "tidy my downloads"),
        ("Scatter screenshots", "square.grid.3x3.square", "take all my screenshots and scatter them around the desktop"),
        ("Study a file", "graduationcap", "summarize and make study notes from "),
        ("Find a file", "magnifyingglass", "find "),
        ("HEIC → JPG", "photo", "convert my HEIC photos to JPG"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack").font(.title3).foregroundStyle(accent)
                TextField("What should I do with your files?", text: $state.text)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { state.onSubmit?() }
                Button { state.onChoose?() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Choose files or a folder")
            }
            if !state.files.isEmpty {
                FlowChips(items: state.files.map(\.lastPathComponent)) { i in state.files.remove(at: i) }
            }
            HStack(spacing: 6) {
                ForEach(chips, id: \.0) { chip in
                    Button { chipTapped(chip) } label: { Label(chip.0, systemImage: chip.1).font(.caption.weight(.medium)) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.14)))
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
            }
            Text(state.message ?? "Drop files here, or press Return. Nothing changes until you approve the plan.")
                .font(.caption).foregroundStyle(state.message == nil ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 580, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(dropping ? accent : Color(nsColor: PanelGlow.color).opacity(0.5), lineWidth: dropping ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { state.files.append(url) } }
                }
            }
            return true
        }
        .onAppear { focused = true }
        .onChange(of: state.focus) { focused = true }
    }

    private func chipTapped(_ chip: (String, String, String)) {
        if chip.2.hasSuffix(" ") {
            state.text = chip.2
            focused = true
        } else {
            state.text = chip.2
            state.onSubmit?()
        }
    }
}

/// File names as little removable tags.
private struct FlowChips: View {
    let items: [String]
    let remove: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 4) {
                    Image(systemName: "doc").font(.caption2)
                    Text(name).font(.caption).lineLimit(1)
                    Button { remove(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
        }
    }
}

// MARK: - A task's card

/// The panel for one task: its plan to approve, its progress, or its report.
final class TaskCardController {
    private var panel: ChatPanel?
    private var host: NSHostingView<TaskCardView>?
    private(set) var task: BackgroundTask?
    private var monitor: Any?

    var isShowing: Bool { panel?.isVisible == true && !hiding }
    /// For --cardtest: on screen, fully opaque, and where.
    var debugState: (visible: Bool, alpha: CGFloat, frame: NSRect) { (panel?.isVisible == true, panel?.alphaValue ?? 0, panel?.frame ?? .zero) }

    /// The card as drawn now (for --taskdemo).
    var debugImage: CGImage? {
        guard let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    /// Where the card hangs: to the left of a rect (the old sidebar), or under one (a cat in the agent bar).
    enum Anchor: Equatable { case beside(NSRect), below(NSRect) }

    /// Called when the card goes away (so the bar can un-highlight its cat).
    var onHide: (() -> Void)?

    func show(_ task: BackgroundTask, beside sidebar: NSRect) { show(task, anchor: .beside(sidebar)) }

    func show(_ task: BackgroundTask, anchor: Anchor) {
        self.task = task
        if panel == nil { build() }
        guard let panel, let host else { return }
        hiding = false
        generation += 1
        let mine = generation
        host.rootView = TaskCardView(task: task, onClose: { [weak self] in self?.hide() }, onResize: { [weak self] h in self?.resize(h) })
        self.anchor = anchor
        place(height: min(max(contentHeight, 200), 600), anchor: anchor)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        // Also brings it back if it was still fading out from a moment ago. Whatever fades came before, the last
        // request wins: when this one ends the card is fully visible.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, self.generation == mine, !self.hiding else { return }
            panel.alphaValue = 1
        })
        // Belt and braces: even if the fade above was swallowed, a card that's meant to be showing is visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == mine, !self.hiding, panel.isVisible else { return }
            if panel.alphaValue < 1 { panel.alphaValue = 1 }
        }
        monitor.map(NSEvent.removeMonitor)
        // Clicking in another app puts the card away (the row stays in the sidebar).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
    }

    private var anchor: Anchor?
    /// For --agentbartest: the height the content asked for.
    var debugContentHeight: CGFloat { contentHeight }
    /// How tall the card's content says it is (reported by the view itself).
    private var contentHeight: CGFloat = 260

    func hide() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        guard let panel, panel.isVisible else { return }
        hiding = true
        generation += 1
        let mine = generation
        onHide?()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A show() during the fade wins: don't put away a card that was just asked for.
            guard let self, self.generation == mine, self.hiding else { return }
            panel.orderOut(nil)
        })
    }

    private var hiding = false
    /// Bumped by every show and hide; a fade only finishes its job if no newer one has started.
    private var generation = 0

    private func build() {
        let p = ChatPanel(size: NSSize(width: 430, height: 200), canKey: !AskPanelController.demoMode)
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = Theme.roundedMask(radius: 14)
        let h = NSHostingView(rootView: TaskCardView(task: BackgroundTask(kind: .find, title: ""), onClose: {}, onResize: { _ in }))
        h.sizingOptions = []
        h.autoresizingMask = [.width, .height]
        effect.addSubview(h)
        p.contentView = effect
        h.frame = effect.bounds
        panel = p
        host = h
    }

    private func resize(_ h: CGFloat) {
        guard h > 1 else { return }
        contentHeight = h
        guard let panel, panel.isVisible, let anchor else { return }
        place(height: min(max(h, 100), 600), anchor: anchor, animated: true)
    }

    private func place(height: CGFloat, anchor: Anchor, animated: Bool = false) {
        guard let panel else { return }
        let r: NSRect
        switch anchor { case .beside(let a), .below(let a): r = a }
        let vf = (NSScreen.screens.first { NSMouseInRect(NSPoint(x: r.midX, y: r.midY), $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 430
        let target: NSRect
        switch anchor {
        case .beside(let sidebar):
            target = NSRect(x: max(vf.minX + 8, sidebar.minX - 12 - width), y: max(vf.minY + 8, sidebar.maxY - height),
                            width: width, height: height)
        case .below(let cat):
            let x = min(max(vf.minX + 8, cat.midX - width / 2), vf.maxX - width - 8)
            // Never taller than the room under the bar (so it can't slide up over it).
            let h = min(height, cat.minY - 8 - (vf.minY + 8))
            target = NSRect(x: x, y: cat.minY - 8 - h, width: width, height: h)
        }
        if animated && panel.isVisible {
            WindowMotion.animate(panel, to: target)
        } else {
            panel.setFrame(target, display: true)
        }
    }
}

/// The go-ahead button: always filled orange, even though the card's window isn't the focused one
/// (macOS would grey out the standard prominent style there).
struct AllowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Color(nsColor: Theme.accent).opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)))
            .contentShape(Capsule())
    }
}

/// The other half of the pair: Deny, in a quiet dark capsule.
struct DenyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.16)))
            .contentShape(Capsule())
    }
}

struct TaskCardView: View {
    @ObservedObject var task: BackgroundTask
    let onClose: () -> Void
    let onResize: (CGFloat) -> Void
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch task.state {
            case .working: working
            case .needsApproval: approval
            case .done: done
            case .failed(let message): Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .cancelled: Text(task.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 430, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // The card's window follows the content's height. (A preference here only ever reported the first,
        // empty layout, so the card stayed at its starting size and long plans were cut off.)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onResize(g.size.height) }
                .onChange(of: g.size.height) { _, h in onResize(h) }
        })
        // minHeight 0: if the content is ever taller than the window, it's the bottom that's cut, never the top
        // (where the Allow button is). Without it SwiftUI centres the overflow.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: PanelGlow.color).opacity(0.45), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: task.kind.symbol).foregroundStyle(accent)
            Text(task.title).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (the task keeps going; it stays in the sidebar)")
        }
    }

    // MARK: Working

    private var working: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let f = task.fraction { ProgressView(value: f).tint(accent) } else { ProgressView().controlSize(.small) }
            Text(task.detail).font(.caption).foregroundStyle(.secondary)
            Button("Stop") { task.cancelRequested = true; task.onCancel?() }.controlSize(.small)
        }
    }

    // MARK: Approval

    private var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let gate = task.gate { gateView(gate) }
            if let plan = task.plan { planView(plan) }
            if let chooser = task.chooser { chooserView(chooser) }
        }
    }

    /// "This is a bigger job, about 14k tokens. Go ahead?": the cost is said before any is spent.
    private func gateView(_ gate: TaskGate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(gate.headline, systemImage: "gauge.with.dots.needle.67percent").font(.headline).foregroundStyle(.orange)
            Text(gate.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { TaskEngine.shared.approve(task) } label: { Label("Go ahead", systemImage: "checkmark") }
                    .buttonStyle(AllowButtonStyle())
                Button { TaskEngine.shared.deny(task) } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(DenyButtonStyle())
                Spacer(minLength: 0)
                Text(gate.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func planView(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(plan.headline).font(.headline)
            // The buttons come first, so they're on screen however long the plan is.
            HStack(spacing: 8) {
                Button { TaskEngine.shared.approve(task); onClose() } label: { Label("Allow", systemImage: "checkmark") }
                    .buttonStyle(AllowButtonStyle())
                    .disabled(!plan.canApprove)
                Button { TaskEngine.shared.deny(task) } label: { Label("Deny", systemImage: "xmark") }
                    .buttonStyle(DenyButtonStyle())
                Spacer(minLength: 0)
                Text(plan.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Nothing has changed yet. Untick anything you don't want, then press Allow.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plan.groups.enumerated()), id: \.element.id) { i, group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: Binding(get: { task.plan?.groups[i].enabled ?? false }, set: { task.plan?.groups[i].enabled = $0 }))
                                    .labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 1) {
                                    Label(group.title, systemImage: group.removes ? "trash" : group.symbol)
                                        .font(.callout.weight(.medium)).foregroundStyle(group.removes ? .orange : .primary)
                                    if !group.subtitle.isEmpty { Text(group.subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                if !group.files.isEmpty {
                                    Button(expanded.contains(group.id) ? "Hide" : "Show files") {
                                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                                    }.buttonStyle(.link).font(.caption)
                                }
                            }
                            if expanded.contains(group.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(group.files.prefix(40).enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    if group.files.count > 40 { Text("…and \(group.files.count - 40) more").font(.caption2).foregroundStyle(.tertiary) }
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            ForEach(Array(plan.options.enumerated()), id: \.element.id) { i, option in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(option.title, isOn: Binding(get: { task.plan?.options[i].on ?? false }, set: { task.plan?.options[i].on = $0 }))
                        .toggleStyle(.checkbox).font(.callout.weight(.medium))
                    Text(option.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }
            }
            if !plan.notes.isEmpty {
                Text(plan.notes.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(3)
            }
        }
    }

    private func chooserView(_ chooser: TaskChooser) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(chooser.heading).font(.headline)
            HStack(spacing: 8) {
                Button { TaskEngine.shared.approve(task); onClose() } label: { Label("Allow", systemImage: "checkmark") }
                    .buttonStyle(AllowButtonStyle())
                    .disabled(!(task.chooser?.items.contains { $0.on } ?? false) || !(task.chooser?.options.contains { $0.on } ?? false))
                Button { TaskEngine.shared.deny(task) } label: { Label("Deny", systemImage: "xmark") }
                    .buttonStyle(DenyButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(chooser.items.enumerated()), id: \.element.id) { i, item in
                        Toggle(isOn: Binding(get: { task.chooser?.items[i].on ?? false }, set: { task.chooser?.items[i].on = $0 })) {
                            HStack { Text(item.title).lineLimit(1); Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 190)
            Text(chooser.optionsHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Array(chooser.options.enumerated()), id: \.element.id) { i, option in
                    Toggle(option.title, isOn: Binding(get: { task.chooser?.options[i].on ?? false }, set: { task.chooser?.options[i].on = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            }
            if let estimate = chooser.estimate {
                let picked = Set(task.chooser?.items.filter(\.on).map(\.id) ?? []), outs = Set(task.chooser?.options.filter(\.on).map(\.id) ?? [])
                Text(estimate(picked, outs)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = task.report {
                Text(r.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !r.lines.isEmpty && r.links.isEmpty || task.kind != .find {
                    ForEach(Array(r.lines.prefix(8).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(r.links) { link in
                            HStack(spacing: 8) {
                                Image(systemName: link.url.hasDirectoryPath ? "folder" : "doc").foregroundStyle(accent)
                                Text(link.title).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([link.url]) }.buttonStyle(.link).font(.caption)
                                Button("Open") { NSWorkspace.shared.open(link.url) }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack(spacing: 8) {
                if task.canUndo {
                    Button { task.onUndo?(task) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help("Puts everything back where it was")
                }
                Button("Done") { TaskEngine.shared.dismiss(task); onClose() }
            }
        }
    }
}

