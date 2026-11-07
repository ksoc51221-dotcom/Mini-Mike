import SwiftUI

final class AskModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
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
    /// The header's ⤢ toggle: 50% wider, with a 50% taller answer area.
    @Published var isLarge = Settings.shared.largePopup
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
    /// Learn mode, for this chat: the first question waits for a hint level. Off unless the panel turns it on.
    @Published var learnMode = false
    /// The hint level this chat is at (nil: not a Learn mode chat, or no level picked yet).
    @Published var hintLevel: Int?
    /// A question they typed, waiting for its hint level.
    @Published var hintQuestion: String?
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
    var onQuizFinished: ((QuizResult) -> Void)?
    var onAsk: ((_ prompt: String) -> Void)?
    /// The Learn toggle was used: remember it for the next chat.
    var onLearnChange: ((Bool) -> Void)?
    /// "Ask Claude" on a local answer: the newest question goes to Claude instead.
    var onAskClaude: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onToggleSize: (() -> Void)?
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
    var width: CGFloat { AskPanelController.width * (isLarge ? Self.largeScale : 1) }
    var maxThreadHeight: CGFloat { 360 * (isLarge ? Self.largeScale : 1) }

    var canGoDeeper: Bool {
        guard let last = turns.last else { return false }
        // Below the full working, "Go deeper" would skip past the hint they chose, so the next level takes its place.
        return last.done && !last.isError && !isStreaming && last.question != Self.deeperLabel
            && last.question != Prompts.quizLabel && !last.answer.contains("<event>") && (hintLevel ?? 4) >= 4
    }

    /// Learn mode can be set while nothing has been asked. A video or a document that's been read has its own way of working.
    var canToggleLearn: Bool {
        guard turns.isEmpty, video == nil, selection.video == nil else { return false }
        switch doc {
        case .loading, .ready: return false
        default: return true
        }
    }

    private var learnApplies: Bool { learnMode && canToggleLearn }

    /// The toggle on the new-chat screen. Later chats start from this choice; a chat already under way keeps its own mode.
    func toggleLearn() {
        guard canToggleLearn else { return }
        withAnimation(Motion.animation(Motion.functional)) {
            learnMode.toggle()
            // A question waiting for a level goes back in the field rather than being sent by surprise.
            if !learnMode, let question = hintQuestion {
                draft = question
                hintQuestion = nil
            }
        }
        onLearnChange?(learnMode)
    }

    /// Show the four hint levels in place of the quick questions. With nothing highlighted, that waits for a typed question.
    var hintPicking: Bool { learnApplies && (!selection.isBlank || hintQuestion != nil) }

    /// The newest answer is a hint below the full working, so the next level can be asked for.
    var canHintUp: Bool {
        guard let level = hintLevel, level < 4, let last = turns.last else { return false }
        return last.done && !last.isError && !isStreaming && fatal == nil
    }

    func pickHint(_ level: Int) {
        guard canSubmit, Prompts.hintLevels.contains(level) else { return }
        let question = hintQuestion
        hintQuestion = nil
        hintLevel = level
        ask(display: Prompts.hintLabel(level, question: question), prompt: Prompts.hint(level, question: question))
    }

    func hintUp() {
        guard canHintUp, let level = hintLevel else { return }
        hintLevel = level + 1
        ask(display: Prompts.hintLabel(level + 1), prompt: Prompts.hint(level + 1, movingUp: true))
    }

    /// This chat isn't a problem to work through: back to the usual quick questions, and any typed question is sent as it is.
    func skipHints() {
        let question = hintQuestion
        hintQuestion = nil
        withAnimation(Motion.animation(Motion.functional)) { learnMode = false }
        if let question { ask(display: question, prompt: question) }
    }

    static let deeperLabel = "Go deeper"

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
        if learnApplies {
            if q.isEmpty {
                if hintPicking { pickHint(Prompts.hintLevels.lowerBound); return }
            } else if CalendarIntent.parse(q) == nil && VideoIntent.parse(q) == nil {
                // Calendar and video requests aren't problems to hint at, so only real questions wait for a level.
                draft = ""
                withAnimation(Motion.animation(Motion.functional)) { hintQuestion = q }
                return
            }
        }
        if q.isEmpty {
            guard turns.isEmpty else { return }
            ask(display: Prompts.emptySubmit, prompt: Prompts.emptySubmit)
        } else {
            draft = ""
            ask(display: q, prompt: q)
        }
    }

    func ask(display: String, prompt: String) {
        guard canSubmit else { return }
        withAnimation(Motion.animation(Motion.functional)) {
            turns.append(Turn(question: display))
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
        // The hidden <meta> line names and files the chat; take it off the answer.
        let meta = Answer.meta(in: turns[i].answer)
        withAnimation(Motion.animation(Motion.functional)) {
            if meta != nil { turns[i].answer = Answer.withoutMeta(turns[i].answer) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
                if model.hintPicking {
                    hintPicker.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                } else if model.turns.isEmpty && model.video == nil
                    && (!model.selection.isBlank || model.videoHint || model.seesScreen || model.doc != .none) {
                    chips.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
                // Video chats start with the summary; the question field appears once there's something to ask about.
                if model.video == nil || !model.turns.isEmpty { inputRow }
                footer
            }
        }
        .padding(14)
        .foregroundStyle(inkColor)
        .frame(width: model.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        .environment(\.marginActivity, { [weak model] in model?.onActivity?() })
        .environment(\.marginQuizFinished, { [weak model] result in model?.onQuizFinished?(result) })
        .onChange(of: model.focusToken) { fieldFocused = true }
        .onChange(of: model.isStreaming) {
            if !model.isStreaming { fieldFocused = true }
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
        } else if model.selection.isBlank {
            HStack(spacing: 6) {
                Text("Ask · \(model.selection.appName)")
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
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let video = model.video { VideoHeader(video: video, image: model.videoThumbnail) } else { source }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HeaderButton(symbol: model.isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: model.isLarge ? "Make smaller" : "Make bigger (50%)") {
                model.onToggleSize?()
            }
            if model.canMinimize {
                HeaderButton(symbol: "sidebar.right", help: "Put away in the sidebar (keeps working)") {
                    model.onMinimize?()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            // Closing ends the chat but never deletes it: it stays in the Library (⌘⇧L) unless history is off.
            HeaderButton(symbol: "xmark", help: Settings.shared.saveHistory
                         ? "Close this chat (it stays in your Library, ⌘⇧L)"
                         : "Close this chat (history is off, so it won't be kept)") {
                model.onClose?()
            }
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.turns) { turn in
                        let isLive = turn.id == model.turns.last?.id && !turn.done
                        TurnView(turn: turn, status: isLive ? model.status : nil, speech: model.speech,
                                 onMinimize: isLive ? { model.onMinimize?() } : nil)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                                    removal: .opacity))
                    }
                    if model.canHintUp || model.canGoDeeper || model.canAskClaude || model.canKeep {
                        HStack(spacing: 16) {
                            if model.canHintUp, let level = model.hintLevel {
                                Button { model.hintUp() } label: {
                                    Label("Hint level \(level + 1)", systemImage: "arrow.up.right")
                                }
                                .buttonStyle(GhostStyle())
                                .help("More help on the same problem: \(Prompts.hintName(level + 1).lowercased())")
                            }
                            if model.canGoDeeper {
                                Button { model.goDeeper() } label: {
                                    Label("Go deeper", systemImage: "arrow.down.right")
                                }
                                .buttonStyle(GhostStyle())
                            }
                            if model.canQuiz {
                                Button { model.quizMe() } label: {
                                    Label("Quiz me", systemImage: "questionmark.circle")
                                }
                                .buttonStyle(GhostStyle())
                                .help("Four quick questions on this. Multiple choice is graded on your Mac.")
                            }
                            if model.canKeep {
                                Button { model.keepNewest() } label: {
                                    Label(model.newestIsKept ? "Kept" : "Keep",
                                          systemImage: model.newestIsKept ? "bookmark.fill" : "bookmark")
                                }
                                .buttonStyle(GhostStyle())
                                .disabled(model.newestIsKept)
                                .help("Save this answer to your library")
                            }
                            if model.canAskClaude {
                                Button { model.askClaudeInstead() } label: {
                                    Label("Ask Claude", systemImage: "sparkles")
                                }
                                .buttonStyle(GhostStyle())
                                .help("Have Claude answer this instead (it can search the web and see your screen)")
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ThreadHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(threadHeight, 24), model.maxThreadHeight))
            .onPreferenceChange(ThreadHeightKey.self) { threadHeight = $0 }
            .onChange(of: threadHeight) {
                // Only fires when a new line starts, so this glides instead of jittering per letter.
                guard threadHeight > model.maxThreadHeight else { return }
                if let graphTurn = latestGraphTurn {
                    // A graph is the answer's centerpiece: keep the question and the top of the graph in view.
                    withAnimation(Motion.animation(Motion.functional)) { proxy.scrollTo(graphTurn, anchor: .top) }
                } else {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: model.canHintUp) {
                if model.canHintUp && threadHeight > model.maxThreadHeight && latestGraphTurn == nil {
                    scrollToBottom(proxy, after: 0.2)
                }
            }
            .onChange(of: model.canGoDeeper) {
                if model.canGoDeeper && threadHeight > model.maxThreadHeight && latestGraphTurn == nil {
                    scrollToBottom(proxy, after: 0.2)
                }
            }
        }
    }

    /// The newest turn, if its answer has a graph in it.
    private var latestGraphTurn: UUID? {
        guard let last = model.turns.last,
              last.answer.range(of: "<graph|<quiz", options: [.caseInsensitive, .regularExpression]) != nil else { return nil }
        return last.id
    }

    /// Deferred so rows that are still animating in (like Go deeper) count toward the bottom.
    private func scrollToBottom(_ proxy: ScrollViewProxy, after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            proxy.scrollTo("bottom", anchor: .bottom) // pinned, flat: no animation while the answer streams
        }
    }

    /// Summarize needs something to summarize: highlighted text, a snip, or a view of the screen.
    private var canSummarize: Bool { !model.selection.isBlank || model.seesScreen }

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

    /// Learn mode: how much help, before any answer.
    private var hintPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.hintQuestion.map { "How much help with “\($0)”?" } ?? "How much help?")
                    .mLabelStyle()
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Skip hints") { model.skipHints() }
                    .buttonStyle(.plain)
                    .font(.geist(12))
                    .foregroundStyle(Theme.inkSecondary.color)
                    .help("Answer this chat the usual way")
            }
            HStack(spacing: 6) {
                ForEach(Array(Prompts.hintLevels), id: \.self) { level in
                    Button { model.pickHint(level) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(level)").font(.geist(14, .semibold)).monospacedDigit()
                            Text(Prompts.hintName(level)).font(.geist(11)).foregroundStyle(Theme.inkSecondary.color)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(HintTileStyle())
                    .accessibilityLabel("Hint level \(level): \(Prompts.hintName(level).lowercased())")
                    .staggerIn(level - 1)
                }
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
                    .staggerIn(index)
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
        FlowLayout(spacing: 6) {
            if case .offered(let name) = model.doc {
                Button { model.onUseDocument?() } label: {
                    Label("Ask about “\(name)”", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(ProminentChipStyle())
                .help("Margin reads the whole page or file on your Mac and sends Claude only the parts that match your question")
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
                .buttonStyle(ChipStyle())
            }
            if canSummarize {
                Button {
                    withAnimation(Motion.animation(Motion.functional)) { model.choosingSummary = true }
                } label: {
                    Label("Summarize", systemImage: "doc.plaintext")
                }
                .buttonStyle(ChipStyle())
            }
            // The quick questions are about "this", so a blank chat skips them.
            ForEach(Array((model.selection.isBlank ? [] : Prompts.chips).enumerated()), id: \.element.label) { index, chip in
                Button { model.ask(display: chip.prompt, prompt: chip.prompt) } label: {
                    if chip.label == "Pronounce" {
                        Label(chip.label, systemImage: "speaker.wave.2.fill")
                    } else if chip.label == "Visualize" {
                        Label(chip.label, systemImage: "chart.xyaxis.line")
                    } else if chip.label == "Simpler" {
                        Label(chip.label, systemImage: "text.badge.minus")
                    } else if chip.label == "Example?" {
                        Label(chip.label, systemImage: "lightbulb")
                    } else if chip.label == "Define terms" {
                        Label(chip.label, systemImage: "character.book.closed")
                    } else {
                        Text(chip.label)
                    }
                }
                .buttonStyle(ChipStyle())
                .staggerIn(index)
            }
        }
    }

    /// The footnote's first part is the model ("Sonnet"); it becomes the engine switch. A footnote that doesn't start with a
    /// model name ("Drawn on your Mac · …") keeps the engine's own name in the switch and the whole note after it.
    private var footerParts: (head: String, rest: String) {
        let note = model.footnote
        if let r = note.range(of: " · "), note[..<r.lowerBound].split(separator: " ").count <= 2 {
            return (String(note[..<r.lowerBound]), String(note[r.upperBound...]))
        }
        return (model.engine.name, note)
    }

    private var footer: some View {
        let parts = footerParts
        let engineHelp = model.engine.isLocal ? (Settings.shared.localIsOnMac ? "\(model.engine.name) on your Mac answers this chat. Click for Claude (⌃⇧L)"
                                                                           : "\(model.engine.name) answers this chat (quick, light on your usage). Click for the full model (⌃⇧L)")
                                            : "Claude answers this chat. Click for the model on your Mac (⌃⇧L)"
        return HStack(spacing: 10) {
            Button { model.onToggleEngine?() } label: {
                HStack(spacing: 4) {
                    Text("⇆")
                    Text(parts.head)
                }
                .font(.geist(12, .medium))
                .foregroundStyle(inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(parts.rest.isEmpty ? engineHelp : parts.rest + "\n" + engineHelp) // the note that used to be a mono footer line
            .accessibilityLabel("Switch model")
            if model.canToggleLearn { learnToggle }
        }
    }

    /// On: a filled chip in ink. Off: plain secondary text. Never the accent, which is kept for Send.
    private var learnToggle: some View {
        let on = model.learnMode
        return Button { model.toggleLearn() } label: {
            HStack(spacing: 4) {
                Glyph(kind: .nib, size: 12, color: on ? inkColor : inkSecondary)
                Text("Learn").font(.geist(12, .medium))
            }
            .foregroundStyle(on ? inkColor : inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? hairStrong : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(on ? "Learn mode is on: choose how much help before any answer. Click to turn it off."
                 : "Turn on Learn mode: choose how much help (hint levels 1-4) before any answer.")
        .accessibilityLabel("Learn mode")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private var placeholder: String {
        switch model.turns.count {
        case 0:
            if model.learnMode && model.hintPicking { return "Or type your question…" }
            if model.selection.isBlank { return "Ask anything…" }
            return model.snipImage == nil ? "What's confusing about this?" : "What do you want to know about this?"
        case 1...3: return "Ask a follow-up…"
        default: return "Still stuck? This might deserve your main chat."
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $model.draft)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { model.submit() }
            Button { model.submit() } label: {
                SendGlyph(busy: model.isStreaming, canSubmit: model.canSubmit)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .disabled(!model.canSubmit)
            .help(model.turns.isEmpty ? "Ask (empty = explain simpler)" : "Ask")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.geist(9, .semibold))
                .foregroundStyle(hovering ? inkColor : inkSecondary)
                .frame(width: 18, height: 18)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(turn.question)
                .font(.geist(13, .semibold))
                .foregroundStyle(inkColor)
                .fixedSize(horizontal: false, vertical: true)
            if turn.answer.isEmpty && !turn.done {
                HStack(spacing: 7) {
                    Glyph(kind: .orbit, size: 14, color: inkSecondary, animated: !Motion.still && !Motion.reduceMotion)
                    ShimmerText(text: status ?? "Thinking")
                    Spacer(minLength: 6)
                    if let onMinimize {
                        Button(action: onMinimize) {
                            Label("Minimize", systemImage: "sidebar.right")
                        }
                        .buttonStyle(ChipStyle())
                        .help("Put this chat away in the sidebar. It keeps working and turns green when done.")
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
                    let tidy = seg.text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
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
                                            Text(Self.inline(streaming ? Self.softenPartial(line.text) : line.text))
                                                .font(.mBody).lineSpacing(4)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    } else {
                                        Text(Self.inline(streaming ? Self.softenPartial(line.text) : line.text))
                                            .font(.mBody).lineSpacing(4)
                                            .fixedSize(horizontal: false, vertical: true)
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
            }
        }
        .tint(accentText)
        .textSelection(.enabled)
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

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Inline-only parsing leaves "- item" as a hyphen; show list items with real bullets.
        let bulleted = s.replacingOccurrences(of: #"(?m)^([ \t]*)[-*+] (?=\S)"#, with: "$1• ", options: .regularExpression)
        var out = (try? AttributedString(markdown: bulleted, options: opts)) ?? AttributedString(bulleted)
        // Inline code: SF Mono 13 on the raised surface.
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .mCode
            out[run.range].backgroundColor = Theme.surfaceRaised.color
        }
        return out
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
                .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
                .animation(Motion.animation(Motion.small), value: configuration.isPressed)
                .animation(Motion.animation(Motion.small), value: hovering)
                .onHover { hovering = $0 }
        }
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
                Text(caption.isEmpty ? "Play your video. Margin hears your Mac's sound, even with headphones."
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
                .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
                .animation(Motion.animation(Motion.small), value: configuration.isPressed)
                .animation(Motion.animation(Motion.small), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// One level in the Learn mode picker. Its edge is drawn as two fills.
private struct HintTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(inkColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous).fill(configuration.isPressed || hovering ? hairStrong : raised))
                .padding(1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hair))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
                .animation(Motion.animation(Motion.small), value: configuration.isPressed)
                .animation(Motion.animation(Motion.small), value: hovering)
                .onHover { hovering = $0 }
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
                .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
                .animation(Motion.animation(Motion.small), value: configuration.isPressed)
                .animation(Motion.animation(Motion.small), value: hovering)
                .onHover { hovering = $0 }
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
    /// Chips used to fade in one by one; they now appear together with no motion.
    func staggerIn(_ index: Int) -> some View { self }
}
