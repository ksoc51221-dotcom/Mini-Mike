import SwiftUI

/// What the Assistant page shows and does: the messages, the call to Haiku, and carrying out (or holding for your OK) what it asks for.
final class AssistantChat: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        var isUser = false
        var text = ""
        var steps: [LibraryAssistant.Step] = []
        /// Waiting for your OK (deleting anything does).
        var pending: LibraryAssistant.Plan?
        var permanent = false
        /// "Cancelled", "Undone"…
        var status: String?
        var tokens: Int?
        var canUndo: Bool { status == nil && pending == nil && steps.contains { $0.undo != nil } }
    }

    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var busy = false
    let assistant: LibraryAssistant
    /// One conversation, shared by the Library's card and the settings page.
    static let shared = AssistantChat()
    /// Tests only: takes the request instead of calling the model.
    nonisolated(unsafe) static var debugSend: ((String) -> Void)?

    init(assistant: LibraryAssistant = LibraryAssistant()) { self.assistant = assistant }

    func send(_ text: String? = nil) {
        let request = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !busy else { return }
        input = ""
        let history = messages.filter { !$0.text.isEmpty }.map { (role: $0.isUser ? "User" : "Assistant", text: $0.text) }
        messages.append(Message(isUser: true, text: request))
        if let stub = Self.debugSend { stub(request); return } // tests: no model call
        busy = true
        let prompt = assistant.userPrompt(request, history: history)
        ClaudeOneShot.run(prompt, system: LibraryAssistant.systemPrompt, model: .haiku, effort: "low", timeout: 90) { [weak self] result in
            self?.finish(result)
        }
    }

    func finish(_ result: Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) {
        busy = false
        switch result {
        case .failure(let failure):
            messages.append(Message(text: "That didn't work: \(failure.localizedDescription)"))
        case .success(let reply):
            guard let plan = LibraryAssistant.parse(reply.text) else {
                messages.append(Message(text: "I couldn't turn that into something I can do. Try saying it another way.", tokens: reply.tokens))
                return
            }
            handle(plan, tokens: reply.tokens)
        }
    }

    /// Safe plans run at once; anything that deletes is described first and waits for Apply.
    func handle(_ plan: LibraryAssistant.Plan, tokens: Int? = nil) {
        let risk = assistant.effectiveRisk(of: plan)
        if risk == .safe {
            messages.append(Message(text: plan.say, steps: assistant.run(plan, apply: true), tokens: tokens))
        } else {
            messages.append(Message(text: plan.say, steps: assistant.run(plan, apply: false), pending: plan, permanent: risk == .permanent, tokens: tokens))
        }
    }

    func apply(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), let plan = messages[i].pending else { return }
        messages[i].pending = nil
        messages[i].steps = assistant.run(plan, apply: true, confirmed: true)
    }

    func cancel(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].pending = nil
        messages[i].status = "Cancelled. Nothing was changed."
    }

    func undo(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].steps.reversed().forEach { $0.undo?() }
        messages[i].status = "Undone."
    }
}

/// The Assistant: a box of commands, the conversation, and a text box. Full width in settings, compact in the Library's card.
struct LibraryAssistantView: View {
    @ObservedObject private var chat: AssistantChat
    var compact = false
    @FocusState private var focused: Bool

    init(chat: AssistantChat = .shared, compact: Bool = false) {
        self.chat = chat
        self.compact = compact
    }

    private var canSend: Bool { !chat.input.trimmingCharacters(in: .whitespaces).isEmpty && !chat.busy }

    private var sideInset: CGFloat { compact ? 18 : 36 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assistant").mDisplayStyle().foregroundStyle(Theme.ink.color)
                    Text("Tell Merlin what to do with your Library: find things, clean up, file, star, or change a setting or shortcut.")
                        .font(.mUI).foregroundStyle(Theme.inkSecondary.color)
                }
                .padding(.horizontal, sideInset).padding(.top, 32).padding(.bottom, 16)
            }

            if compact && chat.messages.isEmpty && !chat.busy {
                // The card with nothing said yet hugs what it holds (no tall empty space above the examples); the
                // conversation's scroll area arrives with the first message.
                EmptyView()
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { m in
                            MessageView(message: m, chat: chat).id(m.id)
                        }
                        if chat.busy {
                            ThinkingIndicator(verbs: ["Thinking", "Looking through your Library", "Working it out", "Lining things up"])
                                .id("busy").transition(.opacity)
                        }
                    }
                    .padding(.horizontal, sideInset).padding(.bottom, 12).padding(.top, compact ? 4 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            }

            VStack(alignment: .leading, spacing: 8) {
                if chat.messages.isEmpty && !chat.busy {
                    AssistantExampleRows(choose: run).padding(.bottom, 4)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    // The placeholder names what it can do, now that the long command list is gone.
                    TextField("Find, star, file, or change a setting…", text: $chat.input, axis: .vertical)
                        .textFieldStyle(.plain).font(.mBody).foregroundStyle(Theme.ink.color)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send() }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .libField(focused: focused)
                    Button { send() } label: {
                        // Accent only when there is something to send; otherwise a quiet hairline square.
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(canSend ? Ink.onAccent : Theme.inkTertiary.color)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(canSend ? Ink.accent : Theme.hairline.color))
                            .animation(Motion.animation(Motion.small), value: canSend)
                    }
                    .buttonStyle(.plain).help("Send").accessibilityLabel("Send")
                    .disabled(!canSend)
                }
                Text("Reads only what you type and chat titles. Deleting always asks first.")
                    .font(.geist(11)).foregroundStyle(Theme.inkSecondary.color).lineLimit(1)
                    .help("Haiku 5.5 reads only what you type, the Library's counts and the titles of the last results, never what's inside your chats. Deleting always asks first, and goes to the Bin.")
            }
            .padding(.horizontal, sideInset).padding(.top, 8).padding(.bottom, compact ? 14 : 20)
        }
        .frame(maxWidth: compact ? .infinity : 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card grows from hugging its contents to full height with the first message: smoothly, not in a jump.
        .animation(compact ? LibMotion.panel : nil, value: chat.messages.isEmpty && !chat.busy)
        .onAppear { focused = true }
    }

    private func send() { chat.send() }

    /// An example either goes straight to the Assistant, or (when it needs your words) opens the text box with a start.
    private func run(_ command: AssistantCommand) {
        if command.fill {
            chat.input = command.prompt
            focused = true
        } else {
            chat.send(command.prompt)
        }
    }
}

private struct MessageView: View {
    let message: AssistantChat.Message
    @ObservedObject var chat: AssistantChat

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 60)
                Text(message.text).font(.mBody).foregroundStyle(Theme.ink.color).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .boxed(Ink.high, radius: Theme.Radius.control)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(message.text).font(.mBody).foregroundStyle(Theme.ink.color).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(message.steps.enumerated()), id: \.offset) { _, step in StepView(step: step, preview: message.pending != nil) }
                if message.pending != nil {
                    HStack(spacing: 8) {
                        Button { chat.apply(message.id) } label: {
                            if message.permanent {
                                Text("Delete for good").secondaryButtonLook(height: 28, tint: Ink.error)
                            } else {
                                Text("Apply").primaryButtonLook(height: 28)
                            }
                        }.buttonStyle(.plain)
                        Button { chat.cancel(message.id) } label: { Text("Cancel").secondaryButtonLook(height: 28) }.buttonStyle(.plain)
                    }
                } else if message.canUndo {
                    Button { chat.undo(message.id) } label: { Text("Undo").secondaryButtonLook(height: 24) }.buttonStyle(.plain)
                }
                if let status = message.status { Text(status).font(.mUI).foregroundStyle(Theme.inkTertiary.color) }
                if let t = message.tokens { Text("\(t) tokens").font(.mMeta).foregroundStyle(Theme.inkTertiary.color) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StepView: View {
    let step: LibraryAssistant.Step
    let preview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !step.failed && !preview {
                    MerlinDoneBadge(on: true, size: 14, ink: Theme.accent.color, mark: Theme.onAccent.color)
                } else {
                    Image(systemName: step.failed ? "exclamationmark.circle" : "arrow.right.circle")
                        .font(.system(size: 12)).foregroundStyle(step.failed ? Ink.error : Theme.inkSecondary.color)
                }
                Text(step.text).font(.mUI).foregroundStyle(Theme.ink.color).fixedSize(horizontal: false, vertical: true)
            }
            if !step.hits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(step.hits) { h in
                        HStack(spacing: 8) {
                            if h.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary.color) }
                            Text(h.title).font(.mUI).foregroundStyle(Theme.ink.color).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(h.sector).font(.mMeta).foregroundStyle(Theme.inkTertiary.color).lineLimit(1)
                            Text(Feed.ago(h.date)).font(.mMeta).foregroundStyle(Theme.inkTertiary.color)
                            if !preview && !h.inBin {
                                Button("Open") { LibraryAssistant.openHook?(h.ref) }
                                    .buttonStyle(.plain).font(.geist(12, .semibold)).foregroundStyle(Theme.accentText.color)
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                    }
                }
                .boxed(Ink.low, radius: Theme.Radius.chip)
                .padding(.leading, 20)
            }
        }
    }
}
