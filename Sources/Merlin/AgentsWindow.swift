import AppKit
import SwiftUI

// The Agents window (Merlin: "the same size as Merlin's library, and in that size box there should be different chat
// boxes for the agents I have"). The Library's own window (`LibraryWindow.makePanel`: size, style, theme), with the
// agents on the left (new, edit, delete after a yes) and the chat of the selected agent on the right: its messages,
// a live "thinking" bubble with the agent's orb, the time, the cost and Stop, and a field to give it a task (Return
// sends, Escape closes). The dock's Agents orb opens it: `AgentsWindow.open()`.
//
// 2026-11-27 refinement (design skills: emil-design-eng, apple-design; motion.dev's defaults): each agent has its own
// SF Symbol and colour; while it works, its mark becomes a thinking orb (the Thinking line's orbs, a still frame under
// Reduce Motion). New messages arrive with a critically damped spring (no bounce, about 0.3 s) and a 6 pt rise; under
// Reduce Motion only a fade. Keyboard actions (Return, Escape) never animate.

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

// MARK: Look

/// An agent's mark: a symbol that fits its role, and a colour of its own (both from the agent, so they never change).
struct AgentLook: Equatable {
    let symbol: String
    let color: Color

    static let palette: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.95), // blue
        Color(red: 0.20, green: 0.66, blue: 0.56), // teal
        Color(red: 0.86, green: 0.47, blue: 0.24), // amber
        Color(red: 0.70, green: 0.42, blue: 0.90), // violet
        Color(red: 0.90, green: 0.36, blue: 0.48), // rose
        Color(red: 0.42, green: 0.66, blue: 0.28), // green
    ]
    /// Role words → symbol (the first match wins).
    static let roleSymbols: [(words: [String], symbol: String)] = [
        (["physics", "science", "chemistry"], "atom"),
        (["math", "maths", "algebra", "calculus"], "function"),
        (["email", "mail", "inbox"], "envelope.fill"),
        (["message", "text", "whatsapp", "chat"], "bubble.left.and.bubble.right.fill"),
        (["essay", "write", "writing", "draft"], "pencil.line"),
        (["note", "notes", "summar"], "note.text"),
        (["calendar", "schedule", "plan"], "calendar"),
        (["research", "source", "web", "news"], "globe.americas.fill"),
        (["code", "coding", "python", "program"], "chevron.left.forwardslash.chevron.right"),
        (["music", "song", "spotify"], "music.note"),
        (["econom", "money", "finance", "budget"], "chart.line.uptrend.xyaxis"),
        (["tutor", "teach", "study", "school", "homework"], "graduationcap.fill"),
        (["travel", "trip"], "airplane"),
    ]
    static let spare = ["bolt.fill", "leaf.fill", "flame.fill", "star.fill", "moon.stars.fill", "hare.fill", "puzzlepiece.fill", "lightbulb.fill"]

    static func of(_ bot: AgentBot) -> AgentLook {
        // A steady number from the id (Swift's hashValue changes each launch).
        let seed = bot.id.uuidString.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        if bot.name == AgentBot.defaultName { return AgentLook(symbol: "sparkles", color: Ink.accent) }
        let words = (bot.role + " " + bot.name).lowercased()
        let symbol = roleSymbols.first { $0.words.contains { words.contains($0) } }?.symbol ?? spare[Int(seed % UInt32(spare.count))]
        return AgentLook(symbol: symbol, color: palette[Int(seed % UInt32(palette.count))])
    }

    /// The orb that fits what the agent does now.
    static func orbState(_ job: AgentJobView) -> Orb.State {
        if job.state == .waiting { return .breathing }
        let s = job.step.lowercased()
        if s.contains("search") || s.contains("web") { return .searching }
        if s.contains("reading") || s.contains("looking") { return .connecting }
        if s.contains("writ") || s.contains("draft") || s.contains("note") { return .composing }
        return .working
    }
}

/// The agent's mark: its symbol on a soft tile, or its thinking orb while it works.
private struct AgentMark: View {
    let bot: AgentBot
    let job: AgentJobView?
    var size: CGFloat = 30

    var body: some View {
        let look = AgentLook.of(bot)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(look.color.opacity(job == nil ? 0.16 : 0.10))
            if let job {
                ThinkingOrb(state: AgentLook.orbState(job), size: size * 0.78)
                    .transition(.opacity)
            } else {
                Image(systemName: look.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(look.color)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: job == nil)
        .accessibilityHidden(true)
    }
}

/// Pressable rows and chips: a small press (0.98), fast in and out; no movement under Reduce Motion.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Window

struct AgentsView: View {
    @ObservedObject var store: AgentBots
    @ObservedObject var pool: AgentPool
    @State private var selected: UUID?
    @State private var creating = false
    @State private var renaming: AgentBot?
    @State private var deleting: AgentBot?
    @State private var hovered: UUID?

    init(store: AgentBots, pool: AgentPool, selected: UUID? = nil) {
        self.store = store
        self.pool = pool
        _selected = State(initialValue: selected)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 256)
                .background(Ink.low)
            Rectangle().fill(Ink.outline.opacity(0.25)).frame(width: 1)
            if let bot = store.bots.first(where: { $0.id == (selected ?? store.defaultBot?.id) }) {
                AgentChatView(store: store, pool: pool, bot: bot)
                    .id(bot.id)
            } else {
                Text("Make an agent to start.").font(Font.geist(13)).foregroundStyle(Ink.onVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var working: Int { store.bots.filter { store.runningJob($0.id) != nil }.count }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agents").font(Font.geist(17, .semibold)).tracking(-0.2).foregroundStyle(Ink.onSurface)
                if working > 0 {
                    Text("\(working) working").font(Font.geist(11, .medium)).foregroundStyle(Ink.accent)
                }
                Spacer()
                Button { creating = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Ink.high, in: Circle())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(Ink.onSurface)
                .help("New agent")
                .disabled(store.bots.count >= AgentBots.maxBots)
            }
            .padding(.horizontal, 16)
            .padding(.top, 40) // under the window's three buttons
            .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.bots) { b in row(b) }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 10))
                Text(String(format: "$%.2f a task · $%.2f a day · %d at once", pool.profile.budgetUSD ?? 0, AgentPool.dailyCapUSD, AgentPool.size))
            }
            .font(Font.geist(11).monospacedDigit())
            .foregroundStyle(Ink.onVariant)
            .padding(16)
            .help("Each agent asks you before it sends, adds, buys or deletes anything.")
        }
    }

    private func row(_ b: AgentBot) -> some View {
        let isSel = b.id == (selected ?? store.defaultBot?.id)
        let job = store.runningJob(b.id)
        let subtitle = job.map { $0.state == .waiting ? "Waiting for your yes" : $0.step } ?? (b.role.isEmpty ? b.model.capitalized : b.role)
        return Button { selected = b.id } label: {
            HStack(spacing: 10) {
                AgentMark(bot: b, job: job, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.name).font(Font.geist(13, .medium)).foregroundStyle(Ink.onSurface).lineLimit(1)
                    Text(subtitle).font(Font.geist(11))
                        .foregroundStyle(job?.state == .waiting ? Color.orange : (job != nil ? AgentLook.of(b).color : Ink.onVariant))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background((isSel ? Ink.high : (hovered == b.id ? Ink.high.opacity(0.5) : Color.clear)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .contextMenu {
            Button("Edit…") { renaming = b }
            if b.name != AgentBot.defaultName { Button("Delete…", role: .destructive) { deleting = b } }
        }
        .accessibilityLabel("\(b.name), \(subtitle)")
    }
}

private struct AgentChatView: View {
    @ObservedObject var store: AgentBots
    @ObservedObject var pool: AgentPool
    let bot: AgentBot
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// motion.dev's spring with no bounce, as Apple's critically damped default.
    private static let arrive = Animation.spring(response: 0.32, dampingFraction: 1)
    private var arrival: AnyTransition {
        Motion.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    var body: some View {
        let job = store.runningJob(bot.id)
        let messages = store.messages(bot.id)
        VStack(spacing: 0) {
            header(job)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty && job == nil { empty }
                        ForEach(messages) { m in bubble(m).id(m.id).transition(arrival) }
                        if let job { thinking(job).id("thinking").transition(arrival) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: messages.count) { _, _ in
                    withAnimation(Motion.reduceMotion ? nil : Self.arrive) { proxy.scrollTo("end") }
                }
                .onChange(of: job == nil) { _, _ in proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            .animation(Motion.reduceMotion ? .easeOut(duration: 0.15) : Self.arrive, value: messages.count)
            .animation(Motion.reduceMotion ? .easeOut(duration: 0.15) : Self.arrive, value: job == nil)
            composer(job)
        }
        .onAppear { focused = true }
    }

    private func header(_ job: AgentJobView?) -> some View {
        HStack(spacing: 12) {
            AgentMark(bot: bot, job: job, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(Font.geist(17, .semibold)).tracking(-0.2).foregroundStyle(Ink.onSurface)
                Text(bot.role.isEmpty ? "Your agent" : bot.role).font(Font.geist(12)).foregroundStyle(Ink.onVariant).lineLimit(1)
            }
            Spacer()
            Text(bot.model.capitalized).font(Font.geist(11, .medium)).foregroundStyle(Ink.onVariant)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Ink.container, in: Capsule())
                .help(bot.model == "haiku" ? "Haiku: fast and cheap" : "Sonnet: careful, for most tasks")
        }
        .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Ink.outline.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom).frame(height: 6).offset(y: 6)
        }
    }

    /// The first look at an agent: its mark, what it can do, and three tasks to start from (a click fills the field).
    private var empty: some View {
        let look = AgentLook.of(bot)
        let ideas = Self.ideas(for: bot)
        return VStack(spacing: 14) {
            AgentMark(bot: bot, job: nil, size: 56)
            VStack(spacing: 4) {
                Text("Give \(bot.name) a task").font(Font.geist(16, .semibold)).foregroundStyle(Ink.onSurface)
                Text("It can search the web, write notes, read your mail and calendar, and send messages. It asks you before it sends, adds, buys or deletes anything.")
                    .font(Font.geist(13)).foregroundStyle(Ink.onVariant).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            VStack(spacing: 6) {
                ForEach(ideas, id: \.self) { idea in
                    Button { draft = idea; focused = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(look.color)
                            Text(idea).font(Font.geist(13)).foregroundStyle(Ink.onSurface)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Ink.container, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    static func ideas(for bot: AgentBot) -> [String] {
        let r = (bot.role + " " + bot.name).lowercased()
        if r.contains("physics") || r.contains("tutor") || r.contains("science") {
            return ["Explain inertia with one everyday example", "Make a note of the SUVAT equations", "Quiz me on Newton's laws"]
        }
        if r.contains("mail") || r.contains("email") {
            return ["Read my newest email and sum it up", "Draft an email to my teacher that I'll be late", "What emails did I get today?"]
        }
        return ["Find two sources on price ceilings for my economics note", "Remind me in 20 minutes to stretch", "What's on my calendar tomorrow?"]
    }

    /// The agent at work: its orb, the step, the time and the cost, and Stop.
    private func thinking(_ job: AgentJobView) -> some View {
        let waiting = job.state == .waiting
        return HStack(spacing: 10) {
            ThinkingOrb(state: AgentLook.orbState(job), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(waiting ? "Waiting for your yes in the dialog" : job.step)
                    .font(Font.geist(13, .medium)).foregroundStyle(waiting ? Color.orange : Ink.onSurface).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(job.elapsedText(now: ctx.date) + " · " + job.costText).font(Font.geist(11).monospacedDigit()).foregroundStyle(Ink.onVariant)
                }
            }
            Spacer(minLength: 16)
            Button { store.stop(bot.id) } label: {
                Label("Stop", systemImage: "stop.fill").font(Font.geist(12, .medium)).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Ink.high, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Ink.onSurface)
            .help("Stop this task")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Ink.container, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func composer(_ job: AgentJobView?) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = !empty && job == nil
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(job == nil ? "Ask \(bot.name) to…" : "\(bot.name) is working. Wait, or press Stop.", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Font.geist(14))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 3)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Ink.onAccent : Ink.onVariant)
                    .frame(width: 28, height: 28)
                    .background(canSend ? Ink.accent : Ink.high, in: Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(Ink.container, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(focused ? Ink.accent.opacity(0.55) : Ink.outline.opacity(0.22), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 6)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.runningJob(bot.id) == nil else { return }
        draft = ""
        store.send(text, to: bot.id)
    }

    @ViewBuilder private func bubble(_ m: AgentMessage) -> some View {
        let mine = m.role == .user
        HStack(alignment: .top, spacing: 10) {
            if mine { Spacer(minLength: 120) } else { AgentMark(bot: bot, job: nil, size: 24).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 5) {
                Text(mine ? AttributedString(m.text) : Self.markdown(m.text)).font(Font.geist(14)).lineSpacing(2)
                    .foregroundStyle(mine ? Ink.onAccent : Ink.onSurface).textSelection(.enabled)
                if !mine, let footer = footer(m) {
                    Text(footer).font(Font.geist(11).monospacedDigit())
                        .foregroundStyle(m.state == .failed ? Ink.error : Ink.onVariant)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(mine ? Ink.accent : Ink.container,
                        in: UnevenRoundedRectangle(topLeadingRadius: mine ? 16 : 4, bottomLeadingRadius: 16,
                                                   bottomTrailingRadius: mine ? 4 : 16, topTrailingRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 120) }
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
            Text("The role picks the agent's symbol: physics, email, essay, notes, research, code and more.")
                .font(Font.geist(11)).foregroundStyle(Ink.onVariant)
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
    /// `Merlin --agentsshot <png>`: the window drawn off screen with sample agents (for review pictures). Writes three
    /// pictures: <png> (an agent at work, with its chat), <png>-empty.png (a new agent) and <png>-dark.png.
    static func renderShot(to url: URL) -> Never {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-agents-shot-\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "merlin.agents.shot")!
        d.removePersistentDomain(forName: "merlin.agents.shot")
        let pool = AgentPool(makeTools: { _ in nil }, saveNote: { _, _ in "" }, report: { _ in }, spend: AgentSpend(defaults: d), store: d)
        let store = AgentBots(pool: pool, folder: dir)
        let tutor = store.create(name: "Physics tutor", role: "explains physics step by step", model: "sonnet")
        _ = store.create(name: "Email helper", role: "drafts my emails", model: "haiku")
        let essay = store.create(name: "Essay coach", role: "reads my essay drafts", model: "sonnet")
        if let m = store.defaultBot {
            store.debugAppend(.user, "what is the boiling point of water on Everest?", to: m.id)
            store.debugAppend(.agent, "About **71 °C**. The air pressure at the top is about a third of sea level, so water boils sooner.", cost: 0.02, to: m.id)
            store.debugAppend(.user, "find two sources on price ceilings and put them in my economics note", to: m.id)
            var work = AgentPool.fixtures[0]
            work.botID = m.id
            var wait = AgentPool.fixtures[1]
            wait.botID = essay?.id
            pool.debugShow([work, wait])
        }
        func draw(_ select: UUID?, dark: Bool, to out: URL) {
            let view = ThemedRoot { AgentsView(store: store, pool: pool, selected: select) }.frame(width: 1120, height: 700)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            print("AGENTSSHOT \(out.path)")
        }
        let base = url.deletingPathExtension().path
        draw(nil, dark: false, to: url)
        draw(tutor?.id, dark: false, to: URL(fileURLWithPath: base + "-empty.png"))
        draw(nil, dark: true, to: URL(fileURLWithPath: base + "-dark.png"))
        try? FileManager.default.removeItem(at: dir)
        d.removePersistentDomain(forName: "merlin.agents.shot")
        exit(0)
    }
}
