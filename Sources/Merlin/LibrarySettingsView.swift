import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hooks

/// Seams other parts of the app fill in. The sector editor lives inside this page (the Sectors section), so the app points
/// `openSectorEditor` at "open settings on Sectors" at launch (see `AppDelegate`). The page itself lives inside the Library
/// window, in the Library's place (see `LibraryShell` and `LibraryWindow.showSettings`).
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

extension Notification.Name {
    /// Tests only: asks the Shortcuts section to "jump" to a row or start "record"ing one, as a click would.
    static let merlinShortcutsPage = Notification.Name("merlin.shortcuts.page")
}

private struct LSActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while the page is kept hidden behind the Library: nothing on it may keep listening to the keyboard then.
    fileprivate var lsActive: Bool {
        get { self[LSActiveKey.self] }
        set { self[LSActiveKey.self] = newValue }
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
        case general, appearance, assistant, rules, shortcuts, usage, storage, sectors, privacy
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .appearance: return "paintpalette"
            case .assistant: return "sparkles"
            case .rules: return "text.bubble"
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
            case .appearance: return "Light or dark, and the colour Merlin uses for buttons, links and highlights."
            case .assistant: return "Tell Merlin what to do with your Library."
            case .rules: return "What Merlin knows about you, how it replies, how the Library Assistant works, and what it may never do. Saved on this Mac."
            case .shortcuts: return "Every Merlin shortcut. Click Change, then press the keys you want. Red means two clash."
            case .usage: return "What Merlin's own calls to Claude have used."
            case .storage: return "What's on disk, and how long it stays."
            case .sectors: return "The subjects your chats are filed under."
            case .privacy: return "What is kept, where, and how to take it with you."
            }
        }
    }

    /// The section showing. Inside the Library window it lives in `LibraryState` (passed as `sectionBinding`); pictures keep their own.
    @State private var ownSection: Section
    private var sectionBinding: Binding<Section>?
    private var section: Section {
        get { sectionBinding?.wrappedValue ?? ownSection }
        nonmutating set { if let sectionBinding { sectionBinding.wrappedValue = newValue } else { ownSection = newValue } }
    }
    @State var data: LibrarySettingsData
    /// The numbers this opening started with, and a count bumped on each opening (the page is kept between openings).
    private let openedWith: LibrarySettingsData?
    private let opens: Int
    /// Inside the Library window: the "‹ Library" button at the top left (also Esc and ⌘[, handled by the window).
    var onBack: (() -> Void)?
    private var embedded: Bool { onBack != nil }
    /// False while the page is hidden behind the Library (it then skips re-reading usage and storage on every library change).
    var active = true
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
    @AppStorage("deleteChatOnClose") private var deleteOnClose = false
    @AppStorage(Settings.edgeDotKey) private var edgeDot = true
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

    init(section: Section = .general, data: LibrarySettingsData? = nil, sectorStore: SectorStore = .shared, shot: Bool = false, dark: Bool = false,
         answersStore: UserDefaults = .standard, sectionBinding: Binding<Section>? = nil, opens: Int = 0, onBack: (() -> Void)? = nil,
         active: Bool = true) {
        _ownSection = State(initialValue: sectionBinding?.wrappedValue ?? section)
        self.sectionBinding = sectionBinding
        self.openedWith = data
        self.opens = opens
        self.onBack = onBack
        self.active = active
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
        .frame(minWidth: embedded ? nil : 700, minHeight: embedded ? nil : (shot ? 560 : 460))
        .background(Theme.canvas.color)
        .environment(\.lsShot, shot)
        .environment(\.lsActive, active)
        .preferredColorScheme(shot ? (dark ? .dark : .light) : nil)
        // Only while showing: the page is kept hidden behind the Library between openings, and each opening brings fresh numbers.
        .onReceive(NotificationCenter.default.publisher(for: Library.changed)) { _ in if !shot && active { refresh() } }
        .onChange(of: opens) { _, _ in if let openedWith { data = openedWith } } // opened again: today's numbers
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
            if let onBack {
                Color.clear.frame(height: 34) // the window's close, minimize and zoom buttons
                LSBackButton(action: onBack).probe("settings-back").padding(.bottom, 8)
            } else {
                Text("Library").mLabelStyle()
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            }
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
                .probe("settings-assistant-orb")
        }
        .padding(.horizontal, 12).padding(.top, embedded ? 0 : 24).padding(.bottom, 24)
        .frame(width: 192)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.color)
    }

    private func pane() -> some View {
        ZStack {
            Group {
                if section == .assistant {
                    LibraryAssistantView() // a chat that fills the pane, with its own header
                        .probe("settings-assistant")
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
            case .rules: LSRules(store: answersStore)
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

        if shot && !embedded {
            content
        } else { // (pictures of the page inside the window scroll too: the page must stay as tall as the window)
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
                LSRow("Delete chat when I close it", "Clicking × on a chat moves it to the Bin, with an Undo for a few seconds. Starred chats stay. You can still bring it back from the Bin.") {
                    LSSwitch(isOn: $deleteOnClose)
                }
                LSRow("Show a dot at the screen edge while Merlin works", "A small dot at the middle of the right screen edge: it breathes while a chat works and stays when an answer is ready. Point there to see your chats and notes.") {
                    LSSwitch(isOn: $edgeDot)
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
            LSVoice()
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
            .help("Merlin's own calls to Claude only. claude.ai chats, Claude Code and anything else aren't counted, so this isn't your plan's total.")

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
                LSRow("Bin", binDays > 0 ? "Deleted chats, notes and screenshots wait here for \(binDays) days, then go for good." : "Deleted things wait here until you empty it.") {
                    LSButton("Open Bin") { LibraryWindow.shared.show(mode: .bin) }
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
                LSRow("What is stored", "Chats and notes as JSON files in \(data.folder.isEmpty ? "Application Support/Merlin/Library" : abbreviated(data.folder)). Screenshots and the Bin sit beside them. A usage count (numbers and labels, never your text) is kept in usage.jsonl next to it.") { EmptyView() }
                LSRow("What leaves this Mac", "The text you highlight and what you ask go to Claude to be answered, through the Claude command line tool. With Local mode on, quick questions stay on this Mac. With the Groq Whisper voice engine on, the audio of what you say goes to Groq to be turned into text. Merlin has no server and no analytics.") { EmptyView() }
                LSRow("Notes as Markdown", "Kept notes are also written to Documents/\(Notebook.folder.lastPathComponent), outside the Library. They are your files.") { EmptyView() }
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
                        Text("This removes every chat, note, screenshot, the Bin and the usage count. Markdown copies in Documents/\(Notebook.folder.lastPathComponent) stay. It can't be undone. Type DELETE to confirm.")
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
                    LSRow("Delete everything", "Remove all chats (starred ones too), notes, screenshots and the Bin from this Mac.") {
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
        _ = lib.deleteAllChats(includingStarred: true) // "everything" means starred chats too
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

/// "‹ Library": back from the settings page to the Library. Quiet, like the sidebar's rows: secondary ink, full ink on hover.
private struct LSBackButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.geist(12, .semibold)).frame(width: 18)
                Text("Library").font(.geist(13, .medium))
            }
            .foregroundStyle(hover ? Theme.ink.color : Theme.inkSecondary.color)
            .padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(LSPressStyle())
        .onHover { hover = $0 }
        .animation(LibMotion.hover, value: hover)
        .help("Back to the Library (Esc or \(ShortcutCommand.libraryBack.hint))")
        .accessibilityLabel("Back to the Library")
    }
}

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

/// Voice: which engine turns your voice into text, and the Groq key (kept in the macOS Keychain; only whether one is saved
/// is ever shown). Pictures and tests read `GroqKeys.shared`, which is a store in memory there, never the Keychain.
private struct LSVoice: View {
    @AppStorage(Settings.voiceEngineKey) private var engine = VoiceEngine.onDevice.rawValue
    @State private var hasKey = false
    @State private var typed = ""
    @State private var status = ""
    @State private var testing = false
    private let keys: GroqKeyStore

    init(keys: GroqKeyStore = GroqKeys.shared) { self.keys = keys }

    var body: some View {
        LSGroup {
            LSRow("Voice engine", "What turns your voice into text when you hold the talk key.") {
                LSChoice(options: [(VoiceEngine.groq.rawValue, VoiceEngine.groq.title), (VoiceEngine.onDevice.rawValue, VoiceEngine.onDevice.title)],
                         selection: $engine, width: 240)
            }
            LSRow("Groq key", "Your Groq API key, kept in the macOS Keychain. Merlin only shows whether one is saved.") {
                HStack(spacing: 8) {
                    if hasKey {
                        Text("Saved").font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
                        LSButton(testing ? "Testing…" : "Test", enabled: !testing) { test() }
                        LSButton("Remove", role: .destructive) {
                            VoiceDecision.removeKey(keys: keys, settings: .shared)
                            engine = VoiceEngine.onDevice.rawValue
                            hasKey = false
                            status = ""
                        }
                    } else {
                        ZStack(alignment: .leading) {
                            if typed.isEmpty {
                                Text("Paste your key").font(.geist(13)).foregroundStyle(Theme.inkTertiary.color).allowsHitTesting(false)
                            }
                            SecureField("", text: $typed)
                                .textFieldStyle(.plain).font(.geist(13)).foregroundStyle(Theme.ink.color)
                                .onSubmit { save() }
                        }
                        .padding(.horizontal, 8).frame(width: 190, height: 26)
                        .lsInputBox()
                        LSButton("Save", enabled: !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { save() }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 6) {
                Text("With Groq, your voice audio leaves this Mac.")
                    .font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
                Spacer(minLength: 8)
                if !status.isEmpty {
                    Text(status).font(.geist(12, .medium))
                        .foregroundStyle(status == GroqTranscriber.KeyCheck.works.message ? Theme.ink.color : Theme.alert.color)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .onAppear { hasKey = keys.hasKey } // one Keychain read per showing, not one per redraw
    }

    private func save() {
        let key = typed
        typed = "" // the field never keeps the key
        guard VoiceDecision.saveKey(key, keys: keys, settings: .shared) else { status = "Couldn't save the key"; return }
        engine = Settings.shared.voiceEngine.rawValue
        hasKey = true
        status = ""
    }

    private func test() {
        guard let key = keys.read() else { hasKey = false; return }
        testing = true
        status = ""
        Task { @MainActor in
            let result = await GroqTranscriber.check(key: key, transport: GroqTranscriber.liveTransport)
            status = result.message
            testing = false
        }
    }
}

/// The Answers section: Context and Rules. Each change is saved as you type.
private struct LSRules: View {
    @AppStorage private var context: String
    @AppStorage private var rules: String
    @AppStorage private var libraryRules: String
    @AppStorage private var routines: String
    @AppStorage private var lockRename: Bool
    @AppStorage private var lockMove: Bool

    init(store: UserDefaults) {
        _context = AppStorage(wrappedValue: "", Settings.contextKey, store: store)
        _rules = AppStorage(wrappedValue: "", Settings.rulesKey, store: store)
        _libraryRules = AppStorage(wrappedValue: "", Settings.libraryRulesKey, store: store)
        _routines = AppStorage(wrappedValue: "", Settings.routinesKey, store: store)
        _lockRename = AppStorage(wrappedValue: true, Settings.lockRenameKey, store: store)
        _lockMove = AppStorage(wrappedValue: true, Settings.lockAskMoveKey, store: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LSTextBox(title: "Context", detail: "What Merlin should always remember about you, in every chat.",
                      placeholder: "I'm a first-year student learning Python and economics. I prefer examples over theory.", text: $context)
            LSTextBox(title: "Chat rules", detail: "How Merlin must answer in a chat, every time.",
                      placeholder: "Straight forward answer: no beating around the bush, deliver the idea directly.", text: $rules)
            LSTextBox(title: "Library rules", detail: "How the Library Assistant should work with your chats, notes and screenshots.",
                      placeholder: "File anything about exams under Study. Keep titles short.", text: $libraryRules)
            LSTextBox(title: "Routines", detail: "One routine on each line: a name, a colon, then the steps with a semicolon between them. Say \"run\" and the name.",
                      placeholder: "Study time: open Notion; start a 50 minute timer; play", text: $routines)
            VStack(alignment: .leading, spacing: 8) {
                Text("Hard locks").mLabelStyle()
                LSGroup {
                    LSRow("Never delete starred chats", "Always on. The Library refuses to delete a starred chat; unstar it first.") {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary.color)
                            LSSwitch(isOn: .constant(Settings.lockKeepStarred)).allowsHitTesting(false).opacity(0.6)
                        }
                    }
                    LSRow("Never rename chats with a locked title", "A chat you named yourself has a locked title. The Assistant won't change it.") {
                        LSSwitch(isOn: $lockRename)
                    }
                    LSRow("Ask before moving chats between sectors", "The Assistant shows what it would move and waits for you to press Apply.") {
                        LSSwitch(isOn: $lockMove)
                    }
                }
                Text("A rule in a prompt is only a request. A lock is enforced by the app itself, so the Assistant can't get around it.")
                    .font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).padding(.top, 2)
            }
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
                                   folder: NSHomeDirectory() + "/Library/Application Support/Merlin/Library",
                                   localMode: true, now: now)
    }

    /// Draws every section, light and dark, to `dir` as PNGs (`settings-<section>-<light|dark>.png`). Headless: the view is
    /// hosted in an NSHostingView that is never put in a window, the library and sectors are throwaways, no Claude is called.
    /// Also draws the page as it sits inside the Library window (`settings-window-<general|sectors|min>-<mode>.png`): the "‹ Library"
    /// button, and the window's three buttons drawn where macOS puts them. The hidden Library underneath reads a throwaway library.
    @MainActor
    static func renderShots(to dir: URL) {
        _ = NSApplication.shared
        Motion.still = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-settingsshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        Library.overrideDirectory = tmp.appendingPathComponent("shared", isDirectory: true) // before anything opens Library.shared
        let library = Library(directory: tmp)
        for (title, sector) in [("Standard deviation vs variance", "Math"), ("Chain rule", "Math"), ("Closures capture variables", "Computer Science"),
                                ("Pronouncing замок", "Language"), ("Supply shifts", "Economics")] {
            library.save(ChatRecord(title: title, sector: sector, app: "Safari", quote: "", turns: [.init(question: title, answer: "An answer.")]))
        }
        let store = SectorStore(directory: tmp, library: library)
        let data = sampleData()
        // Throwaway stores for the Answers pictures: your real Context and Rules never appear in them.
        let emptyName = "com.kien.merlin.shots.empty", filledName = "com.kien.merlin.shots.filled"
        defer { for name in [emptyName, filledName] { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let emptyStore = UserDefaults(suiteName: emptyName)!
        let filledStore = UserDefaults(suiteName: filledName)!
        filledStore.set("Second-year economics student. I know calculus but not statistics yet.", forKey: Settings.contextKey)
        filledStore.set("Straight forward answer: no beating around the bush.\nUse metric units.", forKey: Settings.rulesKey)
        let modes: [(String, Bool, ColorScheme, NSAppearance)] = [("light", false, .light, NSAppearance(named: .aqua)!),
                                                                 ("dark", true, .dark, NSAppearance(named: .darkAqua)!)]
        for (mode, isDark, scheme, appearance) in modes {
            NSApp.appearance = appearance
            var pages = Section.allCases.map { (section: $0, file: $0.rawValue, answers: $0 == .rules ? filledStore : emptyStore) }
            pages.append((section: .rules, file: "rules-empty", answers: emptyStore))
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
            // Inside the Library window: at its usual size (General, Sectors) and at its smallest (920 × 520).
            for (file, section, size) in [("general", Section.general, CGSize(width: 1120, height: 700)),
                                          ("sectors", Section.sectors, CGSize(width: 1120, height: 700)),
                                          ("min", Section.general, CGSize(width: 920, height: 520))] {
                let view = inWindowShot(section: section, size: size, dark: isDark, data: data, sectorStore: store, answersStore: emptyStore)
                    .environment(\.colorScheme, scheme)
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance {
                    let host = NSHostingView(rootView: view)
                    host.appearance = appearance
                    host.frame = NSRect(origin: .zero, size: size)
                    host.settleLayout(passes: 4, interval: 0.12)
                    image = host.snapshotRep()?.cgImage
                }
                let name = "settings-window-\(file)-\(mode).png"
                guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    print("  (no image for \(name))"); continue
                }
                try? png.write(to: dir.appendingPathComponent(name))
                print("  saved \(name)")
            }
        }
    }

    /// The settings page as it sits inside the Library window, ready to draw: the window's content on its settings page, with
    /// the window's close / minimize / zoom buttons drawn in where macOS puts them (pictures only; the real ones are the window's).
    @MainActor
    static func inWindowShot(section: Section, size: CGSize, dark: Bool, data: LibrarySettingsData, sectorStore: SectorStore,
                             answersStore: UserDefaults) -> some View {
        let state = LibraryState()
        state.settingsDataSource = { data }
        state.openSettings(section: section)
        return LibraryShell(state: state, onAsk: { _, _ in }, sectorStore: sectorStore, answersStore: answersStore, shot: true, dark: dark)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) { WindowButtonStandIns(frames: windowButtonFrames(size: size)) }
    }

    /// Where macOS puts the window's three buttons, measured on a Library-style window that is built but never shown
    /// (top-left origin, points).
    @MainActor
    static func windowButtonFrames(size: CGSize) -> [CGRect] {
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.contentView?.layoutSubtreeIfNeeded()
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        let height = w.frame.height
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let b = w.standardWindowButton(type) else { return nil }
            let r = b.convert(b.bounds, to: nil)
            return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
        }
    }
}

/// Pictures only: the window's close / minimize / zoom buttons, drawn where the real ones would float.
private struct WindowButtonStandIns: View {
    let frames: [CGRect]
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                Circle().fill(Color(nsColor: colors[i % colors.count]))
                    .frame(width: min(f.width, f.height) - 2, height: min(f.width, f.height) - 2)
                    .position(x: f.midX, y: f.midY)
            }
        }
        .allowsHitTesting(false)
    }
}


/// The Shortcuts section: every command that has a shortcut, grouped by where it works, with a recorder to change each.
/// A chord two commands share is saved and both rows turn red, each with a button that jumps to the other.
private struct LSShortcuts: View {
    let store: KeybindStore
    @State private var binds: Keybinds
    @State private var recording: String?
    @State private var tabDown: Bool
    @State private var note = ""
    @State private var monitor: Any?
    /// The row that was just jumped to, and whether its border is lit right now (it blinks).
    @State private var pulseID: String?
    @State private var pulseOn = false
    /// A lone modifier pressed and let go while recording (talk can be held on one).
    @State private var lone = LoneModifierPress()
    @State private var pointOn: Bool
    @State private var pointKey: String
    private let live: Bool
    @Environment(\.lsActive) private var pageActive

    /// `recording` starts a row in the "Press keys…" state without listening to the keyboard: that's for the screenshots.
    init(store: KeybindStore = .shared, recording: String? = nil, tabDown: Bool = false) {
        self.store = store
        self.live = recording == nil
        _pointOn = State(initialValue: Settings.shared.pointToAsk)
        _pointKey = State(initialValue: Settings.shared.pointToAskKey.rawValue)
        _binds = State(initialValue: store.current)
        _recording = State(initialValue: recording)
        _tabDown = State(initialValue: tabDown)
    }

    private static func rowID(_ id: String) -> String { "shortcut-row-" + id }

    /// Fn and Right Option are what dictation apps like to take, so a talk key on one gets a note.
    static func modifierWarning(_ chord: Chord) -> String? {
        guard let key = chord.modifierKey, key == 63 || key == 61 else { return nil }
        return "Another dictation app may use this key."
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                let conflicting = binds.conflicting
                if let first = conflicting.first {
                    HStack(spacing: 12) {
                        Text("\(conflicting.count) shortcut\(conflicting.count == 1 ? "" : "s") conflict\(conflicting.count == 1 ? "s" : "")")
                            .font(.geist(13, .medium)).foregroundStyle(Theme.alert.color)
                        Spacer(minLength: 8)
                        LSSmallButton("Go to \(first.title)") { jump(to: first, proxy) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.alert.color, lineWidth: 1))
                }
                ForEach(ShortcutScope.allCases.filter { !ShortcutCommand.inScope($0).isEmpty }, id: \.self) { scope in
                    LSGroupTitle(scope.heading)
                    LSGroup {
                        ForEach(ShortcutCommand.inScope(scope)) { command in row(command, proxy) }
                        if scope == .global {
                            LSRow("Tap Shift twice", "Adds a screenshot of your screen to the open chat, for your next question. Nothing else is typed or changed.") {
                                LSSwitch(isOn: Binding(get: { binds.doubleShift },
                                                       set: { on in store.update { $0.doubleShift = on } }))
                            }
                            LSRow("Point to ask", "Hold Shift on its own, move the pointer over something, and let go to ask about it. Typing capitals and Shift-click work as always.") {
                                LSSwitch(isOn: Binding(get: { pointOn }, set: { on in pointOn = on; if live { Settings.shared.pointToAsk = on } }))
                            }
                            if pointOn {
                                LSRow("Point to ask key", "Which Shift key starts it.") {
                                    LSChoice(options: PointKey.allCases.map { ($0.rawValue, $0.title) },
                                             selection: Binding(get: { pointKey }, set: { key in
                                                 pointKey = key
                                                 if live, let k = PointKey(rawValue: key) { Settings.shared.pointToAskKey = k }
                                             }), width: 260)
                                }
                            }
                        }
                    }
                }
                if !note.isEmpty {
                    Text(note).font(.geist(12, .medium)).foregroundStyle(Theme.alert.color).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top) {
                    Text("Shortcuts need ⌘, ⌥ or ⌃ (or Tab held, for the ones that work anywhere) so typing never triggers them. Esc cancels. "
                         + "Talk can also be one modifier key held on its own: press it and let go while recording. "
                         + "If two shortcuts clash, the one higher in this list is used and the other does nothing until you change it.")
                        .font(.geist(12)).foregroundStyle(Theme.inkTertiary.color).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    LSButton("Reset all", enabled: !binds.isDefault) { stop(); note = ""; store.resetAll() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: KeybindStore.changed)) { _ in binds = store.current }
            .onReceive(NotificationCenter.default.publisher(for: .merlinShortcutsPage)) { n in
                // The tests' way of pressing a button (the buttons themselves call the same two functions).
                if let id = n.userInfo?["jump"] as? String, let c = ShortcutCommand.named(id) { jump(to: c, proxy) }
                if let id = n.userInfo?["record"] as? String, let c = ShortcutCommand.named(id) { start(c) }
            }
            .onDisappear { if live { stop() } }
            // The page is kept (hidden) behind the Library, so leaving it doesn't remove this view. Recording must still end
            // when the page goes back, the window closes or loses focus, or the app is left: otherwise the key monitor keeps
            // eating keys and `Hotkeys.paused` stays on, which silences every shortcut that works anywhere.
            .onChange(of: pageActive) { _, on in if !on { stopRecording() } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopRecording() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stopRecording() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        }
    }

    private func row(_ command: ShortcutCommand, _ proxy: ScrollViewProxy) -> some View {
        let chord = binds.chord(command)
        let isRecording = recording == command.id
        let isDefault = chord == command.defaultChord
        let clash = binds.clash(of: command)
        let red = !clash.isEmpty && !isRecording
        return VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
                    Text(command.detail).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(isRecording ? (tabDown ? "Tab + …" : "Press keys…") : chord.display)
                    .font(lsMono(13, .medium))
                    .foregroundStyle(isRecording ? Theme.inkSecondary.color : (red ? Theme.alert.color : Theme.ink.color))
                    .padding(.horizontal, 10).frame(minWidth: 70, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(isRecording ? Theme.ink.color : (red ? Theme.alert.color : Theme.hairline.color), lineWidth: 1))
                    .accessibilityLabel("\(command.title): \(chord.display)\(red ? ", clashes" : "")")
                LSButton(isRecording ? "Cancel" : "Change") { isRecording ? stop() : start(command) }
                if !isDefault && !isRecording { LSButton("Reset") { stop(); note = ""; store.reset(command) } }
            }
            if !isRecording {
                ForEach(clash.rivals) { other in
                    HStack(spacing: 10) {
                        Text("Also used by \(other.title)").font(.geist(12, .medium)).foregroundStyle(Theme.alert.color)
                        LSSmallButton("Go to \(other.title)") { jump(to: other, proxy) }
                    }
                }
                if let fixed = clash.fixedUse {
                    Text("Used by \(fixed)").font(.geist(12, .medium)).foregroundStyle(Theme.alert.color)
                }
                if let warning = Self.modifierWarning(chord) {
                    Text(warning).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .strokeBorder(Theme.alert.color, lineWidth: 2).padding(3)
            .opacity(pulseID == command.id && pulseOn ? 1 : 0).allowsHitTesting(false))
        .id(Self.rowID(command.id))
    }

    /// Scrolls to `command`'s row and blinks its border so the eye finds it. Nothing else happens: you press Change there as usual.
    private func jump(to command: ShortcutCommand, _ proxy: ScrollViewProxy) {
        stop()
        note = ""
        let reduce = Motion.reduceMotion
        withAnimation(reduce ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(Self.rowID(command.id), anchor: .center) }
        pulseID = command.id
        Task { @MainActor in
            // Reduce Motion: no blinking, the border simply stays lit for a moment.
            for _ in 0..<(reduce ? 1 : 3) {
                withAnimation(reduce ? nil : .easeInOut(duration: 0.2)) { pulseOn = true }
                try? await Task.sleep(nanoseconds: reduce ? 1_400_000_000 : 380_000_000)
                withAnimation(reduce ? nil : .easeInOut(duration: 0.2)) { pulseOn = false }
                try? await Task.sleep(nanoseconds: 260_000_000)
            }
            if !pulseOn { pulseID = nil }
        }
    }

    private func start(_ command: ShortcutCommand) {
        stop()
        note = ""
        recording = command.id
        Hotkeys.paused = true // let the window see every key, including the ones Merlin normally takes
        lone = LoneModifierPress()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let code = Int64(event.keyCode)
            let global = command.scope == .global // hold-Tab is a global-only idea
            if event.type == .flagsChanged {
                // A modifier pressed and let go on its own: talk can be held on it.
                guard command.allowsModifierOnly,
                      let key = lone.flags(ModifierKeys.down(UInt64(event.modifierFlags.rawValue))) else { return event }
                if let why = store.set(.modifierOnly(key), for: command) { note = why } else { note = ""; stop() }
                return event
            }
            if event.type == .keyUp { if code == 48 { tabDown = false }; return event }
            lone.key()
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if code == 53, mods.isEmpty { stop(); return nil } // Esc
            if global, code == 48, mods.isEmpty { tabDown = true; return nil } // Tab on its own: the first half of a hold-Tab chord
            let chord = Chord(keyCode: code, command: mods.contains(.command), shift: mods.contains(.shift),
                              option: mods.contains(.option), control: mods.contains(.control),
                              holdTab: global && CGEventSource.keyState(.hidSystemState, key: 48) && code != 48)
            // Only a chord that can never work is refused (its reason shows below); a clash is saved and shown in red.
            if let why = store.set(chord, for: command) { note = why; tabDown = false } else { note = ""; stop() }
            return nil
        }
    }

    /// `stop()`, but only when a recording is on (so an unrelated window event never touches `Hotkeys.paused`).
    private func stopRecording() { if monitor != nil || recording != nil { stop() } }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        tabDown = false
        Hotkeys.paused = false
    }
}

/// A smaller button for a row's second line.
private struct LSSmallButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.geist(12, .medium)).foregroundStyle(Theme.ink.color)
                .padding(.horizontal, 9).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
                .padding(1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.hairline.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(LSPressStyle())
    }
}

extension LibrarySettingsView {
    /// Draws the Shortcuts section in three states, light and dark, to `dir` as `shortcuts-<state>-<light|dark>.png`:
    /// the defaults, one clash (both rows red), and a row part-way through recording. Every picture has its own in-memory
    /// store (never your saved shortcuts) and no key monitor is installed.
    @MainActor
    static func renderShortcutShots(to dir: URL) {
        _ = NSApplication.shared
        Motion.still = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The clash: the Library's "New chat" is moved onto the chord "Library" opens with (a global one), so a Library row
        // and an "Anywhere" row are both red, far apart. Plus a chord macOS uses ("Move to the Bin" on ⌘C).
        let clashStore = KeybindStore(memory: nil)
        clashStore.set(KeybindStore(memory: nil).current.chord(.history), for: .libraryNewChat)
        clashStore.set(Chord(keyCode: 8, command: true), for: .libraryBin)
        let states: [(String, KeybindStore, String?)] = [("defaults", KeybindStore(memory: nil), nil), ("conflict", clashStore, nil),
                                                         ("recording", KeybindStore(memory: nil), ShortcutCommand.talk.id)]
        let modes: [(String, ColorScheme, NSAppearance)] = [("light", .light, NSAppearance(named: .aqua)!), ("dark", .dark, NSAppearance(named: .darkAqua)!)]
        for (mode, scheme, appearance) in modes {
            NSApp.appearance = appearance
            for (state, store, recording) in states {
                let view = LSShortcuts(store: store, recording: recording)
                    .frame(width: 560, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 32)
                    .frame(width: 632, height: 1180, alignment: .topLeading)
                    .background(Theme.canvas.color)
                    .environment(\.lsShot, true)
                    .environment(\.colorScheme, scheme)
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance {
                    let host = NSHostingView(rootView: view)
                    host.appearance = appearance
                    host.frame = NSRect(origin: .zero, size: CGSize(width: 632, height: 1180))
                    host.settleLayout(passes: 4, interval: 0.12)
                    image = host.snapshotRep()?.cgImage
                }
                let name = "shortcuts-\(state)-\(mode).png"
                guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    print("  (no image for \(name))"); continue
                }
                try? png.write(to: dir.appendingPathComponent(name))
                print("  saved \(name)")
            }
        }
        // The same section inside the Library window at its smallest (920 × 520), in the conflict state: "Talk to Merlin" and
        // "Library" share a chord. The window's own page reads KeybindStore.shared, which is in memory only for this flag.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-shortcutshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sectors = SectorStore(directory: tmp, library: Library(directory: tmp))
        KeybindStore.shared.resetAll()
        KeybindStore.shared.set(KeybindStore(memory: nil).current.chord(.history), for: .talk)
        defer { KeybindStore.shared.resetAll() }
        for (mode, scheme, appearance) in modes {
            NSApp.appearance = appearance
            let size = CGSize(width: 920, height: 520)
            let view = inWindowShot(section: .shortcuts, size: size, dark: mode == "dark", data: sampleData(), sectorStore: sectors, answersStore: .standard)
                .environment(\.colorScheme, scheme)
            var image: CGImage?
            appearance.performAsCurrentDrawingAppearance {
                let host = NSHostingView(rootView: view)
                host.appearance = appearance
                host.frame = NSRect(origin: .zero, size: size)
                host.settleLayout(passes: 4, interval: 0.12)
                image = host.snapshotRep()?.cgImage
            }
            let name = "settings-window-shortcuts-conflict-\(mode).png"
            guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("  (no image for \(name))"); continue
            }
            try? png.write(to: dir.appendingPathComponent(name))
            print("  saved \(name)")
        }
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
