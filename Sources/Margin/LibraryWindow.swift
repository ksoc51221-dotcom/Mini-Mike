import AppKit
import SwiftUI

/// "Chat History & Notebook": every saved chat filed by sector, searchable, plus the notes you kept.
final class LibraryWindow {
    static let shared = LibraryWindow()
    /// Opens a chat about something from the library (set by the app).
    var onAsk: ((_ selection: String, _ prompt: String) -> Void)?

    private var window: NSWindow?
    private let state = LibraryState()

    /// ⌘⇧L: opens the history, or puts it away if it's already the window you're looking at.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow, state.mode == .chats {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(notebook: Bool = false) {
        state.mode = notebook ? .notebook : .chats
        if window == nil {
            let host = NSHostingController(rootView: LibraryView(state: state, onAsk: { [weak self] s, p in self?.onAsk?(s, p) }))
            let w = NSWindow(contentViewController: host)
            w.title = "Margin: History & Notebook"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 960, height: 620))
            w.minSize = NSSize(width: 760, height: 420)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MarginLibrary")
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class LibraryState: ObservableObject {
    enum Mode { case chats, notebook }
    @Published var mode: Mode = .chats
    @Published var sector: String?
    @Published var query = ""
    @Published var selectedChat: UUID?
    @Published var selectedNote: UUID?
    @Published var revision = 0

    init() {
        NotificationCenter.default.addObserver(forName: Library.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
    }
}

private let accent = Color(nsColor: Theme.accent)

/// A steady color for each sector, so a glance sorts the list.
func sectorColor(_ name: String) -> Color {
    let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .mint, .brown, .cyan, .yellow]
    if let i = Sector.defaults.firstIndex(of: name) { return palette[i % palette.count] }
    return palette[abs(name.hashValue) % palette.count]
}

struct LibraryView: View {
    @ObservedObject var state: LibraryState
    let onAsk: (_ selection: String, _ prompt: String) -> Void
    @State private var confirmClear = false

    private var library: Library { Library.shared }

    var body: some View {
        let _ = state.revision // refresh when the library changes
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Search chats and notes")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Save chat history", isOn: Binding(get: { Settings.shared.saveHistory },
                                                              set: { Settings.shared.saveHistory = $0; state.revision += 1 }))
                    Toggle("Name chats when I close them", isOn: Binding(get: { Settings.shared.nameChatsOnClose },
                                                                         set: { Settings.shared.nameChatsOnClose = $0; state.revision += 1 }))
                    Toggle("Also write kept notes to Documents/Margin Notes",
                           isOn: Binding(get: { Settings.shared.mirrorNotes }, set: { Settings.shared.mirrorNotes = $0; state.revision += 1 }))
                    Divider()
                    Button("Clear all chat history…", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Delete every saved chat?", isPresented: $confirmClear) {
            Button("Delete all chats", role: .destructive) { library.deleteAllChats(); state.selectedChat = nil }
        } message: { Text("Your notebook isn't touched. This can't be undone.") }
    }

    // MARK: Sidebar: sectors

    private var sidebar: some View {
        List(selection: Binding<String?>(get: { sidebarSelection }, set: { select($0) })) {
            Section {
                Label("All chats", systemImage: "bubble.left.and.text.bubble.right")
                    .badge(library.chats.count).tag("chats:all")
                Label("Notebook", systemImage: "bookmark")
                    .badge(library.notes.count).tag("notebook:all")
            }
            Section("Sectors") {
                ForEach(library.usedSectors, id: \.name) { s in
                    HStack(spacing: 8) {
                        Circle().fill(sectorColor(s.name)).frame(width: 9, height: 9)
                        Text(s.name)
                        Spacer()
                        Text("\(state.mode == .chats ? s.chats : s.notes)").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag("sector:" + s.name)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarSelection: String {
        if let s = state.sector { return "sector:" + s }
        return state.mode == .chats ? "chats:all" : "notebook:all"
    }

    private func select(_ tag: String?) {
        guard let tag else { return }
        if tag == "chats:all" { state.mode = .chats; state.sector = nil }
        else if tag == "notebook:all" { state.mode = .notebook; state.sector = nil }
        else if tag.hasPrefix("sector:") { state.sector = String(tag.dropFirst(7)) }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if state.mode == .chats {
            let chats = library.search(chats: state.query, sector: state.sector)
            if chats.isEmpty {
                empty(library.chats.isEmpty ? "Your chats show up here as you ask questions."
                                            : "No chats match.", symbol: "bubble.left")
            } else {
                List(selection: $state.selectedChat) {
                    ForEach(chats) { chat in ChatRow(chat: chat).tag(chat.id as UUID?) }
                }
            }
        } else {
            let notes = library.search(notes: state.query, sector: state.sector)
            if notes.isEmpty {
                empty(library.notes.isEmpty ? "Tap Keep under an answer to save it here." : "No notes match.", symbol: "bookmark")
            } else {
                List(selection: $state.selectedNote) {
                    ForEach(notes) { note in NoteRow(note: note).tag(note.id as UUID?) }
                }
            }
        }
    }

    private func empty(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if state.mode == .chats, let id = state.selectedChat, let chat = library.chat(id) {
            ChatDetail(chat: chat, state: state, onAsk: onAsk).id(chat.id)
        } else if state.mode == .notebook, let id = state.selectedNote, let note = library.notes.first(where: { $0.id == id }) {
            NoteDetail(note: note, state: state).id(note.id)
        } else {
            empty("Pick something on the left.", symbol: "sidebar.left")
        }
    }
}

struct ChatRow: View {
    let chat: ChatRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(sectorColor(chat.sector)).frame(width: 7, height: 7)
                Text(chat.title).font(.headline).lineLimit(1)
            }
            Text(chat.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(chat.sector)
                Text("·")
                Text(chat.updated.formatted(.relative(presentation: .named)))
                if !chat.quizzes.isEmpty, let q = chat.quizzes.last {
                    Text("·"); Label("\(q.correct)/\(q.total)", systemImage: "questionmark.circle")
                }
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: note.kind == .missed ? "xmark.circle" : "bookmark.fill")
                    .font(.caption).foregroundStyle(note.kind == .missed ? Color.red : accent)
                Text(note.question).font(.headline).lineLimit(1)
            }
            Text(note.body).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Text("\(note.sector) · \(note.created.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Details

struct ChatDetail: View {
    let chat: ChatRecord
    @ObservedObject var state: LibraryState
    let onAsk: (_ selection: String, _ prompt: String) -> Void
    @State private var name = ""
    @State private var speech = SpeechStore()
    @State private var newSector = ""
    @State private var askingNewSector = false
    @FocusState private var titleFocused: Bool

    /// Saves what's typed as the chat's name (and stops Margin renaming it), if it's really different.
    private func commitName() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != chat.title else { name = chat.title; return }
        Library.shared.rename(chat.id, to: t)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("Title", text: $name)
                        .textFieldStyle(.plain).font(.title2.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit { commitName() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitName() } }
                    if chat.titleLocked {
                        Button { Library.shared.unlockTitle(chat.id) } label: {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("You named this chat, so Margin won't rename it. Click to let Margin name it again.")
                    }
                    Spacer()
                    sectorMenu
                }
                Text("\(chat.app) · \(chat.created.formatted(.dateTime.day().month(.wide).year().hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
                if !chat.quote.isEmpty {
                    Text(chat.quote).font(.callout).italic().foregroundStyle(.secondary).lineLimit(6)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3) }
                }
                ForEach(Array(chat.turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question).font(.callout.weight(.semibold)).foregroundStyle(accent)
                        AnswerView(text: turn.answer, streaming: false, speech: speech)
                    }
                }
                if !chat.quizzes.isEmpty {
                    Divider()
                    ForEach(Array(chat.quizzes.enumerated()), id: \.offset) { _, q in
                        Label("\(q.title): \(q.correct) of \(q.total) right · \(q.date.formatted(.dateTime.day().month(.abbreviated)))",
                              systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button { onAsk(digest, Prompts.quiz) } label: { Label("Quiz me on this", systemImage: "questionmark.circle") }
                    Button { copy() } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                    Spacer()
                    Button(role: .destructive) {
                        Library.shared.delete(chat: chat.id)
                        state.selectedChat = nil
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { name = chat.title }
        .onChange(of: chat.title) { _, new in if !titleFocused { name = new } }
        .onChange(of: chat.id) { _, _ in name = chat.title }
        .alert("New sector", isPresented: $askingNewSector) {
            TextField("Sector name", text: $newSector)
            Button("Move") { Library.shared.move(chat.id, toSector: newSector); newSector = "" }
            Button("Cancel", role: .cancel) { newSector = "" }
        }
    }

    private var sectorMenu: some View {
        Menu {
            ForEach(Library.shared.allSectors, id: \.self) { s in
                Button { Library.shared.move(chat.id, toSector: s) } label: {
                    if s == chat.sector { Label(s, systemImage: "checkmark") } else { Text(s) }
                }
            }
            Divider()
            Button("New sector…") { askingNewSector = true }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(sectorColor(chat.sector)).frame(width: 8, height: 8)
                Text(chat.sector)
            }
        }
        .menuStyle(.button).fixedSize()
    }

    /// A short version of the chat to quiz on in a fresh chat (so it costs one small call).
    private var digest: String {
        let text = chat.turns.map { "Q: \($0.question)\nA: \(Answer.plainText($0.answer))" }.joined(separator: "\n\n")
        return "\(chat.title)\n\n" + String(text.prefix(3500))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(chat.title)\n\n" + chat.transcript, forType: .string)
    }
}

struct NoteDetail: View {
    let note: Note
    @ObservedObject var state: LibraryState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(note.question).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(sectorColor(note.sector)).frame(width: 8, height: 8)
                    Text("\(note.sector) · \(note.app) · \(note.created.formatted(.dateTime.day().month(.wide).year()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !note.quote.isEmpty {
                    Text(note.quote).font(.callout).italic().foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3) }
                }
                MarkdownText(text: note.body, streaming: false)
                HStack {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Notebook.markdown(note), forType: .string) } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Library.shared.delete(note: note.id)
                        state.selectedNote = nil
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
