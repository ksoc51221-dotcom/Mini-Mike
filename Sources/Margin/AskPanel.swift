import AppKit
import SwiftUI

enum AgentPhase {
    case idle      // no question asked yet
    case working   // searching / writing
    case done
    case failed
}

/// The chat window. Pressing on its top edge (not on a header button) drags the whole window, and Margin
/// is told where it ended up. Done here, not in SwiftUI, because SwiftUI keeps the mouse for itself.
final class ChatPanel: FloatingPanel {
    var onMoved: (() -> Void)?
    private var dragging = false
    private var mouseStart = NSPoint.zero
    private var originStart = NSPoint.zero

    /// The padding strip along the top, and the header up to where its buttons begin.
    func startsDrag(at p: NSPoint) -> Bool {
        let fromTop = frame.height - p.y
        return fromTop < 14 || (fromTop < 40 && p.x < frame.width - 92)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where startsDrag(at: event.locationInWindow):
            dragging = true
            mouseStart = convertPoint(toScreen: event.locationInWindow)
            originStart = frame.origin
            if !AskPanelController.demoMode, !isKeyWindow { makeKey() } // clicking the chat still gives it the keyboard
        case .leftMouseDragged where dragging:
            let now = convertPoint(toScreen: event.locationInWindow)
            setFrameOrigin(NSPoint(x: originStart.x + now.x - mouseStart.x, y: originStart.y + now.y - mouseStart.y))
            onMoved?()
        case .leftMouseUp where dragging:
            dragging = false
        default:
            super.sendEvent(event)
        }
    }
}

/// Owns one agent: its popup window, its Claude session, its screenshot and its decay timer.
/// The AgentDock decides where it goes when minimized.
final class AskPanelController {
    enum Anchor {
        case selection(NSRect) // the ? icon's frame (or the snip's end point)
        case dock(NSRect)      // the sidebar's frame; the chat opens to its left
    }

    /// Normal width; the "make bigger" toggle multiplies it (see AskModel.width).
    static let width: CGFloat = 380
    static let cornerRadius: CGFloat = 14
    /// `--demo` runs without taking keyboard focus from whatever the user is doing.
    static var demoMode = false

    /// Seconds of idleness before the popup starts fading, and when it goes back to the sidebar.
    private static let fadeStart: TimeInterval = 16
    private static let minimizeAfter: TimeInterval = 20
    /// Don't hold the first question back forever waiting on a screenshot.
    private static let screenshotTimeout: TimeInterval = 3

    /// Called once, as soon as closing begins.
    var onClosed: (() -> Void)?
    /// The user (or a click-away) wants this put back in the sidebar.
    var onMinimizeRequest: (() -> Void)?
    /// Phase or activity changed (drives the sidebar row).
    var onUpdate: (() -> Void)?
    /// "Summarize video" was tapped: the dock swaps this chat for a video agent.
    var onOpenVideo: ((VideoSource) -> Void)?

    private(set) var phase: AgentPhase = .idle {
        didSet { if phase != oldValue { onUpdate?() } }
    }
    private(set) var isMinimized = false
    var activity: String? { model.status }
    /// The chat's sector once Claude (or a quick guess on this Mac) has filed it.
    var sector: String? { model.sector }
    var title: String {
        // A name you gave it in History wins.
        if let saved = Library.shared.chat(recordID), saved.titleLocked { return saved.title }
        return model.autoTitle
            ?? model.turns.first?.question
            ?? (!selection.text.isEmpty ? selection.text
                : selection.regionImage != nil ? "Snip from \(selection.appName)" : "Chat from \(selection.appName)")
    }

    private let panel: ChatPanel
    /// The light-orange glow around the chat (its own window, which follows this one).
    private let glow: PanelGlow
    private let hosting: NSHostingView<AskView>
    private let model: AskModel
    /// Whatever is answering this chat. It's created at the first question (Claude, or the model on this Mac
    /// in Local mode), so a chat that is never asked anything starts nothing.
    private var session: AnswerSession?
    private let choice: ModelChoice
    private let webSearch: Bool
    /// Who answers this chat, and with what (decided at the first question).
    private var plan: Router.Plan?
    private var localModelName = ""
    /// The prompt behind the newest question (the chat shows a label, e.g. "Summarize: overall meaning").
    private var lastPrompt = ""
    /// This video chat's answers come from the model on this Mac (it reads the transcript in parts), and the task doing so.
    private var videoLocal = false
    private var videoTask: Task<Void, Never>?
    private var videoIndex: DocIndex?
    private var videoCompacted = false
    /// What the newest local answer saved Claude (taken back if it's asked of Claude after all).
    private var lastLocalSaving = 0
    private let selection: Selection
    private let context: String?
    private let screenMode: ScreenContext
    private var anchor: Anchor
    /// Where you dragged the chat to (its top-left corner). Once set, the chat stays there: it opens
    /// there, grows from there, and doesn't fade away by itself.
    private var placedTopLeft: NSPoint?
    private var contentHeight: CGFloat = 140
    private var monitors: [Any] = []
    private var tick: Timer?
    private var lastActivity = Date()
    private var sentFirst = false
    private var closed = false

    /// Waiting for SwiftUI's first measurement, so the popup appears at its real size.
    private var awaitingFirstLayout = false
    /// A minimize/expand flight is running; the real window stays hidden meanwhile.
    private var inFlight = false
    private var fading = false

    private var screenshot: Data?
    private var screenshotReady = false
    /// Work that needs the screenshot (the first question to Claude), waiting for it to arrive or time out.
    private var afterScreenshot: (() -> Void)?

    /// No word from the answerer for this long while a question is out: give up instead of waiting forever.
    private static let stallTimeout: TimeInterval = 180
    private var watchdog: Timer?
    private var lastEvent = Date()

    // Video agents
    private var videoSource: VideoSource?
    private var videoTranscript: VideoTranscript?
    private var transcription: Transcription?
    private var listenTimer: Timer?
    private var listenStarted = Date()
    /// Listening stops by itself after this long.
    private static let maxListen: TimeInterval = 3 * 3600

    init(selection: Selection, iconFrame: NSRect) {
        let settings = Settings.shared
        let choice = settings.model
        let web = settings.webSearch
        self.choice = choice
        self.webSearch = web
        self.selection = selection
        self.context = selection.context.get(waitingUpTo: 0.4)
        self.anchor = .selection(iconFrame)
        // Video agents work from the transcript, not a screenshot.
        self.screenMode = ScreenCapture.hasPermission && selection.video == nil ? settings.screenContext : .off

        let localFirst = OllamaClient.shared.status.isUsable
            && Router.mayGoLocal(selection: selection.text, hasSnip: selection.regionImage != nil,
                                 isVideo: selection.video != nil, localMode: settings.localMode)
        let askModel = AskModel(selection: selection,
                                footnote: Self.footnote(choice: choice, web: web, screen: screenMode, plan: nil,
                                                        localModel: settings.localModel, localFirst: localFirst))
        askModel.seesScreen = screenMode != .off
        if selection.video != nil {
            askModel.isLarge = true // summaries are long; this doesn't change the saved preference
        } else {
            askModel.videoHint = YouTube.videoID(in: selection.text) != nil || BrowserTab.isBrowser(selection.bundleID)
        }
        model = askModel
        panel = ChatPanel(size: NSSize(width: askModel.width, height: 140), canKey: !Self.demoMode) // test windows can never take your typing

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = Theme.roundedMask(radius: Self.cornerRadius)
        hosting = NSHostingView(rootView: AskView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        hosting.frame = effect.bounds
        glow = PanelGlow(around: panel, cornerRadius: Self.cornerRadius)
        panel.hasShadow = false // the orange glow does the lifting; a dark shadow would muddy it
        panel.ignoresMouseEvents = Self.demoMode // test windows never take your clicks or typing
    }

    func show() {
        model.onHeight = { [weak self] h in self?.resize(toContentHeight: h) }
        model.onClose = { [weak self] in self?.close() }
        model.onMinimize = { [weak self] in self?.onMinimizeRequest?() }
        model.onMeta = { [weak self] in self?.onUpdate?() } // the sidebar row takes the new name
        model.onTurnComplete = { [weak self] in self?.turnCompleted() }
        model.onKeep = { [weak self] id in self?.keep(turn: id) }
        model.onUseDocument = { [weak self] in self?.useDocument() }
        model.onDropDocument = { [weak self] in self?.dropDocument() }
        model.onQuizFinished = { [weak self] result in self?.quizFinished(result) }
        panel.onMoved = { [weak self] in self?.userMoved() }
        model.onToggleSize = { [weak self] in self?.toggleSize() }
        // A pronunciation plays by itself only while you're looking at the chat.
        model.speech.canAutoPlay = { [weak self] in
            guard let self else { return false }
            return !self.isMinimized && !self.closed
        }
        model.onActivity = { [weak self] in self?.touch() }
        model.onAsk = { [weak self] prompt in self?.send(prompt) }
        model.onAskClaude = { [weak self] in self?.askClaudeInstead() }

        // The session itself starts at the first question (measured: starting it early made no difference to
        // how fast the first answer came). Only the "Claude isn't installed" error is shown right away.
        if ClaudeSession.claudePath == nil { model.fatal = ClaudeSession.StartError.cliNotFound.localizedDescription }
        warmUpLocalModel()
        captureScreen()
        lookForDocument()
        wireVideo()
        if let video = selection.video { startVideo(video) }

        // Put it on screen invisibly so SwiftUI measures itself, then appear at the right size.
        awaitingFirstLayout = true
        panel.setFrame(targetFrame(height: contentHeight), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.appear() }
    }

    private func appear() {
        guard awaitingFirstLayout, !closed else { return }
        awaitingFirstLayout = false
        panel.setFrame(targetFrame(height: contentHeight), display: true)
        if Self.demoMode { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Motion.easeOut
            panel.animator().alphaValue = 1
        }
        if let content = panel.contentView {
            Motion.popIn(content, from: 0.965, dy: growsDown ? 8 : -8, damping: 22, stiffness: 320)
        }
        glow.popped()
        installMonitors()
        startDecay()
    }

    /// Whether you're typing in this chat right now.
    var isFocused: Bool { panel.isKeyWindow && !isMinimized && !closed }

    /// Brings the open chat back under your keyboard (Option+Shift+Tab when you'd clicked elsewhere).
    func focus() {
        guard !closed, !isMinimized, !awaitingFirstLayout else { return }
        if !Self.demoMode { panel.makeKeyAndOrderFront(nil) }
        model.focusToken += 1
        touch()
    }

    /// Nothing in this chat worth coming back to: no question, no draft, nothing highlighted or snipped.
    var isEmptyChat: Bool {
        model.turns.isEmpty && model.draft.isEmpty && selection.isBlank && model.video == nil
    }

    /// Click-away / Esc / the shortcut: the chat goes back to the sidebar, still there to reopen.
    /// Only the × buttons delete a chat (a completely empty one has nothing to keep, so it just goes away).
    func dismissGesture() {
        if isEmptyChat { close() } else { onMinimizeRequest?() }
    }

    /// The chat was dragged: remember the spot.
    private func userMoved() {
        guard !closed, !isMinimized else { return }
        placedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        touch()
    }

    /// Flies a snapshot of the chat into its sidebar circle. `landed` runs when it arrives.
    func minimize(into disc: NSRect, landed: @escaping () -> Void) {
        guard !closed, !isMinimized else { return }
        isMinimized = true
        awaitingFirstLayout = false
        model.instantText = true
        model.speech.stopAll()
        stopDecay()
        removeMonitors()

        let from = panel.frame
        let image = panel.isVisible && panel.alphaValue > 0.05 ? snapshot() : nil
        panel.alphaValue = 0
        panel.orderOut(nil)
        guard let image else { return landed() }

        inFlight = true
        Ghost.fly(image, from: from, to: disc,
                  fromRadius: Self.cornerRadius, toRadius: disc.width / 2,
                  toOpacity: 0.25, duration: 0.42, timing: Motion.easeInOut) { [weak self] remove in
            self?.inFlight = false
            landed()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: remove)
        }
    }

    /// Grows the chat back out of its sidebar circle (to where you left it, or beside the sidebar).
    func expand(from disc: NSRect, beside sidebar: NSRect) {
        guard !closed else { return }
        isMinimized = false
        model.instantText = false
        anchor = .dock(sidebar)
        inFlight = true

        // Lay it out (invisibly) at its real size so the flying snapshot matches what lands.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let target = targetFrame(height: contentHeight)
        panel.setFrame(target, display: true)
        hosting.layoutSubtreeIfNeeded()

        let land = { [weak self] in
            guard let self, !self.closed, !self.isMinimized else { return }
            self.inFlight = false
            if !Self.demoMode { self.panel.makeKeyAndOrderFront(nil) }
            self.model.focusToken += 1
            self.glow.popped()
            self.installMonitors()
            self.startDecay()
            self.resize(toContentHeight: self.contentHeight)
        }
        guard let image = snapshot() else {
            panel.alphaValue = 1
            return land()
        }
        Ghost.fly(image, from: disc, to: target,
                  fromRadius: disc.width / 2, toRadius: Self.cornerRadius,
                  fromOpacity: 0.3, duration: 0.4, timing: Motion.easeOut) { [weak self] remove in
            guard let self else { return remove() }
            // Cross-fade from the snapshot to the live window.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                self.panel.animator().alphaValue = 1
            }
            land()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: remove)
        }
    }

    /// Closing a chat names it (see ChatNaming): one small call, only for chats that went on for a while, never for a chat
    /// you named or filed yourself.
    private func nameOnClose() {
        guard Settings.shared.saveHistory, Settings.shared.nameChatsOnClose else { return }
        let record = Library.shared.chat(recordID)
        guard ChatNaming.shouldRename(record, hadClaudeTitle: model.autoTitle != nil) else { return }
        ChatNaming.rename(recordID)
    }

    func close() {
        guard !closed else { return }
        closed = true
        videoTask?.cancel()
        nameOnClose()
        stopDecay()
        removeMonitors()
        session?.stop()
        stopWatchdog()
        model.stopAnimations()
        model.speech.cleanup()
        listenTimer?.invalidate()
        if let transcription { Task { await transcription.cancel() } }
        onClosed?()
        guard !isMinimized, panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        let panel = self.panel
        if let content = panel.contentView { Motion.shrinkOut(content, to: 0.97, duration: 0.16) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = Motion.easeIn
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            if let content = panel.contentView { Motion.reset(content) }
        })
    }

    // MARK: - Library (history and notebook)

    private let recordID = UUID()

    // MARK: - Whole page / PDF

    private var docURL: URL?
    private var docIndex: DocIndex?

    /// Is a readable document open behind this chat? (Asked in the background; offers the chip if so.)
    private func lookForDocument() {
        guard selection.video == nil, selection.pid > 0 else { return }
        let pid = selection.pid
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let url = PageReader.documentURL(pid: pid), PageReader.isReadable(url) else { return }
            DispatchQueue.main.async {
                guard let self, !self.closed, self.docURL == nil else { return }
                self.docURL = url
                if self.model.doc == .none { self.model.doc = .offered(PageReader.displayName(url)) }
            }
        }
    }

    private func useDocument() {
        guard let url = docURL else { return }
        let name = PageReader.displayName(url)
        model.doc = .loading(name)
        PageReader.read(url, pid: selection.pid) { [weak self] index in
            guard let self, !self.closed else { return }
            guard let index else {
                self.model.doc = .failed("Couldn't read \(name).")
                return
            }
            self.docIndex = index
            var detail = index.pageCount.map { "\($0) pages" } ?? index.kind
            if let note = index.note { detail += " · \(note)" }
            self.model.doc = .ready(name: index.title, detail: detail)
            self.model.footnote = "\(self.choice.title) · reading “\(index.title)” · sends only the parts that match · web search off"
        }
    }

    private func dropDocument() {
        docIndex = nil
        model.doc = docURL.map { .offered(PageReader.displayName($0)) } ?? .none
        model.footnote = Self.footnote(choice: choice, web: webSearch, screen: screenMode, plan: nil, localModel: Settings.shared.localModel, localFirst: false)
    }

    /// The passages to send with this question (nil if this chat isn't reading a document).
    private func documentPassages(for question: String) -> (passages: [Passage], overview: Bool)? {
        guard let docIndex else { return nil }
        if Prompts.isDocOverview(question) { return (docIndex.overview(), true) }
        let found = docIndex.relevant(to: question + " " + selection.text)
        return found.isEmpty ? (docIndex.overview(budget: 3600), true) : (found, false)
    }

    /// A turn is fully printed: file the chat if Claude didn't, then save it.
    private func turnCompleted() {
        if model.sector == nil {
            let said = model.turns.last.map { Answer.plainText($0.answer) } ?? ""
            model.sector = Sector.guess(from: [selection.text, model.turns.first?.question ?? "", said].joined(separator: " "))
                ?? Sector.other
            onUpdate?()
        }
        saveToLibrary()
    }

    private var libraryQuote: String {
        if !selection.text.isEmpty { return String(selection.text.prefix(600)) }
        if selection.regionImage != nil { return "Snip from \(selection.appName)" }
        if let video = model.video { return "Video: \(video.title)" }
        return ""
    }

    private func saveToLibrary() {
        guard Settings.shared.saveHistory else { return }
        // A calendar card isn't something to look up later.
        guard !model.turns.contains(where: { $0.answer.contains("<event>") }) else { return }
        let turns = model.turns.filter { $0.done && !$0.isError && !$0.answer.isEmpty }
            .map { ChatRecord.Turn(question: $0.question, answer: $0.answer) }
        guard !turns.isEmpty else { return }
        let library = Library.shared
        var record = library.chat(recordID)
            ?? ChatRecord(id: recordID, title: title, sector: model.sector ?? Sector.other,
                          app: selection.appName, quote: libraryQuote, turns: turns)
        if !record.titleLocked { record.title = String(title.prefix(80)) }
        // A sector you moved the chat to stays; otherwise it follows the chat.
        if library.chat(recordID) == nil { record.sector = model.sector ?? Sector.other }
        else if !record.sectorLocked, let named = model.sector { record.sector = named }
        record.turns = turns
        library.save(record)
    }

    /// "Keep" under an answer: it goes into the notebook (and its sector's Markdown file).
    private func keep(turn id: UUID) {
        guard let turn = model.turns.first(where: { $0.id == id }) else { return }
        let sector = Library.shared.chat(recordID)?.sector ?? model.sector ?? Sector.other
        let note = Note(title: String(title.prefix(80)), sector: sector, app: selection.appName, quote: libraryQuote,
                        question: turn.question, body: Answer.plainText(turn.answer), chatID: recordID)
        Library.shared.add(note)
        if Settings.shared.mirrorNotes { Notebook.export(note) }
        saveToLibrary() // a kept answer's chat is kept too
    }

    /// A quiz was finished: the score goes on the chat, and the questions you missed go in the notebook.
    private func quizFinished(_ result: QuizResult) {
        let library = Library.shared
        if var record = library.chat(recordID) {
            record.quizzes.append(result)
            library.save(record)
        }
        let sector = library.chat(recordID)?.sector ?? model.sector ?? Sector.other
        for m in result.missed where !library.notes.contains(where: { $0.chatID == recordID && $0.question == m.question }) {
            let note = Note(kind: .missed, title: String(title.prefix(80)), sector: sector, app: selection.appName,
                            quote: libraryQuote, question: m.question,
                            body: m.answer + (m.why.isEmpty ? "" : "\n\n" + m.why), chatID: recordID)
            library.add(note)
            if Settings.shared.mirrorNotes { Notebook.export(note) }
        }
    }

    // MARK: - Screenshot

    private func captureScreen() {
        guard screenMode != .off else {
            screenshotReady = true
            return
        }
        ScreenCapture.capture(screenMode, at: selection.mouse, pid: selection.pid) { [weak self] data in
            self?.screenshotArrived(data)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenshotTimeout) { [weak self] in
            self?.screenshotArrived(nil)
        }
    }

    private func screenshotArrived(_ data: Data?) {
        guard !screenshotReady else { return }
        screenshot = data
        screenshotReady = true
        if let work = afterScreenshot {
            afterScreenshot = nil
            work()
        }
    }

    /// Runs `work` once the screenshot is in (right away if it already is).
    private func whenScreenshotReady(_ work: @escaping () -> Void) {
        if screenshotReady { work() } else { afterScreenshot = work }
    }

    // MARK: - Video

    private func wireVideo() {
        model.onSummarizeVideo = { [weak self] in self?.summarizeVideoFromHere() }
        model.onChooseLanguage = { [weak self] language in self?.transcribe(in: language) }
        model.onStopListening = { [weak self] in self?.stopListening() }
        model.onChooseStyle = { [weak self] style in self?.requestSummary(style) }
    }

    /// The chip in a normal chat: a YouTube link in the highlight, or the browser's current tab.
    private func summarizeVideoFromHere() {
        if let id = YouTube.videoID(in: selection.text) {
            onOpenVideo?(.youtube(id: id))
        } else if let browser = selection.bundleID, let url = BrowserTab.currentURL(bundleID: browser),
                  let id = YouTube.videoID(in: url) {
            onOpenVideo?(.youtube(id: id))
        } else {
            onOpenVideo?(.listen) // not a YouTube page: listen to whatever is playing
        }
    }

    private func startVideo(_ source: VideoSource) {
        videoSource = source
        model.onListenInstead = nil
        switch source {
        case .youtube(let id):
            model.video = VideoState(icon: "play.rectangle.fill", title: "YouTube video", subtitle: "youtu.be/\(id)",
                                     thumbnail: YouTube.thumbnailURL(id), stage: .fetching)
            if let url = YouTube.thumbnailURL(id) {
                Task { @MainActor [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    self?.model.videoThumbnail = NSImage(data: data)
                }
            }
            Task { @MainActor [weak self] in
                do {
                    let transcript = try await YouTube.transcript(for: id)
                    self?.transcriptReady(transcript)
                } catch {
                    self?.model.onListenInstead = { [weak self] in self?.startVideo(.listen) }
                    self?.videoFailed("Couldn't read this video's transcript. \(error.localizedDescription) "
                                      + "Play it and let Margin listen along instead.")
                }
            }
        case .listen:
            model.video = VideoState(icon: "waveform", title: "Listen along",
                                     subtitle: "Transcribes your Mac's sound while the video plays",
                                     thumbnail: nil, stage: .chooseLanguage)
        case .file(let url):
            model.video = VideoState(icon: "film", title: url.deletingPathExtension().lastPathComponent,
                                     subtitle: url.lastPathComponent, thumbnail: nil, stage: .chooseLanguage)
        }
        onUpdate?()
    }

    private func setStage(_ stage: VideoState.Stage) {
        withAnimation(.easeInOut(duration: 0.2)) { model.video?.stage = stage }
    }

    /// Listen along / file: the user said which language is spoken.
    private func transcribe(in language: SpokenLanguage) {
        guard let source = videoSource else { return }
        let transcription = Transcription(language: language)
        self.transcription = transcription
        setStage(.preparingModel(0))
        phase = .working
        Task { @MainActor [weak self] in
            do {
                try await transcription.prepare { fraction in self?.setStage(.preparingModel(fraction)) }
                switch source {
                case .listen:
                    try await transcription.startListening()
                    self?.beginListening(language)
                case .file(let url):
                    self?.setStage(.transcribing(0))
                    try await transcription.transcribeFile(url) { fraction in self?.setStage(.transcribing(fraction)) }
                    self?.transcriptionFinished(language)
                case .youtube:
                    break
                }
            } catch {
                self?.videoFailed(error.localizedDescription)
            }
        }
    }

    private func beginListening(_ language: SpokenLanguage) {
        listenStarted = Date()
        var caption = ""
        transcription?.onUpdate = { lines, partial in
            caption = (lines.suffix(4).map(\.text) + [partial]).joined(separator: " ")
        }
        setStage(.listening(elapsed: 0, caption: ""))
        listenTimer?.invalidate()
        listenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.listenStarted)
            self.model.video?.stage = .listening(elapsed: elapsed, caption: caption)
            self.model.status = "Listening · \(VideoTranscript.clock(elapsed))" // the sidebar row's label
            self.onUpdate?()
            if elapsed > Self.maxListen { self.stopListening() }
        }
        listenLanguage = language
    }

    private var listenLanguage: SpokenLanguage = .english

    private func stopListening() {
        listenTimer?.invalidate()
        model.status = nil
        setStage(.finishing)
        Task { @MainActor [weak self] in
            guard let self, let transcription = self.transcription else { return }
            try? await transcription.stopListening()
            self.transcriptionFinished(self.listenLanguage)
        }
    }

    private func transcriptionFinished(_ language: SpokenLanguage) {
        guard let lines = transcription?.lines, !lines.isEmpty else {
            return videoFailed("I didn't catch any speech. Check the video's sound is playing (not muted), then try again.")
        }
        var title = "Audio from your Mac"
        if case .file(let url) = videoSource { title = url.deletingPathExtension().lastPathComponent }
        transcriptReady(VideoTranscript(title: title, channel: nil, duration: lines.last?.start,
                                        languageCode: language.code,
                                        origin: "on-device transcription of the audio (may have recognition errors)",
                                        segments: lines))
    }

    private func transcriptReady(_ transcript: VideoTranscript) {
        videoTranscript = transcript
        if case .youtube = videoSource {
            model.video?.title = transcript.title
            model.video?.subtitle = [transcript.channel, transcript.duration.map(VideoTranscript.clock), transcript.languageName]
                .compactMap { $0 }.joined(separator: " · ")
        }
        phase = .idle
        if transcript.isEnglish {
            requestSummary(.english)
        } else {
            setStage(.chooseStyle(language: transcript.languageName)) // the user picks, every time
            onUpdate?()
        }
    }

    private func requestSummary(_ style: SummaryStyle) {
        guard let transcript = videoTranscript else { return }
        setStage(.ready)
        let display = transcript.isEnglish ? "Summarize this video" : "Summarize: \(style.label(language: transcript.languageName))"
        model.ask(display: display,
                  prompt: Prompts.videoRequest(style, language: transcript.languageName, link: videoSource?.link))
    }

    private func videoFailed(_ message: String) {
        listenTimer?.invalidate()
        model.status = nil
        phase = .idle
        setStage(.failed(message))
        onUpdate?()
    }

    func debugStartVideo(_ source: VideoSource) { startVideo(source) }
    func debugSetVideoStage(_ stage: VideoState.Stage) { model.video?.stage = stage }
    func debugTranscriptReady(_ t: VideoTranscript) { transcriptReady(t) }

    // MARK: - Answering

    /// What the chat's footnote says it can use. `plan` is nil before the first question.
    private static func footnote(choice: ModelChoice, web: Bool, screen: ScreenContext, plan: Router.Plan?,
                                 localModel: String, localFirst: Bool) -> String {
        if let plan {
            if plan.isLocal { return "\(localModel) · on your Mac · nothing sent to Claude · ⌃⇧L for Claude" }
            if plan.lean { return "\(choice.title) · text only · web search off" }
        } else if localFirst {
            return "Quick questions stay on your Mac (\(localModel)) · the rest goes to \(choice.title)"
        }
        var parts = [choice.title, web ? "web search on" : "web search off"]
        switch screen {
        case .smart: parts.append("sees your screen if needed")
        case .screen: parts.append("sees your screen")
        case .window: parts.append("sees this window")
        case .off: break
        }
        return parts.joined(separator: " · ")
    }

    private func send(_ prompt: String) {
        // "Add … to my calendar" is understood here, on this Mac: no Claude call, and nothing is added until you say so.
        if let draft = CalendarIntent.parse(prompt) { return answerWithEvent(draft) }
        // "Summarize this video": the video summarizer takes over (a video chat itself is already one, so it's left alone).
        if model.video == nil, docIndex == nil, let intent = VideoIntent.parse(prompt), answerWithVideo(intent) { return }
        phase = .working
        touch()
        lastPrompt = prompt
        startWatchdog()
        if sentFirst {
            sendFollowUp(prompt)
        } else {
            sentFirst = true
            sendFirst(prompt)
        }
    }

    /// Typed or spoken in this chat: summarize the video. The chat turns into a video agent for it. False if there's no
    /// summarizer wired up (a test); true once it's handled, including by saying why it can't be done.
    private func answerWithVideo(_ intent: VideoIntent) -> Bool {
        guard let open = onOpenVideo else { return false }
        func say(_ text: String) {
            if model.autoTitle == nil { model.autoTitle = "Video summary" }
            model.append(text)
            model.finishTurn()
            phase = .done
            touch()
            onUpdate?()
        }
        switch intent {
        case .youtube(let id?):
            open(.youtube(id: id))
        case .youtube(nil):
            switch VideoIntent.locate(alsoTry: selection.bundleID) {
            case .video(let id): open(.youtube(id: id))
            case let problem: say(VideoIntent.explain(problem))
            }
        case .listenAlong:
            guard ScreenCapture.hasPermission else {
                ScreenCapture.requestPermission()
                say("Listening needs Screen & System Audio Recording permission. Turn Margin on in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again.")
                return true
            }
            open(.listen)
        }
        return true
    }

    /// The calendar card, as this turn's answer.
    private func answerWithEvent(_ draft: CalendarIntent.Draft) {
        if model.autoTitle == nil { model.autoTitle = "Calendar: " + String(draft.title.prefix(40)) }
        if model.sector == nil { model.sector = "Calendar" }
        model.append("<event>\(EventCard.encode(draft))</event>")
        model.finishTurn()
        phase = .done
        touch()
        onUpdate?()
    }

    /// The first question: choose who answers, then start only that.
    private func sendFirst(_ prompt: String) {
        if let transcript = videoTranscript {
            // A video chat works from its transcript. With Local Mode on (and English), the model on this Mac reads it;
            // otherwise Claude does, with the usual tools (to check things it says).
            if Settings.shared.localMode, OllamaClient.shared.status.isUsable, transcript.isEnglish {
                startLocalVideo(transcript, request: prompt)
            } else {
                startClaudeVideo(transcript, request: prompt)
            }
            return
        }
        let settings = Settings.shared
        // With Local Mode on, a graph that clearly fits a ready-made one is drawn here, with no Claude call.
        if settings.localMode, selection.video == nil, docIndex == nil, selection.regionImage == nil, !selection.isBlank,
           let template = GraphTemplates.match(prompt: prompt, selection: selection.text) {
            let chosen = Router.Plan(engine: .local, lean: false, why: "graph template")
            plan = chosen
            localModelName = GraphTemplates.label
            model.footnote = "Drawn on your Mac · no Claude call"
            let session = TemplateSession(template)
            attach(session)
            model.markNewestTurn(localModel: GraphTemplates.label)
            session.send(prompt, images: [])
            return
        }
        let chosen = Router.plan(.init(prompt: prompt, selection: selection.text, context: context,
                                       hasSnip: selection.regionImage != nil, isBlank: selection.isBlank,
                                       isVideo: selection.video != nil, hasDocument: docIndex != nil,
                                       localMode: settings.localMode, localUsable: OllamaClient.shared.status.isUsable,
                                       smart: screenMode == .smart))
        plan = chosen
        model.footnote = Self.footnote(choice: choice, web: webSearch, screen: screenMode, plan: chosen,
                                       localModel: settings.localModel, localFirst: false)
        if chosen.isLocal {
            startLocal(prompt)
        } else if chosen.lean {
            startClaude(prompt, chosen) // no screenshot to wait for
        } else {
            whenScreenshotReady { [weak self] in self?.startClaude(prompt, chosen) }
        }
    }

    /// A video chat answered by Claude from the whole transcript. `earlier` is what was said before, for a chat that moved over.
    private func startClaudeVideo(_ transcript: VideoTranscript, request: String, earlier: [(question: String, answer: String)] = []) {
        videoTask?.cancel()
        videoLocal = false
        model.answerFilter = nil
        plan = Router.Plan(engine: .claude, lean: false, why: "video")
        guard let claude = startClaudeSession(lean: false, features: .all) else { return }
        let history = earlier.isEmpty ? "" : "Earlier in this chat:\n"
            + earlier.map { "Q: \(Prompts.clip($0.question, 300))\nA: \(Prompts.clip($0.answer, 1200))" }.joined(separator: "\n") + "\n\n"
        claude.send(Prompts.video(transcript, link: videoSource?.link, request: history + request), images: [])
    }

    /// A video chat answered on this Mac: a long transcript is read in parts and boiled down to notes, then the notes become
    /// the summary. No Claude call. If the model doesn't answer, Claude takes over.
    private func startLocalVideo(_ transcript: VideoTranscript, request: String) {
        let name = Settings.shared.localModel
        localModelName = name
        videoLocal = true
        videoCompacted = false
        let chosen = Router.Plan(engine: .local, lean: false, why: "video summary")
        plan = chosen
        model.footnote = Self.footnote(choice: choice, web: webSearch, screen: .off, plan: chosen, localModel: name, localFirst: false)
        model.markNewestTurn(localModel: name)
        let parts = VideoDigest.chunks(transcript)
        // A small model gets links wrong: it writes plain times, and the links are made here when the answer is done.
        var request = request
        if let link = videoSource?.link {
            request = request.replacingOccurrences(of: Prompts.stampPhrase(link: link), with: Prompts.stampPhrase(link: nil))
            model.answerFilter = { VideoDigest.linkify($0, link: link) }
        }
        videoTask?.cancel()
        videoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var notes: [String]?
            if parts.count > 1 {
                var collected: [String] = []
                for (i, part) in parts.enumerated() {
                    if Task.isCancelled || self.closed { return }
                    self.model.status = "Reading part \(i + 1) of \(parts.count) on your Mac…"
                    self.lastEvent = Date() // a long video is slow on a small model; that isn't a stall
                    let prompt = VideoDigest.notesPrompt(part: i + 1, of: parts.count, chunk: part)
                    guard let text = await OllamaClient.shared.generateText(system: VideoDigest.notesSystem, prompt: prompt, maxTokens: 350) else {
                        if Task.isCancelled || self.closed { return }
                        OllamaClient.shared.noteFailure(.notRunning)
                        self.videoLocal = false
                        self.model.markNewestTurn(localModel: nil)
                        self.model.footnote = "Ollama didn't answer · " + Self.footnote(choice: self.choice, web: self.webSearch, screen: .off,
                                                                                         plan: Router.Plan(engine: .claude, lean: false, why: "video"),
                                                                                         localModel: name, localFirst: false)
                        self.startClaudeVideo(transcript, request: request)
                        return
                    }
                    collected.append(text)
                }
                notes = collected
            }
            if Task.isCancelled || self.closed { return }
            self.model.status = "Writing the summary on your Mac…"
            self.lastEvent = Date()
            let local = LocalSession(model: name, system: Prompts.localVideoSystem, maxTokens: 1300)
            self.attach(local)
            try? local.start()
            local.send(VideoDigest.finalPrompt(transcript: transcript, link: self.videoSource?.link, notes: notes, request: request), images: [])
        }
    }

    // MARK: - ⌃⇧L: who answers this chat

    /// Moves THIS chat to Claude (if the model on this Mac was answering it) or to the model on this Mac (if Claude was),
    /// and answers the last question again that way. Only this chat: Local Mode itself, and every other and future chat,
    /// are untouched. Returns what to tell the person.
    @discardableResult
    func toggleEngine() -> String {
        guard !closed, sentFirst, !model.turns.isEmpty, plan != nil else {
            return "Ask something first. Then ⌃⇧L moves this one chat between Claude and your Mac."
        }
        return plan?.isLocal == true ? switchToClaude() : switchToLocal()
    }

    private func stopAnswering() {
        videoTask?.cancel()
        session?.stop()
        session = nil
        stopWatchdog()
    }

    private func switchToClaude() -> String {
        stopAnswering()
        model.restartNewestTurn()
        phase = .working
        touch()
        startWatchdog()
        if lastLocalSaving > 0 { UsageLog.record(.reask(saving: lastLocalSaving)) }
        lastLocalSaving = 0
        let lean = videoTranscript == nil && selection.regionImage == nil
            && (docIndex != nil || (!selection.text.isEmpty && !Router.needsWeb(lastPrompt) && !Router.needsScreen(lastPrompt)))
        escalate(prompt: lastPrompt, earlier: model.earlierExchanges(), note: "Switched to Claude for this chat (⌃⇧L to go back)", lean: lean)
        onUpdate?()
        return "This chat now uses Claude. Your other chats, and new ones, are unchanged."
    }

    private func switchToLocal() -> String {
        guard OllamaClient.shared.status.isUsable else {
            return "Ollama isn't running (or \(Settings.shared.localModel) isn't installed), so this chat stays on Claude."
        }
        if let transcript = videoTranscript {
            guard transcript.isEnglish else { return "Summaries on your Mac are English only, so this video stays on Claude." }
        } else {
            if docIndex != nil { return "Chats about a whole page or document use Claude, so this one stays." }
            guard Router.mayGoLocal(selection: selection.text, hasSnip: selection.regionImage != nil, isVideo: false, localMode: true)
                    || (Prompts.isSummary(lastPrompt) && !selection.text.isEmpty && selection.regionImage == nil
                        && selection.text.count <= Router.maxLocalSummary) else {
                return "This chat needs Claude (a snip, a blank chat, very long text or non-Latin text), so it stays."
            }
            if Router.needsClaude(lastPrompt) { return "That question needs Claude (the web, your screen, graphs or translation), so this chat stays." }
        }
        stopAnswering()
        model.restartNewestTurn()
        phase = .working
        touch()
        startWatchdog()
        lastLocalSaving = 0
        if let transcript = videoTranscript {
            startLocalVideo(transcript, request: lastPrompt)
        } else {
            let chosen = Router.Plan(engine: .local, lean: false, why: "switched by you")
            plan = chosen
            model.footnote = Self.footnote(choice: choice, web: webSearch, screen: screenMode, plan: chosen,
                                           localModel: Settings.shared.localModel, localFirst: false)
            startLocal(lastPrompt, earlier: model.earlierExchanges())
        }
        onUpdate?()
        return "This chat now runs on your Mac (\(Settings.shared.localModel)). Your other chats, and new ones, are unchanged."
    }

    /// Later questions go to whoever started the chat, unless they need something it doesn't have.
    private func sendFollowUp(_ prompt: String) {
        if let plan, Router.needsEscalation(prompt, from: plan) {
            // A quiz needs nothing but the conversation, so it moves over as a lean call.
            let lean = prompt == Prompts.quiz && !Router.needsWeb(prompt) && !Router.needsScreen(prompt)
            escalate(prompt: prompt, earlier: model.earlierExchanges(), lean: lean)
            return
        }
        if plan?.isLocal == true { model.markNewestTurn(localModel: localModelName) }
        var text = prompt
        if videoLocal, let transcript = videoTranscript {
            // Only the transcript passages this question is about go to the small model, found here by keyword.
            let index = videoIndex ?? VideoDigest.index(transcript)
            videoIndex = index
            text = VideoDigest.followUp(prompt, index: index)
        }
        if let doc = documentPassages(for: prompt) { text = Prompts.withPassages(prompt, doc.passages, overview: doc.overview) }
        // The first prompt left out the voice and graph instructions; add them now if this question needs them.
        if let claude = session as? ClaudeSession, let extra = Prompts.extraInstructions(for: prompt, have: claude.features) {
            text = extra.text + "\n\n" + text
            claude.didSendExtra(extra.added)
        }
        session?.send(text, images: [])
    }

    private func startLocal(_ prompt: String, earlier: [(question: String, answer: String)] = []) {
        localModelName = Settings.shared.localModel
        let local = LocalSession(model: localModelName)
        attach(local)
        try? local.start()
        model.markNewestTurn(localModel: localModelName)
        let text = Prompts.first(app: selection.appName, selection: selection.text, context: context, question: prompt,
                                 selectionLimit: Prompts.isSummary(prompt) ? Prompts.maxSummarySelection : Prompts.maxSelection,
                                 earlier: earlier)
        local.send(text, images: [])
    }

    /// Starts a Claude session for this chat. A lean one has no web tools. nil (and the error shown) if it can't start.
    private func startClaudeSession(lean: Bool, features: Prompts.Features) -> ClaudeSession? {
        let claude = ClaudeSession(model: choice, webSearch: lean ? false : webSearch, features: features)
        attach(claude)
        do {
            try claude.start()
            return claude
        } catch {
            stopWatchdog()
            model.fail(error.localizedDescription, sessionDead: true)
            phase = .failed
            return nil
        }
    }

    /// The first message to Claude: the highlight (or snip, or screenshot) and the question. `earlier` is for a
    /// chat that moved over from the local model.
    private func startClaude(_ prompt: String, _ plan: Router.Plan,
                             earlier: [(question: String, answer: String)] = []) {
        let features = Prompts.features(question: prompt, selection: selection.text, context: context)
        guard !closed, let claude = startClaudeSession(lean: plan.lean, features: features) else { return }
        var images: [Data] = []
        if let snip = selection.regionImage { images.append(snip) }
        // A lean chat doesn't get the whole-screen screenshot; it's kept in case the chat moves to a full one.
        let shot = plan.lean ? nil : screenshot
        if let shot { images.append(shot) }
        var text = Prompts.first(app: selection.appName, selection: selection.text, context: context,
                                 question: prompt, hasScreenshot: shot != nil,
                                 hasSnip: selection.regionImage != nil,
                                 selectionLimit: Prompts.isSummary(prompt) ? Prompts.maxSummarySelection : Prompts.maxSelection,
                                 earlier: earlier)
        if let docIndex, let doc = documentPassages(for: prompt) {
            text = Prompts.firstWithDocument(app: selection.appName, doc: docIndex, selection: selection.text,
                                             passages: doc.passages, question: prompt, overview: doc.overview)
        }
        claude.send(text, images: images)
        if shot != nil { screenshot = nil }
    }

    /// Moves the chat to a full Claude session (web search, the screenshot) and asks it `prompt`, with what was
    /// said so far. `note` says why, in the footnote.
    private func escalate(prompt: String, earlier: [(question: String, answer: String)], note: String? = nil,
                          lean: Bool = false) {
        session?.stop()
        session = nil
        videoTask?.cancel()
        videoLocal = false
        let full = Router.Plan(engine: .claude, lean: lean, why: "escalated")
        plan = full
        model.markNewestTurn(localModel: nil)
        let base = Self.footnote(choice: choice, web: webSearch, screen: screenMode, plan: full,
                                 localModel: localModelName, localFirst: false)
        model.footnote = note.map { "\($0) · \(base)" } ?? base
        // A video chat is about its transcript, not a highlight.
        if let transcript = videoTranscript { return startClaudeVideo(transcript, request: prompt, earlier: earlier) }
        if lean { return startClaude(prompt, full, earlier: earlier) }
        whenScreenshotReady { [weak self] in self?.startClaude(prompt, full, earlier: earlier) }
    }

    /// "Ask Claude" under a local answer: Claude answers that question instead.
    private func askClaudeInstead() {
        phase = .working
        touch()
        startWatchdog()
        UsageLog.record(.reask(saving: lastLocalSaving))
        lastLocalSaving = 0
        escalate(prompt: lastPrompt, earlier: model.earlierExchanges())
    }

    /// The local model couldn't start an answer (Ollama off, model missing): Claude takes the question.
    private func fallBackToClaude(_ reason: String) {
        guard plan?.isLocal == true, !model.turns.isEmpty else { return handle(.error(reason)) }
        let why: String
        switch OllamaClient.shared.status {
        case _ where plan?.why == "graph template": why = reason
        case .notRunning: why = "Ollama isn't running"
        case .modelMissing: why = "\(localModelName) isn't installed"
        case .unknown, .ready: why = "The local model failed"
        }
        escalate(prompt: lastPrompt, earlier: model.earlierExchanges(), note: why)
    }

    private func attach(_ new: AnswerSession) {
        session = new
        new.onEvent = { [weak self] event in self?.handle(event) }
        new.onUsage = { [weak self] usage in self?.record(usage) }
    }

    /// Loads the local model while you're still typing, so its first answer doesn't wait for it.
    private func warmUpLocalModel() {
        let settings = Settings.shared
        guard Router.mayGoLocal(selection: selection.text, hasSnip: selection.regionImage != nil,
                                isVideo: selection.video != nil, localMode: settings.localMode) else { return }
        OllamaClient.shared.warmUp { [weak self] status in
            guard let self, !self.closed, !self.sentFirst, !status.isUsable else { return }
            // Ollama isn't there: don't promise a local answer.
            self.model.footnote = Self.footnote(choice: self.choice, web: self.webSearch, screen: self.screenMode,
                                                plan: nil, localModel: settings.localModel, localFirst: false)
        }
    }

    private func record(_ usage: ClaudeSession.Usage) {
        guard let plan else { return }
        let first = model.turns.count <= 1
        let saved: Int
        if plan.isLocal {
            saved = UsageLog.savedByLocal(followUp: !first, screenshot: screenMode != .off, web: webSearch)
            lastLocalSaving = saved
        } else if plan.lean {
            saved = UsageLog.savedByLean(screenshot: screenMode != .off, web: webSearch)
        } else {
            saved = 0
        }
        UsageLog.record(UsageLog.Entry(engine: plan.isLocal ? "local" : "claude", lean: plan.lean, why: plan.why,
                                       first: first, usage: usage, saved: saved))
    }

    // MARK: - Stalls

    private func startWatchdog() {
        lastEvent = Date()
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() } // the chat is gone
            self.checkStall()
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkStall() {
        guard !closed, model.isStreaming, Date().timeIntervalSince(lastEvent) > Self.stallTimeout else { return }
        stopWatchdog()
        let who = plan?.isLocal == true ? "The local model" : "Claude"
        session?.stop()
        model.fail("\(who) didn't answer in time.", sessionDead: true)
        phase = .failed
        onUpdate?()
    }

    private func handle(_ event: ClaudeSession.Event) {
        lastEvent = Date()
        switch event {
        case .delta(let text):
            let wasResearching = model.status != nil
            model.append(text)
            if wasResearching { onUpdate?() }
        case .activity(let label):
            model.toolActivity(label)
            onUpdate?()
        case .turnDone:
            stopWatchdog()
            model.finishTurn()
            phase = .done
            if videoLocal, !videoCompacted, let local = session as? LocalSession {
                // The notes did their job; later questions get transcript passages instead (the model's memory is small).
                local.replaceFirstUserMessage(with: "Summarize this video.")
                videoCompacted = true
            }
        case .error(let message):
            stopWatchdog()
            model.fail(message, sessionDead: !(session?.isAlive ?? false))
            phase = .failed
        case .unavailable(let reason):
            fallBackToClaude(reason)
        }
        touch()
    }

    // MARK: - Decay (only while expanded)

    private func touch() {
        lastActivity = Date()
        guard fading else { return }
        fading = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Motion.easeOut
            panel.animator().alphaValue = 1
        }
    }

    private func startDecay() {
        lastActivity = Date()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.decayTick() }
    }

    private func stopDecay() {
        tick?.invalidate()
        tick = nil
        fading = false
    }

    private func decayTick() {
        guard !inFlight, !awaitingFirstLayout, !closed else { return }
        if placedTopLeft != nil { return } // you put it there; it stays until you click away
        let hovering = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
        let composing = model.turns.isEmpty && !model.draft.isEmpty
        if phase == .working || model.isStreaming || hovering || composing || model.video?.isBusy == true {
            touch()
            return
        }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= Self.minimizeAfter {
            dismissGesture()
        } else if idle > Self.fadeStart, !fading {
            // One continuous fade instead of stepping the opacity down.
            fading = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.minimizeAfter - idle
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                panel.animator().alphaValue = 0.3
            }
        }
    }

    private func installMonitors() {
        removeMonitors()
        guard !Self.demoMode else { return } // the user's own clicks mustn't interfere with --demo
        // Clicks in other apps. (Global monitors never see Margin's own windows, like the sidebar.)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismissGesture()
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { // Esc
                self.dismissGesture()
                return nil
            }
            self.touch()
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: - Layout

    /// The header's ⤢ button: 50% bigger (or back). The old layout stays pinned top-left while the
    /// box grows, and the new layout fades in over it, so text never visibly reflows or stretches.
    private func toggleSize() {
        guard !closed, !isMinimized, !inFlight, !awaitingFirstLayout else { return }
        let from = panel.frame
        let background = snapshotBackground
        guard let before = snapshot() else {
            model.isLarge.toggle()
            Settings.shared.largePopup = model.isLarge
            return
        }
        inFlight = true
        let area = (NSScreen.screens.first { $0.frame.intersects(from) } ?? NSScreen.main)?.frame
            ?? from.insetBy(dx: -400, dy: -400)
        let ghost = Ghost(image: before, frame: from, radius: Self.cornerRadius,
                          gravity: .topLeft, background: background, area: area)
        panel.alphaValue = 0
        model.isLarge.toggle()
        Settings.shared.largePopup = model.isLarge

        // Give SwiftUI a beat to lay out at the new size, then morph into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.closed else { return ghost.dismiss() }
            self.hosting.layoutSubtreeIfNeeded()
            let target = self.targetFrame(height: self.contentHeight)
            self.panel.setFrame(target, display: true)
            self.hosting.layoutSubtreeIfNeeded()
            ghost.animate(to: target, radius: Self.cornerRadius, crossfadeTo: self.snapshot(),
                          gravity: .topLeft, background: background,
                          duration: 0.34, timing: Motion.easeOut) { [weak self] remove in
                guard let self, !self.closed else { return remove() }
                self.inFlight = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.1
                    self.panel.animator().alphaValue = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: remove)
                self.resize(toContentHeight: self.contentHeight)
            }
        }
    }

    private func resize(toContentHeight h: CGFloat) {
        guard h > 0 else { return }
        let changed = abs(h - contentHeight) > 0.5
        contentHeight = h
        if awaitingFirstLayout {
            DispatchQueue.main.async { [weak self] in self?.appear() }
            return
        }
        guard changed, !closed, !isMinimized, !inFlight else { return }
        let target = targetFrame(height: h)
        WindowMotion.animate(panel, to: target, duration: 0.22) { [weak self] in self?.panel.invalidateShadow() }
    }

    /// Opening below the ? (or beside the sidebar) means the bottom edge is the one that moves.
    private var growsDown: Bool {
        switch anchor {
        case .selection(let icon): return icon.minY - visibleFrame(around: icon).minY > 300
        case .dock: return true
        }
    }

    private func visibleFrame(around rect: NSRect) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return (NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main)?
            .visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func targetFrame(height h: CGFloat) -> NSRect {
        let anchorRect: NSRect
        switch anchor {
        case .selection(let r), .dock(let r): anchorRect = r
        }
        let vf = visibleFrame(around: placedTopLeft.map { NSRect(origin: $0, size: .zero) } ?? anchorRect)
        let height = min(h, vf.height - 16)
        var x: CGFloat
        var y: CGFloat

        if let placed = placedTopLeft {
            x = placed.x                                     // where you dragged it
            y = placed.y - height
        } else {
            switch anchor {
            case .selection(let icon):
                x = icon.minX - 12
                y = growsDown ? icon.minY - 4 - height : icon.maxY + 4
            case .dock(let sidebar):
                x = sidebar.minX - 12 - model.width          // to the left of the sidebar
                y = sidebar.maxY - height                    // top-aligned with it
            }
        }
        x = min(max(x, vf.minX + 8), vf.maxX - model.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - 8 - height)
        return NSRect(x: x, y: y, width: model.width, height: height)
    }

    // MARK: - Debug hooks for --demo

    /// Asks a question for the user (shown as `display`).
    func ask(_ prompt: String, display: String) { model.ask(display: display, prompt: prompt) }

    func debugAsk(_ question: String) { model.ask(display: question, prompt: question) }
    // For --localtest.
    var debugPlan: Router.Plan? { plan }
    var debugFootnote: String { model.footnote }
    var debugTurns: [AskModel.Turn] { model.turns }
    var debugCanAskClaude: Bool { model.canAskClaude }
    func debugAskClaudeInstead() { model.askClaudeInstead() }
    var debugVideoLocal: Bool { videoLocal }
    var debugVideoStatus: String? { model.status }
    /// Who is answering: "none" until the first question, then "local" or "claude".
    var debugEngine: String { session is LocalSession ? "local" : session is ClaudeSession ? "claude" : "none" }
    func debugChooseSummary() { model.choosingSummary = true }
    func debugSummarize(_ kind: Prompts.Summary) { model.summarize(kind) }
    func debugSnapshot() -> CGImage? { snapshot() }
    var debugPanelFrame: NSRect { panel.frame }
    var debugPanelAlpha: CGFloat { panel.alphaValue }
    var debugGlow: PanelGlow { glow }
    /// What the shortcut does to a chat you're typing in (test windows can't take the keyboard).
    func debugDismissFromShortcut() { dismissGesture() }
    /// Drags the chat like the header does, then reports where it ended up.
    func debugDrag(by delta: NSSize) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.width, y: panel.frame.minY + delta.height))
        userMoved()
    }
    /// Drags the chat by its top edge with mouse events sent through the window (the same path a real drag
    /// takes; in demo mode the chat doesn't take the keyboard). False if that spot doesn't start a drag.
    func debugDragHeader(by delta: NSSize) -> Bool {
        let start = NSPoint(x: panel.frame.minX + 60, y: panel.frame.maxY - 22)
        guard panel.startsDrag(at: NSPoint(x: 60, y: panel.frame.height - 22)) else { return false }
        func send(_ type: NSEvent.EventType, at screen: NSPoint) {
            let location = NSPoint(x: screen.x - panel.frame.minX, y: screen.y - panel.frame.minY)
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            panel.sendEvent(e)
        }
        send(.leftMouseDown, at: start)
        for i in 1...6 {
            let f = CGFloat(i) / 6
            send(.leftMouseDragged, at: NSPoint(x: start.x + delta.width * f, y: start.y + delta.height * f))
        }
        send(.leftMouseUp, at: NSPoint(x: start.x + delta.width, y: start.y + delta.height))
        return true
    }
    var debugIsPlaced: Bool { placedTopLeft != nil }
    var debugIsMinimized: Bool { isMinimized }
    func debugToggleSize() { toggleSize() }
    func debugInject(question: String, answer: String) { model.debugInject(question: question, answer: answer) }
    var debugSpeech: SpeechStore { model.speech }
    var debugFrame: NSRect { panel.frame }

    /// Catalog colors like windowBackgroundColor don't resolve offscreen, so snapshots use concrete ones.
    private var snapshotBackground: NSColor {
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 0.16 : 0.97, alpha: 1)
    }

    /// The chat drawn into an image (over a solid background, since blur can't be captured).
    private func snapshot() -> CGImage? {
        let bounds = hosting.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hosting.cacheDisplay(in: bounds, to: rep)

        let scale = panel.backingScaleFactor
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = bounds.size // must be set before the context exists, or drawing lands at 1x in a corner
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(origin: .zero, size: bounds.size)
        snapshotBackground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        // draw(in:) alone uses copy compositing and would wipe the background; layer it on top instead.
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out.cgImage
    }
}
