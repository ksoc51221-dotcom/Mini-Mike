import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hooks

/// Seams other parts of the app fill in. The sector editor lives inside this page (the Sectors section), so the app points
/// `openSectorEditor` at "open settings on Sectors" at launch (see `AppDelegate`).
enum LibrarySettingsHooks {
    static var openSectorEditor: (() -> Void)?
    /// How many sectors are in use (replaced in shots and tests).
    static var sectorCount: () -> Int = { Library.shared.usedSectors.count }
}

// Colours are the real `Theme` tokens (REDESIGN-3-INSTRUMENT.md). Pictures resolve them under a drawing appearance (see renderShots).

private struct LSShotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while drawing pictures: AppKit-backed controls don't render in ImageRenderer, so drawn look-alikes stand in.
    fileprivate var lsShot: Bool {
        get { self[LSShotKey.self] }
        set { self[LSShotKey.self] = newValue }
    }
}

private func lsMono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font { .geistMono(size, weight).monospacedDigit() }

// MARK: - Data

/// Everything the page reads, gathered in one value so pictures can use made-up data.
struct LibrarySettingsData {
    var entries: [UsageLog.Entry] = []
    var storage = LibraryUsage.StorageReport()
    var sectorCount = 0
    var folder = ""
    var localMode = false
    var now = Date()

    static func live() -> LibrarySettingsData {
        let lib = Library.shared
        return LibrarySettingsData(entries: UsageLog.load(), storage: LibraryUsage.storage(of: lib),
                                   sectorCount: LibrarySettingsHooks.sectorCount(), folder: lib.directory.path,
                                   localMode: Settings.shared.localMode)
    }
}

// MARK: - View

struct LibrarySettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, appearance, assistant, answers, shortcuts, usage, storage, sectors, privacy
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .appearance: return "paintpalette"
            case .assistant: return "sparkles"
            case .answers: return "text.bubble"
            case .shortcuts: return "keyboard"
            case .usage: return "chart.bar"
            case .storage: return "internaldrive"
            case .sectors: return "square.grid.2x2"
            case .privacy: return "lock"
            }
        }
        var blurb: String {
            switch self {
            case .general: return "How the Library looks and what it remembers."
            case .appearance: return "Light or dark, and the colour Margin uses for buttons, links and highlights."
            case .assistant: return "Tell Margin what to do with your Library."
            case .answers: return "What Margin knows about you and how it replies. Saved on this Mac, and sent to the model when a chat starts."
            case .shortcuts: return "The keys that open Margin's things. Click Change, then press the keys you want."
            case .usage: return "What Margin's own calls to Claude have used."
            case .storage: return "What's on disk, and how long it stays."
            case .sectors: return "The subjects your chats are filed under."
            case .privacy: return "What is kept, where, and how to take it with you."
            }
        }
    }

    @State var section: Section
    @State var data: LibrarySettingsData
    /// The sectors the Sectors section edits (a throwaway one in pictures).
    var sectorStore: SectorStore = .shared
    var shot = false
    var dark = false
    /// Where the Answers section reads and writes. Pictures pass a throwaway store, so your own text never lands in one.
    var answersStore: UserDefaults = .standard

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A new accent redraws the page's contents (not the page itself, so the open section and its data stay).
    @ObservedObject private var themeStore = ThemeStore.shared

    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("nameChatsOnClose") private var nameOnClose = true
    @AppStorage("libraryDefaultView") private var defaultView = LibraryDefaultView.desk.rawValue
    @AppStorage("libraryRowDensity") private var density = LibraryRowDensity.comfortable.rawValue
    @AppStorage("libraryShowPreviews") private var previews = false
    @AppStorage("binAutoEmptyDays") private var binDays = 30
    @AppStorage("screenshotRetentionDays") private var shotDays = 0

    @State private var confirmingBin = false
    @State private var confirmingDelete = false
    @State private var typed = ""
    @State private var message = ""
    @Namespace private var navNS

    init(section: Section = .general, data: LibrarySettingsData? = nil, sectorStore: SectorStore = .shared, shot: Bool = false, dark: Bool = false, answersStore: UserDefaults = .standard) {
        _section = State(initialValue: section)
        self.answersStore = answersStore
        self.sectorStore = sectorStore
        _data = State(initialValue: data ?? LibrarySettingsData.live())
        self.shot = shot
        self.dark = dark
    }

    private var spring: Animation? { Motion.still ? nil : Motion.animation(Motion.smooth) }
    private var smallSpring: Animation? { Motion.still ? nil : Motion.animation(Motion.snappy) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar()
            Rectangle().fill(Theme.hairline.color).frame(width: 1).frame(maxHeight: .infinity)
            pane()
        }
        .id(themeStore.revision)
        .frame(minWidth: 700, minHeight: shot ? 560 : 460)
        .background(Theme.canvas.color)
        .environment(\.lsShot, shot)
        .preferredColorScheme(shot ? (dark ? .dark : .light) : nil)
        .onReceive(NotificationCenter.default.publisher(for: Library.changed)) { _ in if !shot { refresh() } }
    }

    private func refresh() {
        // Library is main-thread only, so the numbers are gathered here; the usage log is read in the background.
        let lib = Library.shared
        let storage = LibraryUsage.storage(of: lib)
        let count = LibrarySettingsHooks.sectorCount()
        let folder = lib.directory.path
        DispatchQueue.global(qos: .utility).async {
            let fresh = LibrarySettingsData(entries: UsageLog.load(), storage: storage, sectorCount: count, folder: folder,
                                            localMode: Settings.shared.localMode)
            DispatchQueue.main.async { data = fresh }
        }
    }

    // MARK: Sidebar and pane

    private func sidebar() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Library").mLabelStyle()
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            ForEach(Array(Section.allCases.filter { $0 != .assistant }.enumerated()), id: \.element.id) { _, s in
                let on = s == section
                Button {
                    withAnimation(spring) { section = s }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol)
                            .font(.geist(12)).frame(width: 18)
                            .foregroundStyle(on ? Theme.ink.color : Theme.inkSecondary.color)
                        Text(s.title).font(.geist(13, on ? .medium : .regular)).foregroundStyle(on ? Theme.ink.color : Theme.inkSecondary.color)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background {
                        if on {
                            Theme.surfaceSelected.color
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .matchedGeometryEffect(id: "bar", in: navNS)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LSPressStyle())
            }
            Spacer(minLength: 0)
            Rectangle().fill(Theme.hairline.color).frame(height: 1).padding(.horizontal, 4).padding(.bottom, 6)
            AssistantOrbButton(open: section == .assistant) { withAnimation(spring) { section = .assistant } }
        }
        .padding(.horizontal, 12).padding(.vertical, 24)
        .frame(width: 192)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.color)
    }

    private func pane() -> some View {
        ZStack {
            Group {
                if section == .assistant {
                    LibraryAssistantView() // a chat that fills the pane, with its own header
                } else if section == .sectors {
                    // The editor brings its own header and scrolling, so it fills the pane instead of sitting in a card.
                    SectorEditorView(store: sectorStore)
                } else {
                    paneContent()
                }
            }
            .id(section)
            .transition(Motion.still || Motion.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(spring, value: section)
    }

    @ViewBuilder
    private func paneContent() -> some View {
        let content = VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                DecodeText(section.title).mDisplayStyle().foregroundStyle(Theme.ink.color).frame(minHeight: 34, alignment: .leading)
                Text(section.blurb).font(.mUI).foregroundStyle(Theme.inkSecondary.color)
            }
            switch section {
            case .general: general()
            case .appearance: LSAppearance()
            case .assistant: EmptyView()
            case .answers: LSAnswers(store: answersStore)
            case .shortcuts: LSShortcuts()
            case .usage: usage()
            case .storage: storage()
            case .sectors: EmptyView()
            case .privacy: privacy()
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 36).padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)

        if shot {
            content
        } else {
            ScrollView { content }
        }
    }

    // MARK: General

    private func general() -> some View {
        VStack(alignment: .leading, spacing: 24) {
            LSGroup {
                LSRow("Save history", "Keep your chats in the Library on this Mac. Off means nothing is kept once a chat closes.") {
                    LSSwitch(isOn: $saveHistory)
                }
                LSRow("Name chats when they close", "After a longer chat, Claude gives it a better title and sector. Counts as a small call.") {
                    LSSwitch(isOn: $nameOnClose)
                }
            }
            LSGroup {
                LSRow("Open on", "What you see when the Library opens.") {
                    LSChoice(options: LibraryDefaultView.allCases.map { ($0.rawValue, $0.title) }, selection: $defaultView, width: 220)
                }
                LSRow("Row density", "How much room each chat in the list gets.") {
                    LSChoice(options: LibraryRowDensity.allCases.map { ($0.rawValue, $0.title) }, selection: $density, width: 190)
                }
                LSRow("Show answer previews", "A one-line start of the answer under each title.") {
                    LSSwitch(isOn: $previews)
                }
            }
        }
    }

    // MARK: Usage

    private func usage() -> some View {
        let periods = LibraryUsage.periods(data.entries, now: data.now)
        let days = LibraryUsage.daily(data.entries, days: 14, now: data.now)
        let monthStart = LibraryUsage.monthStart(data.now)
        let split = LibraryUsage.split(data.entries, from: monthStart)
        let local = LibraryUsage.localSavings(data.entries, from: monthStart)
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                LSPeriodCard(title: "This week", totals: periods.week)
                LSPeriodCard(title: "This month", totals: periods.month)
            }
            .help("Margin's own calls to Claude only. claude.ai chats, Claude Code and anything else aren't counted, so this isn't your plan's total.")

            LSGroupTitle("Tokens per day, last 14 days").help("Cost is at API prices, for comparison. On a Claude plan you aren't billed per token. Cached input is counted in full.")
            LSBarChart(days: days).padding(16).lsCard()

            LSGroupTitle("This month: answers and upkeep")
            VStack(alignment: .leading, spacing: 14) {
                LSSplitBar(answers: split.answers.tokens, upkeep: split.housekeeping.tokens)
                HStack(alignment: .top, spacing: 12) {
                    LSSplitLegend(color: Theme.ink.color, title: "Your chats", totals: split.answers,
                                  note: "\(split.answers.calls) answers")
                    LSSplitLegend(color: Theme.inkTertiary.color, title: "Library upkeep", totals: split.housekeeping,
                                  note: "naming, filing, sector descriptions")
                }
            }
            .padding(16).lsCard()

            LSGroupTitle("Local mode")
            LSGroup {
                if local.answers > 0 || local.saved > 0 {
                    LSRow("Answered on this Mac", "Used none of your Claude tokens.") { LSNumber("\(local.answers)") }
                    LSRow("Estimated tokens saved", "An estimate, not a measurement: about \(local.percent)% of what this month's answers would have used.") {
                        LSNumber(LibraryUsage.compact(local.saved))
                    }
                } else {
                    LSRow(data.localMode ? "Nothing answered locally yet" : "Local mode is off",
                          data.localMode ? "Quick questions and short summaries will be answered on this Mac." : "Turn it on from the menu bar to answer quick questions on this Mac and save Claude tokens.") {
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: Storage

    private func storage() -> some View {
        let bin = data.storage[.bin]
        let binItems = data.storage.binItems
        return VStack(alignment: .leading, spacing: 24) {
            LSGroup {
                ForEach(LibraryUsage.Kind.allCases) { kind in
                    let s = data.storage[kind]
                    LSRow(kind.title, "\(s.files) \(s.files == 1 ? "file" : "files")") {
                        LSNumber(LibraryUsage.bytes(s.bytes))
                    }
                }
                LSRow("Total", "In \(data.folder.isEmpty ? "the Library folder" : abbreviated(data.folder))") {
                    LSNumber(LibraryUsage.bytes(data.storage.total), bold: true)
                }
            }
            LSGroup {
                LSRow("Library folder", "Where chats and notes are kept, as small JSON files.") {
                    LSButton("Reveal folder") { NSWorkspace.shared.open(Library.shared.directory) }
                }
                if confirmingBin {
                    LSRow("Empty the Bin?", "\(binItems) \(binItems == 1 ? "item goes" : "items go") for good. This can't be undone.") {
                        HStack(spacing: 8) {
                            LSButton("Cancel") { withAnimation(smallSpring) { confirmingBin = false } }
                            LSButton("Empty Bin", role: .destructive) {
                                Library.shared.emptyBin()
                                withAnimation(smallSpring) { confirmingBin = false }
                                refresh()
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    LSRow("Empty Bin now", binItems == 0 ? "The Bin is empty." : "Delete everything in the Bin for good (\(LibraryUsage.bytes(bin.bytes))).") {
                        LSButton("Empty Bin…", enabled: binItems > 0) { withAnimation(smallSpring) { confirmingBin = true } }
                    }
                    .transition(.opacity)
                }
                LSRow("Empty the Bin automatically", "Items you delete wait in the Bin this long first.") {
                    LSChoice(options: [("7", "7 days"), ("30", "30 days"), ("90", "90 days"), ("0", "Never")],
                             selection: Binding(get: { String(binDays) }, set: { binDays = Int($0) ?? 30}), width: 290)
                }
                LSRow("Keep screenshots for", "Screenshots older than this are deleted for good, picture and all. Chats stay.") {
                    LSChoice(options: [("30", "30 days"), ("90", "90 days"), ("365", "1 year"), ("0", "Forever")],
                             selection: Binding(get: { String(shotDays) }, set: { shotDays = Int($0) ?? 0}), width: 290)
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    // MARK: Privacy

    private func privacy() -> some View {
        VStack(alignment: .leading, spacing: 24) {
            LSGroup {
                LSRow("What is stored", "Chats and notes as JSON files in \(data.folder.isEmpty ? "Application Support/Margin/Library" : abbreviated(data.folder)). Screenshots and the Bin sit beside them. A usage count (numbers and labels, never your text) is kept in usage.jsonl next to it.") { EmptyView() }
                LSRow("What leaves this Mac", "The text you highlight and what you ask go to Claude to be answered, through the Claude command line tool. With Local mode on, quick questions stay on this Mac. Margin has no server and no analytics.") { EmptyView() }
                LSRow("Notes as Markdown", "Kept notes are also written to Documents/Margin Notes, outside the Library. They are your files.") { EmptyView() }
            }
            LSGroup {
                LSRow("Export library", "Every chat and note, to a file you choose.") {
                    HStack(spacing: 8) {
                        LSButton("JSON…") { exportLibrary(zip: false) }
                        LSButton("Zip…") { exportLibrary(zip: true) }
                    }
                }
                if confirmingDelete {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Delete everything").font(.geist(13, .medium)).foregroundStyle(Theme.alert.color)
                        Text("This removes every chat, note, screenshot, the Bin and the usage count. Markdown copies in Documents/Margin Notes stay. It can't be undone. Type DELETE to confirm.")
                            .font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            TextField("DELETE", text: $typed)
                                .textFieldStyle(.plain).font(.geist(13)).foregroundStyle(Theme.ink.color)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .lsInputBox()
                                .frame(width: 150)
                            LSButton("Cancel") { withAnimation(smallSpring) { confirmingDelete = false; typed = "" } }
                            LSButton("Delete everything", role: .destructive, enabled: typed == "DELETE") { deleteEverything() }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                } else {
                    LSRow("Delete everything", "Remove all chats, notes, screenshots and the Bin from this Mac.") {
                        LSButton("Delete everything…", role: .destructive) { withAnimation(smallSpring) { confirmingDelete = true } }
                    }
                    .transition(.opacity)
                }
            }
            if !message.isEmpty {
                Text(message).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
            }
        }
    }

    // MARK: Actions (runtime only)

    private func exportLibrary(zip: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LibraryUsage.exportName(ext: zip ? "zip" : "json")
        panel.allowedContentTypes = [zip ? .zip : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if zip {
            let source = Library.shared.directory
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--keepParent", source.path, dest.path]
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async { message = p.terminationStatus == 0 ? "Exported to \(dest.lastPathComponent)." : "The zip couldn't be written." }
            }
        } else if let json = LibraryUsage.exportJSON(chats: Library.shared.chats, notes: Library.shared.notes),
                  (try? json.write(to: dest, options: .atomic)) != nil {
            message = "Exported to \(dest.lastPathComponent)."
        } else {
            message = "The file couldn't be written."
        }
    }

    private func deleteEverything() {
        let lib = Library.shared
        _ = lib.deleteAllChats()
        for n in lib.notes { lib.delete(note: n.id) }
        _ = lib.deleteAllScreenshots()
        lib.emptyBin()
        lib.flush()
        try? FileManager.default.removeItem(at: UsageLog.url)
        withAnimation(smallSpring) { confirmingDelete = false; typed = "" }
        message = "Everything is deleted."
        refresh()
    }
}

// MARK: - Building blocks

private struct LSPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

/// A raised card with a 1px edge drawn as two fills (never a stroke). `edge` is the hairline unless a card should stand out.
private struct LSCard: ViewModifier {
    var edge: Color = Theme.hairline.color
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.Radius.container - 1, style: .continuous).fill(Theme.surface.color))
            .padding(1)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).fill(edge))
    }
}

private struct LSInputBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
            .padding(1)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.hairlineStrong.color))
    }
}

extension View {
    fileprivate func lsCard(edge: Color = Theme.hairline.color) -> some View { modifier(LSCard(edge: edge)) }
    fileprivate func lsInputBox() -> some View { modifier(LSInputBox()) }
}

private struct LSGroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).mLabelStyle().padding(.bottom, -14)
    }
}

/// A card of rows with hairlines between them.
private struct LSGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(LSDividedLayout(line: Theme.hairline.color)) { content }
        }
        .lsCard()
    }
}

private struct LSDividedLayout: _VariadicView_MultiViewRoot {
    var line: Color
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Rectangle().fill(line).frame(height: 1).padding(.leading, 16) }
        }
    }
}

private struct LSRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control
    init(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
            }
            .help(detail)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LSNumber: View {
    let text: String
    var bold = false
    init(_ text: String, bold: Bool = false) { self.text = text; self.bold = bold }
    var body: some View {
        Text(text).font(lsMono(13, bold ? .semibold : .regular)).foregroundStyle(Theme.ink.color).contentTransition(.numericText())
    }
}

private struct LSButton: View {
    let title: String
    var role: ButtonRole?
    var prominent = false
    var enabled = true
    let action: () -> Void
    init(_ title: String, role: ButtonRole? = nil, prominent: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.prominent = prominent; self.enabled = enabled; self.action = action
    }
    var body: some View {
        let destructive = role == .destructive
        let fg: Color = prominent ? Theme.onAccent.color : (destructive ? Theme.alert.color : Theme.ink.color)
        Button(action: action) {
            Text(title).font(.geist(13, .medium)).foregroundStyle(fg)
                .padding(.horizontal, 12).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(prominent ? Theme.accent.color : Theme.surfaceRaised.color))
                .padding(1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(prominent ? Theme.accent.color : Theme.hairline.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(LSPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The Answers section: Context and Rules. Each change is saved as you type.
private struct LSAnswers: View {
    @AppStorage private var context: String
    @AppStorage private var rules: String

    init(store: UserDefaults) {
        _context = AppStorage(wrappedValue: "", Settings.contextKey, store: store)
        _rules = AppStorage(wrappedValue: "", Settings.rulesKey, store: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LSTextBox(title: "Context", detail: "What Margin should always remember about you, in every chat.",
                      placeholder: "I'm a first-year student learning Python and economics. I prefer examples over theory.", text: $context)
            LSTextBox(title: "Rules", detail: "How Margin must answer, every time.",
                      placeholder: "Straight forward answer: no beating around the bush, deliver the idea directly.", text: $rules)
        }
    }
}

/// A large text box with a title, a character count and placeholder text that goes away once you type.
private struct LSTextBox: View {
    let title: String
    let detail: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        let over = text.count > Prompts.maxPersonal
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
                Spacer(minLength: 8)
                Text("\(text.count.formatted()) / \(Prompts.maxPersonal.formatted())")
                    .font(.geist(11).monospacedDigit())
                    .foregroundStyle(over ? Theme.alert.color : Theme.inkTertiary.color)
                    .accessibilityLabel("\(text.count) of \(Prompts.maxPersonal) characters")
            }
            Text(over ? "Only the first \(Prompts.maxPersonal.formatted()) characters are sent." : detail)
                .font(.geist(12)).foregroundStyle(over ? Theme.alert.color : Theme.inkSecondary.color)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.geist(13))
                    .foregroundStyle(Theme.ink.color)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7).padding(.vertical, 8)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.geist(13)).foregroundStyle(Theme.inkTertiary.color)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 124)
            .lsInputBox()
        }
        .padding(16)
        .lsCard()
    }
}

/// A switch drawn by hand: an ink track when on (the accent is kept for marks), a knob that springs across.
private struct LSSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(Motion.still ? nil : Motion.animation(Motion.snappy)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(isOn ? Theme.ink.color : Theme.hairlineStrong.color).frame(width: 38, height: 22)
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(isOn ? Theme.canvas.color : Theme.inkTertiary.color).frame(width: 16, height: 16).padding(.horizontal, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A segmented choice drawn by hand: the picked option sits on the selected surface.
private struct LSChoice: View {
    let options: [(String, String)]
    @Binding var selection: String
    var width: CGFloat
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { withAnimation(Motion.still ? nil : Motion.animation(Motion.snappy)) { selection = value } } label: {
                    Text(title).font(.geist(12, on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink.color : Theme.inkSecondary.color)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? Theme.surfaceSelected.color : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
        .padding(1)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.hairline.color))
        .frame(width: width)
    }
}

private struct LSPeriodCard: View {
    let title: String
    let totals: LibraryUsage.Totals
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).mLabelStyle()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LibraryUsage.compact(totals.tokens)).font(lsMono(22, .medium)).foregroundStyle(Theme.ink.color).contentTransition(.numericText())
                Text("tokens").font(.geist(12, .medium)).foregroundStyle(Theme.inkSecondary.color)
            }
            VStack(spacing: 6) {
                line("Input", LibraryUsage.compact(totals.input))
                line("Output", LibraryUsage.compact(totals.output))
                line("Cached", LibraryUsage.compact(totals.cached))
                Rectangle().fill(Theme.hairline.color).frame(height: 1)
                line("Cost", LibraryUsage.dollars(totals.cost))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lsCard()
    }
    private func line(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
            Spacer()
            Text(value).font(lsMono(12)).foregroundStyle(Theme.ink.color).contentTransition(.numericText())
        }
    }
}

private struct LSBarChart: View {
    let days: [LibraryUsage.Day]
    private let height: CGFloat = 96
    @State private var drawn: CGFloat = Motion.still ? 1 : 0
    @State private var pulse = false

    var body: some View {
        let peak = max(1, days.map(\.tokens).max() ?? 1)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(LibraryUsage.compact(peak)).font(lsMono(11)).foregroundStyle(Theme.inkTertiary.color)
                    .frame(width: 34, height: height, alignment: .topLeading)
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                        let today = i == days.count - 1
                        let h = day.tokens == 0 ? 2 : max(4, height * CGFloat(day.tokens) / CGFloat(peak))
                        Rectangle()
                            .fill(day.tokens == 0 ? Theme.hairline.color : (today ? Theme.ink.color : Theme.inkTertiary.color))
                            .frame(height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                            .scaleEffect(x: 1, y: today && pulse ? 1.08 : 1, anchor: .bottom)
                    }
                }
                .frame(height: height, alignment: .bottom)
                .mask(alignment: .leading) {
                    GeometryReader { g in Rectangle().frame(width: g.size.width * drawn) }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 34)
                Text(days.first.map { $0.start.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.geist(12, .medium)).foregroundStyle(Theme.inkSecondary.color)
        }
        .onAppear {
            guard !Motion.still else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.6))) { drawn = 1 }
            guard !Motion.reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.18)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.easeOut(duration: 0.3)) { pulse = false } }
            }
        }
    }
}

private struct LSSplitBar: View {
    let answers: Int
    let upkeep: Int
    var body: some View {
        GeometryReader { geo in
            let total = max(1, answers + upkeep)
            let gap: CGFloat = answers > 0 && upkeep > 0 ? 2 : 0
            let usable = geo.size.width - gap
            HStack(spacing: gap) {
                if answers + upkeep == 0 {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.hairline.color)
                } else {
                    if answers > 0 { RoundedRectangle(cornerRadius: 2).fill(Theme.ink.color).frame(width: max(4, usable * CGFloat(answers) / CGFloat(total))) }
                    if upkeep > 0 { RoundedRectangle(cornerRadius: 2).fill(Theme.inkTertiary.color) }
                }
            }
        }
        .frame(height: 10)
    }
}

private struct LSSplitLegend: View {
    let color: Color
    let title: String
    let totals: LibraryUsage.Totals
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(title).font(.geist(12, .medium)).foregroundStyle(Theme.ink.color)
            }
            Text("\(LibraryUsage.compact(totals.tokens)) tokens · \(LibraryUsage.dollars(totals.cost))")
                .font(lsMono(12)).foregroundStyle(Theme.ink.color).contentTransition(.numericText())
            Text(note).font(.geist(11)).foregroundStyle(Theme.inkTertiary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window

/// The Library settings window. The Library window opens it with `LibrarySettingsWindow.show()` (or `show(section:)`).
final class LibrarySettingsWindow: NSWindowController, NSWindowDelegate {
    private static var current: LibrarySettingsWindow?

    static func show(section: LibrarySettingsView.Section = .general) {
        if let w = current, let win = w.window {
            win.contentView = NSHostingView(rootView: LibrarySettingsView(section: section))
            present(win, animated: false)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Library Settings"
        window.backgroundColor = Theme.canvas.ns
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)
        window.contentView = NSHostingView(rootView: LibrarySettingsView(section: section))
        window.center()
        window.setFrameAutosaveName("MarginLibrarySettings")
        let controller = LibrarySettingsWindow(window: window)
        window.delegate = controller
        current = controller
        Library.shared.applyRetention()
        present(window, animated: true)
    }

    /// Always in front of the (floating) dashboard and everything else, focused, centered over the dashboard when it's open,
    /// with a short pop-in (scale 0.96 to 1 plus fade; Reduce Motion: fade only).
    private static func present(_ window: NSWindow, animated: Bool) {
        window.level = .floating // same level as the dashboard, ordered after it, so it sits on top
        if let lib = LibraryWindow.shared.debugWindow, lib.isVisible {
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: lib.frame.midX - f.width / 2, y: lib.frame.midY - f.height / 2))
        }
        let target = window.frame
        let pop = animated && !window.isVisible && !Motion.reduceMotion
        if animated && !window.isVisible {
            window.alphaValue = 0
            if pop {
                let w = target.width * 0.96, h = target.height * 0.96
                window.setFrame(NSRect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h), display: false)
            }
        }
        NSApp.activate() // opened from a click in the Library, so taking focus is expected
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard animated else { window.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.4, 1) // slight spring overshoot
            window.animator().alphaValue = 1
            if pop { window.animator().setFrame(target, display: true) }
        }
    }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

// MARK: - Pictures

extension LibrarySettingsView {
    /// Made-up usage and storage so every section can be drawn without touching real data.
    static func sampleData(now: Date = Date()) -> LibrarySettingsData {
        var entries: [UsageLog.Entry] = []
        let cal = Calendar.current
        let tokensPerDay = [0, 3200, 5400, 0, 8800, 12100, 6400, 2100, 0, 9300, 14200, 7600, 4100, 10800, 6900, 5200]
        for (i, base) in tokensPerDay.enumerated() where base > 0 {
            guard let day = cal.date(byAdding: .day, value: -(tokensPerDay.count - 1 - i), to: now) else { continue }
            var e = UsageLog.Entry(engine: "claude")
            e.time = day
            e.input = base / 4
            e.output = base / 6
            e.cached = base - e.input - e.output
            e.costUSD = Double(base) / 120_000
            e.why = "the highlight is enough"
            entries.append(e)
            if i % 3 == 0 {
                var h = UsageLog.Entry(engine: "claude")
                h.time = day
                h.lean = true
                h.why = LibraryUsage.Housekeeping.naming.label
                h.input = 420
                h.output = 40
                h.cached = 300
                h.costUSD = 0.002
                entries.append(h)
            }
            if i % 2 == 1 {
                var l = UsageLog.Entry(engine: "local", saved: 4200)
                l.time = day
                entries.append(l)
            }
        }
        var storage = LibraryUsage.StorageReport()
        storage.sizes[.chats] = .init(bytes: 2_400_000, files: 25)
        storage.sizes[.notes] = .init(bytes: 310_000, files: 9)
        storage.sizes[.screenshots] = .init(bytes: 86_000_000, files: 59)
        storage.sizes[.bin] = .init(bytes: 31_000_000, files: 143)
        storage.binItems = 71
        return LibrarySettingsData(entries: entries, storage: storage, sectorCount: 12,
                                   folder: NSHomeDirectory() + "/Library/Application Support/Margin/Library",
                                   localMode: true, now: now)
    }

    /// Draws every section, light and dark, to `dir` as PNGs (`settings-<section>-<light|dark>.png`). Headless: the view is
    /// hosted in an NSHostingView that is never put in a window, the library and sectors are throwaways, no Claude is called.
    @MainActor
    static func renderShots(to dir: URL) {
        _ = NSApplication.shared
        Motion.still = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-settingsshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let library = Library(directory: tmp)
        for (title, sector) in [("Standard deviation vs variance", "Math"), ("Chain rule", "Math"), ("Closures capture variables", "Computer Science"),
                                ("Pronouncing замок", "Language"), ("Supply shifts", "Economics")] {
            library.save(ChatRecord(title: title, sector: sector, app: "Safari", quote: "", turns: [.init(question: title, answer: "An answer.")]))
        }
        let store = SectorStore(directory: tmp, library: library)
        let data = sampleData()
        // Throwaway stores for the Answers pictures: your real Context and Rules never appear in them.
        let emptyName = "com.kien.margin.shots.empty", filledName = "com.kien.margin.shots.filled"
        defer { for name in [emptyName, filledName] { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let emptyStore = UserDefaults(suiteName: emptyName)!
        let filledStore = UserDefaults(suiteName: filledName)!
        filledStore.set("Second-year economics student. I know calculus but not statistics yet.", forKey: Settings.contextKey)
        filledStore.set("Straight forward answer: no beating around the bush.\nUse metric units.", forKey: Settings.rulesKey)
        let modes: [(String, Bool, ColorScheme, NSAppearance)] = [("light", false, .light, NSAppearance(named: .aqua)!),
                                                                 ("dark", true, .dark, NSAppearance(named: .darkAqua)!)]
        for (mode, isDark, scheme, appearance) in modes {
            NSApp.appearance = appearance
            var pages = Section.allCases.map { (section: $0, file: $0.rawValue, answers: $0 == .answers ? filledStore : emptyStore) }
            pages.append((section: .answers, file: "answers-empty", answers: emptyStore))
            for (section, file, answers) in pages {
                let view = LibrarySettingsView(section: section, data: data, sectorStore: store, shot: true, dark: isDark, answersStore: answers)
                    .environment(\.colorScheme, scheme)
                let size = CGSize(width: 780, height: section == .sectors ? 640 : (section == .usage ? 1500 : 900))
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance {
                    let host = NSHostingView(rootView: view)
                    host.appearance = appearance
                    host.frame = NSRect(origin: .zero, size: size)
                    host.settleLayout(passes: 4, interval: 0.12)
                    image = host.snapshotRep()?.cgImage
                }
                let name = "settings-\(file)-\(mode).png"
                guard let image,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    print("  (no image for \(name))"); continue
                }
                try? png.write(to: dir.appendingPathComponent(name))
                print("  saved \(name)")
            }
        }
    }
}


/// The Shortcuts section: every chord Margin listens for, with a recorder to change it.
private struct LSShortcuts: View {
    @State private var binds = KeybindStore.shared.current
    @State private var recording: Hotkeys.Action?
    @State private var note = ""
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LSGroup {
                ForEach(Hotkeys.Action.allCases, id: \.self) { action in row(action) }
            }
            LSGroup {
                LSRow("Tap Shift twice", "Adds a screenshot of your screen to the open chat, for your next question. Nothing else is typed or changed.") {
                    LSSwitch(isOn: Binding(get: { binds.doubleShift },
                                           set: { on in KeybindStore.shared.update { $0.doubleShift = on } }))
                }
            }
            if !note.isEmpty {
                Text(note).font(.geist(12, .medium)).foregroundStyle(Theme.alert.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Chords need ⌘, ⌥ or ⌃ (or Tab held) so typing never triggers them. Esc cancels.")
                    .font(.geist(12)).foregroundStyle(Theme.inkTertiary.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                LSButton("Reset all", enabled: !binds.isDefault) { stop(); note = ""; KeybindStore.shared.resetAll() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: KeybindStore.changed)) { _ in binds = KeybindStore.shared.current }
        .onDisappear { stop() }
    }

    private func row(_ action: Hotkeys.Action) -> some View {
        let chord = binds.chord(action)
        let isRecording = recording == action
        let isDefault = chord == Keybinds.defaults.chord(action)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
                Text(action.detail).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(isRecording ? (tabDown ? "Tab + …" : "Press keys…") : chord.display)
                .font(lsMono(13, .medium)).foregroundStyle(isRecording ? Theme.inkSecondary.color : Theme.ink.color)
                .padding(.horizontal, 10).frame(minWidth: 70, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(isRecording ? Theme.ink.color : Theme.hairline.color, lineWidth: 1))
            LSButton(isRecording ? "Cancel" : "Change") { isRecording ? stop() : start(action) }
            if !isDefault && !isRecording { LSButton("Reset") { stop(); note = ""; KeybindStore.shared.reset(action) } }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var tabDown = false

    private func start(_ action: Hotkeys.Action) {
        stop()
        note = ""
        recording = action
        Hotkeys.paused = true // let the window see every key, including the ones Margin normally takes
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let code = Int64(event.keyCode)
            if event.type == .keyUp { if code == 48 { tabDown = false }; return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if code == 53, mods.isEmpty { stop(); return nil } // Esc
            if code == 48, mods.isEmpty { tabDown = true; return nil } // Tab on its own: the first half of a hold-Tab chord
            let chord = Chord(keyCode: code, command: mods.contains(.command), shift: mods.contains(.shift),
                              option: mods.contains(.option), control: mods.contains(.control),
                              holdTab: CGEventSource.keyState(.hidSystemState, key: 48) && code != 48)
            if let why = KeybindStore.shared.set(chord, for: action) { note = why; tabDown = false } else { note = ""; stop() }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        tabDown = false
        Hotkeys.paused = false
    }
}


// MARK: - Appearance

/// Light or dark, and one accent colour anywhere on the wheel.
private struct LSAppearance: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var draft = ThemeStore.shared.accent
    @State private var dragging = false
    @Environment(\.colorScheme) private var scheme

    private var modeBinding: Binding<String> {
        Binding(get: { store.mode.rawValue }, set: { store.setMode(AppearanceMode(rawValue: $0) ?? .system) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LSGroup {
                LSRow("Mode", "System follows your Mac's Light or Dark setting.") {
                    LSChoice(options: AppearanceMode.allCases.map { ($0.rawValue, $0.title) }, selection: modeBinding, width: 210)
                }
            }
            LSGroupTitle("Accent colour")
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ForEach(AccentTheme.presets, id: \.name) { preset in swatch(preset.name, preset.theme) }
                }
                HueSlider(hue: Binding(get: { draft.hue ?? AccentTheme.limeHue },
                                       set: { draft = AccentTheme(hue: $0) }),
                          onCommit: { store.setAccent(draft) })
                    .frame(height: 28)
                preview
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lsCard()
            HStack {
                Text("Drag along the spectrum for any colour. Text and buttons adjust themselves to stay readable.")
                    .font(.geist(12)).foregroundStyle(Theme.inkTertiary.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                LSButton("Reset", enabled: store.accent != .lime || store.mode != .system) {
                    store.setAccent(.lime); store.setMode(.system); draft = .lime
                }
            }
        }
        .onChange(of: store.accent) { _, new in draft = new }
    }

    private func swatch(_ name: String, _ theme: AccentTheme) -> some View {
        let on = isSame(draft, theme)
        return Button {
            withAnimation(Motion.still ? nil : Motion.animation(Motion.snappy)) { draft = theme }
            store.setAccent(theme)
        } label: {
            Circle().fill(Color(nsColor: theme.fill)).frame(width: 22, height: 22)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Theme.ink.color : Color.clear, lineWidth: 2))
                .scaleEffect(on ? 1.06 : 1)
        }
        .buttonStyle(.plain).help(name).accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func isSame(_ a: AccentTheme, _ b: AccentTheme) -> Bool {
        switch (a.hue, b.hue) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 0.004
        default: return false
        }
    }

    /// How the chosen colour looks in use: a fill with its ink, and a link.
    private var preview: some View {
        let dark = scheme == .dark
        return HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                Text("Send").font(.geist(13, .medium))
            }
            .foregroundStyle(Color(nsColor: draft.onFill))
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(nsColor: draft.fill)))
            Text("A link in an answer").font(.geist(13, .medium)).foregroundStyle(Color(nsColor: draft.text(dark: dark)))
            Text("Highlight").font(.geist(13))
                .foregroundStyle(Theme.ink.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: draft.wash(dark: dark))))
            Spacer(minLength: 0)
        }
    }
}

/// A rainbow track with a knob. Updates as you drag; commits when you let go.
private struct HueSlider: View {
    @Binding var hue: Double
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 22
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.05).map { Color(hue: $0, saturation: 0.76, brightness: 1) },
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 12)
                    .overlay(Capsule().strokeBorder(Theme.hairline.color, lineWidth: 1))
                Circle().fill(Color(hue: hue, saturation: 0.76, brightness: 1))
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(hue) * (w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in hue = Double(min(max((v.location.x - knob / 2) / (w - knob), 0), 1)) }
                .onEnded { _ in onCommit() })
        }
        .accessibilityElement()
        .accessibilityLabel("Accent hue")
        .accessibilityValue("\(Int(hue * 360)) degrees")
        .accessibilityAdjustableAction { dir in
            hue = min(max(hue + (dir == .increment ? 0.03 : -0.03), 0), 1)
            onCommit()
        }
    }
}
