import AppKit
import SwiftUI

// The Agents window (Merlin: "the same size as Merlin's library, and in that size box there should be different chat
// boxes for the agents I have"). The Library's own window (`LibraryWindow.makePanel`: size, style, theme), with the
// agents on the left (new, rename, delete after a yes) and the chat of the selected agent on the right: its messages,
// a live step line with the time, the cost and Stop, and a field to give it a task (Return sends, Escape closes).
// The dock's Agents orb opens it: `AgentsWindow.open()`.

enum AgentsWindow {
    private static var panel: LibraryPanel?

    /// Opens the window (or brings it forward), with `select` chosen when given.
    static func open(select: UUID? = nil) {
        guard let store = AgentBots.shared else { return }
        if panel == nil {
            let p = LibraryWindow.makePanel(ThemedRoot { AgentsView(store: store, pool: store.pool) })
            p.title = "Merlin Agents"
            p.center()
            panel = p
        }
        if let select { NotificationCenter.default.post(name: .agentsSelect, object: select) }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    static func close() { panel?.orderOut(nil) }
    static var isOpen: Bool { panel?.isVisible ?? false }
}

extension Notification.Name {
    static let agentsSelect = Notification.Name("merlin.agents.select")
}

struct AgentsView: View {
    @ObservedObject var store: AgentBots
    @ObservedObject var pool: AgentPool
    @State private var selected: UUID?
    @State private var creating = false
    @State private var renaming: AgentBot?
    @State private var deleting: AgentBot?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
                .background(Ink.low)
            Rectangle().fill(Ink.outline.opacity(0.4)).frame(width: 1)
            if let bot = store.bots.first(where: { $0.id == (selected ?? store.defaultBot?.id) }) {
                AgentChatView(store: store, pool: pool, bot: bot)
                    .id(bot.id)
            } else {
                Text("Make an agent to start.").foregroundStyle(Ink.onVariant).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.lowest)
        .onExitCommand { AgentsWindow.close() }
        .onReceive(NotificationCenter.default.publisher(for: .agentsSelect)) { n in selected = n.object as? UUID }
        .sheet(isPresented: $creating) { AgentEditSheet(title: "New agent", bot: nil) { name, role, model in
            if let b = store.create(name: name, role: role, model: model) { selected = b.id; return true }
            return false
        } }
        .sheet(item: $renaming) { b in AgentEditSheet(title: "Edit \(b.name)", bot: b) { name, role, model in
            store.update(b.id, name: name, role: role, model: model)
        } }
        .confirmationDialog("Delete the agent “\(deleting?.name ?? "")” and its chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, store.delete(d.id), selected == d.id { selected = store.defaultBot?.id }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This can't be undone.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents").font(Font.geist(17, .semibold)).foregroundStyle(Ink.onSurface)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help("New agent")
                    .disabled(store.bots.count >= AgentBots.maxBots)
            }
            .padding(.horizontal, 16)
            .padding(.top, 40) // under the window's three buttons
            .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.bots) { b in row(b) }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Text(String(format: "Limits: $%.2f a task, $%.2f a day, %d at once", pool.profile.budgetUSD ?? 0, AgentPool.dailyCapUSD, AgentPool.size))
                .font(Font.geist(11)).foregroundStyle(Ink.onVariant)
                .padding(16)
        }
    }

    private func row(_ b: AgentBot) -> some View {
        let isSel = b.id == (selected ?? store.defaultBot?.id)
        let job = store.runningJob(b.id)
        return Button { selected = b.id } label: {
            HStack(spacing: 10) {
                Circle().fill(job == nil ? Ink.outline : (job?.state == .waiting ? Color.orange : Ink.accent)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(Font.geist(13, .medium)).foregroundStyle(Ink.onSurface).lineLimit(1)
                    Text(job?.step ?? (b.role.isEmpty ? b.model.capitalized : b.role)).font(Font.geist(11)).foregroundStyle(Ink.onVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(isSel ? Ink.high : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { renaming = b }
            if b.name != AgentBot.defaultName { Button("Delete…", role: .destructive) { deleting = b } }
        }
    }
}

private struct AgentChatView: View {
    @ObservedObject var store: AgentBots
    @ObservedObject var pool: AgentPool
    let bot: AgentBot
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let job = store.runningJob(bot.id)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bot.name).font(Font.geist(17, .semibold)).foregroundStyle(Ink.onSurface)
                if !bot.role.isEmpty { Text(bot.role).font(Font.geist(13)).foregroundStyle(Ink.onVariant).lineLimit(1) }
                Spacer()
                Text(bot.model.capitalized).font(Font.geist(11, .medium)).foregroundStyle(Ink.onVariant)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Ink.container, in: Capsule())
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.messages(bot.id).isEmpty {
                            Text("Give \(bot.name) a task below. It can search the web, write notes, read your mail and calendar, and more. It asks you before it sends, buys, adds or deletes anything.")
                                .font(Font.geist(13)).foregroundStyle(Ink.onVariant).padding(.top, 8)
                        }
                        ForEach(store.messages(bot.id)) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: store.messages(bot.id).count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end") } }
                .onAppear { proxy.scrollTo("end") }
            }
            if let job {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(job.step).font(Font.geist(12)).foregroundStyle(job.state == .waiting ? .orange : Ink.onVariant).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(job.elapsedText(now: ctx.date) + " · " + job.costText).font(Font.geist(11).monospacedDigit()).foregroundStyle(Ink.onVariant)
                    }
                    Button("Stop") { store.stop(bot.id) }.controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Ink.low)
            }
            HStack(spacing: 8) {
                TextField("Ask \(bot.name) to…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Font.geist(14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || job != nil)
            }
            .padding(12)
            .background(Ink.container, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(16)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.runningJob(bot.id) == nil else { return }
        draft = ""
        store.send(text, to: bot.id)
    }

    @ViewBuilder private func bubble(_ m: AgentMessage) -> some View {
        let mine = m.role == .user
        HStack {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 4) {
                Text(mine ? AttributedString(m.text) : Self.markdown(m.text)).font(Font.geist(14))
                    .foregroundStyle(mine ? Ink.onAccent : Ink.onSurface).textSelection(.enabled)
                if !mine, let footer = footer(m) {
                    Text(footer).font(Font.geist(11)).foregroundStyle(Ink.onVariant)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mine ? Ink.accent : Ink.container, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !mine { Spacer(minLength: 80) }
        }
    }

    /// An agent's answer: bold, italics, code and links read as such; line breaks stay.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func footer(_ m: AgentMessage) -> String? {
        var parts: [String] = []
        if let s = m.state, s != .done { parts.append(s.rawValue.capitalized) }
        if let c = m.costUSD { parts.append(String(format: "$%.2f", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct AgentEditSheet: View {
    let title: String
    let bot: AgentBot?
    /// (name, role, model) → saved? (false: the name is empty or in use).
    let save: (String, String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var model = "sonnet"
    @State private var problem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Font.geist(16, .semibold))
            TextField("Name (for example: Physics tutor)", text: $name).textFieldStyle(.roundedBorder)
                .disabled(bot?.name == AgentBot.defaultName)
            TextField("Role, optional (for example: explains physics step by step)", text: $role).textFieldStyle(.roundedBorder)
            Picker("Model", selection: $model) {
                Text("Sonnet: careful, for most tasks").tag("sonnet")
                Text("Haiku: fast and cheap, for short tasks").tag("haiku")
            }
            if problem { Text("That name is empty or another agent has it.").font(Font.geist(12)).foregroundStyle(Ink.error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(bot == nil ? "Create" : "Save") {
                    if save(name, role, model) { dismiss() } else { problem = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = bot?.name ?? ""
            role = bot?.role ?? ""
            model = bot?.model ?? "sonnet"
        }
    }
}

extension AgentsWindow {
    /// `Merlin --agentsshot <png>`: the window drawn off screen with sample agents and a chat (for review pictures).
    static func renderShot(to url: URL) -> Never {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-agents-shot-\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "merlin.agents.shot")!
        d.removePersistentDomain(forName: "merlin.agents.shot")
        let pool = AgentPool(makeTools: { _ in nil }, saveNote: { _, _ in "" }, report: { _ in }, spend: AgentSpend(defaults: d), store: d)
        let store = AgentBots(pool: pool, folder: dir)
        _ = store.create(name: "Physics tutor", role: "explains physics step by step", model: "sonnet")
        _ = store.create(name: "Email helper", role: "drafts my emails", model: "haiku")
        if let m = store.defaultBot { store.send("find two sources on price ceilings and put them in my economics note", to: m.id) }
        let view = ThemedRoot { AgentsView(store: store, pool: pool) }.frame(width: 1120, height: 700)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        try? FileManager.default.removeItem(at: dir)
        d.removePersistentDomain(forName: "merlin.agents.shot")
        print("AGENTSSHOT \(url.path)")
        exit(0)
    }
}
