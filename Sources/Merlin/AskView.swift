import SwiftUI

final class AskModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        /// The words as the speech engine wrote them, for a dictated question (nil when typed). Claude's <heard> fix can
        /// then replace `question`, once `DictationFix` agrees it is only a small fix.
        var spoken: String?
        /// Claude's <heard> line, kept here when a tool starts and wipes the text written so far.
        var heard: String?
        var answer = ""
        var done = false
        var isError = false
        /// Set when a model on this Mac wrote the answer (Local mode): its name.
        var localModel: String?
    }

    let selection: Selection
    /// Voice clips Claude speaks in this chat (thrown away with it).
    let speech = SpeechStore()
    /// e.g. "Sonnet · web search on · sees your screen": what this agent can use. It changes when the chat
    /// moves between the local model and Claude.
    @Published var footnote: String
    /// Who answers this chat, for the Qwen/Claude button next to the question field.
    struct Engine: Equatable { var name: String; var isLocal: Bool }
    @Published var engine = Engine(name: "Claude", isLocal: false)
    var onToggleEngine: (() -> Void)?
    /// Decoded once (the view re-renders every frame while text flows in).
    let snipImage: NSImage?

    @Published var turns: [Turn] = []
    @Published var draft = ""
    @Published var isStreaming = false
    /// Live activity while working, e.g. "Searching “swift 6.4 release”".
    @Published var status: String?
    /// Set when the session can't continue (CLI missing, process died).
    @Published var fatal: String?
    /// Bumped to put the cursor back in the question field (e.g. after re-expanding).
    @Published var focusToken = 0
    /// The large auto size: 50% wider, with a 50% taller answer area (video summaries start like this).
    @Published var isLarge = false
    /// The chat has a size set by hand (or fills the screen): it takes the window's size, and only the answer area scrolls.
    @Published var isManualSize = false
    /// The chat fills the screen (the ⤢ button's state).
    @Published var isFilled = false
    /// Video agents: what's being summarized and where it's at.
    /// The chat's name and sector, from Claude's hidden <meta> line (nil until the first answer arrives).
    @Published var autoTitle: String?
    @Published var sector: String?
    /// Answers kept in the library.
    @Published var keptTurns: Set<UUID> = []
    /// Reading the whole page or PDF behind the highlight (only the passages that matter are sent to Claude).
    enum DocState: Equatable {
        case none
        /// A document is open in the app: offer to read it. (its name)
        case offered(String)
        case loading(String)
        case ready(name: String, detail: String)
        case failed(String)
    }
    @Published var doc: DocState = .none
    var onUseDocument: (() -> Void)?
    var onDropDocument: (() -> Void)?
    @Published var video: VideoState?
    @Published var videoThumbnail: NSImage?
    /// This chat could summarize a video (the highlight has a YouTube link, or it came from a browser).
    @Published var videoHint = false
    /// Showing the two Summarize choices in place of the quick questions.
    @Published var choosingSummary = false
    /// Learn mode, for this chat: Merlin's answers mark the few words that carry the key ideas. Off unless the panel turns it on.
    @Published var learnMode = false
    /// This chat sends a screenshot, so Summarize works even with nothing highlighted.
    var seesScreen = false
    var onSummarizeVideo: (() -> Void)?
    var onChooseLanguage: ((SpokenLanguage) -> Void)?
    var onStopListening: (() -> Void)?
    var onChooseStyle: ((SummaryStyle) -> Void)?
    var onListenInstead: (() -> Void)?

    /// The first answer named the chat (title and sector).
    var onMeta: (() -> Void)?
    /// A turn finished printing (its text is complete): time to save the chat.
    var onTurnComplete: (() -> Void)?
    var onKeep: ((_ turn: UUID) -> Void)?
    /// Starred from this window (it's applied when the chat is first saved, if that hasn't happened yet).
    @Published var starred = false
    /// Screenshots added for the next question (double-tap Shift, or the camera button).
    struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let thumb: NSImage?
    }
    @Published var attachments: [Attachment] = []
    static let maxAttachments = 3
    var onAttachScreenshot: (() -> Void)?
    var onToggleStar: (() -> Void)?
    var onQuizFinished: ((QuizResult) -> Void)?
    var onAsk: ((_ prompt: String) -> Void)?
    /// Typed text in a blank chat: true when it was a command and has run (see `CommandRunner`).
    var onCommand: ((_ text: String) -> Bool)?
    /// The Learn toggle was used: remember it for the next chat.
    var onLearnChange: ((Bool) -> Void)?
    /// "Ask Claude" on a local answer: the newest question goes to Claude instead.
    var onAskClaude: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onToggleSize: (() -> Void)?
    /// A click on empty header space (the controller fills the screen when it was the second click of a double-click).
    var onHeaderTap: (() -> Void)?
    var onActivity: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?

    /// Minimized agents skip the typewriter and take text as it comes.
    var instantText = false {
        didSet { if instantText { drainAll() } }
    }

    // Typewriter: Claude's text arrives in bursts; we reveal it at a steady 60 fps.
    private var pending = ""
    private var finishWhenDrained = false
    private var drainTimer: Timer?

    init(selection: Selection, footnote: String) {
        self.selection = selection
        self.footnote = footnote
        self.snipImage = selection.regionImage.flatMap { NSImage(data: $0) }
    }

    var canSubmit: Bool { !isStreaming && fatal == nil }
    var canMinimize: Bool { fatal == nil }

    static let largeScale: CGFloat = 1.5
    /// The width carried over from the last hand resize (`ChatStartSize`). Nil: the default width.
    var startWidth: CGFloat?
    var width: CGFloat { startWidth ?? AskPanelController.width * (isLarge ? Self.largeScale : 1) }
    var maxThreadHeight: CGFloat { 360 * (isLarge ? Self.largeScale : 1) }

    var canGoDeeper: Bool {
        guard let last = turns.last else { return false }
        return last.done && !last.isError && !isStreaming && last.question != Self.deeperLabel
            && last.question != Prompts.quizLabel && !last.answer.contains("<event>")
    }

    /// Learn mode can be switched at any point in an ordinary chat. A video or a document that's been read has its own way of working.
    var canToggleLearn: Bool {
        guard video == nil, selection.video == nil else { return false }
        switch doc {
        case .loading, .ready: return false
        default: return true
        }
    }

    /// Whether this chat's answers should carry highlighted key words (Learn mode on, in a chat that can use it).
    var learnApplies: Bool { learnMode && canToggleLearn }

    /// The Learn switch at the top of the chat. Later chats start from this choice. It changes what the model is asked for
    /// from the next question on, so answers already given keep what they have.
    func toggleLearn() {
        guard canToggleLearn else { return }
        withAnimation(Motion.animation(Motion.functional)) { learnMode.toggle() }
        onLearnChange?(learnMode)
    }

    static let deeperLabel = "Go deeper"
    static let screenshotSuffix = " · with screenshot"

    /// The newest answer is finished and has something worth keeping.
    var canKeep: Bool {
        guard let last = turns.last else { return false }
        return last.done && !last.isError && !last.answer.isEmpty && !isStreaming && fatal == nil
            && !last.answer.contains("<event>")
    }

    var newestIsKept: Bool { turns.last.map { keptTurns.contains($0.id) } ?? false }

    /// Quizzing needs something to quiz on: a finished, ordinary answer.
    var canQuiz: Bool {
        guard canKeep, let last = turns.last else { return false }
        return last.question != Prompts.quizLabel && !last.answer.lowercased().contains("<quiz")
    }

    func keepNewest() {
        guard canKeep, let last = turns.last, !keptTurns.contains(last.id) else { return }
        withAnimation(Motion.animation(Motion.functional)) { keptTurns.insert(last.id) }
        onKeep?(last.id)
    }

    func quizMe() {
        guard canQuiz else { return }
        ask(display: Prompts.quizLabel, prompt: Prompts.quiz)
    }

    /// The newest answer came from the local model and is finished, so Claude can be asked the same thing.
    var canAskClaude: Bool {
        guard let last = turns.last else { return false }
        return last.done && last.localModel != nil && !isStreaming && fatal == nil
    }

    /// Throws away the newest (local) answer and has Claude answer that question instead.
    func askClaudeInstead() {
        guard canAskClaude, let i = turns.indices.last else { return }
        withAnimation(Motion.animation(Motion.functional)) {
            turns[i].answer = ""
            turns[i].done = false
            turns[i].isError = false
            turns[i].localModel = nil
            isStreaming = true
            status = nil
        }
        speech.autoPlayNext = true
        onAskClaude?()
    }

    /// Throws away the newest answer (finished, failed or half-written) so another engine can answer that question: ⌃⇧L.
    func restartNewestTurn() {
        guard let i = turns.indices.last else { return }
        finishWhenDrained = false
        pending = ""
        withAnimation(Motion.animation(Motion.functional)) {
            turns[i].answer = ""
            turns[i].done = false
            turns[i].isError = false
            turns[i].localModel = nil
            isStreaming = true
            status = nil
            fatal = nil
        }
        speech.autoPlayNext = true
    }

    /// Applied to each answer when it finishes printing (a local video summary's timestamps become links).
    var answerFilter: ((String) -> String)?

    /// Marks the newest turn as answered by the local model (or, with nil, by Claude).
    func markNewestTurn(localModel: String?) {
        guard let i = turns.indices.last else { return }
        turns[i].localModel = localModel
    }

    /// The questions and answers so far, without the newest question (it's the one being asked now).
    /// Voice clips and graphs become plain words so they read well in a prompt.
    func earlierExchanges(excludingNewest: Bool = true) -> [(question: String, answer: String)] {
        let past = excludingNewest ? Array(turns.dropLast()) : turns
        return past.filter { $0.done && !$0.isError }.map { ($0.question, Answer.plainText($0.answer)) }
    }

    func submit() {
        guard canSubmit else { return }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty, !attachments.isEmpty {
            ask(display: Prompts.aboutScreenshot, prompt: Prompts.aboutScreenshot)
        } else if q.isEmpty {
            guard turns.isEmpty else { return }
            ask(display: Prompts.emptySubmit, prompt: Prompts.emptySubmit)
        } else {
            // A blank chat's first words may be a command ("open microeconomics note"): it acts, and Claude isn't asked.
            if turns.isEmpty, attachments.isEmpty, onCommand?(q) == true {
                draft = ""
                return
            }
            draft = ""
            ask(display: q, prompt: q)
        }
    }

    func ask(display: String, prompt: String, spoken: Bool = false) {
        guard canSubmit else { return }
        let shown = attachments.isEmpty ? display : display + Self.screenshotSuffix
        withAnimation(Motion.animation(Motion.functional)) {
            turns.append(Turn(question: shown, spoken: spoken ? display : nil))
            isStreaming = true
            status = nil
        }
        speech.autoPlayNext = true // if the answer speaks, play the first clip once
        onAsk?(prompt)
    }

    /// For `--voicedemo`: a finished turn without calling Claude.
    func debugInject(question: String, answer: String) {
        turns.append(Turn(question: question, answer: answer, done: true))
    }

    func goDeeper() { ask(display: Self.deeperLabel, prompt: Prompts.deeper) }

    // MARK: Teaching visuals (the Visual menu: Diagram, Animate)

    /// The Library chat this window saves into (set by the panel); its Visuals folder holds the files.
    var chatID: UUID?
    /// A visual was added to an answer: the panel saves the chat again.
    var onVisualAdded: (() -> Void)?
    @Published var visualStage: TeachVisuals.Stage?
    @Published var visualError: TeachVisuals.Failure?
    private var visualJob: TeachVisuals.CancelHandle?
    /// The job the status line belongs to: a cancelled job's late result never touches a newer one.
    private var visualToken: UUID?

    var visualsFolder: URL? { chatID.map { TeachVisuals.folder(chat: $0, library: Library.shared.directory) } }

    var canMakeVisual: Bool { canKeep && chatID != nil && visualStage == nil }

    /// One extra model call for the newest answer. The tag goes on that turn, even if you ask something else meanwhile.
    func makeVisual(_ kind: TeachVisuals.Kind) {
        guard canMakeVisual, let chatID, let turn = turns.last else { return }
        let turnID = turn.id
        visualError = nil
        let input = TeachVisuals.Input(kind: kind, chat: chatID, library: Library.shared.directory,
                                       selection: selection.text, question: turn.question, answer: turn.answer)
        let token = UUID()
        visualToken = token
        visualJob = TeachVisuals.make(input, stage: { [weak self] stage in
            guard let self, self.visualToken == token else { return }
            self.visualStage = stage
        }) { [weak self] result in
            guard let self, self.visualToken == token else { return }
            self.visualToken = nil
            self.visualJob = nil
            self.visualStage = nil
            switch result {
            case .success(let file):
                // Only onto the same, finished answer ("Ask Claude" may have restarted it meanwhile).
                guard let i = self.turns.firstIndex(where: { $0.id == turnID }), self.turns[i].done, !self.turns[i].isError else { return }
                withAnimation(Motion.animation(Motion.functional)) {
                    self.turns[i].answer += "\n\n" + Answer.visualMarkup(kind: kind, file: file)
                }
                self.onVisualAdded?()
            case .failure(let f):
                self.visualError = f == .cancelled ? nil : f
            }
        }
    }

    func cancelVisual() {
        visualJob?.cancel()
        visualJob = nil
        visualToken = nil
        visualStage = nil
    }

    func summarize(_ kind: Prompts.Summary) {
        choosingSummary = false
        ask(display: kind.display, prompt: kind.prompt)
    }

    func append(_ text: String) {
        guard !turns.isEmpty, !text.isEmpty else { return }
        if status != nil {
            withAnimation(Motion.animation(Motion.small)) { status = nil }
        }
        pending += text
        if instantText { drainAll() } else { startDrain() }
    }

    /// A tool started: anything written so far was narration ("Let me look that up…").
    func toolActivity(_ label: String) {
        if let i = turns.indices.last, !turns[i].done, let heard = Answer.heard(in: turns[i].answer + pending) {
            turns[i].heard = heard // the <heard> line came before the search: keep it
        }
        pending = ""
        withAnimation(Motion.animation(Motion.functional)) {
            if let i = turns.indices.last, !turns[i].done { turns[i].answer = "" }
            status = label
        }
    }

    func finishTurn() {
        finishWhenDrained = true
        if pending.isEmpty || instantText { drainAll() }
    }

    func fail(_ message: String, sessionDead: Bool) {
        finishWhenDrained = false
        flushPending()
        withAnimation(Motion.animation(Motion.functional)) {
            isStreaming = false
            status = nil
            if let i = turns.indices.last {
                let partial = turns[i].answer
                turns[i].answer = partial.isEmpty ? message : partial + "\n\n" + message
                turns[i].isError = true
                turns[i].done = true
            }
            if sessionDead { fatal = turns.isEmpty ? message : "Close this and select the text again to retry." }
        }
    }

    func stopAnimations() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func startDrain() {
        guard drainTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.drainTick() }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func drainTick() {
        guard let i = turns.indices.last, !pending.isEmpty else {
            stopAnimations()
            if finishWhenDrained { completeTurn() }
            return
        }
        // A steady flow that speeds up when Claude is far ahead, so we never lag behind much.
        let n = max(2, pending.count / 12)
        var chunk = String(pending.prefix(n))
        pending.removeFirst(chunk.count)
        // A graph's or quiz's JSON is never shown as text, so don't spend time typing it: jump to its end.
        let shown = turns[i].answer + chunk
        for tag in ["graph", "quiz", "event"] {
            if let open = shown.range(of: "<\(tag)", options: [.backwards, .caseInsensitive]),
               shown.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<shown.endIndex) == nil {
                if let close = pending.range(of: "</\(tag)>", options: .caseInsensitive) {
                    chunk += pending[..<close.upperBound]
                    pending.removeSubrange(..<close.upperBound)
                } else {
                    chunk += pending
                    pending = ""
                }
            }
        }
        turns[i].answer += chunk
    }

    private func flushPending() {
        stopAnimations()
        if let i = turns.indices.last, !pending.isEmpty { turns[i].answer += pending }
        pending = ""
    }

    private func drainAll() {
        flushPending()
        if finishWhenDrained { completeTurn() }
    }

    private func completeTurn() {
        finishWhenDrained = false
        guard let i = turns.indices.last else { return }
        // The hidden <meta> line names and files the chat; a <heard> line fixes a misheard spoken question. Both come off.
        let meta = Answer.meta(in: turns[i].answer)
        let fixed = turns[i].spoken.flatMap { DictationFix.accept(original: $0, corrected: Answer.heard(in: turns[i].answer) ?? turns[i].heard) }
        withAnimation(Motion.animation(Motion.functional)) {
            turns[i].answer = Answer.withoutMeta(turns[i].answer)
            if let fixed {
                turns[i].question = turns[i].question.hasSuffix(Self.screenshotSuffix) ? fixed + Self.screenshotSuffix : fixed
            }
            if let answerFilter { turns[i].answer = answerFilter(turns[i].answer) }
            turns[i].done = true
            isStreaming = false
            status = nil
        }
        if let meta, autoTitle == nil {
            autoTitle = meta.title
            sector = Sector.normalize(meta.sector, known: Library.shared.allSectors)
            onMeta?()
        }
        onTurnComplete?()
    }
}

// MARK: - Views

private let accent = Theme.accent.color
private let wash = Theme.accentWash.color
private let raised = Theme.surfaceRaised.color
private let hair = Theme.hairline.color
private let hairStrong = Theme.hairlineStrong.color
private let inkColor = Theme.ink.color
private let inkSecondary = Theme.inkSecondary.color
private let inkTertiary = Theme.inkTertiary.color
private let accentText = Theme.accentText.color

struct AskView: View {
    @ObservedObject var model: AskModel
    @FocusState private var fieldFocused: Bool
    @State private var threadHeight: CGFloat = 0
    /// How tall the answer area shows (a size set by hand gives it all the room left).
    @State private var threadViewport: CGFloat = 0
    /// Taller than this, the answer area scrolls (and follows the newest line).
    private var scrollLimit: CGFloat { model.isManualSize ? threadViewport : model.maxThreadHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            sourceRow
            docRow
            if let video = model.video, video.stage != .ready {
                VideoStageView(model: model, stage: video.stage)
                    .transition(.opacity)
            }
            if !model.turns.isEmpty { thread }
            if let fatal = model.fatal {
                Text(fatal)
                    .font(.geist(12))
                    .foregroundStyle(Theme.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                if model.turns.isEmpty && model.video == nil
                    && (model.videoHint || model.choosingSummary || model.doc != .none) {
                    chips.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
                // Video chats start with the summary; the question field appears once there's something to ask about.
                if model.video == nil || !model.turns.isEmpty { inputRow }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .foregroundStyle(inkColor)
        // Auto size: the chat's own width, and as tall as its content. A size set by hand: the window's size.
        .frame(width: model.isManualSize ? nil : model.width, alignment: .leading)
        .frame(maxWidth: model.isManualSize ? .infinity : nil, maxHeight: model.isManualSize ? .infinity : nil, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: !model.isManualSize)
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { h in model.onHeight?(h) }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top) // while the panel grows, clip the bottom, not both ends
        .background(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).fill(Theme.surfaceTint.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
            .strokeBorder(hair, lineWidth: 1))
        .overlay(alignment: .top) {
            // A small grip: the top of the chat drags it around the screen.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(hairStrong).frame(width: 28, height: 3).padding(.top, 5)
                .allowsHitTesting(false)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
        }
        .onChange(of: model.draft) { model.onActivity?() }
        .environment(\.merlinActivity, { [weak model] in model?.onActivity?() })
        .environment(\.merlinQuizFinished, { [weak model] result in model?.onQuizFinished?(result) })
        .environment(\.merlinFollowUp, { [weak model] question in model?.ask(display: question, prompt: question) })
        .onChange(of: model.focusToken) { fieldFocused = true }
        .onChange(of: model.isStreaming) {
            if !model.isStreaming { fieldFocused = true }
        }
    }

    /// What the chat is about, under the header: a video, a snip or the selected passage. A blank chat shows nothing.
    @ViewBuilder
    private var sourceRow: some View {
        if let video = model.video {
            VideoHeader(video: video, image: model.videoThumbnail)
        } else if model.snipImage != nil || !model.selection.isBlank {
            source
        }
    }

    @ViewBuilder
    private var source: some View {
        if let image = model.snipImage {
            HStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(hairStrong, lineWidth: 1))
                Text("Snip · \(model.selection.appName)")
                    .mLabelStyle()
                    .foregroundStyle(inkSecondary)
                    .lineLimit(1)
            }
        } else {
            // The selected passage: a 2 pt accent bar, italic, and a small mono label above it.
            QuoteMark(text: model.selection.text, label: "Selection · \(model.selection.appName)")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            if model.canToggleLearn { learnSwitch }
            Spacer(minLength: 0)
            // One star: it stars the chat and keeps the newest answer (`ChatStar`).
            let star = ChatStar.state(saveHistory: Settings.shared.saveHistory, starred: model.starred,
                                      canKeep: model.canKeep, newestIsKept: model.newestIsKept)
            if star.shown {
                HeaderButton(symbol: star.filled ? "star.fill" : "star", help: star.help, active: star.filled) {
                    if star.keeps { model.keepNewest() }
                    if star.togglesChat { model.onToggleStar?() }
                }
                .disabled(!star.keeps && !star.togglesChat)
                .accessibilityLabel(star.help)
            }
            HeaderButton(symbol: model.isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: model.isFilled ? "Back to its size" : "Fill the screen") {
                model.onToggleSize?()
            }
            if model.canMinimize {
                HeaderButton(symbol: "sidebar.right", help: "Put away at the right screen edge (keeps working)") {
                    model.onMinimize?()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            // Closing ends the chat. It stays in the Library (⌘⇧L) unless history is off, or "Delete chat when I close it" is on (then it goes to the Bin).
            HeaderButton(symbol: "xmark", help: Settings.shared.saveHistory
                         ? (Settings.shared.deleteChatOnClose
                            ? "Close this chat (it moves to the Bin, unless it's starred)"
                            : "Close this chat (it stays in your Library, \(KeybindStore.shared.current.chord(.history).display))")
                         : "Close this chat (history is off, so it won't be kept)") {
                model.onClose?()
            }
        }
        // Empty header space: a double-click fills the screen (the controls above it keep their own clicks).
        // A plain button, not a tap gesture: the window replays a header click to the view (see `ChatPanel.sendEvent`),
        // and a button answers a replayed click where a tap gesture does not.
        .background(Button(action: { model.onHeaderTap?() }) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain).focusable(false).accessibilityHidden(true))
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.turns) { turn in
                        let isLive = turn.id == model.turns.last?.id && !turn.done
                        TurnView(turn: turn, status: isLive ? model.status : nil, speech: model.speech,
                                 onMinimize: isLive ? { model.onMinimize?() } : nil, local: isLive && model.engine.isLocal)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                                    removal: .opacity))
                    }
                    if model.canGoDeeper || model.canKeep {
                        HStack(spacing: model.canMakeVisual ? 10 : 16) {
                            if model.canGoDeeper {
                                Button { model.goDeeper() } label: {
                                    Label("Go deeper", systemImage: "arrow.down.right")
                                }
                                .buttonStyle(GhostStyle())
                            }
                            if model.canMakeVisual {
                                Menu {
                                    Button("Diagram") { model.makeVisual(.diagram) }
                                    Button("Animate") { model.makeVisual(.video) }
                                } label: {
                                    Label("Visual", systemImage: "photo.on.rectangle.angled")
                                        .labelStyle(.iconOnly)
                                }
                                .accessibilityLabel("Visual")
                                .menuStyle(.button)
                                .buttonStyle(GhostStyle())
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Draw a diagram or animate a short video of this answer (one extra Claude call)")
                            }
                            if model.canKeep {
                                if let answer = model.turns.last?.answer {
                                    SaveToNoteButton(answer: answer)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    if model.visualStage != nil || model.visualError != nil {
                        TeachVisualStatus(stage: model.visualStage, error: model.visualError,
                                          cancel: { model.cancelVisual() }, dismiss: { model.visualError = nil })
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.visualsFolder, model.visualsFolder)
                .padding(.trailing, 6)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ThreadHeightKey.self, value: g.size.height)
                })
            }
            // Auto size: as tall as the answer, up to a cap. A size set by hand: whatever room the window leaves.
            .frame(height: model.isManualSize ? nil : min(max(threadHeight, 24), model.maxThreadHeight))
            .frame(minHeight: model.isManualSize ? 24 : nil, maxHeight: model.isManualSize ? .infinity : nil)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { threadViewport = $0 }
            .onPreferenceChange(ThreadHeightKey.self) { threadHeight = $0 }
            .onChange(of: threadHeight) {
                // Only fires when a new line starts, so this glides instead of jittering per letter.
                guard threadHeight > scrollLimit else { return }
                if let graphTurn = latestGraphTurn {
                    // A graph is the answer's centerpiece: keep the question and the top of the graph in view.
                    withAnimation(Motion.animation(Motion.functional)) { proxy.scrollTo(graphTurn, anchor: .top) }
                } else {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: model.canGoDeeper) {
                if model.canGoDeeper && threadHeight > scrollLimit && latestGraphTurn == nil {
                    scrollToBottom(proxy, after: 0.2)
                }
            }
        }
    }

    /// The newest turn, if its answer has a graph in it.
    private var latestGraphTurn: UUID? {
        guard let last = model.turns.last,
              last.answer.range(of: "<graph|<quiz|<board|<scene", options: [.caseInsensitive, .regularExpression]) != nil else { return nil }
        return last.id
    }

    /// Deferred so rows that are still animating in (like Go deeper) count toward the bottom.
    private func scrollToBottom(_ proxy: ScrollViewProxy, after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            proxy.scrollTo("bottom", anchor: .bottom) // pinned, flat: no animation while the answer streams
        }
    }


    private var chips: some View {
        Group {
            if model.choosingSummary {
                summaryChoices
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 10)), removal: .opacity))
            } else {
                quickQuestions
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -10)), removal: .opacity))
            }
        }
    }

    /// After tapping Summarize: how to summarize it.
    private var summaryChoices: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.animation(Motion.functional)) { model.choosingSummary = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.mLabel.weight(.semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSecondary.color)
                .help("Back")
                Text(model.selection.isBlank ? "Summarize what's on your screen by its…" : "Summarize it by its…")
                    .mLabelStyle()
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(Prompts.Summary.allCases.enumerated()), id: \.element) { index, kind in
                    Button { model.summarize(kind) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .buttonStyle(ChipStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var docRow: some View {
        switch model.doc {
        case .none, .offered:
            EmptyView()
        case .loading(let name):
            HStack(spacing: 8) {
                ShimmerText(text: "Reading \(name)…")
            }
            .transition(.opacity)
        case .ready(let name, let detail):
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(inkSecondary)
                Text(name).font(.geist(12, .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.geist(12, .medium)).foregroundStyle(Theme.inkSecondary.color).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.onDropDocument?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary.color) }
                    .buttonStyle(.plain).help("Stop reading this document")
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(raised))
            .transition(.opacity)
        case .failed(let message):
            Text(message).font(.geist(12, .medium)).foregroundStyle(Theme.alert.color).transition(.opacity)
        }
    }

    private var quickQuestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                if case .offered(let name) = model.doc {
                    Button { model.onUseDocument?() } label: {
                        Label("Ask about “\(name)”", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(ProminentChipStyle())
                    .help("Merlin reads the whole page or file on your Mac and sends Claude only the parts that match your question")
                }
                if case .ready = model.doc {
                    Button { model.ask(display: "Summarize this document", prompt: Prompts.docSummary) } label: {
                        Label("Summarize document", systemImage: "doc.plaintext")
                    }
                    .buttonStyle(ProminentChipStyle())
                    Button { model.ask(display: "Key terms in this document", prompt: Prompts.docTerms) } label: {
                        Label("Key terms", systemImage: "tag")
                    }
                    .buttonStyle(ProminentChipStyle())
                }
                if model.videoHint {
                    Button { model.onSummarizeVideo?() } label: {
                        Label("Summarize video", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(ProminentChipStyle())
                }
            }
        }
    }

    /// Learn mode as a small switch at the top of the chat. Same shape and motion as the Settings switch (`LSSwitch`),
    /// at about three quarters of its size: a rounded-square track in ink when on, a knob that springs across without bounce.
    /// Never the accent, which is kept for Send.
    private var learnSwitch: some View {
        let on = model.learnMode
        return Button { model.toggleLearn() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(on ? inkColor : hairStrong)
                    .frame(width: 28, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(on ? Theme.canvas.color : Theme.inkTertiary.color)
                            .frame(width: 11, height: 11)
                            .offset(x: on ? 6 : -6)
                    }
                Text("Learn").font(.geist(12, .medium))
                    .foregroundStyle(on ? inkColor : inkSecondary)
            }
            .animation(Motion.still ? nil : Motion.animation(Motion.snappy), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(on ? "Learn mode is on: answers explain more, in simpler steps, and highlight the key words to remember. Click to turn it off."
                 : "Turn on Learn mode: answers explain more, in simpler steps, and highlight the key words to remember.")
        .accessibilityLabel("Learn mode")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private var placeholder: String {
        switch model.turns.count {
        case 0:
            if model.selection.isBlank { return "Ask anything…" }
            return model.snipImage == nil ? "What's confusing about this?" : "What do you want to know about this?"
        case 1...3: return "Ask a follow-up…"
        default: return "Still stuck? This might deserve your main chat."
        }
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty { attachmentStrip }
            inputField
        }
    }

    /// The screenshots waiting to go with the next question.
    private var attachmentStrip: some View {
        HStack(spacing: 8) {
            ForEach(model.attachments) { item in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumb = item.thumb {
                            Image(nsImage: thumb).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(raised)
                        }
                    }
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(hair, lineWidth: 1))
                    Button {
                        withAnimation(Motion.animation(Motion.small)) { model.attachments.removeAll { $0.id == item.id } }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(Theme.ink.color, Theme.canvas.color)
                    }
                    .buttonStyle(.plain).offset(x: 5, y: -5)
                    .help("Remove this screenshot").accessibilityLabel("Remove screenshot")
                }
            }
            Text("Goes with your next question")
                .font(.geist(12, .medium)).foregroundStyle(inkSecondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $model.draft)
                .textFieldStyle(.plain)
                .font(.geist(13))
                .focused($fieldFocused)
                .onSubmit { model.submit() }
            Button { model.onAttachScreenshot?() } label: {
                Image(systemName: "camera.viewfinder").font(.system(size: 14, weight: .regular)).foregroundStyle(inkSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .help("Add a screenshot of your screen as context (or tap Shift twice)")
            .accessibilityLabel("Add screenshot")
            Button { model.submit() } label: {
                SendGlyph(busy: model.isStreaming, canSubmit: model.canSubmit)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .disabled(!model.canSubmit)
            .help(model.turns.isEmpty ? "Ask (empty = explain simpler)" : "Ask")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(fieldFocused ? hairStrong : hair, lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            // Focus: a 1 pt accent underline sweeps in from the left.
            GeometryReader { g in
                Rectangle().fill(accent).frame(width: fieldFocused ? g.size.width : 0, height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .allowsHitTesting(false)
        }
        .animation(Motion.animation(Motion.small), value: fieldFocused)
    }
}

/// The selected passage: a 2 pt neutral bar on the left, Geist Italic in secondary ink, and a small sentence-case
/// "Selection · App" label above it. Static: nothing animates on first paint.
struct QuoteMark: View {
    let text: String
    var label: String? = nil
    var lines: Int? = 2
    @State private var drawn: Bool

    /// `animated: false` draws the bar already in place (the library has no sweep). `lines: nil` shows the whole quote.
    init(text: String, label: String? = nil, animated: Bool = true, lines: Int? = 2) {
        self.text = text
        self.label = label
        self.lines = lines
        _drawn = State(initialValue: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .mLabelStyle()
                    .lineLimit(1)
            }
            Text(text)
                .font(.mQuote)
                .foregroundStyle(Theme.inkSecondary.color)
                .lineSpacing(3)
                .lineLimit(lines)
                .truncationMode(.tail)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        // Neutral: lime is kept for the one primary action.
                        Rectangle().fill(inkTertiary)
                            .frame(width: 2, height: drawn ? g.size.height : 0)
                    }
                    .frame(width: 2)
                }
        }
        .help(text)
    }
}

/// The send button's face: an arrow, which morphs into a small square while an answer streams. There is no stop action yet
/// (the only way to stop an answer is to close the chat), so the square is a state indicator and the button stays disabled.
private struct SendGlyph: View {
    let busy: Bool
    let canSubmit: Bool

    var body: some View {
        ZStack {
            Image(systemName: "arrow.up")
                .font(.geist(11, .semibold))
                .opacity(busy ? 0 : 1)
                .scaleEffect(busy || Motion.reduceMotion ? 0.7 : 1)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: 8, height: 8)
                .opacity(busy ? 1 : 0)
                .scaleEffect(busy || Motion.reduceMotion ? 1 : 0.7)
        }
        .foregroundStyle(canSubmit ? Theme.onAccent.color : inkTertiary)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(canSubmit ? accent : hair))
        .animation(Motion.animation(Motion.small), value: busy)
        .animation(Motion.animation(Motion.small), value: canSubmit)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    /// Lit up (the star of a starred chat).
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.geist(10.5, .semibold))
                .foregroundStyle(hovering || active ? inkColor : inkSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(hovering ? hairStrong : Color.clear))
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .onHover { h in withAnimation(Motion.animation(Motion.small)) { hovering = h } }
        .help(help)
    }
}

private struct TurnView: View {
    let turn: AskModel.Turn
    let status: String?
    let speech: SpeechStore
    let onMinimize: (() -> Void)?
    /// The live answer comes from the local model (Local mode).
    var local = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(turn.question)
                .font(.geist(13, .semibold))
                .foregroundStyle(inkColor)
                .fixedSize(horizontal: false, vertical: true)
            if turn.answer.isEmpty && !turn.done {
                HStack(spacing: 7) {
                    ThinkingIndicator(status: status, local: local || turn.localModel != nil)
                    Spacer(minLength: 6)
                    if let onMinimize {
                        Button(action: onMinimize) {
                            Label("Minimize", systemImage: "sidebar.right")
                        }
                        .buttonStyle(GhostStyle()) // quiet: the status on the left is the main thing while it thinks
                        .help("Put this chat away in the panel at the right screen edge. It keeps working, and a dot there shows when it's done.")
                    }
                }
                .transition(.opacity)
            } else {
                AnswerView(text: turn.answer, streaming: !turn.done, speech: speech)
                    .foregroundStyle(turn.isError ? Theme.alert.color : inkColor)
                    .transition(.opacity)
                if let local = turn.localModel {
                    Label(Settings.isClaudeModel(local) ? "Answered by \(EngineLabel.full(local))" : "Answered on your Mac · \(local)",
                          systemImage: Settings.isClaudeModel(local) ? "hare" : "laptopcomputer")
                        .font(.geist(12, .medium))
                        .foregroundStyle(Theme.inkSecondary.color)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// Status text with a soft highlight sweeping across it, like it's thinking.
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = 0

    var body: some View {
        label
            .foregroundStyle(Theme.inkSecondary.color)
            .overlay {
                if !Motion.reduceMotion { GeometryReader { g in
                    LinearGradient(colors: [.clear, inkColor, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(36, g.size.width * 0.35))
                        .offset(x: -g.size.width * 0.35 + phase * g.size.width * 1.35)
                }
                .mask(label)
                .allowsHitTesting(false) }
            }
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: text)
            .onAppear {
                guard !Motion.reduceMotion, !Motion.still else { return } // Reduce Motion: plain secondary text
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }

    private var label: some View {
        Text(text)
            .mLabelStyle()
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Inline markdown plus ``` code fences — enough for short answers.
struct MarkdownText: View {
    let text: String
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    Text(seg.text)
                        .font(.mCode)
                        .foregroundStyle(inkColor)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(raised))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(hair, lineWidth: 1))
                } else {
                    // Tables first (a table's lines are not prose), then display equations and prose as before.
                    ForEach(Array(MarkdownTable.blocks(seg.text, streaming: streaming).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .table(let table):
                            TableCard(table: table, streaming: streaming)
                        case .text(let text):
                            ForEach(Array(MathRender.blocks(text).enumerated()), id: \.offset) { _, piece in
                                switch piece {
                                case .block(let latex): MathBlock(latex: latex)
                                case .text(let t), .inline(let t), .auto(_, let t): prose(t)
                                }
                            }
                        }
                    }
                }
            }
        }
        .tint(accentText)
        .textSelection(.enabled)
    }

    @ViewBuilder private func prose(_ text: String) -> some View {
        let tidy = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let parts = tidy.components(separatedBy: "Sources:")
        let body = parts.count > 1 ? parts.dropLast().joined(separator: "Sources:") : tidy
        let sources = parts.count > 1 ? (parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        ForEach(Array(body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
            if !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(Self.lines(para).enumerated()), id: \.offset) { _, line in
                        if let marker = line.marker {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(marker).font(.mBody).foregroundStyle(inkSecondary)
                                    .frame(minWidth: 12, alignment: .trailing)
                                MathLine(text: line.text, streaming: streaming)
                            }
                        } else {
                            MathLine(text: line.text, streaming: streaming)
                        }
                    }
                }
            }
        }
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sources")
                    .mLabelStyle()
                let links = Self.sourceLinks(sources)
                if links.isEmpty {
                    Text(Self.inline(sources))
                        .font(.geist(12))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayout(spacing: 12) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                            SourceChip(link: link)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// A paragraph's lines: list items ("- x", "• x", "1. x") split into a marker and text so wrapped lines hang
    /// under the text; other consecutive lines stay together as one block.
    static func lines(_ para: String) -> [(marker: String?, text: String)] {
        var out: [(marker: String?, text: String)] = []
        for raw in para.components(separatedBy: "\n") {
            if let m = raw.range(of: #"^\s*(?:[-*+•]|\d{1,2}[.)])\s+(?=\S)"#, options: .regularExpression) {
                let head = raw[m].trimmingCharacters(in: .whitespaces)
                let marker = head.first?.isNumber == true ? head : "•"
                out.append((marker, String(raw[m.upperBound...])))
            } else if let m = raw.range(of: #"^(?: {2,}|\t)\s*(?=\S)"#, options: .regularExpression) {
                // An indented line (a list step's continuation): an empty marker lines it up with the step's text,
                // wrapped lines included, instead of leading spaces that only move its first line.
                out.append(("", String(raw[m.upperBound...])))
            } else if let last = out.last, last.marker == nil {
                out[out.count - 1].text += "\n" + raw
            } else {
                out.append((nil, raw))
            }
        }
        return out
    }

    static func segments(_ text: String) -> [(text: String, isCode: Bool)] {
        let parts = text.components(separatedBy: "```")
        return parts.enumerated().compactMap { i, part in
            let isCode = i % 2 == 1
            var body = part
            if isCode, let nl = body.firstIndex(of: "\n") {
                let firstLine = body[body.startIndex..<nl]
                if !firstLine.contains(" ") && firstLine.count < 20 { body = String(body[body.index(after: nl)...]) }
            }
            let trimmed = body.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : (trimmed, isCode)
        }
    }

    /// While text is still arriving, hide half-typed markdown so it doesn't flash raw symbols:
    /// close an open **bold** or `code`, and show a link's text until its URL finishes.
    static func softenPartial(_ s: String) -> String {
        var t = s
        while t.hasSuffix("*") || t.hasSuffix("`") || t.hasSuffix("[") { t.removeLast() }
        if let r = t.range(of: #"\[([^\]\n]*)\]\([^)\s]*$"#, options: .regularExpression) {
            let linkText = t[r].dropFirst().prefix { $0 != "]" }
            t.replaceSubrange(r, with: linkText)
        }
        if t.components(separatedBy: "**").count % 2 == 0 { t += "**" }
        if t.components(separatedBy: "`").count % 2 == 0 { t += "`" }
        return t
    }

    /// "[Swift book](https://…), [Apple](https://…)" as chips: the site's name (no www.) with the link behind it.
    static func sourceLinks(_ s: String) -> [(title: String, domain: String, url: URL)] {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\((https?://[^)\s]+)\)"#) else { return [] }
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let url = URL(string: ns.substring(with: m.range(at: 2))), let host = url.host else { return nil }
            return (ns.substring(with: m.range(at: 1)), host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, url)
        }
    }

    /// A parsed line cut at Highlights' stand-in characters (which are dropped): each stretch with whether a mark covers it.
    /// `inside` carries a mark that is open at the start (an equation came in the middle) and out again at the end.
    static func highlightRuns(_ a: AttributedString, inside: inout Bool) -> [(text: AttributedString, marked: Bool)] {
        var out: [(text: AttributedString, marked: Bool)] = []
        var start = a.startIndex
        var i = a.startIndex
        while i < a.endIndex {
            let next = a.characters.index(after: i)
            let ch = a.characters[i]
            if ch == Highlights.open || ch == Highlights.close {
                if start < i { out.append((AttributedString(a[start..<i]), inside)) }
                inside = ch == Highlights.open
                start = next
            }
            i = next
        }
        if start < a.endIndex { out.append((AttributedString(a[start..<a.endIndex]), inside)) }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Inline-only parsing leaves "- item" as a hyphen; show list items with real bullets.
        let bulleted = s.replacingOccurrences(of: #"(?m)^([ \t]*)[-*+] (?=\S)"#, with: "$1• ", options: .regularExpression)
        let pretty = MathPretty.prettify(bulleted) // LaTeX → symbols; u_y, t^2 marked for real sub/superscripts
        var out = (try? AttributedString(markdown: pretty, options: opts)) ?? AttributedString(pretty)
        MathPretty.style(&out)
        // Inline code: SF Mono 13 on the raised surface.
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .mCode
            out[run.range].backgroundColor = Theme.surfaceRaised.color
        }
        return out
    }
}

/// A Markdown table in an answer: Merlin's surface, a hairline between rows, the header in smaller secondary ink, the first
/// column in medium weight, 10 pt cell padding, text wrapping inside its cell. Columns share the width by content (90 pt
/// at least); a table that still needs more scrolls sideways inside its own card. "Copy table" shows on hover.
struct TableCard: View {
    let table: MarkdownTable
    var streaming = false
    /// Pictures only: show the Copy table button as if the pointer were on the table.
    var forceHover = false
    @State private var available: CGFloat = 0
    @State private var hovering = false
    @State private var copied = false
    @State private var atEnd = false
    @Environment(\.colorScheme) private var scheme

    static let padding: CGFloat = 10
    static let bodyFont = Font.geist(14), firstFont = Font.geist(14, .medium), headerFont = Font.geist(12, .medium)

    var body: some View {
        let widths = Self.widths(table, available: available, dark: scheme == .dark)
        let total = widths.reduce(0, +)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Measures the width the answer gives the table.
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { available = $0 }
            // Before the width is known (first layout pass) the grid also sits in the scroll view, so it can never push the
            // chat wider than itself.
            if available <= 0 || total > available + 0.5 {
                ScrollView(.horizontal, showsIndicators: true) { grid(widths) }
                    .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.x + $0.containerSize.width >= $0.contentSize.width - 2 }) { _, end in
                        atEnd = end
                    }
                    // A soft fade at the right edge says there is more to the side, until the end is reached.
                    .overlay(alignment: .trailing) {
                        if !atEnd {
                            LinearGradient(colors: [Theme.surface.color.opacity(0), Theme.surface.color], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 28)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                grid(widths)
            }
        }
        .background(shape.fill(Theme.surface.color))
        .clipShape(shape)
        .overlay(shape.strokeBorder(hair, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if (hovering || forceHover) && !streaming {
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy table", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(TableCopyStyle())
                .padding(5)
                .transition(.opacity)
            }
        }
        .animation(Motion.still ? nil : Motion.animation(Motion.small), value: hovering)
        .onHover { hovering = $0 }
    }

    private func grid(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(table.padded(table.header), widths, header: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(hair).frame(height: 1)
                row(table.padded(cells), widths, header: false)
            }
        }
        .frame(width: widths.reduce(0, +), alignment: .leading)
    }

    private func row(_ cells: [String], _ widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { c, cell in
                MathLine(text: Self.cellText(cell), streaming: streaming,
                         font: header ? Self.headerFont : (c == 0 ? Self.firstFont : Self.bodyFont))
                    .foregroundStyle(header ? inkSecondary : inkColor)
                    .frame(width: max(0, (widths.indices.contains(c) ? widths[c] : MarkdownTable.minimumColumn) - Self.padding * 2),
                           alignment: .topLeading)
                    .padding(Self.padding)
            }
        }
    }

    /// `<br>` inside a cell is a line break.
    static func cellText(_ cell: String) -> String {
        cell.replacingOccurrences(of: #"\s*<br\s*/?>\s*"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.tsv, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    /// Column widths for the table at this width: content measured in the cell fonts (formulas as their typeset images).
    static func widths(_ table: MarkdownTable, available: CGFloat, dark: Bool) -> [CGFloat] {
        let n = table.columnCount
        var natural = [CGFloat](repeating: 0, count: n), minimum = [CGFloat](repeating: 0, count: n)
        for (r, cells) in ([table.header] + table.rows).enumerated() {
            for (c, cell) in table.padded(cells).enumerated() {
                let font: NSFont = r == 0 ? .merlin(12, .medium) : (c == 0 ? .merlin(14, .medium) : .merlin(14))
                let m = measure(cell, font: font, dark: dark)
                natural[c] = max(natural[c], m.line + padding * 2)
                minimum[c] = max(minimum[c], m.word + padding * 2)
            }
        }
        return MarkdownTable.columnWidths(natural: natural, minimum: minimum, available: available)
    }

    /// A cell's width on one line, and its widest piece that can't wrap (a long word counts up to 130 pt: it can break).
    private static func measure(_ cell: String, font: NSFont, dark: Bool) -> (line: CGFloat, word: CGFloat) {
        let spans = MarkdownTable.mathSpans(cell)
        let words = MarkdownTable.plainCell(spans.rest)
        func width(_ s: String) -> CGFloat { ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width * 1.06) }
        // A cell with <br> is as wide as its longest line.
        var line = cellText(spans.rest).components(separatedBy: "\n").map { width(MarkdownTable.plainCell($0)) }.max() ?? 0
        var widest: CGFloat = 0
        for word in words.split(separator: " ") { widest = max(widest, min(130, width(String(word)))) }
        for latex in spans.latex {
            let w = MathRender.render(latex, size: 15, display: false, dark: dark).image?.size.width
                ?? width(MathRender.fallbackText(latex))
            // The typeset image sits in text with a little side bearing: allow for it, or the formula touches the edge.
            line += w + 8
            widest = max(widest, w + 8)
        }
        return (line, widest)
    }
}

/// The quiet Copy table button: secondary ink on the surface, ink on hover, dips to 0.97 when pressed.
private struct TableCopyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CopyBody(configuration: configuration) }

    private struct CopyBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.geist(12, .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(hovering ? inkColor : inkSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surface.color))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(hair, lineWidth: 1))
                .contentShape(Rectangle())
                .pressAndHover(configuration.isPressed, $hovering)
        }
    }
}

/// A source as a plain text link: the site's name, underlined on hover.
private struct SourceChip: View {
    let link: (title: String, domain: String, url: URL)
    @State private var hovering = false

    var body: some View {
        Link(destination: link.url) {
            Text(link.domain)
                .font(.geist(12, .medium))
                .foregroundStyle(hovering ? inkColor : inkSecondary)
                .underline(hovering)
        }
        .animation(Motion.animation(Motion.small), value: hovering)
        .onHover { hovering = $0 }
        .help(link.title)
    }
}

/// A quiet text action (no box): grey, ink on hover, dips to 0.97 when pressed.
private struct GhostStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.geist(12, .semibold))
                .foregroundStyle(hovering && enabled ? inkColor : inkSecondary)
                .contentShape(Rectangle())
                .pressAndHover(configuration.isPressed, $hovering)
        }
    }
}

/// "Save to note" under an answer: a small menu of your named notes (most recently changed first) and "New note…". The
/// answer's own Markdown is added (tables stay tables; see `Answer.noteMarkup` for Merlin's tags). No Claude call.
struct SaveToNoteButton: View {
    let answer: String
    var library: Library = .shared
    @State private var open = false
    @State private var saved: String?

    var body: some View {
        Button { open = true } label: {
            Label(saved.map { "Saved to \($0)" } ?? "Save to note", systemImage: saved == nil ? "note.text.badge.plus" : "checkmark")
                .lineLimit(1)
        }
        .buttonStyle(GhostStyle())
        .help("Add this answer, tables and all, to a named note")
        .accessibilityLabel("Save to note")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SaveToNoteMenu(sheets: library.sheets.map { (id: $0.id, name: $0.name) },
                           onPick: { id in finish(SheetActions.saveAnswer(answer, toSheet: id, library: library)) },
                           onNew: { name in finish(SheetActions.saveAnswer(answer, toNewSheet: name, library: library)) })
        }
    }

    private func finish(_ sheet: Note?) {
        open = false
        guard let sheet else { return }
        withAnimation(Motion.animation(Motion.small)) { saved = sheet.name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(Motion.animation(Motion.small)) { saved = nil }
        }
    }
}

/// The menu itself (its own view, so pictures can draw it without a popover).
struct SaveToNoteMenu: View {
    let sheets: [(id: UUID, name: String)]
    let onPick: (UUID) -> Void
    let onNew: (String) -> Void
    @State var naming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Save to note").mLabelStyle().padding(.horizontal, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sheets, id: \.id) { s in
                        SaveToNoteRow(symbol: "note.text", title: s.name) { onPick(s.id) }
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            if !sheets.isEmpty { Rectangle().fill(Theme.hairline.color).frame(height: 1).padding(.vertical, 4) }
            if naming {
                NewSheetField(onCreate: onNew).padding(.horizontal, 4).padding(.vertical, 2)
            } else {
                SaveToNoteRow(symbol: "plus", title: "New note…") {
                    withAnimation(Motion.animation(Motion.small)) { naming = true }
                }
            }
        }
        .padding(8)
        .frame(width: 280)
    }
}

private struct SaveToNoteRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(inkSecondary).frame(width: 16)
                Text(title).font(.geist(13)).foregroundStyle(inkColor).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(hovering ? Theme.surfaceSelected.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}

/// Buttons dip slightly when pressed.
private struct PressStyle: ButtonStyle {
    /// 0.97 for buttons with a label; small icon-only buttons dip further, or the press would not show.
    var scale: CGFloat = Motion.pressScale
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? scale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

/// Thumbnail (or an icon), title, and channel · length · language.
private struct VideoHeader: View {
    let video: VideoState
    let image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if video.thumbnail != nil {
                ZStack {
                    raised
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                    }
                }
                .animation(Motion.animation(Motion.functional), value: image != nil)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.geist(11, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.45)))
                )
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(raised)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: video.icon).font(.geist(20, .semibold)).foregroundStyle(inkSecondary))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.geist(13, .semibold))
                    .lineLimit(2)
                if let subtitle = video.subtitle {
                    Text(subtitle)
                        .font(.geist(12, .medium))
                        .foregroundStyle(Theme.inkSecondary.color)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// What a video agent shows before (and while) its summary is being written.
private struct VideoStageView: View {
    @ObservedObject var model: AskModel
    let stage: VideoState.Stage

    var body: some View {
        switch stage {
        case .fetching:
            ShimmerText(text: "Reading the video's transcript…")
        case .chooseLanguage:
            VStack(alignment: .leading, spacing: 8) {
                Text("What language is spoken in it?")
                    .font(.geist(12))
                    .foregroundStyle(Theme.inkSecondary.color)
                HStack(spacing: 6) {
                    ForEach(SpokenLanguage.allCases, id: \.self) { language in
                        Button(language.title) { model.onChooseLanguage?(language) }
                            .buttonStyle(ChipStyle())
                    }
                }
            }
        case .preparingModel(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ShimmerText(text: "Getting Apple's speech model for this language (first time only)…")
                ProgressView(value: fraction).tint(accent)
            }
        case .listening(let elapsed, let caption):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PulsingDot()
                    Text("Listening · \(VideoTranscript.clock(elapsed))")
                        .font(.mNum.weight(.semibold))
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Button { model.onStopListening?() } label: {
                        Label("Stop & summarize", systemImage: "stop.fill")
                    }
                    .buttonStyle(ProminentChipStyle())
                }
                Text(caption.isEmpty ? "Play your video. Merlin hears your Mac's sound, even with headphones."
                                     : "…" + String(caption.suffix(220)))
                    .font(.geist(12))
                    .foregroundStyle(Theme.inkSecondary.color)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(Motion.animation(Motion.small), value: caption)
                Text("You can minimize this; it keeps listening.")
                    .font(.geist(12, .medium))
                    .foregroundStyle(Theme.inkTertiary.color)
            }
        case .transcribing(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ShimmerText(text: "Transcribing… \(Int(fraction * 100))%")
                ProgressView(value: fraction).tint(accent)
            }
        case .finishing:
            ShimmerText(text: "Finishing the transcript…")
        case .chooseStyle(let language):
            VStack(alignment: .leading, spacing: 8) {
                Text("This video is in \(language). How should I summarize it?")
                    .font(.geist(12))
                FlowLayout(spacing: 6) {
                    ForEach(SummaryStyle.allCases, id: \.self) { style in
                        Button(style.label(language: language)) { model.onChooseStyle?(style) }
                            .buttonStyle(ChipStyle())
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.geist(12))
                    .foregroundStyle(Theme.alert.color)
                    .fixedSize(horizontal: false, vertical: true)
                if model.onListenInstead != nil {
                    Button { model.onListenInstead?() } label: {
                        Label("Listen along instead", systemImage: "waveform")
                    }
                    .buttonStyle(ChipStyle())
                }
            }
        case .ready:
            EmptyView()
        }
    }
}

/// A softly pulsing red "recording" dot.
private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.alert.color)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Lays chips out left to right and wraps onto the next line when they don't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current.items.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// A filled accent button, for the one action that matters right now.
private struct ProminentChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentBody(configuration: configuration)
    }

    private struct ProminentBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.geist(12, .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(accent))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.onAccent.color.opacity(hovering ? 0.08 : 0)))
                .foregroundStyle(Theme.onAccent.color)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .pressAndHover(configuration.isPressed, $hovering)
        }
    }
}

private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.geist(12, .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(configuration.isPressed || hovering ? hairStrong : raised))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(hair, lineWidth: 1))
                .foregroundStyle(inkColor)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .pressAndHover(configuration.isPressed, $hovering)
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ThreadHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// The shared button feel: dips to 0.97 while pressed, and tracks whether the pointer is over it.
    func pressAndHover(_ isPressed: Bool, _ hovering: Binding<Bool>) -> some View {
        scaleEffect(isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: isPressed)
            .animation(Motion.animation(Motion.small), value: hovering.wrappedValue)
            .onHover { hovering.wrappedValue = $0 }
    }
}


// MARK: - The one star in the chat header

/// The header's one star does two jobs: it stars the chat (top of the Library, safe from delete) and keeps the newest
/// answer in the notebook. It is full only when both are done (or when the one possible job is done).
enum ChatStar {
    struct State: Equatable {
        let shown: Bool
        let filled: Bool
        /// A click keeps the newest answer.
        let keeps: Bool
        /// A click stars or unstars the chat.
        let togglesChat: Bool
        let help: String
    }

    static func state(saveHistory: Bool, starred: Bool, canKeep: Bool, newestIsKept: Bool) -> State {
        let needsKeep = canKeep && !newestIsKept
        guard saveHistory else {
            // No chat history: the star only keeps the answer.
            return State(shown: canKeep, filled: canKeep && newestIsKept, keeps: needsKeep, togglesChat: false,
                         help: needsKeep ? "Keep this answer" : "Kept")
        }
        if starred && !needsKeep {
            return State(shown: true, filled: true, keeps: false, togglesChat: true, help: "Unstar this chat (kept answers stay in your Library)")
        }
        if starred {
            return State(shown: true, filled: false, keeps: true, togglesChat: false, help: "Keep the newest answer (this chat is starred)")
        }
        return State(shown: true, filled: false, keeps: needsKeep, togglesChat: true,
                     help: needsKeep ? "Star this chat and keep this answer" : "Star this chat (keeps it at the top of your Library and safe from delete)")
    }
}
