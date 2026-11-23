import AppKit
import SwiftUI

// The Library's page for a sheet (a named note): the Markdown drawn (tables as tables), an Edit toggle that shows the raw
// Markdown in a plain text editor, and Tidy (one Claude call, only on click, with Undo).

/// What Done saves. If the sheet changed somewhere else while you were editing (Save to note under an answer), nothing is
/// lost: text added at the end joins your edit; any other change is kept below your edit under a dated divider.
enum SheetEdit {
    static func commit(draft: String, base: String, current: String, date: Date = Date()) -> String {
        guard current != base else { return draft }
        guard draft != base else { return current } // you changed nothing: the newer text stands as it is
        if current.hasPrefix(base) {
            let added = String(current.dropFirst(base.count))
            return draft + added
        }
        return SheetMerge.append(markup: draft, adding: current, date: date)
    }

    /// The sheet's Markdown cut at its divider lines (`---` alone on a line, outside code), so the page can draw a rule
    /// there: the shared Markdown renderer has no divider of its own.
    static func sections(_ markup: String) -> [String] {
        var out: [String] = [], current: [String] = []
        var inFence = false
        for line in markup.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle() }
            if !inFence, t.count >= 3, t.allSatisfy({ $0 == "-" }) {
                out.append(current.joined(separator: "\n")); current = []
            } else {
                current.append(line)
            }
        }
        out.append(current.joined(separator: "\n"))
        return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct SheetDetail: View {
    let sheet: Note
    let onClear: () -> Void
    var library: Library = .shared

    @State private var editing: Bool
    @State private var draft: String
    @State private var nameDraft: String
    /// The Markdown when Edit was clicked (to tell your edit from a change made elsewhere meanwhile).
    @State private var base: String
    @State private var tidyOpen = false
    @State private var instruction = ""
    @State private var tidying = false
    @State private var message: String?
    /// Bumped when the Undo bar is closed or used, so the page draws again (the Tidy itself lives in `SheetTidy.lastTidy`).
    @State private var undoRevision = 0
    @FocusState private var nameFocused: Bool
    /// Pictures (`--uishots`) open a sheet already in Edit mode.
    nonisolated(unsafe) static var debugStartEditing = false
    /// A sheet's text is open in the editor (the Library's own shortcuts, like ⌘⌫ for the Bin, stand down).
    nonisolated(unsafe) static var editingNow = false

    init(sheet: Note, initialEditing: Bool = false, library: Library = .shared, onClear: @escaping () -> Void) {
        self.sheet = sheet
        self.onClear = onClear
        self.library = library
        _editing = State(initialValue: initialEditing)
        _draft = State(initialValue: sheet.markup)
        _nameDraft = State(initialValue: sheet.name)
        _base = State(initialValue: sheet.markup)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(sector: sheet.sector, app: "", when: sheet.lastChanged, moveRequest: 0, onMove: nil) {
                BarIconButton(symbol: "doc.on.doc", help: "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sheet.markup, forType: .string)
                }
            } after: {
                BarIconButton(symbol: "trash", help: "Move to Bin (\(ShortcutCommand.libraryBin.hint))", danger: true) {
                    if editing { commit() }
                    onClear()
                }
            }
            titleRow
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
            if let message {
                Text(message).font(.mUI).foregroundStyle(Ink.onVariant).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 8)
                    .transition(.opacity)
            }
            if editing { editor } else { page }
        }
        .overlay(alignment: .bottom) {
            let _ = undoRevision
            if !editing, let outcome = SheetTidy.undoable(sheet.id, library: library) {
                UndoBar(toast: LibraryState.Toast(text: "Tidied", undo: [sheet.id]), onUndo: { undoTidy(outcome) },
                        onClose: { SheetTidy.forget(sheet.id); withAnimation(LibMotion.small) { undoRevision += 1 } })
                    .frame(maxWidth: 360).padding(12)
                    .transition(LibMotion.still || LibMotion.reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { SheetDetail.editingNow = editing }
        .onChange(of: editing) { _, now in SheetDetail.editingNow = now }
        .onDisappear {
            if editing { commit() }
            SheetDetail.editingNow = false
        }
    }

    // MARK: Parts

    private var titleRow: some View {
        HStack(spacing: 8) {
            if editing {
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.plain).font(.mHeading).foregroundStyle(Ink.onSurface)
                    .focused($nameFocused)
                    .onSubmit { commit() }
            } else {
                Text(sheet.name).font(.mHeading).foregroundStyle(Ink.onSurface).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if tidying {
                ShimmerText(text: "Tidying…").font(.geist(12, .semibold))
            }
            if !editing {
                Button { tidyOpen = true } label: {
                    Label("Tidy", systemImage: "wand.and.stars").secondaryButtonLook(tint: Ink.onVariant)
                }
                .buttonStyle(LibPressStyle())
                .disabled(tidying || sheet.markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Claude reformats this note (one call). Undo puts the old text back.")
                .accessibilityLabel("Tidy")
                .popover(isPresented: $tidyOpen, arrowEdge: .bottom) { tidyPopover }
            }
            Button { editing ? commit() : startEditing() } label: {
                if editing {
                    Text("Done").primaryButtonLook(height: 28)
                } else {
                    Label("Edit", systemImage: "pencil").secondaryButtonLook(tint: Ink.onVariant)
                }
            }
            .buttonStyle(LibPressStyle())
            .disabled(tidying)
            .keyboardShortcut(editing ? KeyboardShortcut("s", modifiers: .command) : nil)
            .help(editing ? "Save (⌘S)" : "Edit the Markdown")
            .accessibilityLabel(editing ? "Done" : "Edit")
        }
    }

    private var page: some View {
        Page {
            let parts = SheetEdit.sections(sheet.markup)
            if parts.isEmpty {
                Text("Empty. Click Edit to type or paste, or use Save to note under an answer.")
                    .font(.mUI).foregroundStyle(Ink.onVariant)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { HLine() }
                MarkdownText(text: part, streaming: false)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.mCode)
            .foregroundStyle(Ink.onSurface)
            .scrollContentBackground(.hidden)
            .padding(10)
            .boxed(Ink.low, radius: Theme.Radius.control)
            .padding(.horizontal, 24).padding(.bottom, 20)
            .accessibilityLabel("Note Markdown")
    }

    private var tidyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tidy this note").font(.mUI.weight(.semibold)).foregroundStyle(Ink.onSurface)
            Text("Claude reformats it in one call and keeps every fact. Undo puts the old text back.")
                .font(.geist(12)).foregroundStyle(Ink.onVariant).fixedSize(horizontal: false, vertical: true)
            TextField("How? (optional) e.g. a table of term, definition, formula", text: $instruction)
                .textFieldStyle(.plain).font(.mUI)
                .padding(.horizontal, 10).frame(height: 30)
                .libField(focused: false)
                .onSubmit(tidy)
            HStack {
                Spacer()
                Button("Cancel") { tidyOpen = false }.buttonStyle(.plain).font(.geist(12, .semibold)).foregroundStyle(Ink.onVariant)
                Button(action: tidy) { Text("Tidy").primaryButtonLook() }.buttonStyle(LibPressStyle())
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Actions

    private func startEditing() {
        draft = sheet.markup
        base = sheet.markup
        nameDraft = sheet.name
        message = nil
        withAnimation(LibMotion.small) { editing = true }
    }

    /// Done: saves the edit (and a new name). Never drops text that arrived while you edited.
    private func commit() {
        let current = library.sheet(sheet.id)?.markup ?? base
        library.setMarkup(sheet.id, SheetEdit.commit(draft: draft, base: base, current: current))
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if n != sheet.name, !n.isEmpty, !library.renameSheet(sheet.id, to: n) {
            message = "Another note is already called \(n). The name stays \(sheet.name)."
        }
        withAnimation(LibMotion.small) { editing = false }
    }

    private func tidy() {
        tidyOpen = false
        tidying = true
        message = nil
        SheetTidy.run(sheet: sheet.id, instruction: instruction, library: library) { outcome in
            tidying = false
            switch outcome {
            case .tidied: withAnimation(LibMotion.small) { undoRevision += 1 } // the Undo bar shows until closed or used
            case .failed(let why): withAnimation(LibMotion.small) { message = why }
            }
        }
    }

    private func undoTidy(_ outcome: SheetTidy.Outcome) {
        if !SheetTidy.undo(outcome, sheet: sheet.id, library: library) {
            message = "The note changed after Tidy, so Undo left it as it is."
        }
        SheetTidy.forget(sheet.id)
        withAnimation(LibMotion.small) { undoRevision += 1 }
    }
}

/// A name box and a Create button: "New note" in the Library, and "New note…" under an answer.
struct NewSheetField: View {
    var placeholder = "Note name"
    let onCreate: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var ready: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain).font(.mUI).foregroundStyle(Ink.onSurface)
                .focused($focused)
                .padding(.horizontal, 10).frame(height: 30)
                .libField(focused: focused)
                .onSubmit { if ready { onCreate(name) } }
            Button { onCreate(name) } label: { Text("Create").primaryButtonLook(height: 30) }
                .buttonStyle(LibPressStyle()).disabled(!ready).opacity(ready ? 1 : 0.5)
                .accessibilityLabel("Create note")
        }
        .onAppear { focused = true }
    }
}
