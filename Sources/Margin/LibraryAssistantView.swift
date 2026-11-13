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

    init(assistant: LibraryAssistant = LibraryAssistant()) { self.assistant = assistant }

    func send(_ text: String? = nil) {
        let request = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !busy else { return }
        input = ""
        let history = messages.filter { !$0.text.isEmpty }.map { (role: $0.isUser ? "User" : "Assistant", text: $0.text) }
        messages.append(Message(isUser: true, text: request))
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
        let risk = LibraryAssistant.risk(of: plan)
        if risk == .safe {
            messages.append(Message(text: plan.say, steps: assistant.run(plan, apply: true), tokens: tokens))
        } else {
            messages.append(Message(text: plan.say, steps: assistant.run(plan, apply: false), pending: plan, permanent: risk == .permanent, tokens: tokens))
        }
    }

    func apply(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), let plan = messages[i].pending else { return }
        messages[i].pending = nil
        messages[i].steps = assistant.run(plan, apply: true)
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
    @State private var commandsOpen: Bool

    init(chat: AssistantChat = .shared, compact: Bool = false) {
        self.chat = chat
        self.compact = compact
        _commandsOpen = State(initialValue: chat.messages.isEmpty)
    }

    private var sideInset: CGFloat { compact ? 14 : 36 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assistant").mDisplayStyle().foregroundStyle(Theme.ink.color)
                    Text("Tell Margin what to do with your Library: find things, clean up, file, star, review, or change a setting or shortcut.")
                        .font(.mUI).foregroundStyle(Theme.inkSecondary.color)
                }
                .padding(.horizontal, sideInset).padding(.top, 32).padding(.bottom, 16)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty && !commandsOpen {
                            Text("Pick a command, or tell me what you need.").font(.mUI).foregroundStyle(Theme.inkTertiary.color)
                        }
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

            VStack(alignment: .leading, spacing: 8) {
                if commandsOpen {
                    AssistantCommandTray(choose: run, maxHeight: compact ? 250 : 300)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading)))
                }
                Button {
                    withAnimation(Motion.animation(Motion.functional)) { commandsOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                        Text("Commands")
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(commandsOpen ? 180 : 0))
                    }
                    .font(.geist(12, .medium)).foregroundStyle(Theme.ink.color)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline.color, lineWidth: 1))
                }
                .buttonStyle(.plain).help("Find, tidy, star, review, change settings and shortcuts")
                .accessibilityValue(commandsOpen ? "Open" : "Closed")

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Tell Margin what to do…", text: $chat.input, axis: .vertical)
                        .textFieldStyle(.plain).font(.mBody).foregroundStyle(Theme.ink.color)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send() }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .libField(focused: focused)
                    Button { send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.onAccent)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.accent))
                            .opacity(chat.input.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy ? 0.35 : 1)
                    }
                    .buttonStyle(.plain).help("Send").accessibilityLabel("Send")
                    .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy)
                }
                Text("Haiku 5.5 reads only what you type, the Library's counts and the titles of the last results, never what's inside your chats. Deleting always asks first, and goes to the Bin.")
                    .font(.geist(11)).foregroundStyle(Theme.inkTertiary.color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, sideInset).padding(.top, 8).padding(.bottom, compact ? 14 : 20)
        }
        .frame(maxWidth: compact ? .infinity : 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focused = true }
    }

    private func send() {
        withAnimation(Motion.animation(Motion.functional)) { commandsOpen = false }
        chat.send()
    }

    /// A command either goes straight to the Assistant, or (when it needs your words) opens the text box with a start.
    private func run(_ command: AssistantCommand) {
        withAnimation(Motion.animation(Motion.functional)) { commandsOpen = false }
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
                    MarginDoneBadge(on: true, size: 14, ink: Theme.accent.color, mark: Theme.onAccent.color)
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
