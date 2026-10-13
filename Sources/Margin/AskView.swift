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
    /// Answers kept in the notebook.
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
        return last.done && !last.isError && !isStreaming && last.question != Self.deeperLabel
            && last.question != Prompts.quizLabel && !last.answer.contains("<event>")
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
        withAnimation(.snappy(duration: 0.25)) { keptTurns.insert(last.id) }
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
        withAnimation(.snappy(duration: 0.28)) {
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
        withAnimation(.snappy(duration: 0.28)) {
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
        withAnimation(.snappy(duration: 0.28)) {
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
            withAnimation(.easeOut(duration: 0.2)) { status = nil }
        }
        pending += text
        if instantText { drainAll() } else { startDrain() }
    }

    /// A tool started: anything written so far was narration ("Let me look that up…").
    func toolActivity(_ label: String) {
        pending = ""
        withAnimation(.easeInOut(duration: 0.22)) {
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
        withAnimation(.snappy(duration: 0.25)) {
            isStreaming = false
            status = nil
            if let i = turns.indices.last {
                let partial = turns[i].answer
                turns[i].answer = partial.isEmpty ? message : partial + "\n\n" + message
                turns[i].isError = true
                turns[i].done = true
            }
            if sessionDead { fatal = turns.isEmpty ? message : "Close this and highlight again to retry." }
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
        withAnimation(.snappy(duration: 0.3)) {
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

private let accent = Color(nsColor: Theme.accent)

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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                if model.turns.isEmpty && model.video == nil
                    && (!model.selection.isBlank || model.videoHint || model.seesScreen || model.doc != .none) {
                    chips.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
                // Video chats start with the summary; the question field appears once there's something to ask about.
                if model.video == nil || !model.turns.isEmpty { inputRow }
                Text(model.footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: model.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { h in model.onHeight?(h) }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top) // while the panel grows, clip the bottom, not both ends
        .overlay(RoundedRectangle(cornerRadius: AskPanelController.cornerRadius)
            .strokeBorder(Color(nsColor: PanelGlow.color).opacity(0.45), lineWidth: 1))
        .overlay(alignment: .top) {
            // A small grip: the top of the chat drags it around the screen.
            Capsule().fill(Color.primary.opacity(0.16)).frame(width: 30, height: 3).padding(.top, 5)
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
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(0.7), lineWidth: 1))
                Text("Your snip from \(model.selection.appName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if model.selection.isBlank {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Ask anything · \(model.selection.appName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(model.selection.text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3)
                }
                .help(model.selection.text)
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
            HeaderButton(symbol: "xmark", help: "Delete this chat (clicking elsewhere only puts it in the sidebar)") {
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
                    if model.canGoDeeper || model.canAskClaude || model.canKeep {
                        FlowLayout(spacing: 6) {
                            if model.canGoDeeper {
                                Button { model.goDeeper() } label: {
                                    Label("Go deeper", systemImage: "arrow.down.right")
                                }
                                .buttonStyle(ChipStyle())
                            }
                            if model.canQuiz {
                                Button { model.quizMe() } label: {
                                    Label("Quiz me", systemImage: "questionmark.circle")
                                }
                                .buttonStyle(ChipStyle())
                                .help("Four quick questions on this. Multiple choice is graded on your Mac.")
                            }
                            if model.canKeep {
                                Button { model.keepNewest() } label: {
                                    Label(model.newestIsKept ? "Kept" : "Keep",
                                          systemImage: model.newestIsKept ? "bookmark.fill" : "bookmark")
                                }
                                .buttonStyle(ChipStyle())
                                .disabled(model.newestIsKept)
                                .help("Save this answer to your notebook")
                            }
                            if model.canAskClaude {
                                Button { model.askClaudeInstead() } label: {
                                    Label("Ask Claude", systemImage: "sparkles")
                                }
                                .buttonStyle(ChipStyle())
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
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(graphTurn, anchor: .top) }
                } else {
                    scrollToBottom(proxy)
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
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
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

    /// After tapping Summarize: how to summarize it.
    private var summaryChoices: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.choosingSummary = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back")
                Text(model.selection.isBlank ? "Summarize what's on your screen by its…" : "Summarize it by its…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(Prompts.Summary.allCases, id: \.self) { kind in
                    Button { model.summarize(kind) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .buttonStyle(ProminentChipStyle())
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
                ProgressView().controlSize(.small)
                ShimmerText(text: "Reading \(name)…")
            }
            .transition(.opacity)
        case .ready(let name, let detail):
            HStack(spacing: 7) {
                Image(systemName: "doc.text.fill").foregroundStyle(accent)
                Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.onDropDocument?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Stop reading this document")
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.1)))
            .transition(.opacity)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).transition(.opacity)
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
                    withAnimation(.snappy(duration: 0.25)) { model.choosingSummary = true }
                } label: {
                    Label("Summarize", systemImage: "doc.plaintext")
                }
                .buttonStyle(ChipStyle())
            }
            // The quick questions are about "this", so a blank chat skips them.
            ForEach(model.selection.isBlank ? [] : Prompts.chips, id: \.label) { chip in
                Button { model.ask(display: chip.prompt, prompt: chip.prompt) } label: {
                    if chip.label == "Pronounce" {
                        Label(chip.label, systemImage: "speaker.wave.2.fill")
                    } else if chip.label == "Visualize" {
                        Label(chip.label, systemImage: "chart.xyaxis.line")
                    } else {
                        Text(chip.label)
                    }
                }
                .buttonStyle(ChipStyle())
            }
        }
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
        HStack(spacing: 8) {
            TextField(placeholder, text: $model.draft)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { model.submit() }
            Button { model.submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent.opacity(model.canSubmit ? 1 : 0.35)))
                    .animation(.easeOut(duration: 0.2), value: model.canSubmit)
            }
            .buttonStyle(PressStyle())
            .disabled(!model.canSubmit)
            .help(model.turns.isEmpty ? "Ask (empty = explain simpler)" : "Ask")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(fieldFocused ? 0.08 : 0.06)))
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
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
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
            if turn.answer.isEmpty && !turn.done {
                HStack(spacing: 6) {
                    ShimmerText(text: status ?? "Thinking…")
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
                    .foregroundStyle(turn.isError ? Color.red : Color.primary)
                    .transition(.opacity)
                if let local = turn.localModel {
                    Label("Answered on your Mac · \(local)", systemImage: "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(36, g.size.width * 0.35))
                        .offset(x: -g.size.width * 0.35 + phase * g.size.width * 1.35)
                }
                .mask(label)
                .allowsHitTesting(false)
            }
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: text)
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }

    private var label: some View {
        Text(text)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Inline markdown plus ``` code fences — enough for short answers.
struct MarkdownText: View {
    let text: String
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    Text(seg.text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                } else {
                    Text(Self.inline(streaming ? Self.softenPartial(seg.text) : seg.text))
                        .font(.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(accent)
        .textSelection(.enabled)
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

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Inline-only parsing leaves "- item" as a hyphen; show list items with real bullets.
        let bulleted = s.replacingOccurrences(of: #"(?m)^([ \t]*)[-*+] (?=\S)"#, with: "$1• ", options: .regularExpression)
        return (try? AttributedString(markdown: bulleted, options: opts)) ?? AttributedString(bulleted)
    }
}

/// Buttons dip slightly when pressed.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
                    accent.opacity(0.15)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: image != nil)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.45)))
                )
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accent.opacity(0.15))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: video.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(accent))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = video.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 8)
                    Button { model.onStopListening?() } label: {
                        Label("Stop & summarize", systemImage: "stop.fill")
                    }
                    .buttonStyle(ProminentChipStyle())
                }
                Text(caption.isEmpty ? "Play your video. Margin hears your Mac's sound, even with headphones."
                                     : "…" + String(caption.suffix(220)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.2), value: caption)
                Text("You can minimize this; it keeps listening.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                    .font(.callout)
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
                    .font(.callout)
                    .foregroundStyle(.red)
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
            .fill(Color.red)
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

/// A filled terracotta pill, for the one action that matters right now.
private struct ProminentChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(configuration.isPressed ? 0.3 : hovering ? 0.22 : 0.14)))
                .foregroundStyle(accent)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
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

